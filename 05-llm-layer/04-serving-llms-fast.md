# Serving LLMs Fast

**What you'll be able to do after this:** decompose `ttft_llm` into prefill and queueing and
attack each separately; explain from the roofline why decode is 69× more expensive per token
than prefill and why batching is therefore nearly free until it is catastrophic; predict
whether speculative decoding will help you before implementing it; choose a serving engine
configuration from measured TTFT/TPOT curves; and know what structured output and local Apple
Silicon serving really cost.

---

## 1. Intuition

An LLM request has two phases with opposite performance characteristics, and almost every
serving decision follows from that asymmetry.

**Prefill** processes the whole prompt at once. It is a stack of large matrix multiplications,
so the accelerator is compute-bound and per-token cost is tiny — measured below at 0.092 ms
per token. Prefill determines `ttft_llm`, and it is proportional to prompt length, which is
why [`02-context-and-memory.md`](02-context-and-memory.md) is really a chapter about latency.

**Decode** produces one token at a time. Each step reads the entire weight matrix from memory
to compute one column of output, so the accelerator is memory-bandwidth-bound and mostly idle
in arithmetic terms — measured below at 6.37 ms per token, **69× the per-token cost of
prefill**. Decode determines how long the reply takes to finish, and it is the reason batching
exists: if you are reading the weights anyway, you may as well serve 16 users with that read.

For voice the shape of the traffic is peculiar and favourable. Replies are short (~60 tokens,
because §2.3 of [`01-prompting-for-speech.md`](01-prompting-for-speech.md) demands it), prompts
are long but ~90% prefix-cache hits, and only the *first clause* is on the critical path —
once audio starts, the rest of the tokens only need to keep ahead of the mouth, which needs
roughly 3–5 tokens per second against a decoder that produces 150+. **You are optimising
`ttft_llm`, not throughput per stream**, and the two want different configurations.

---

## 2. Rigour

### 2.1 The two phases, measured

`[MEASURED]` GPT-2 124M, PyTorch on Apple M5 MPS, batch 1. Absolute numbers are for this tiny
model on a laptop; the ratios are what transfer.

| Prompt tokens | Prefill | Throughput | Per token |
|---|---|---|---|
| 128 | 12.04 ms | 10 634 tok/s | 0.094 ms |
| 256 | 21.99 ms | 11 642 tok/s | 0.086 ms |
| 512 | 43.54 ms | 11 760 tok/s | 0.085 ms |
| 1024 | 94.56 ms | 10 829 tok/s | 0.092 ms |
| 2048 | 205.19 ms | 9 981 tok/s | 0.100 ms |

Prefill is linear with a slight superlinear drift from attention's $O(n^2)$ term, which at
these lengths is small compared to the linear feed-forward work. Decode of a single token with
a warm cache costs **6.37 ms**, so:

$$
\frac{t_{\text{decode/token}}}{t_{\text{prefill/token}}} = \frac{6.37}{0.092} = 69\times
$$

The explanation is arithmetic intensity. A decode step performs $O(P)$ FLOPs while reading
$O(P)$ bytes of weights, so intensity is ~1–2 FLOP/byte and the hardware — which wants
hundreds — sits idle waiting on memory. Prefill over $n$ tokens performs $O(nP)$ FLOPs for the
same $O(P)$ byte read, so its intensity scales with $n$. **Batching decode raises intensity the
same way prefill does**, which is why batch 16 costs barely three times batch 1.

### 2.2 Batching: nearly free, then a cliff

`[MEASURED]` decode step latency by batch size, context 256:

| Batch | Step latency | Aggregate | Latency vs batch 1 |
|---|---|---|---|
| 1 | 5.07 ms | 197.4 tok/s | 1.00× |
| 2 | 5.68 ms | 352.2 tok/s | 1.12× |
| 4 | 6.93 ms | 577.3 tok/s | 1.37× |
| 8 | 9.65 ms | 829.1 tok/s | 1.90× |
| **16** | 16.98 ms | **942.2 tok/s** | 3.35× |
| 32 | 45.69 ms | 700.4 tok/s | 9.02× |

Three regimes. Below batch 8, doubling the batch costs 12–37% more latency and buys 70–80%
more throughput — nearly free. At 16 this machine reaches peak aggregate throughput. Past that
the curve inverts: batch 32 is *slower in aggregate* than batch 16, and at batch 64 the machine
thrashes (measured between 238 ms and 2.6 s per step across runs, which is the signature of
memory pressure rather than a scaling law).

The cliff is a memory-capacity fact, not a mystery. KV cache bytes per token are

$$
2 \times L \times H_{kv} \times d_{head} \times \text{bytes}
$$

For GPT-2 in fp32 that is $2\times12\times12\times64\times4 = 72$ KiB/token, so batch 64 at
context 256 needs 1.15 GiB of KV alone on a 16 GiB shared-memory machine that is also holding
weights, activations and the OS. For Llama-3-8B with grouped-query attention
($L=32$, $H_{kv}=8$, $d_{head}=128$, fp16) it is 128 KiB/token `[INFERENCE — arithmetic from
the published config]`, so a single 4096-token conversation holds 512 MiB and 32 of them hold
16 GiB. **KV cache, not weights, is what limits concurrency**, and it is why long contexts
reduce the number of sessions per GPU
([`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)).

### 2.3 Prefix caching is the single biggest lever

Covered mechanically in [`02-context-and-memory.md`](02-context-and-memory.md) §2.4; here is
what it does to a *server*. Measured earlier on the same machine: a 1024-token prefix plus 128
new tokens costs 148.08 ms cold and 22.10 ms with the cache hit — **85.1%** saved; at 2048 + 64
the saving is **94.0%** `[MEASURED]`.

At the fleet level this is capacity, not just latency. In the §3 simulation, an engine serving
1200-token prompts at a 90% cache hit sustains 10 turns/s with `ttft_llm` p50 of 15 ms; the
same engine with a cold cache cannot hold the TTFT budget even at 4 turns/s. The prefix cache
multiplies the number of conversations a GPU can hold, so the operational rules from
[`02-context-and-memory.md`](02-context-and-memory.md) — stable prefix first, no per-session
data in the system prompt, session affinity — are capacity-planning decisions.

### 2.4 Continuous batching and chunked prefill

Static batching collects requests, runs them as a group, and admits nobody until the whole
group finishes. Two failures follow: a request arriving just after a batch starts waits for
the entire batch, and the batch runs until its *longest* member completes, so short replies
are held hostage.

Continuous batching (Orca's "iteration-level scheduling", 2022) makes admission and eviction
decisions **every decode step**: finished sequences free their slot immediately, and waiting
requests join at the next step. For voice, where replies vary from 8 to 120 tokens, this is
the difference between a usable and an unusable engine — measured in §3 as `ttft_llm` p50 of
489 ms versus 15 ms.

Chunked prefill addresses the remaining problem: a long prefill monopolises the engine, so
every decoding stream stalls for its duration, and users mid-sentence hear a gap. Splitting the
prefill into fixed chunks interleaved with decode steps bounds that stall. It is a genuine
trade — the prefilling request waits longer for its own first token — so it pays only when
prefills are large:

| Scenario | Continuous TTFT p50 | Chunked TTFT p50 | Continuous TPOT p95 | Chunked TPOT p95 |
|---|---|---|---|---|
| 90% cache hit (119 tokens) | 15 ms | 24 ms | 16.89 ms | 16.65 ms |
| 0% cache hit (1200 tokens) | 116 ms | 178 ms | 41.27 ms | **33.69 ms** |

`[MEASURED]` from §3. With a warm prefix cache chunking buys nothing and costs 9 ms; with cold
1200-token prefills it cuts TPOT p95 by 18% at the cost of 62 ms of TTFT. Turn it on when
prefills are long, off when the cache is doing its job.

### 2.5 Speculative decoding: predict before you implement

A cheap draft model proposes $k$ tokens; the target model verifies all $k$ in **one** forward
pass and accepts the longest prefix that matches what it would have produced. Output is
provably identical to the target's own greedy decoding — verified in the measurement below.

Expected tokens per round with acceptance probability $\alpha$:

$$
E[\text{tokens}] = \frac{1 - \alpha^{k+1}}{1 - \alpha}
$$

Cost per round is $k$ draft steps plus one target step, so with $r = c_{\text{draft}} /
c_{\text{target}}$ the speedup is

$$
S = \frac{1}{kr + 1}\cdot\frac{1 - \alpha^{k+1}}{1 - \alpha}
$$

`[MEASURED]` GPT-2 124M target, DistilGPT-2 82M draft, greedy, 48 tokens, M5:

| $k$ | Wall clock | Acceptance $\alpha$ | $E[\text{tokens}]$ | Predicted $S$ | Measured $S$ | Output identical |
|---|---|---|---|---|---|---|
| 2 | 971 ms | 0.44 | 1.64 | 0.78 | 0.33 | yes |
| 3 | 731 ms | 0.46 | 1.77 | 0.66 | 0.44 | yes |
| 4 | 1125 ms | 0.39 | 1.64 | 0.51 | 0.29 | yes |
| 6 | 1523 ms | 0.23 | 1.31 | 0.30 | 0.21 | yes |
| 8 | 1503 ms | 0.24 | 1.32 | 0.24 | 0.21 | yes |

Baseline greedy decoding took 322.5 ms. **Every configuration is slower**, and the formula said
so in advance: measured $r = c_{\text{draft}}/c_{\text{target}} = 3.11/5.60 = 0.56$, because
DistilGPT-2 has half the layers of GPT-2 and is nowhere near cheap enough. Setting $S > 1$ at
$\alpha = 0.44$, $k = 2$ requires $r < 0.32$.

The rule to carry away: **speculative decoding needs both a high acceptance rate and a draft
model roughly an order of magnitude cheaper than the target.** Production pairs (a 1B draft
for a 70B target, or an n-gram/Medusa head) satisfy that; a "small version of the same family"
often does not. Also note $\alpha$ falling with $k$ — the further the draft runs unsupervised,
the more it diverges — so long draft windows are counterproductive. Measured $S$ trails
predicted $S$ because each round pays Python dispatch and KV-cache-rollback overhead that the
formula ignores; a fused implementation closes most of that gap, but not the sign.

### 2.6 Model size, and what voice actually needs

| Model scale | Typical TTFT contribution | Where it is right for voice |
|---|---|---|
| 1–3B | lowest | classification, routing, slot extraction, summarisation off the critical path |
| 7–14B | low | the conversational model for most scoped agents |
| 30–70B | moderate | complex reasoning, ambiguous multi-tool flows |
| Frontier hosted | highest and least controllable | when quality dominates and you accept the tail |

The productive move is **not** picking one model but splitting the workload. The turn-by-turn
conversational model must be small and fast; summarisation
([`02-context-and-memory.md`](02-context-and-memory.md) §2.8), post-call extraction, and
evaluation ([`../08-eval-safety/02-simulation-and-load.md`](../08-eval-safety/02-simulation-and-load.md))
run on separate pools where latency is irrelevant. Quantisation (int8/int4) reduces the weight
read that dominates decode and therefore helps decode more than prefill — and, as with ASR
([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md)), quality must be re-measured on
*your* task, never assumed from a benchmark table.

### 2.7 Structured output without a latency tax

Constrained decoding masks the logits to the tokens a grammar permits, guaranteeing valid JSON.
Two costs. Building the mask per step is CPU work in the decode loop, which is why modern
implementations precompute per-state token masks (XGrammar, Outlines) and why a schema with
many alternations can still cost real time. More subtly, **constraining the output distribution
changes it**: a schema that forces a field order the model finds unnatural degrades content
quality, not just format.

For voice there is a stronger design rule. **Do not put structured output on the speech path.**
The user is waiting for speech, and JSON is not speakable. Either emit the spoken reply first
and the structure afterwards in a second, off-path call, or use tool calls — which are
constrained generation with the schema attached to a function
([`03-tools-and-agentic.md`](03-tools-and-agentic.md)) — and let the *arguments* carry the
structure while the spoken text stays free-form.

### 2.8 Local serving on Apple Silicon

Unified memory changes the arithmetic: weights and KV share one pool, so capacity is
straightforwardly `RAM − OS − activations`, and there is no host-to-device copy. Bandwidth,
not FLOPs, sets decode speed — consistent with §2.1's roofline. The practical stack is MLX
(Metal-native, best Apple integration), llama.cpp/GGUF with Metal (widest quantisation and
model support), and Ollama as a wrapper over the latter. What you do **not** get is continuous
batching at production quality, so a laptop serves one conversation well and ten badly. Local
serving is for development, offline demos and privacy-constrained deployments, not for
concurrency ([`../00-setup/02-hardware-and-cost.md`](../00-setup/02-hardware-and-cost.md)).

---

## 3. From scratch

A discrete-event model of one serving engine, calibrated on the measurements above.
Standalone, stdlib only, deterministic.

```python
"""Static vs continuous batching vs chunked prefill, for voice-shaped traffic.

A discrete-event model of one LLM serving engine. Step costs are calibrated on
GPT-2 124M measured on an M5 (Section 2): prefill 0.092 ms/token, and a decode
step whose cost grows sublinearly with batch size until the accelerator
saturates. Voice traffic is distinctive: short replies (~60 tokens), a prompt
that is mostly a prefix-cache hit, and a hard TTFT budget.
"""

import random
import statistics

SEED = 3
N_REQUESTS = 600
SCENARIOS = [(0.90, 0.010), (0.0, 0.004)]   # (prefix-cache hit, arrivals per ms)
PROMPT_TOKENS = 1200          # full conversation context
OUT_TOKENS = (60, 25)         # mean, stdev of reply length in tokens
PREFILL_MS_PER_TOKEN = 0.092  # measured
CHUNK = 256                   # tokens of prefill admitted per step when chunking
MAX_BATCH = 16                # measured throughput peak
STATIC_TIMEOUT = 20.0         # ms a static batcher waits to fill a batch
TTFT_BUDGET = 300.0           # ms

# measured decode-step latency (ms) by batch size, GPT-2 124M on M5, ctx 256
DECODE_CURVE = [(1, 5.07), (2, 5.68), (4, 6.93), (8, 9.65), (16, 16.98), (32, 45.69)]


def decode_ms(bs):
    """Piecewise-linear interpolation of the measured decode curve."""
    if bs <= 0:
        return 0.0
    lo = DECODE_CURVE[0]
    for hi in DECODE_CURVE:
        if hi[0] >= bs:
            if hi[0] == lo[0]:
                return hi[1]
            f = (bs - lo[0]) / (hi[0] - lo[0])
            return lo[1] + f * (hi[1] - lo[1])
        lo = hi
    return DECODE_CURVE[-1][1] * bs / DECODE_CURVE[-1][0]


class Req:
    __slots__ = ("arrive", "prefill_left", "out_left", "n_out", "first_token_at", "done_at")

    def __init__(self, arrive, prefill, out):
        self.arrive, self.prefill_left, self.out_left, self.n_out = arrive, prefill, out, out
        self.first_token_at = self.done_at = None


def make_trace(cache_hit, rate):
    rng = random.Random(SEED)
    t, reqs = 0.0, []
    for _ in range(N_REQUESTS):
        t += rng.expovariate(rate)
        reqs.append(Req(t, int(PROMPT_TOKENS * (1 - cache_hit)),
                        max(8, int(rng.gauss(*OUT_TOKENS)))))
    return reqs


def simulate(mode, cache_hit, rate):
    """mode: 'static' | 'continuous' | 'chunked'."""
    pending, i = make_trace(cache_hit, rate), 0
    clock, running, done = 0.0, [], []
    batch_started = False       # static batching only: has this batch begun executing

    while i < len(pending) or running:
        # Admission. A static batcher only admits while its batch is still forming.
        if mode != "static" or not batch_started:
            while (i < len(pending) and pending[i].arrive <= clock
                   and len(running) < MAX_BATCH):
                running.append(pending[i]); i += 1

        if not running:
            clock = max(clock, pending[i].arrive)
            continue

        # A static batcher also waits, briefly, to fill the batch before starting.
        if (mode == "static" and not batch_started and len(running) < MAX_BATCH
                and i < len(pending) and clock < running[0].arrive + STATIC_TIMEOUT):
            clock = min(pending[i].arrive, running[0].arrive + STATIC_TIMEOUT)
            continue
        batch_started = True
        prefilling = [r for r in running if r.prefill_left > 0]
        decoding = [r for r in running if r.prefill_left == 0]

        if prefilling and mode != "chunked":
            # Prefill monopolises the engine: every decoder stalls for its duration.
            r = prefilling[0]
            clock += r.prefill_left * PREFILL_MS_PER_TOKEN
            r.prefill_left = 0
            emitted = [r]
        else:
            budget, cost, joined = CHUNK, 0.0, []
            for r in prefilling:                    # interleave prefill with decode
                take = min(budget, r.prefill_left)
                r.prefill_left -= take
                budget -= take
                cost += take * PREFILL_MS_PER_TOKEN
                if r.prefill_left == 0:
                    joined.append(r)
                if budget == 0:
                    break
            cost += decode_ms(len(decoding))
            clock += cost
            emitted = decoding + joined

        for r in emitted:
            if r.first_token_at is None:
                r.first_token_at = clock
            r.out_left -= 1
            if r.out_left <= 0:
                r.done_at = clock
                done.append(r)
        running = [r for r in running if r.done_at is None]
        if not running:
            batch_started = False
    return done


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


if __name__ == "__main__":
    print(f"{N_REQUESTS} turns per run, prompt {PROMPT_TOKENS} tokens, "
          f"max batch {MAX_BATCH}, TTFT budget {TTFT_BUDGET:.0f} ms")
    for cache_hit, rate in SCENARIOS:
        print(f"\nprefix cache hit {cache_hit:.0%} -> {int(PROMPT_TOKENS*(1-cache_hit))} "
              f"tokens prefilled per turn, offered {rate*1000:.0f} turns/s\n")
        print(f"{'engine':12s} {'ttft p50':>9} {'ttft p95':>9} {'tpot mean':>10} "
              f"{'tpot p95':>9} {'turn p95':>9} {'ttft<budget':>12}")
        for mode in ("static", "continuous", "chunked"):
            d = simulate(mode, cache_hit, rate)
            ttft = [r.first_token_at - r.arrive for r in d]
            tpot = [(r.done_at - r.first_token_at) / max(1, r.n_out - 1) for r in d]
            turn = [r.done_at - r.arrive for r in d]
            ok = sum(t <= TTFT_BUDGET for t in ttft) / len(ttft)
            print(f"{mode:12s} {pct(ttft,.5):9.0f} {pct(ttft,.95):9.0f} "
                  f"{statistics.mean(tpot):10.2f} {pct(tpot,.95):9.2f} "
                  f"{pct(turn,.95):9.0f} {ok:12.1%}")
```

Output `[MEASURED]`:

```
600 turns per run, prompt 1200 tokens, max batch 16, TTFT budget 300 ms

prefix cache hit 90% -> 119 tokens prefilled per turn, offered 10 turns/s

engine        ttft p50  ttft p95  tpot mean  tpot p95  turn p95  ttft<budget
static             489       996      10.83     17.68      1931        24.8%
continuous          15        27      10.23     16.89      1281        98.5%
chunked             24        48      10.20     16.65      1289        98.2%

prefix cache hit 0% -> 1200 tokens prefilled per turn, offered 4 turns/s

engine        ttft p50  ttft p95  tpot mean  tpot p95  turn p95  ttft<budget
static             764      1462      11.67     27.49      2695         7.3%
continuous         116       390      16.62     41.27      2740        92.3%
chunked            178       662      15.43     33.69      2496        78.7%
```

Three load-bearing details. **The two scenarios run at different offered loads on purpose** —
the cold-cache engine is given 2.5× *less* traffic and still misses the TTFT budget five times
as often, which is the capacity argument for prefix caching stated as an experiment rather than
an assertion. **In the non-chunked branch a prefill emits no decode tokens**, because the
engine really is monopolised; modelling decoders as continuing through someone else's prefill
is the mistake that makes chunked prefill look pointless. And **`batch_started` is what makes
static batching static**: without it the simulation quietly becomes continuous batching with
extra steps, which is also the most common way a real "static" baseline is measured wrong.

---

## 4. How production does it

**vLLM** is the reference implementation of most of this chapter. PagedAttention stores KV in
fixed-size blocks so sequences do not need contiguous memory, which removes the fragmentation
that otherwise caps batch size; automatic prefix caching hashes each block by its tokens plus
all preceding tokens (`docs/design/prefix_caching.md`, retrieved 2026-08-22), giving the §2.3
behaviour; the scheduler is iteration-level, and chunked prefill is a scheduler policy rather
than a separate mode. Its dashboard exposes exactly the metrics in §3 — TTFT, time per output
token, and the running/waiting queue depths, which are the autoscaling signals in
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md).

**SGLang** adds RadixAttention, a radix tree over cached prefixes that shares them across
requests rather than only within a session. For a voice fleet with one shared system prompt
and per-user suffixes, that is the difference between caching the system prompt once and
caching it per session. **TensorRT-LLM** trades flexibility for kernel-level speed on NVIDIA
hardware, and **llama.cpp** covers everything else including Metal.

**The hosted-API view of the same machinery** is prompt caching with a discounted cached-input
price, a minimum cacheable prefix length, and an eviction TTL measured in minutes. Your side of
the contract is unchanged: identical prefix bytes, stable ordering, and a router that keeps a
conversation on one cache. Nothing above is available for inspection, which is the real cost of
the hosted option — you cannot see your cache hit rate unless the provider reports it.

**Framework-level measurement.** LiveKit records `llm_node_ttft` and `llm_node_tps` per
assistant message in `MetricsReport` (`livekit-agents/livekit/agents/llm/chat_context.py`,
retrieved 2026-08-22), so `ttft_llm` regressions are attributable per turn rather than
aggregated per service. Preemptive generation — starting the LLM request before the turn is
confirmed complete — is the framework's own speculative execution, and it trades wasted prefill
for latency exactly like §2.5 trades wasted draft tokens.

---

## 5. At scale

**Size the fleet from TTFT, not throughput.** Peak aggregate throughput sits at the batch size
where per-request latency has already tripled (batch 16 in §2.2: 942 tok/s at 3.35× the
single-stream latency). A throughput-optimised configuration will pass your capacity tests and
fail your latency SLO. Set the maximum batch from the point where TTFT p95 still fits the
budget, then buy replicas.

**Concurrency is bounded by KV memory, so it is bounded by context length.** With 128 KiB per
token for an 8B GQA model, an 80 GiB accelerator holding 16 GiB of weights has ~64 GiB for KV,
which is ~512k tokens, which is 128 conversations at 4k context or 42 at 12k `[INFERENCE —
arithmetic]`. Every 1000 tokens you add to the context removes conversations from the GPU. That
makes the curation policy in [`02-context-and-memory.md`](02-context-and-memory.md) a
hardware-budget decision.

**Voice traffic is bursty in a specific way.** One conversation issues a request roughly every
5–8 seconds, so 1000 concurrent calls generate 125–200 requests/s of *short* requests with
strong prefix locality. That profile is ideal for continuous batching and cache-affinity
routing, and terrible for a load balancer that spreads by least-connections — which is the
common default and quietly destroys the 5.85× cost saving computed in
[`02-context-and-memory.md`](02-context-and-memory.md) §5.

**Cost per 1000 minutes follows the token arithmetic.** With 20 turns per 6-minute call, 167
calls per 1000 minutes and ~60 output tokens per turn, output is only 0.2 M tokens per 1000
minutes while input is 2.6 M — voice is an **input-token-dominated** workload, the opposite of
most LLM applications. Optimise prefill and caching first; output-token price is close to
noise.

**Cold starts are a real SLO risk.** Loading a 16 GiB model and warming the cache is tens of
seconds, during which a scaled-up replica serves nothing. Keep a warm pool sized to the burst
you must absorb, and never let an autoscaler scale from zero on a call path
([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).

**Alert on the decomposition, not the total.** `ttft_llm` rising with a flat queue depth means
prompts grew; rising with queue depth means capacity; a falling cache-hit rate means routing
or prompt-ordering drift. Those are three different pages and three different fixes
([`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md)).

---

## 6. Exercises

**E5.4.1** Reproduce §2.1 on any local model: prefill 128–2048 tokens, decode with a warm
cache, and report the per-token ratio. State whether your ratio is closer to 10× or 100× and
what that implies about your hardware's bandwidth-to-FLOPs balance.

**E5.4.2** Measure your own decode-versus-batch curve and find the knee. Then re-run §3 with
your curve substituted for `DECODE_CURVE` and report how the recommended `MAX_BATCH` changes.

**E5.4.3** Compute KV cache bytes per token for the model you serve, then the maximum
concurrent conversations at your context length. Verify it empirically by increasing
concurrency until the engine starts evicting or thrashing.

**E5.4.4** Before implementing speculative decoding, measure $r = c_{\text{draft}} /
c_{\text{target}}$ and estimate $\alpha$ on 100 real replies. Predict $S$ with the §2.5
formula, then implement it and compare. Explain any gap.

**E5.4.5** Turn chunked prefill on and off under two workloads — warm cache and cold cache —
and reproduce the TTFT/TPOT trade in §2.4. State the prefill length above which chunking pays
for your budget.

**E5.4.6** Take a JSON schema you constrain against and measure TTFT and TPOT with and without
constrained decoding, plus quality on 50 examples. Report whether the format guarantee cost you
content quality.

**E5.4.7** Break cache affinity deliberately: route each turn of a conversation to a random
replica and measure the change in `ttft_llm` p50 and in input tokens billed at full price.
Relate the result to [`02-context-and-memory.md`](02-context-and-memory.md) §5.

**E5.4.8** Build the TTFT decomposition dashboard: queue wait, prefill, and first-token
compute as three series. Induce each failure mode in turn (longer prompts, more load, colder
cache) and confirm the dashboard identifies which one you caused.

---

## 7. Interview drill

> "We are serving a 8B model for a voice agent. p50 TTFT is 180 ms and p95 is 1.4 seconds.
> GPU utilisation is 40%. What is happening?"

Forty percent utilisation with a bad tail is the diagnostic signature, and it rules things out
immediately. The GPU is not saturated, so this is not a capacity shortfall in FLOPs; the tail
is coming from waiting, and the candidates are queueing behind other requests, prefill of long
prompts, and cache misses. All three are visible if TTFT is decomposed into queue wait, prefill
time, and prompt length, which is the first thing to ask for.

The most likely cause is head-of-line blocking from prefill. In a serving engine without
chunked prefill, one 4000-token prompt monopolises the accelerator for the duration of its
prefill, and every other request — including ones with tiny prompts — waits. That produces
exactly this pattern: a good median because most turns have short prefills against a warm cache,
and a bad p95 because it only takes one long prefill to stall the queue. Utilisation stays
moderate because the machine is memory-bound during decode and idle during the queue wait. The
fix is chunked prefill plus continuous batching, which in the measurement in §2.4 cut TPOT p95
by 18% under long prefills, and a cap on prompt length that forces compaction rather than
letting a runaway context arrive at the engine.

The second candidate is prefix cache misses, and the way to tell them apart is the cache-hit
rate correlated with the slow requests. If the p95 turns are cache misses, the cause is usually
routing — a least-connections load balancer scattering a conversation across replicas — or a
prompt whose head is not byte-stable, typically because a timestamp or session id was placed in
the system prompt. That is a one-line fix worth 85% of the prefill on every subsequent turn.

A senior answer adds two things. First, that 40% utilisation is not a target to raise: for a
latency-critical service, queueing theory says the p95 explodes as utilisation approaches
saturation, so running a serving fleet hot is a deliberate choice to fail the SLO, and the same
argument appears in [`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md).
Second, that a 1.4-second p95 may not need fixing at the LLM at all — what the user perceives is
`eou_to_ttfa`, and if the aggregator is emitting a first clause early
([`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md)) the tail may already be
hidden. The premise worth challenging is whether TTFT p95 is the metric the complaint is
actually about; measuring the perceived quantity before optimising the internal one is the
difference between fixing the system and optimising a number.

---

## Sources

- Yu et al., "Orca: A Distributed Serving System for Transformer-Based Generative Models", OSDI 2022 — iteration-level (continuous) scheduling, §2.4.
- Kwon et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention", SOSP 2023, arXiv:2309.06180 — vLLM, paged KV, §2.2 and §4.
- Leviathan, Kalman & Matias, "Fast Inference from Transformers via Speculative Decoding", ICML 2023, arXiv:2211.17192; Chen et al., "Accelerating Large Language Model Decoding with Speculative Sampling", arXiv:2302.01318 — the acceptance-rate formula in §2.5.
- Zheng et al., "SGLang: Efficient Execution of Structured Language Model Programs", arXiv:2312.07104 — RadixAttention, §4.
- Agrawal et al., "Sarathi-Serve: Taming Throughput-Latency Tradeoff in LLM Inference", OSDI 2024, arXiv:2403.02310 — chunked prefill, §2.4.
- `vllm-project/vllm`, `docs/design/prefix_caching.md` (retrieved 2026-08-22) — block hashing over the block's tokens plus all preceding tokens.
- `livekit/agents`, `livekit-agents/livekit/agents/llm/chat_context.py` (retrieved 2026-08-22) — `MetricsReport.llm_node_ttft` and `llm_node_tps`.
- `[MEASURED]` on Apple M5 / macOS 26.5.2, Python 3.12, `torch` 2.13.0 on MPS: prefill scaling, decode-versus-batch curve, prefill/decode per-token ratio (GPT-2 124M); speculative decoding acceptance and speedup (GPT-2 124M target, DistilGPT-2 82M draft, greedy, 48 tokens, KV caches cropped on rejection, output verified identical to greedy baseline). The §3 tables are the output of the §3 listing, a simulation calibrated on those measurements rather than a trace of a production engine. Batch-64 decode timings varied between 238 ms and 2.6 s across runs and are reported only as evidence of memory thrash, not as a measurement.
