# The Latency Budget

**What you'll be able to do after this:** decompose mouth-to-ear latency into terms
you can each name, measure and attack; distinguish *perceived* from *measured*
latency and know which one the product is judged on; explain from data why a system
at 90% utilisation has a p95 six times worse than the same system at 70%; and size
a worker fleet from an arrival rate and a service time.

This is the chapter that makes the rest of the curriculum actionable. Every later
design decision — streaming versus batch, cascaded versus speech-to-speech, which
endpointing policy, how much headroom — is an entry in this budget.

---

## 1. Intuition

Latency in a voice agent behaves like a fixed sum of money. You have roughly
800 milliseconds to spend before the conversation stops feeling like a
conversation. Every component wants some. The question is never "is this fast
enough" in isolation; it is "what am I buying with these 120 ms, and is there
something else I would rather spend them on".

Three ideas make the budget tractable.

**First: most of your budget is not compute.** The largest single line item in a
typical cascaded agent is the *endpointing wait* — the interval after the user stops
making sound during which the system waits to see whether they are actually
finished. That is a decision under uncertainty, not a computation. It costs zero
CPU and 300–800 ms. Engineers spend weeks quantising models to save 40 ms while a
hardcoded 700 ms timeout sits untouched in a config file.

**Second: the user's clock starts before yours.** Your metrics naturally begin at
`t_eou`, the moment your system decided the turn was over. The user's perception
begins at `speech_end`, when they stopped talking. The gap between those two is
invisible in your dashboard and fully visible to them. Any latency report that does
not show both numbers is misleading, usually in the flattering direction.

**Third: averages are irrelevant and percentiles are the product.** A user does not
experience your mean latency. They experience a sequence of turns, and one bad turn
in twenty is enough to form an impression. §2.5 shows a system where the median
wait is *exactly zero* while the 95th percentile is 675 ms — the same system, the
same second. If you optimise p50 you will ship something that feels broken and
measures fine.

---

## 2. Rigour

### 2.1 The full decomposition

Define the timeline for one turn. All marks are monotonic timestamps; the names are
the contract used throughout this curriculum.

| Term | From → To | Nature | What controls it |
|---|---|---|---|
| Capture buffering | acoustic → first sample available | fixed | device block size |
| Client processing | sample → processed frame | compute | AEC/AGC/NS chain, resampling |
| Uplink transit | client → server | network | distance, medium, MTU |
| Jitter buffer | arrival → playable order | **policy** | target depth, adaptivity |
| Endpoint wait | `speech_end` → `t_eou` | **policy** | silence threshold, turn model |
| ASR finalisation | `t_eou` → `stt_final` | compute | streaming vs window-recompute |
| LLM queue | `stt_final` → `llm_request` | queueing | worker load, admission |
| LLM prefill | `llm_request` → `ttft_llm` | compute | prompt length, KV cache hit |
| Aggregation | `ttft_llm` → `first_clause` | **policy** | clause-boundary rule |
| TTS synthesis | `first_clause` → `ttfb_tts` | compute | architecture, first-chunk size |
| Downlink transit | `ttfb_tts` → first packet at client | network | as uplink |
| Playout buffering | packet → acoustic | **policy** | playout target depth |

The two headline metrics:

$$
\texttt{eou\_to\_ttfa} = t_{\text{ttfa}} - t_{\text{eou}}, \qquad
\texttt{perceived\_gap} = t_{\text{ttfa}} - t_{\text{speech\_end}}
$$

Note which rows are marked **policy**. Four of the twelve terms are pure decisions —
they consume no resources and can be changed by editing a number. Together they
routinely account for more than half the budget. That is the highest-leverage fact
in this chapter.

### 2.2 Three budgets

The following are an **explicit illustrative model**, not measurements: each row is
a plausible value for its regime, and the arithmetic is shown so you can substitute
your own measurements. Component-level measurements appear in the chapters that own
each component.

| Term | A. Local on M5 | B. Cloud cascaded | C. Native S2S |
|---|---|---|---|
| Capture buffering | 20 | 20 | 20 |
| Client processing (AEC etc.) | 5 | 10 | 10 |
| Uplink transit | 0 | 25 | 25 |
| Jitter buffer | 0 | 60 | 60 |
| **Endpoint wait** | **500** | **300** | **200** |
| ASR finalisation | 180 | 120 | — |
| LLM queue | 0 | 15 | — |
| LLM prefill (TTFT) | 250 | 280 | — |
| Aggregation | 60 | 50 | — |
| TTS synthesis (TTFB) | 150 | 120 | — |
| Model first audio (S2S) | — | — | 300 |
| Downlink transit | 0 | 25 | 25 |
| Playout buffering | 40 | 40 | 40 |
| **`eou_to_ttfa`** | **680** | **650** | **365** |
| **`perceived_gap`** | **1205** | **1065** | **680** |

Four readings of this table matter more than its exact numbers.

**Local is not faster.** Regime A eliminates 110 ms of network and jitter and gives
it all back in slower local models and a more conservative endpointing policy. The
reason to run locally is cost, privacy and offline capability — not latency. This
surprises people.

**The cascade's problem is not any single stage.** No row in column B is
outrageous. `eou_to_ttfa` is 650 ms because six defensible numbers are added
together. There is no single fix; there is a portfolio of 50–120 ms improvements.

**Native S2S wins by deleting rows, not by being a better model.** Column C removes
ASR finalisation, the LLM queue, aggregation and TTS synthesis — 570 ms of
serialised stages — and replaces them with one 300 ms number. That structural
advantage is why the comparison in
[`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)
is not close on latency alone.

**Endpoint wait is the largest line in all three columns.** 500, 300 and 200 ms
respectively. If you want one sentence from this chapter: *the endpointing policy is
your latency architecture*.

### 2.3 What the target actually is

Human conversation sets the reference. Stivers et al. (2009, PNAS) measured
question–answer transitions across ten typologically diverse languages and found
all distributions unimodal, with the greatest number of transitions falling **between
0 and 200 ms**; language means ranged from 7 to 468 ms. So the human baseline for a
prompt reply is roughly 200 ms, and there is real cross-cultural variation around it.

Three implications, and the third is the useful one.

A voice agent cannot reach 200 ms with a cascade — column B's `perceived_gap` is
five times that. It follows that voice agents are *not* competing with human
conversational timing and should not pretend to. The realistic goal is to stay
inside the range where a listener attributes the delay to thoughtfulness or a phone
line rather than to a machine. In practice teams target `perceived_gap` under
roughly 800 ms at p95, and treat anything past 1.5 s as a defect.

Third: **silence is not the only way to occupy the gap.** Humans fill turn
transitions with breath, "mm", "so", and gaze. An agent that emits a short
acknowledgement 200 ms after `t_eou` — "sure", "let me check" — has satisfied the
conversational deadline even if the substantive answer arrives 900 ms later. This
is not a trick; it is how humans handle the same problem, and it converts a latency
problem into a prompt-design problem. The cost is that a filler emitted before the
tool result is known can be contradicted by it, so fillers must be
content-free. See [`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md).

### 2.4 Little's law and the concurrency arithmetic

For any stable system, the average number in the system equals arrival rate times
average time in system:

$$L = \lambda W$$

This is unconditional — no distributional assumptions — which makes it the right
first tool for capacity questions. Two uses.

**Sizing from call volume.** If calls arrive at $\lambda = 2$ per second and last
$W = 180$ s on average, then $L = 360$ concurrent calls in steady state. That, not
your daily call total, is what the fleet must hold.

**Sizing from turn volume.** Within one worker, if turns arrive at 28 per second and
each occupies a slot for 200 ms, then $L = 5.6$ slots are busy on average. A worker
with 8 slots is at $\rho = 0.7$ utilisation.

The peak-to-average ratio is where plans die. A contact centre's busy hour may carry
three times the daily mean, so provisioning to the mean guarantees failure exactly
when it is most expensive. And unlike a web service, you cannot absorb the peak with
a queue: a caller cannot be told to wait 4 seconds for the agent's first word.

### 2.5 Why utilisation destroys the tail

Simulation of an M/M/c queue — Poisson turn arrivals, exponentially distributed
service, $c = 8$ parallel slots, mean service 200 ms, 400 000 turns per point.
Values are **queue wait only**, excluding service `[MEASURED]`:

| $\rho$ | p50 | p90 | p95 | p99 | mean |
|---|---|---|---|---|---|
| 0.30 | 0.0 | 0.0 | 0.0 | 0.0 | 0.1 |
| 0.50 | 0.0 | 0.0 | 8.3 | 87.1 | 2.9 |
| 0.60 | 0.0 | 21.2 | 64.6 | 162.8 | 8.7 |
| 0.70 | 0.0 | 82.8 | 140.9 | 270.4 | 22.3 |
| 0.80 | 0.0 | 187.0 | 270.5 | 464.9 | 56.0 |
| 0.90 | 83.6 | 492.6 | 675.3 | 1050.3 | 176.0 |
| 0.95 | 255.8 | 1085.0 | 1401.8 | 2314.1 | 423.3 |

This table repays careful reading.

**The median is a liar.** At $\rho = 0.8$ the median wait is *exactly zero* — most
turns find a free slot immediately — while one turn in twenty waits 271 ms and one
in a hundred waits 465 ms. A dashboard showing p50 would report this system as
having no queueing at all.

**The knee is real and it is near 0.7.** Going from $\rho = 0.7$ to $0.9$ — adding
28% more traffic to the same hardware — takes p95 from 141 ms to 675 ms, a **4.8×
increase**. Going from 0.9 to 0.95 doubles it again. Nothing broke; no component
got slower. This is the geometry of queueing, and it is why "our servers are only
90% utilised, that's efficient" is a statement about cost, not about service.

**Where it lands in the budget.** At $\rho = 0.7$, 141 ms of p95 queue wait is a
real but affordable line item in §2.2. At $\rho = 0.9$, 675 ms alone exceeds the
entire `eou_to_ttfa` of column B. Utilisation is not an ops detail; it is a term in
your latency budget, and it belongs in the table.

The practical rule: **provision for p95 at $\rho \le 0.7$.** The 30% you leave idle
is not waste, it is the tail latency you are buying.

### 2.6 Variability costs as much as load

Same simulation at fixed $\rho = 0.80$, varying only the coefficient of variation of
service time (CV $= 0$ is deterministic, 1 is exponential) `[MEASURED]`:

| CV | p50 | p95 | p99 |
|---|---|---|---|
| 0.0 | 0.0 | 137.1 | 223.1 |
| 0.5 | 0.0 | 174.5 | 291.6 |
| 1.0 | 0.0 | 270.5 | 464.9 |
| 2.0 | 0.0 | 671.8 | 1192.4 |

At identical utilisation and identical *mean* service time, going from deterministic
to CV $= 2$ multiplies p95 by 4.9×. Reducing variance is worth as much as reducing
load, and it is often cheaper.

This is directly actionable, because a voice pipeline's service time is highly
variable by default and much of that variance is self-inflicted:

- **Prompt length varies** with conversation history, so prefill time varies. Bound
  the context and the variance collapses.
- **Reply length varies**, so TTS work varies. A persona instructed to answer in one
  or two sentences has lower variance, not just a lower mean.
- **Tool calls turn one 200 ms service into an occasional 3 s service.** That is CV
  $\gg 1$. Move tool execution off the response path where possible, and cap it with
  a timeout — the timeout's real job is variance control, not error handling.
- **Retries multiply service time** for a small fraction of turns, which is exactly
  the shape that hurts p99.

The general principle worth internalising: in a latency-critical system, a change
that makes the *worst* case better while making the mean slightly worse is usually
a good trade.

---

## 3. From scratch

Two tools. First, the queue simulator that produced §2.5 and §2.6 — worth having
because it answers capacity questions in seconds and you can trust it more than an
Erlang calculator whose assumptions you have not read.

```python
"""M/G/c queue: wait-time percentiles vs utilisation and service variability."""
import numpy as np

def simulate(rho, c=8, mean_service=0.200, n=400_000, cv=1.0, seed=7):
    """rho = offered load / capacity. cv = coefficient of variation of service.
    Returns (p50, p90, p95, p99, mean) of QUEUE WAIT in ms, excluding service."""
    rng = np.random.default_rng(seed)
    lam = rho * c / mean_service                 # arrivals/s from rho = lam*ES/c
    arrival = np.cumsum(rng.exponential(1 / lam, n))
    if cv == 0.0:
        service = np.full(n, mean_service)       # deterministic
    elif cv == 1.0:
        service = rng.exponential(mean_service, n)
    else:                                        # gamma with the requested CV
        k = 1 / cv ** 2
        service = rng.gamma(k, mean_service / k, n)

    free = np.zeros(c)                           # next-free time per slot
    wait = np.empty(n)
    for i in range(n):
        j = int(np.argmin(free))                 # earliest-available slot
        start = max(arrival[i], free[j])
        wait[i] = start - arrival[i]
        free[j] = start + service[i]

    w = np.sort(wait) * 1000
    pct = lambda p: w[min(len(w) - 1, int(p * len(w)))]
    return pct(.50), pct(.90), pct(.95), pct(.99), w.mean()

if __name__ == "__main__":
    print(f"{'rho':>5} {'p50':>8} {'p95':>8} {'p99':>8}   queue wait, ms")
    for rho in (0.30, 0.50, 0.70, 0.80, 0.90, 0.95):
        p50, _, p95, p99, _ = simulate(rho)
        print(f"{rho:5.2f} {p50:8.1f} {p95:8.1f} {p99:8.1f}")
```

Second, the budget calculator. Trivial arithmetic, and that is the point: the value
is in forcing every term to have an owner and a number.

```python
"""Latency budget: enumerate every term, sum the two headline metrics."""
from dataclasses import dataclass

@dataclass
class Term:
    name: str
    ms: float
    kind: str          # "fixed" | "compute" | "network" | "policy" | "queue"
    after_eou: bool    # does it fall inside eou_to_ttfa?

BUDGET = [
    Term("capture buffering",      20, "fixed",   False),
    Term("client processing",      10, "compute", False),
    Term("uplink transit",         25, "network", False),
    Term("jitter buffer",          60, "policy",  False),
    Term("endpoint wait",         300, "policy",  False),
    Term("asr finalisation",      120, "compute", True),
    Term("llm queue (p95)",       141, "queue",   True),
    Term("llm prefill (ttft)",    280, "compute", True),
    Term("aggregation",            50, "policy",  True),
    Term("tts synthesis (ttfb)",  120, "compute", True),
    Term("downlink transit",       25, "network", True),
    Term("playout buffering",      40, "policy",  True),
]

def report(budget, target_perceived=800.0):
    eou = sum(t.ms for t in budget if t.after_eou)
    perceived = sum(t.ms for t in budget)
    width = max(len(t.name) for t in budget)
    for t in sorted(budget, key=lambda t: -t.ms):
        share = 100 * t.ms / perceived
        print(f"  {t.name:<{width}}  {t.ms:6.0f} ms  {share:4.1f}%  {t.kind:<7}"
              f"{'  [in eou_to_ttfa]' if t.after_eou else ''}")
    print(f"\n  eou_to_ttfa   = {eou:6.0f} ms")
    print(f"  perceived_gap = {perceived:6.0f} ms   (target {target_perceived:.0f})")
    # Policy terms cost nothing to change: quantify the free headroom.
    policy = sum(t.ms for t in budget if t.kind == "policy")
    print(f"  of which pure policy: {policy:.0f} ms ({100*policy/perceived:.0f}%) "
          f"-- changeable without touching a model")
    if perceived > target_perceived:
        print(f"  OVER BUDGET by {perceived - target_perceived:.0f} ms")

if __name__ == "__main__":
    report(BUDGET)
```

Run it before optimising anything. The `pure policy` line is the one that changes
behaviour: it tells you how much of your latency is available for free, and in the
configuration above it is a large fraction of the total.

---

## 4. How production does it

**Instrument per turn, not per request.** The unit of analysis is a turn, and the
span structure that works is session → turn → stage, with the marks from §2.1 as
span boundaries. `livekit-agents` (v1.7.0) depends on `opentelemetry-api`,
`opentelemetry-sdk`, `opentelemetry-exporter-otlp` and `prometheus-client`, and
exposes a metrics-collection path on the session, so the plumbing exists; what you
must add is the *semantic* mapping from your policy decisions to spans. Pipecat
likewise exposes per-service metrics including time-to-first-byte for its STT/LLM/TTS
services. Neither framework can know your endpointing policy's contribution unless
you record `speech_end` alongside `t_eou`. Details and dashboard design in
[`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md).

**Beware vendor latency numbers.** A TTS vendor's advertised "75 ms" is almost
always time-to-first-byte *at their edge*, measured from receipt of the complete
text, on a warm connection, in their region. Your budget needs first-byte at *your*
process, from the moment your aggregator released a clause, including TLS and
queueing, from your region. The two numbers can differ by more than 100 ms. The same
applies to ASR "real-time factor" claims, which exclude the finalisation delay that
§2.1 charges you.

**Measure with a loopback harness, not a stopwatch.** The reliable method is to
inject a known audio file at the client edge and record the returned audio at the
same edge, then cross-correlate to recover the true acoustic-to-acoustic delay. This
catches everything — device buffers, jitter buffers, the playout queue — that
server-side spans structurally cannot see. Anything measured only inside your
server is a lower bound.

**Cold starts belong in the budget as a separate distribution.** A worker that must
load a model on first use has a bimodal latency distribution, and reporting a single
p95 over both modes hides it. Track warm and cold separately, and treat "fraction of
turns served cold" as its own SLI
([`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)).

---

## 5. At scale

**Capacity planning, worked.** Suppose 40 000 calls per busy hour, mean call
duration 180 s, mean 14 turns per call, 200 ms of service per turn, and 8 slots per
worker.

- Concurrent calls: $\lambda = 40000/3600 = 11.1$ calls/s, so $L = 11.1 \times 180
  = 2000$ concurrent calls.
- Turn rate: $2000 \text{ calls} \times 14 \text{ turns} / 180\text{ s} = 155.6$
  turns/s.
- Slot-seconds needed: $155.6 \times 0.200 = 31.1$ busy slots.
- At $\rho = 0.7$: $31.1 / 0.7 = 44.4$ slots $\rightarrow$ 6 workers of 8 slots.
- At $\rho = 0.9$: 34.6 slots $\rightarrow$ 5 workers — one machine cheaper, and
  from §2.5, p95 queue wait rises from 141 ms to 675 ms.

That last line is the whole discipline in one comparison: the sixth worker costs one
machine and buys 534 ms of p95. State the tradeoff in those terms and the decision
makes itself.

**Headroom must also cover failure.** If a worker dies at $\rho = 0.7$ across six
workers, the survivors move to $0.84$ and p95 roughly doubles. Sizing for
$N-1$ availability at the target utilisation is a separate calculation from sizing
for load, and skipping it means every deploy and every instance failure is a latency
incident.

**Long calls make draining expensive.** Workers hold sessions for minutes, so a
rolling deploy must stop accepting new sessions and wait. With a 180 s mean and a
long tail, full drain can take 10+ minutes; capping maximum call duration is what
makes deploys bounded.

**Regional placement buys tens of milliseconds, and only tens.** Uplink plus
downlink in §2.2 is 50 ms; moving the agent closer might halve it. Worth doing, and
not a substitute for fixing a 500 ms endpointing policy. Spend attention in
proportion to the line items.

**Cost and latency trade against each other explicitly.** Bigger model: better
answers, worse TTFT. Longer context: better grounding, worse prefill. Aggressive
endpointing: lower latency, more interruptions of the user. Higher utilisation:
lower cost, worse tail. There is no configuration that wins all four, so the
deliverable of this chapter is not a number but a *stated position* on each axis,
with the measurement that justifies it.

---

## 6. Exercises

**E1.4.1** Instrument any pipeline you have — even the stub loop from
[`00-what-is-a-voice-agent.md`](00-what-is-a-voice-agent.md) — to emit all twelve
terms of §2.1. Produce the §3 report for it. Which single term is largest, and is it
compute or policy?

**E1.4.2** Using the §3 simulator, find the utilisation at which p95 queue wait
first exceeds 100 ms for $c = 1, 4, 16, 64$ slots at a 200 ms mean service. Plot the
threshold against $c$ and explain the trend. Why do larger pools tolerate higher
utilisation?

**E1.4.3** A colleague proposes running at $\rho = 0.85$ to cut cloud spend by 20%.
Using §2.5, compute the p95 and p99 queue-wait change, express it as a percentage of
the column-B budget in §2.2, and write the three-sentence argument you would make in
a design review — for or against.

**E1.4.4** Take the CV table in §2.6. Your pipeline calls a tool on 15% of turns,
and the tool takes 2.5 s. Compute the resulting mean and CV of service time, then
use the simulator to find the p95 at $\rho = 0.7$. Now move the tool off the
response path (respond first, act after) and recompute. Quantify the win.

**E1.4.5** Build the budget for a regime not in §2.2: a browser-based agent where
ASR and TTS are hosted vendors but the LLM runs on your own GPU in a different
region. Identify the two terms that dominate and the one architectural change that
would remove the most milliseconds.

**E1.4.6** Design the loopback measurement from §4: inject a 1 kHz click at the
client, capture the returned audio, and recover acoustic-to-acoustic delay by
cross-correlation. Write the procedure precisely enough to be repeatable, and state
which of the twelve terms it can and cannot separate.

**E1.4.7** Given the §5 scenario, recompute the fleet size for a 400 ms mean service
time (a larger model) at $\rho = 0.7$. Then find the utilisation at which the larger
model on the *original* fleet size matches the smaller model's p95. Interpret the
result as a statement about model choice.

**E1.4.8** Human transitions are modally 0–200 ms (§2.3), and column B of §2.2 is
1065 ms. Enumerate every change you could make to reach 800 ms, with the millisecond
saving and the cost of each, then choose a set and defend the total.

---

## 7. Interview drill

> "Design a real-time voice agent that handles tool calling, memory, and barge-in
> interruptions with sub-second latency. Walk me through the architecture."

This is the question the bootcamp advertises, and latency is the axis on which it is
actually graded. The trap is to answer with a box diagram. A strong answer leads
with the budget, because the budget is what forces every architectural choice.

Start by disambiguating "sub-second", since the phrase is ambiguous and the
distinction is the first thing a senior interviewer listens for: sub-second
`eou_to_ttfa` is comfortably achievable with a cascade, whereas sub-second
`perceived_gap` requires attacking the endpointing policy. State which one you are
committing to and why.

Then present the budget as the design. From §2.2 column B: 650 ms
`eou_to_ttfa`, 1065 ms perceived — over budget, so name the three moves that close
the gap and their cost. Replace the fixed silence timeout with a semantic turn
detector: 300 ms → roughly 150 ms, at the cost of a model and some false endpoints
([`../03-turn-taking/03-semantic-turn-detection.md`](../03-turn-taking/03-semantic-turn-detection.md)).
Emit a content-free acknowledgement at `t_eou` + 200 ms, which satisfies the
conversational deadline while the substantive reply is still being generated. Hold
utilisation at 0.7 so the queue term stays near 141 ms instead of 675 ms.

Handle the three named features as budget entries rather than as features. **Tool
calling** is a variance problem before it is a capability problem (§2.6): tools push
CV above 1, so they need timeouts for variance control, filler speech to cover the
gap, and off-path execution wherever the answer does not depend on the result.
**Memory** is a prefill-cost problem: every retained token is TTFT, so the design
question is what to *evict* and how to keep volatile content at the end of the
prompt so the prefix cache still hits
([`../05-llm-layer/02-context-and-memory.md`](../05-llm-layer/02-context-and-memory.md)).
**Barge-in** is not a latency term at all — it is a correctness requirement with its
own sub-budget, since interrupt-to-silence must be under roughly 100 ms or the agent
sounds deaf, and that budget is dominated by buffers already committed downstream
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)).

Close on measurement, which is what separates a design answer from an engineering
answer: p95 not p50, `perceived_gap` reported alongside `eou_to_ttfa`, loopback
measurement at the client edge rather than server-side spans, warm and cold
distributions kept separate, and a latency-regression gate in CI so the budget is
enforced rather than aspirational.

---

## Sources

- Stivers, T., Enfield, N. J., Brown, P., Englert, C., Hayashi, M., Heinemann, T., Hoymann, G., Rossano, F., de Ruiter, J. P., Yoon, K.-E. & Levinson, S. C. (2009). *Universals and cultural variation in turn-taking in conversation.* PNAS 106(26), 10587–10592. Ten languages; all response-offset distributions unimodal with the greatest number of transitions between 0 and 200 ms, language means ranging 7–468 ms. Figures verified 2026-08-22.
- Little, J. D. C. (1961). *A proof for the queuing formula $L = \lambda W$.* Operations Research 9(3), 383–387.
- Kleinrock, L. *Queueing Systems, Volume 1: Theory* — M/M/c waiting-time distributions; the simulation in §3 is used in preference to closed forms so that non-exponential service (§2.6) is covered by the same tool.
- `livekit-agents` 1.7.0 package metadata (PyPI JSON, retrieved 2026-08-22) — confirms the `opentelemetry-api`, `opentelemetry-sdk`, `opentelemetry-exporter-otlp` and `prometheus-client` dependencies referenced in §4.
- Beyer, B. et al. *Site Reliability Engineering* (Google) — percentile-based SLOs and error budgets; the argument in §2.1 that p50 is not a service level.
- All `[MEASURED]` values in §2.5 and §2.6 were produced by the simulator in §3, 400 000 turns per point, on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2.
