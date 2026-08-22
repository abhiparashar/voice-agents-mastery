# Serving ASR: Runtimes, Batching, and Cost per Audio Hour

**What you'll be able to do after this:** choose a runtime from a stated constraint
rather than by habit; explain why batching a streaming model can *increase* latency and
when it does not; compute concurrent streams per GPU from VRAM and real-time factor;
and build the self-host-versus-vendor cost model with the arithmetic visible so the
crossover point is a number instead of an opinion.

---

## 1. Intuition

Training a recogniser is a research problem. Serving one is a bin-packing problem with
a deadline, and almost every interesting decision is a consequence of one fact:
**streaming inference wants small units of work, and hardware wants large ones.**

A GPU is efficient when it is given a big matrix multiplication. A voice agent hands
you 320 samples every 20 milliseconds, per session, from hundreds of sessions that
started at unrelated times. Reconciling those two facts is the entire discipline. Get
it right and one GPU serves hundreds of concurrent conversations; get it wrong and it
serves a dozen, or it serves hundreds with 400 ms of added latency that nobody can
locate.

Three consequences shape everything in this chapter.

**Batching is not free in a real-time system.** In offline processing you batch because
throughput is all that matters. In streaming you batch by *waiting*, and waiting is
latency you charge to every request in the batch. There is an optimum, it is small, and
it depends on your arrival rate — which means it is a tuned parameter, not a default.

**The runtime matters more than the hardware.** The same Whisper weights served through
PyTorch, CTranslate2 and ggml differ by large factors in throughput and memory,
because most of the win is in kernel fusion, quantisation and memory management rather
than in raw FLOPs. Choosing the runtime is usually a bigger lever than choosing the
accelerator.

**Quantisation is a quality change, not a speed setting.** int8 is routinely described
as free. It is not: it changes model outputs, and whether that change matters is an
empirical question about *your* audio. The rule is unconditional — re-measure WER after
quantising, on your golden set, through your audio path
([`07-evaluation.md`](07-evaluation.md)).

---

## 2. Rigour

### 2.1 Real-time factor, and why it is not enough

**Real-time factor** is processing time divided by audio duration:

$$\mathrm{RTF} = \frac{t_{\text{process}}}{t_{\text{audio}}}$$

RTF of 0.1 means ten seconds of audio processed in one second. Its usefulness is
capacity planning: one worker can sustain roughly $1/\mathrm{RTF}$ concurrent
real-time streams *if* the work packs perfectly.

It is nonetheless the wrong headline metric for a voice agent, for three reasons.

**RTF says nothing about latency.** A model with RTF 0.05 that requires the entire
utterance before producing output has excellent RTF and unusable latency. Whisper is
exactly this shape.

**RTF is measured at the wrong batch size.** Published figures are usually offline,
batched, on long files. Streaming inference on 200 ms chunks has far worse effective
RTF because per-call overhead — kernel launches, state marshalling, Python — no longer
amortises.

**RTF ignores the padding tax.** For a fixed-window model, RTF computed on 30-second
files is an optimistic lie about 3-second turns
([`04-attention-and-whisper.md`](04-attention-and-whisper.md) §2.2).

So quote RTF for capacity and quote emission latency for product
([`05-streaming-asr.md`](05-streaming-asr.md) §2.5). They are different numbers with
different uses, and conflating them is how a deployment ends up fast and unresponsive
at once.

### 2.2 Runtimes: what each one actually buys

| Runtime | Mechanism | Best for | Cost |
|---|---|---|---|
| **PyTorch eager** | reference execution | research, debugging | slowest; highest memory |
| **ONNX Runtime** | graph optimisation, fused kernels, broad backends | portability, CPU, mixed hardware | export friction on dynamic control flow |
| **CTranslate2** (`faster-whisper`) | purpose-built Transformer inference: int8/int8-float16, layer fusion, custom memory allocator | encoder-decoder ASR on CPU or single GPU | Transformer architectures only |
| **TensorRT** | ahead-of-time kernel selection and fusion per GPU | maximum NVIDIA throughput | engine build per model *and* per GPU; brittle |
| **ggml / whisper.cpp** | hand-written C kernels, quantised weights, Metal/Accelerate | Apple Silicon, embedded, no Python | fewer models; manual optimisation |
| **MLX** | Apple unified-memory arrays with lazy evaluation | Apple Silicon GPU without CUDA | Apple only; younger ecosystem |
| **vLLM / SGLang** | continuous batching, paged KV cache | LLM serving; relevant to your LLM stage | not built for ASR encoders |

The pattern worth extracting: the large wins come from *specialisation*. CTranslate2
beats PyTorch not because it has better mathematics but because it knows it is running
a Transformer and can fuse, quantise and manage memory accordingly. The corollary is
that specialised runtimes constrain what you can deploy — a custom architecture may
have no path to them, which is a real consideration when choosing a model.

### 2.3 Quantisation, honestly

| Precision | Memory vs fp32 | Typical use |
|---|---|---|
| fp32 | 1× | reference |
| fp16 / bf16 | 0.5× | GPU default; bf16 has more exponent range, less mantissa |
| int8 | 0.25× | CPU inference; large speedup from integer kernels |
| int8-float16 | ~0.25× weights | int8 weights, fp16 compute — common CTranslate2 choice |
| int4 | 0.125× | aggressive; more likely to shift outputs measurably |

Two things to understand rather than assume.

**Where the speedup comes from depends on the bottleneck.** For a memory-bandwidth-bound
model, halving weight size roughly halves the time spent moving weights, so the
speedup approaches the compression ratio. For a compute-bound model you gain only if
the hardware has faster integer paths. Encoder-decoder ASR at small batch is largely
bandwidth-bound, which is why int8 helps so much there.

**Accuracy degradation is not uniform, and the average hides it.** Quantisation
typically costs little on clean wideband speech and considerably more where the model
was already uncertain — accents, noise, narrowband telephony, domain vocabulary. So an
aggregate WER check can pass while your hardest and most valuable traffic regresses.
Evaluate quantisation *segmented* by condition (§5 of
[`07-evaluation.md`](07-evaluation.md)), not on a single aggregate.

### 2.4 The batching problem

For an offline batch job, batching is unambiguously good. For streaming, the cost
structure changes.

**Static batching** collects $B$ requests, runs them together, returns all results.
Latency added to the *first* arrival is the time to collect the remaining $B-1$. At
arrival rate $\lambda$, the expected wait for the first of a batch is approximately

$$\mathbb{E}[\text{wait}] \approx \frac{B-1}{\lambda}$$

At $\lambda = 50$ chunks/s and $B = 8$, that is 140 ms — a substantial fraction of the
turn budget ([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md)),
paid so the GPU can be more efficient. Whether that is a good trade is arithmetic, not
taste, and it depends entirely on $\lambda$: at high concurrency the wait vanishes and
batching is nearly free; at low concurrency it is pure loss. **The same batch size is
correct at scale and wrong in a pilot.**

**Dynamic batching** caps the wait: fill the batch or fire after $T_{\max}$, whichever
comes first. This is the right default because it degrades gracefully — efficient when
busy, low-latency when idle. Set $T_{\max}$ from the budget, typically 10–30 ms for
chunk-level ASR.

**Chunk-level batching across sessions** is the shape that works for streaming
encoders: every session produces a chunk every $C$ milliseconds, so you gather all
chunks due in the current window and run one batched encoder pass. Sessions are
naturally phase-shifted, which is precisely why $T_{\max}$ matters.

The hard constraint that beginners miss: **batched streaming inference requires
per-session state to be batched too.** A streaming transducer carries encoder state per
session, so the batch is a gather of heterogeneous states, a forward pass, and a
scatter back. Getting that state marshalling wrong is the most common source of subtle
cross-session contamination bugs — session A's audio influencing session B's output —
and it is why the exported-graph designs in `sherpa-onnx` make state an explicit
tensor rather than hidden object state.

### 2.5 Concurrency arithmetic per GPU

Two independent limits; the binding one is whichever is smaller.

**VRAM limit.**

$$N_{\text{vram}} = \frac{V_{\text{total}} - V_{\text{weights}} - V_{\text{reserve}}}{V_{\text{per-session}}}$$

Weights are loaded once and shared. Per-session cost is activations plus decoder state
plus, for a streaming model, carried encoder state.

**Compute limit.**

$$N_{\text{compute}} = \frac{\rho_{\max}}{\mathrm{RTF}_{\text{streaming}}}$$

with $\rho_{\max} \approx 0.7$ from the queueing argument
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md) §2.5)
— not 1.0, because running a real-time service at full utilisation destroys the tail.
Note that $\mathrm{RTF}_{\text{streaming}}$ must be the *streaming, batched* figure
from §2.1, not a published offline number.

Worked example with stated assumptions (substitute measurements before believing it):
a 24 GiB GPU, a 3 GiB quantised model, 1 GiB reserve, 40 MiB per session,
streaming RTF 0.02 at the batch size you actually run.

$$N_{\text{vram}} = \frac{24 - 3 - 1}{0.04} = 500, \qquad
N_{\text{compute}} = \frac{0.7}{0.02} = 35$$

Compute binds at 35, and it binds by more than an order of magnitude. This is the
usual situation for ASR and it has a direct operational implication: **buying more
VRAM does not increase ASR concurrency.** Teams provision large-memory GPUs for ASR
and are surprised. The levers that matter are RTF (runtime, quantisation, model size)
and batching efficiency.

### 2.6 Cold starts and warm pools

Model load time is dead time, and for a voice agent it lands in the worst place: the
first turn of a call.

| Phase | Typical cost driver |
|---|---|
| Download weights | network, once per node if cached |
| Deserialise / build | format-dependent; TensorRT engine build is minutes, not seconds |
| Allocate and warm | first call triggers lazy allocation and autotuning |

Three mitigations, and the third is the one people forget. **Warm pools**: keep $k$
processes with the model resident, sized from your scale-up lead time. **Bake weights
into the image or a local cache** so scale-up does not depend on a model registry.
**Force a warm-up inference at startup** before marking the worker ready — otherwise
the readiness probe passes and the first real request pays the autotuning cost. That
last one converts a mysterious p99 spike after every deploy into nothing.

Report cold and warm latency as separate distributions, and track *fraction of turns
served cold* as its own metric. A single blended p95 over a bimodal distribution is
uninterpretable.

---

## 3. From scratch

The decision that actually needs arithmetic is self-host versus vendor. Below is the
model, with every assumption named. Standalone, stdlib only.

```python
"""Self-host vs vendor cost per 1000 audio-minutes, with the arithmetic exposed."""
from dataclasses import dataclass

@dataclass
class SelfHost:
    gpu_hourly_usd: float       # instance price, on-demand or amortised reserved
    streams_per_gpu: int        # from the COMPUTE limit in 2.5, not the VRAM limit
    utilisation: float          # long-run average; NOT the 0.7 tail ceiling
    ops_overhead: float = 0.30  # monitoring, on-call, upgrades, as a fraction

    def usd_per_1000_min(self) -> float:
        # One GPU delivers streams_per_gpu * 60 audio-minutes per wall-clock hour
        # at full occupancy; multiply by realised utilisation.
        audio_min_per_hour = self.streams_per_gpu * 60 * self.utilisation
        raw = self.gpu_hourly_usd / audio_min_per_hour * 1000
        return raw * (1 + self.ops_overhead)

@dataclass
class Vendor:
    usd_per_minute: float
    discount: float = 0.0       # committed-use or volume discount

    def usd_per_1000_min(self) -> float:
        return self.usd_per_minute * (1 - self.discount) * 1000

def breakeven_minutes(sh: SelfHost, v: Vendor, fixed_monthly_usd: float) -> float:
    """Monthly minutes at which self-hosting becomes cheaper, including the fixed
    engineering cost of owning the stack. Below this, the vendor wins on cost."""
    delta_per_min = (v.usd_per_1000_min() - sh.usd_per_1000_min()) / 1000
    if delta_per_min <= 0:
        return float("inf")     # self-hosting is never cheaper at these rates
    return fixed_monthly_usd / delta_per_min

if __name__ == "__main__":
    # ---- ASSUMPTIONS. Every one of these must be replaced with a measurement
    # before the output means anything. They are illustrative, not prices.
    sh = SelfHost(gpu_hourly_usd=0.75, streams_per_gpu=35, utilisation=0.45)
    v = Vendor(usd_per_minute=0.0043)
    fixed = 4000.0              # ~ a fraction of one engineer, monthly

    print(f"self-host : ${sh.usd_per_1000_min():7.2f} per 1000 audio-min "
          f"(GPU ${sh.gpu_hourly_usd}/h, {sh.streams_per_gpu} streams, "
          f"util {sh.utilisation:.0%}, ops +{sh.ops_overhead:.0%})")
    print(f"vendor    : ${v.usd_per_1000_min():7.2f} per 1000 audio-min "
          f"(${v.usd_per_minute}/min)")
    be = breakeven_minutes(sh, v, fixed)
    print(f"breakeven : {be:,.0f} audio-min/month "
          f"(= {be/60:,.0f} audio-hours, {be/43200:.2f}x a fully busy 24/7 stream)")

    print("\nsensitivity -- streams per GPU is the dominant term:")
    for s in (10, 20, 35, 60, 100):
        alt = SelfHost(0.75, s, 0.45)
        print(f"  {s:3d} streams -> ${alt.usd_per_1000_min():7.2f} / 1000 min")

    print("\nsensitivity -- utilisation punishes over-provisioning:")
    for u in (0.15, 0.30, 0.45, 0.70):
        alt = SelfHost(0.75, 35, u)
        print(f"  util {u:.0%} -> ${alt.usd_per_1000_min():7.2f} / 1000 min")
```

Measured output `[MEASURED]` (from the stated assumptions, which are not prices):

```
self-host : $   1.03 per 1000 audio-min (GPU $0.75/h, 35 streams, util 45%, ops +30%)
vendor    : $   4.30 per 1000 audio-min ($0.0043/min)
breakeven : 1,223,895 audio-min/month (= 20,398 audio-hours, 28.33x a fully busy 24/7 stream)

sensitivity -- streams per GPU is the dominant term:
   10 streams -> $   3.61 / 1000 min
   20 streams -> $   1.81 / 1000 min
   35 streams -> $   1.03 / 1000 min
   60 streams -> $   0.60 / 1000 min
  100 streams -> $   0.36 / 1000 min

sensitivity -- utilisation punishes over-provisioning:
  util 15% -> $   3.10 / 1000 min
  util 30% -> $   1.55 / 1000 min
  util 45% -> $   1.03 / 1000 min
  util 70% -> $   0.66 / 1000 min
```

Three readings, and the second is the one that decides real architectures.

**Per minute, self-hosting is roughly 4× cheaper** under these assumptions: $1.03
versus $4.30 per 1000 audio-minutes. That is the number people quote when they argue
for self-hosting, and taken alone it is misleading.

**The fixed engineering cost sets a volume floor.** Owning the stack costs something
every month whether you serve one minute or a million — monitoring, upgrades, on-call,
the person who understands §2.4. At an assumed \$4 000/month that floor puts breakeven
at **1.22 million audio-minutes per month**, about 20 400 audio-hours, equivalent to
**28 continuously busy streams around the clock**. Below that, the vendor is cheaper
*despite* costing 4× per minute, because you cannot amortise the fixed cost. This is
why "self-hosting is cheaper" and "we should use the vendor" are simultaneously true
for most teams, and why the only honest form of this argument includes a volume.

**Both sensitivity tables collapse the advantage fast.** At 10 streams per GPU
self-hosting costs \$3.61 per 1000 minutes against the vendor's \$4.30 — the 4×
advantage becomes 1.2×, and the fixed cost then makes self-hosting strictly worse at
any realistic volume. Same story for utilisation: at 15% realised utilisation, \$3.10
is near parity. So the entire case for self-hosting rests on achieving *both* high
concurrency per GPU *and* high realised utilisation — which is exactly the engineering
in §2 (padding elimination, quantisation, chunk-level batching) plus the capacity
management in §5. Neither is free, and a team that has not done them is comparing a
hypothetical cost against a real price.

Substitute your own measured `streams_per_gpu`, your own realised utilisation, and
current published prices before making any decision. `[UNVERIFIED PRICE]` applies to
the GPU hourly rate, the vendor per-minute rate and the fixed monthly cost above; they
are placeholders with plausible magnitudes, not quotes. The *structure* of the model —
per-minute advantage against a fixed-cost floor, with concurrency and utilisation as
the dominant sensitivities — is the part that transfers.

---

## 4. How production does it

**`k2-fsa/sherpa-onnx`** is the clearest open reference for streaming ASR serving:
transducer models exported as separate encoder, decoder and joiner ONNX graphs, with
explicit state tensors carried across chunks, plus WebSocket servers for streaming and
offline recognition. The design lesson from §2.4 is visible in its interfaces — state
is data, not hidden object state, which is exactly what makes cross-session batching
safe.

**NVIDIA Riva** packages ASR/TTS as Triton-backed services with TensorRT engines,
dynamic batching and gRPC/HTTP interfaces. It is the reference for what a
fully-engineered on-prem GPU speech stack looks like, and the reason to study it even
if you do not deploy it is its explicit separation of batching policy from model.

**`SYSTRAN/faster-whisper`** is the practical default for Whisper-family serving,
and the pattern that makes it work in production is not the runtime alone: it is
VAD-segmenting first ([`../03-turn-taking/01-vad.md`](../03-turn-taking/01-vad.md)),
batching segments of similar duration, and thereby eliminating the padding tax. That
combination — WhisperX's architecture — is worth more than any quantisation setting.

**Vendor streaming APIs** are, from a serving perspective, someone else's solution to
this chapter. What you are buying is their batching, their warm pools and their
capacity headroom. What you give up is control over the tail: you cannot see their
queue, and their p99 becomes yours.

**Model registries and image baking.** Production deployments do not download weights
at startup (§2.6). Weights are baked into the container image or pulled to a local
cache by an init container, and the readiness probe fires only after a warm-up
inference.

---

## 5. At scale

**The padding tax is the first thing to fix, and it is worth more than everything
else.** For a fixed-window model serving short conversational turns, most of your
compute is processing silence. VAD-segment, then batch by similar duration. This is
close to an order of magnitude on a voice-agent workload and it requires no new
hardware.

**Utilisation is bimodal and that is the real cost problem.** Contact-centre traffic
has a busy hour several times the daily mean, so a fleet sized for peak sits idle
overnight — and §3 shows cost per minute scales inversely with realised utilisation.
The mitigations are the usual ones with a real-time twist: autoscale on in-flight
sessions rather than CPU, place batch transcription workloads on the same fleet to
soak up trough capacity, and use vendor APIs for overflow above your owned capacity so
you pay marginal rates only at the peak.

**Multi-tenancy needs explicit fairness.** One tenant sending 500 concurrent streams
will starve everyone else on a shared batching queue. Per-tenant admission control and
weighted queueing are not refinements; without them your SLO is defined by your noisiest
customer.

**Right-size the model per use case, because it is the cheapest lever.** A digit-string
confirmation does not need `large-v3`; a `tiny.en` or a small transducer will do, at a
fraction of the RTF, and §2.5 shows concurrency is compute-bound. Routing by intent to
different model sizes is unglamorous and frequently halves the bill.

**Instrument the serving layer separately from the model.** Queue depth, batch size
distribution, RTF at the batch size actually used, cold-start fraction and per-tenant
concurrency. Model quality metrics ([`07-evaluation.md`](07-evaluation.md)) will not
tell you that your batch collector is waiting 80 ms because arrival rate dropped
overnight — and that is precisely the class of bug that shows up as "latency is worse
at 3am", which sounds impossible until you understand §2.4.

---

## 6. Exercises

**E2.8.1** Run the §3 model with your own measured `streams_per_gpu` and current
published prices for a GPU instance and a hosted ASR API. Report the breakeven, then
identify which single assumption most changes the answer.

**E2.8.2** Derive the expected wait for the first arrival in a static batch of size $B$
at Poisson arrival rate $\lambda$, and verify it by simulation. Then compute, for
$\lambda = 20$ and $\lambda = 200$ chunks/s, the batch size at which added wait exceeds
30 ms.

**E2.8.3** Implement dynamic batching with a $T_{\max}$ cap in front of a stub model.
Measure the achieved batch-size distribution and added latency at three arrival rates,
and show that it degrades gracefully where static batching does not.

**E2.8.4** Compute the padding waste for a fixed 30-second-window model over a
realistic turn-duration distribution of your choosing. Then compute the batching gain
from grouping VAD segments into duration buckets, and state the total speedup.

**E2.8.5** Quantise a model to int8 and evaluate WER *segmented* by condition: clean
wideband, telephony-band, accented, and utterances containing domain entities. Report
each separately and state whether you would ship it.

**E2.8.6** For a GPU of your choosing, measure or estimate both limits in §2.5 and
identify which binds. Then find the change that moves the binding limit and quantify
its effect on cost per 1000 minutes using §3.

**E2.8.7** Design the batched state marshalling for a streaming transducer: what must be
gathered, what must be scattered, and what test would catch cross-session
contamination. Write the test's assertion precisely.

---

## 7. Interview drill

> "You are serving Whisper large-v3 on one A10 for a voice agent. You handle 12
> concurrent calls before latency degrades. Product wants 100. Budget is flat. Go."

The expected failure is to reach for hardware or quantisation immediately. The
diagnosis has to come first, because §2.5 says the binding limit is usually compute and
the dominant waste on this specific workload is usually padding.

Start by establishing where the work goes: measure the turn-duration distribution and
compute the padding tax. If mean turn duration is around 3 seconds against a fixed
30-second window, roughly 90% of the GPU is processing silence — and that alone is
close to the required factor. So the first action is VAD segmentation plus
duration-bucketed batching, no new hardware and no accuracy change, since you are
removing padding rather than altering the model.

Then work the remaining levers in order of benefit per unit of risk, naming the cost of
each. **Model right-sizing**: `large-v3` is probably unnecessary for most turns; route
by intent, keep the large model for hard audio, and measure entity WER
([`07-evaluation.md`](07-evaluation.md)) rather than aggregate WER to confirm the
smaller model is adequate where it is used. **Runtime and quantisation**: CTranslate2
int8 or int8-float16, with WER re-measured *segmented by condition* per §2.3, because
the aggregate will hide degradation on exactly the telephony and accented traffic you
care about. **Dynamic chunk-level batching** with a $T_{\max}$ cap sized from the
latency budget, which at 100 concurrent calls costs almost nothing in wait time (§2.4)
— note that batching gets *cheaper* as you scale, so it is the right lever precisely at
the target concurrency. **Warm-up on startup and warm pools** so the deploy does not
reintroduce a p99 cliff (§2.6).

The candidate should also name what they will *not* do and why: not switch to a
streaming transducer, because although it is the architecturally correct answer for
latency ([`03-rnnt-transducer.md`](03-rnnt-transducer.md)) it is a model change with a
quality-validation cost, and the padding fix delivers the required factor without it.
Being able to identify the correct-but-out-of-scope answer is part of the answer.

Close on verification: state the acceptance criteria as concurrent calls at a p95
`eou_to_ttfa` target with entity WER not regressed beyond a stated margin, measured on
the golden set through the production audio path. A capacity claim without a paired
quality claim is how these projects ship a regression.

---

## Sources

- `SYSTRAN/faster-whisper` and `OpenNMT/CTranslate2` — the int8 / int8-float16 quantisation options, layer fusion and memory management referenced in §2.2–§2.3.
- `ggml-org/whisper.cpp` — ggml quantised formats and Metal/Accelerate backends.
- `k2-fsa/sherpa-onnx` — exported encoder/decoder/joiner graphs with explicit state tensors, and the streaming WebSocket servers described in §4.
- NVIDIA Riva documentation and `triton-inference-server` — dynamic batching and TensorRT engine deployment for speech services.
- `m-bain/whisperX` — VAD segmentation plus duration batching, the padding-tax mitigation in §4 and §5.
- `vllm-project/vllm`, `sgl-project/sglang` — continuous batching and paged attention; relevant to the LLM stage in [`../05-llm-layer/04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md) rather than to ASR encoders.
- Little, J. D. C. (1961) and the utilisation/tail argument in [`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md) §2.5, which supplies the $\rho_{\max} \approx 0.7$ used in §2.5.
- `[UNVERIFIED PRICE]`: the GPU hourly rate and vendor per-minute rate in §3 are illustrative placeholders, not quotes. Verify current prices directly before using the model.
- All `[MEASURED]` values in §3 are outputs of the listed code under its stated assumptions, run on Apple M5 / macOS 26.5.2, CPython 3.12.
