# Design interviews

**What you'll be able to do after this:** answer a staff-level voice-agent design question
with arithmetic rather than adjectives — allocating a latency budget, sizing pools and trunks
from offered load, counting GPUs, and pricing the result per 1000 call-minutes; and recognise
which term dominates before you start designing, because in five of the six scenarios below
it is the same one.

---

## 1. Intuition

Every voice-agent design question reduces to four computations, and doing them in that order
is most of what separates a senior answer from an enthusiastic one.

1. **Latency budget.** Pick the mouth-to-ear target, allocate it term by term, report the
   slack. If the slack is negative, say so immediately — you have just proved the
   requirement infeasible with the proposed architecture, which is a better answer than a
   diagram.
2. **Capacity.** Convert traffic to erlangs ($A = \lambda h$), then size the worker pool at
   its *safe* utilisation, which depends on pool size, and the trunks at a blocking target.
3. **Infrastructure.** GPUs from per-session VRAM with variance headroom; regions from
   geography and residency.
4. **Cost.** $ per 1000 call-minutes, decomposed, so the conversation is about the dominant
   term rather than the interesting one.

Two results from the calculator in §3 are worth knowing before you walk in.

**The endpointer dominates the latency budget in every scenario below** — 33% to 44% of the
allocation, larger than ASR, LLM and TTS combined in most of them. A candidate who opens by
optimising the model chain is optimising the small half.

**The LLM is 0.63% of cost, and only if you have prefix caching.** Turn caching off and the
LLM term triples (3.2×), which is a bigger swing than most architectural choices. Meanwhile
telephony and managed-agent minutes are 31.6% each. Cost conversations that begin with model
selection begin in the wrong place.

---

## 2. Rigour

All figures `[MEASURED]` from the §3 calculator. Each answer assumes a cascaded pipeline
unless stated.

### 2.1 A sub-second tool-calling barge-in agent

> *Design an agent that answers in under 800 ms, calls a backend tool on most turns, and
> handles interruption cleanly. 50 concurrent calls, web clients.*

**Latency: 780 ms allocated against 800 ms — feasible with 20 ms of slack, and that is
uncomfortably tight.** The allocation is endpoint 330, `stt_final` 90, `ttft_llm` 180,
`first_clause` 60, `ttfb_tts` 90, network 30. The endpointer alone is **42%** of it.

So the design work is in three places, in this order. **The endpointer must be adaptive**,
because a fixed 700 ms timeout spends the whole budget; the measured adaptive endpointer
achieved 330 ms at a 2.78% cut-off rate against 3.04% for the fixed 700 ms one — better on
both axes ([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)).
**The tool call must not be on the critical path.** With a tool on most turns, the honest
`ttfa` is dominated by the backend, and the answer is filler speech plus speculative
execution — previously measured to cut `ttfa` p50 from 1815 ms to 551 ms *with no change in
answer time* ([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)).
That is the single highest-leverage move available, and it is a product decision as much as
an engineering one. **Barge-in needs a priority interrupt path plus an ordered playback
report**: a shared flag or an in-band FIFO interrupt both leave 1220 ms of stale audio, a
priority path leaves 20 ms, and only the ordered report tells you where to truncate the
transcript ([`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)).

**Capacity: 50 E needs a 69-worker pool at 74% safe utilisation** — 26% headroom, because a
small pool cannot run hot. **Cost: $21.64/1000 min**, of which managed agent minutes are
$10.00 and TTS $6.19; the LLM is 0.92%.

The premise to challenge: 800 ms mouth-to-ear with a tool call on most turns is achievable
only if "answer" means *starts speaking*, not *delivers the result*. Say that out loud.

### 2.2 A 10 000-concurrent inbound support line

> *Inbound PSTN, 10 000 concurrent calls at peak, four-minute average, 1200 ms target.*

**Latency: 1050 ms of 1200 — comfortable.** The interesting numbers are elsewhere.

**Capacity: 10 000 E needs 9970 SIP channels at 1% blocking — 100% utilisation.** That is
the trunking gain at scale, and it is the good news you bring to the procurement
conversation: capacity grows almost linearly with load while efficiency approaches 100%,
where a 50-erlang pool needs 64 channels for 78%. The corollary is that **splitting the pool
destroys it** — two regional pools of 5000 E need more channels than one of 10 000.

**The worker pool is 10 257 for 10 000 E: 2% headroom at 98% safe utilisation.** Large pools
are efficient, which is the same mathematics from the other side, and it is why one large
shared pool beats many dedicated ones unless isolation is a requirement you can price
([`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)).

**Cost is where the design is decided: $10.66/1000 min self-hosting ASR, TTS and agents,
against $31.64 fully managed** — a 66% reduction. At this volume the crossovers have long
since been passed, and telephony ($10.00) is now 94% of the remaining bill, which points the
next optimisation at carrier contracts rather than at anything technical.

At 10 000 concurrent the constraints that bite are not in the model layer: one million
packets per second of SRTP, connection counts, and the fact that media cannot sit behind an
HTTP load balancer ([`../06-realtime-systems/02-webrtc-internals.md`](../06-realtime-systems/02-webrtc-internals.md)).

### 2.3 Outbound collections, 500 lines

> *Outbound dialling, 500 simultaneous lines, compliance-sensitive, 1500 ms target.*

**Latency: 1270 ms of 1500.** Loose, deliberately — outbound calls tolerate more latency
than inbound because the callee is not waiting on a service.

**Capacity: 527 channels for 500 E at 95% utilisation; 556 workers at 90% safe rho.** But
the binding constraint here is not capacity, it is that **outbound arrivals are not
Poisson**. A dialling campaign is a correlated arrival process, which breaks every Erlang
assumption; the mitigation is to rate-limit your own dialler, which you control, and that
turns a capacity problem into a scheduling one.

The design is dominated by two non-technical requirements. **Answering-machine detection and
consent**: TCPA-style consent must be recorded per number with a working opt-out, and AMD
failure modes are the classic source of complaints
([`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)).
**Disclosure in the greeting**: AI Act Art. 50(1) plus recording consent, spoken before the
first recorded frame, which is three seconds you cannot compress.

**Cost $25.46/1000 min** with self-hosted TTS. Note the ordering: telephony $10.00 and agent
minutes $10.00 swamp everything, and the LLM is 0.78%.

### 2.4 An in-car assistant, offline-capable

> *In-vehicle voice assistant. 600 ms target. Must work with no connectivity.*

**Latency: 565 ms of 600 — feasible, and the network term is 5 ms because there is no
network.** That is the whole architectural advantage, and it is large: the network term and
the region question both disappear.

**Everything runs locally**, which inverts the cost structure entirely: **$1.09/1000 min, of
which the LLM is 57.74%** — because it is the only metered thing left. That inversion is the
answer to "why would anyone self-host": at the edge you are not choosing between vendors,
you are choosing between a local model and no service.

The engineering constraints are the ones the setup module cares about: model size against
available RAM and accelerator, quantisation quality loss, and a hard requirement that
nothing blocks on a network call
([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md),
[`../04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md)). A single concurrent
session means the pool question is trivial and the *cold start* question is everything — an
assistant that takes two seconds to wake has failed.

The premise to challenge: "offline-capable" usually means *degraded* offline. Ask which
intents must work with no connectivity; it is normally a small set, and designing for that
set is far cheaper than a full local stack.

### 2.5 Multilingual healthcare intake, HIPAA

> *Patient intake, eight languages, 800 concurrent, seven-minute calls, HIPAA.*

**Latency: 1190 ms of 1500.** Generous on purpose: intake is not a latency-critical
interaction, and the slack is better spent on accuracy.

**Capacity: 829 channels for 800 E; 870 workers at 92% safe rho.** Seven-minute calls make
the drain question acute — a deploy must wait out sessions that legitimately run 20 minutes,
which is why `DRAIN_TIMEOUT` is an hour and why deploy frequency is bounded by session
length ([`../06-realtime-systems/08-deployment.md`](../06-realtime-systems/08-deployment.md)).

**Compliance decides the architecture, not performance.** Every processor touching audio or
transcripts needs a BAA, which eliminates most vendors and prices the rest; entity accuracy
on names, dates and medication names matters far more than WER, so contextual biasing and
confirmation strategy are the real quality levers
([`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md)); and
recorded audio containing PHI needs a bounded retention and a deletion fan-out that actually
reaches vendors and backups.

**Cost $31.64/1000 min fully managed.** Do not self-host to save money here — the vendor
constraint is BAAs, and the marginal saving is not worth adding a compliance surface you
must certify.

### 2.6 A real-time interpreter for two humans

> *Live two-way interpretation between two people. 1000 ms target, 200 concurrent,
> ten-minute sessions.*

**Latency: 900 ms of 1000, and this is the scenario where the target is hardest to defend**
— because there are *two* humans waiting, and every turn pays the full pipeline twice over
the course of the exchange. The interpreter is also the case where turn-taking is genuinely
different: there is no agent turn to interrupt, so the classical barge-in machinery does not
apply, and the system must decide when a speaker has finished a *translatable unit* rather
than a turn.

**This is the strongest case for speech-to-speech in the whole set.** Full-duplex removes
the endpointing decision, which was measured to take `eou_to_ttfa` p50 from 1370 ms to
343 ms — and unlike a transactional agent, an interpreter makes no tool calls, so the
finding that S2S plus a tool call is *worse* than cascaded (1499 ms against 1370 ms) does not
apply ([`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)).
Prosody preservation is also a genuine product feature here rather than a nicety.

**Capacity: 236 workers for 200 E at 85% safe rho.** **Cost $26.59/1000 min**, and note that
TTS is now the top term at $11.14 because the agent speaks 45% of the time rather than 25% —
a persona parameter moving the largest cost line, exactly as the persona chapter measured
([`../05-llm-layer/05-persona-design.md`](../05-llm-layer/05-persona-design.md)).

Ten-minute sessions with audio-native models run straight into the context tax: a dual-stream
scheme at 212.5 tokens/s fills a 32k window in 2.6 minutes, so this design needs explicit
session segmentation.

### 2.7 What the arithmetic says across all six

| Scenario | Slack | Endpoint share | Pool / concurrent | Safe ρ | $/1000 min | LLM share |
|---|---|---|---|---|---|---|
| 1. sub-second tool agent | +20 ms | 42% | 69 / 50 | 74% | $21.64 | 0.92% |
| 2. 10k inbound | +150 ms | 38% | 10257 / 10000 | 98% | $10.66 | 1.86% |
| 3. outbound 500 | +230 ms | 39% | 556 / 500 | 90% | $25.46 | 0.78% |
| 4. in-car offline | +35 ms | 44% | 5 / 1 | 25% | $1.09 | 57.74% |
| 5. healthcare intake | +310 ms | 38% | 870 / 800 | 92% | $31.64 | 0.63% |
| 6. interpreter | +100 ms | 33% | 236 / 200 | 85% | $26.59 | 0.75% |

Three cross-cutting facts an interviewer is listening for. **Safe utilisation rises with
pool size** — 25% at a pool of 5, 98% at 10 257 — so "we run at 70%" is not a policy, it is
a statement about scale. **The endpointer is the largest latency term in every scenario**,
so it is the first thing to design and the first thing to instrument. And **the LLM is a
rounding error everywhere except the fully self-hosted edge case**, where it becomes the
majority precisely because everything else stopped being metered.

---

## 3. From scratch

The calculator that produced every number above. Standalone, stdlib only, deterministic.

```python
"""A design calculator for voice agents: six scenarios, one set of arithmetic.

Every design question in this chapter reduces to the same four computations,
and doing them in code rather than on a whiteboard is what makes the answers
comparable.

  1. Latency budget -- allocate a mouth-to-ear target across the pipeline and
     report the slack (or the deficit).
  2. Capacity -- offered load in erlangs, then Erlang B for trunks and a safe
     utilisation for the worker pool, which depends on pool size.
  3. Infrastructure -- GPU count from per-session VRAM with headroom.
  4. Cost -- $ per 1000 call-minutes, decomposed so the dominant term is
     visible, and with prefix caching modelled because omitting it overstates
     the LLM term several-fold.

Prices are the published figures this curriculum verified on 2026-08-22.
Deterministic: pure arithmetic.
"""

import math

# ---- verified per-minute prices (USD), 2026-08-22 -------------------------
P_WEBRTC_MIN = 0.0004         # participant minute
P_AGENT_MIN = 0.0100          # managed agent minute
P_TELEPHONY_IN = 0.0100       # US local inbound
P_ASR_MIN = 0.0048            # Nova-3
P_TTS_PER_MCHAR = 30.0        # Aura-2, $/1M characters
P_LLM_IN_PER_MTOK = 0.10      # Gemini 2.5 Flash-Lite, uncached input
P_LLM_CACHED_PER_MTOK = 0.01  # cached input -- a tenth of the price
P_LLM_OUT_PER_MTOK = 0.40
P_EGRESS_GB = 0.10

WPM = 150.0                   # conversational speech
CHARS_PER_WORD = 5.5
TOK_PER_WORD = 1.04           # measured: tiktoken o200k_base on speech


# ---- 1. latency ----------------------------------------------------------
def latency_budget(target_ms, alloc):
    used = sum(alloc.values())
    return used, target_ms - used


# ---- 2. capacity ---------------------------------------------------------
def erlang_b(n, a):
    b = 1.0
    for k in range(1, n + 1):
        b = a * b / (k + a * b)
    return b


def trunks_for(a, target=0.01):
    n = 1
    while erlang_b(n, a) > target and n < 100_000:
        n += 1
    return n


def erlang_c(n, a):
    if a >= n:
        return 1.0
    b = erlang_b(n, a)
    return n * b / (n - a * (1 - b))


def safe_rho(n, aht_s, budget_ms=500.0, target=0.01):
    """Highest utilisation at which under 1% of calls wait over 500 ms."""
    best, rho = 0.0, 0.01
    while rho < 0.995:
        a = rho * n
        c = erlang_c(n, a)
        rate = (n - a) / aht_s
        if c * math.exp(-rate * budget_ms / 1000.0) <= target:
            best = rho
        rho += 0.005
    return best


def pool_for(concurrent, aht_s):
    """Smallest pool whose safe utilisation still carries the offered load."""
    n = max(1, int(concurrent))
    while n < 200_000:
        if safe_rho(n, aht_s) * n >= concurrent:
            return n
        n += 1
    return n


# ---- 3. GPUs ------------------------------------------------------------
def gpus_for(concurrent, vram_gb=24.0, model_gb=9.0, per_session_gb=0.42,
             headroom=0.16):
    budget = (vram_gb - model_gb) * (1 - headroom)
    per_gpu = max(1, int(budget / per_session_gb))
    return max(1, math.ceil(concurrent / per_gpu)), per_gpu


# ---- 4. cost ------------------------------------------------------------
def cost_per_1000_min(agent_talk_frac=0.25, turns_per_min=4.0,
                      ctx_tokens=1400, out_words=40, telephony=True,
                      managed_agents=True, self_host_tts=False,
                      self_host_asr=False, cache_hit=0.85):
    """$ per 1000 call-minutes, decomposed by layer.

    `cache_hit` is the fraction of input tokens served from the prefix cache,
    billed at a tenth of the uncached rate. Omitting it overstates the LLM
    term several-fold -- the most common error in these estimates.
    """
    c = {}
    c["media"] = P_WEBRTC_MIN * 1000
    c["egress"] = 0.6 / 1024 * P_EGRESS_GB * 1000        # ~0.6 MB per minute
    c["telephony"] = P_TELEPHONY_IN * 1000 if telephony else 0.0
    c["agent"] = P_AGENT_MIN * 1000 if managed_agents else 0.0
    c["asr"] = 0.0 if self_host_asr else P_ASR_MIN * 1000
    spoken_chars = WPM * agent_talk_frac * CHARS_PER_WORD
    c["tts"] = 0.0 if self_host_tts else \
        spoken_chars / 1e6 * P_TTS_PER_MCHAR * 1000
    tok_in = ctx_tokens * turns_per_min
    tok_out = out_words * TOK_PER_WORD * turns_per_min
    in_cost = (tok_in * cache_hit / 1e6 * P_LLM_CACHED_PER_MTOK
               + tok_in * (1 - cache_hit) / 1e6 * P_LLM_IN_PER_MTOK)
    c["llm"] = (in_cost + tok_out / 1e6 * P_LLM_OUT_PER_MTOK) * 1000
    return c


# ---- scenarios ----------------------------------------------------------
SCENARIOS = [
    dict(name="1. sub-second tool-calling barge-in agent",
         target_ms=800, concurrent=50, aht_s=180, telephony=False,
         host=dict(),
         alloc=dict(endpoint=330, stt_final=90, ttft_llm=180, first_clause=60,
                    ttfb_tts=90, network=30)),
    dict(name="2. 10k-concurrent inbound support line",
         target_ms=1200, concurrent=10_000, aht_s=240, telephony=True,
         host=dict(managed_agents=False, self_host_tts=True,
                   self_host_asr=True),
         alloc=dict(endpoint=400, stt_final=110, ttft_llm=260, first_clause=90,
                    ttfb_tts=130, network=60)),
    dict(name="3. outbound collections, 500 lines",
         target_ms=1500, concurrent=500, aht_s=150, telephony=True,
         host=dict(self_host_tts=True),
         alloc=dict(endpoint=500, stt_final=120, ttft_llm=320, first_clause=100,
                    ttfb_tts=160, network=70)),
    dict(name="4. in-car assistant, offline-capable",
         target_ms=600, concurrent=1, aht_s=45, telephony=False,
         host=dict(managed_agents=False, self_host_tts=True,
                   self_host_asr=True, cache_hit=0.0),
         alloc=dict(endpoint=250, stt_final=60, ttft_llm=140, first_clause=40,
                    ttfb_tts=70, network=5)),
    dict(name="5. multilingual healthcare intake (HIPAA)",
         target_ms=1500, concurrent=800, aht_s=420, telephony=True,
         host=dict(),
         alloc=dict(endpoint=450, stt_final=140, ttft_llm=300, first_clause=90,
                    ttfb_tts=150, network=60)),
    dict(name="6. real-time interpreter, two humans",
         target_ms=1000, concurrent=200, aht_s=600, telephony=False,
         host=dict(agent_talk_frac=0.45),
         alloc=dict(endpoint=300, stt_final=120, ttft_llm=220, first_clause=80,
                    ttfb_tts=140, network=40)),
]


def report(s):
    print(f"--- {s['name']}")
    used, slack = latency_budget(s["target_ms"], s["alloc"])
    print(f"  latency  target {s['target_ms']:5d} ms | allocated {used:5d} ms | "
          f"slack {slack:+5d} ms  [{'FEASIBLE' if slack >= 0 else 'INFEASIBLE'}]")
    worst = max(s["alloc"], key=s["alloc"].get)
    print(f"           largest term: {worst} = {s['alloc'][worst]} ms "
          f"({s['alloc'][worst]/used:.0%} of the allocation)")
    a = s["concurrent"]
    pool = pool_for(a, s["aht_s"])
    rho = safe_rho(pool, s["aht_s"])
    print(f"  capacity {a} concurrent = {a} E | pool {pool} workers "
          f"at safe rho {rho:.0%} ({pool-a} spare, {1-rho:.0%} headroom)")
    if s["telephony"]:
        print(f"           SIP channels at 1% blocking: {trunks_for(a)} "
              f"(utilisation {a/trunks_for(a):.0%})")
    g, per_gpu = gpus_for(a)
    print(f"  gpus     {g} x 24 GB at {per_gpu} sessions/GPU "
          f"(if self-hosting the LLM)")
    c = cost_per_1000_min(telephony=s["telephony"], **s["host"])
    tot = sum(c.values())
    model = c["asr"] + c["tts"] + c["llm"]
    top = sorted(c.items(), key=lambda kv: -kv[1])[:3]
    print(f"  cost     ${tot:.2f} per 1000 call-min | top: " +
          ", ".join(f"{k} ${v:.2f}" for k, v in top))
    share = f"{c['llm']/model:.1%}" if model > 0 else "n/a"
    print(f"           llm = {c['llm']/tot:.2%} of total, {share} of the "
          f"model layer | ${tot*a*60*24*30/1000:,.0f}/mo at full duty")
    print()


if __name__ == "__main__":
    print("DESIGN CALCULATOR -- six scenarios\n")
    for s in SCENARIOS:
        report(s)
    print("cost decomposition, fully managed inbound:")
    c = cost_per_1000_min(telephony=True)
    for k, v in sorted(c.items(), key=lambda kv: -kv[1]):
        print(f"  {k:11s} ${v:7.2f}  {v/sum(c.values()):6.2%}")
    print(f"  {'TOTAL':11s} ${sum(c.values()):7.2f}")
    print("\nthe same call with prefix caching turned off:")
    c2 = cost_per_1000_min(telephony=True, cache_hit=0.0)
    print(f"  llm ${c2['llm']:.2f} vs ${c['llm']:.2f} "
          f"({c2['llm']/c['llm']:.1f}x), total ${sum(c2.values()):.2f}")
    print("\nself-hosting the expensive layers instead:")
    for label, kw in (("TTS only", dict(self_host_tts=True)),
                      ("TTS + agents", dict(self_host_tts=True,
                                            managed_agents=False)),
                      ("TTS + agents + ASR", dict(self_host_tts=True,
                                                  managed_agents=False,
                                                  self_host_asr=True))):
        t = sum(cost_per_1000_min(telephony=True, **kw).values())
        print(f"  {label:20s} ${t:7.2f} ({t/sum(c.values())-1:+.0%})")
```

Output `[MEASURED]`:

```
DESIGN CALCULATOR -- six scenarios

--- 1. sub-second tool-calling barge-in agent
  latency  target   800 ms | allocated   780 ms | slack   +20 ms  [FEASIBLE]
           largest term: endpoint = 330 ms (42% of the allocation)
  capacity 50 concurrent = 50 E | pool 69 workers at safe rho 74% (19 spare, 26% headroom)
  gpus     2 x 24 GB at 30 sessions/GPU (if self-hosting the LLM)
  cost     $21.64 per 1000 call-min | top: agent $10.00, tts $6.19, asr $4.80
           llm = 0.92% of total, 1.8% of the model layer | $46,752/mo at full duty

--- 2. 10k-concurrent inbound support line
  latency  target  1200 ms | allocated  1050 ms | slack  +150 ms  [FEASIBLE]
           largest term: endpoint = 400 ms (38% of the allocation)
  capacity 10000 concurrent = 10000 E | pool 10257 workers at safe rho 98% (257 spare, 2% headroom)
           SIP channels at 1% blocking: 9970 (utilisation 100%)
  gpus     334 x 24 GB at 30 sessions/GPU (if self-hosting the LLM)
  cost     $10.66 per 1000 call-min | top: telephony $10.00, media $0.40, llm $0.20
           llm = 1.86% of total, 100.0% of the model layer | $4,603,718/mo at full duty

--- 3. outbound collections, 500 lines
  latency  target  1500 ms | allocated  1270 ms | slack  +230 ms  [FEASIBLE]
           largest term: endpoint = 500 ms (39% of the allocation)
  capacity 500 concurrent = 500 E | pool 556 workers at safe rho 90% (56 spare, 10% headroom)
           SIP channels at 1% blocking: 527 (utilisation 95%)
  gpus     17 x 24 GB at 30 sessions/GPU (if self-hosting the LLM)
  cost     $25.46 per 1000 call-min | top: telephony $10.00, agent $10.00, asr $4.80
           llm = 0.78% of total, 4.0% of the model layer | $549,866/mo at full duty

--- 4. in-car assistant, offline-capable
  latency  target   600 ms | allocated   565 ms | slack   +35 ms  [FEASIBLE]
           largest term: endpoint = 250 ms (44% of the allocation)
  capacity 1 concurrent = 1 E | pool 5 workers at safe rho 25% (4 spare, 75% headroom)
  gpus     1 x 24 GB at 30 sessions/GPU (if self-hosting the LLM)
  cost     $1.09 per 1000 call-min | top: llm $0.63, media $0.40, egress $0.06
           llm = 57.74% of total, 100.0% of the model layer | $47/mo at full duty

--- 5. multilingual healthcare intake (HIPAA)
  latency  target  1500 ms | allocated  1190 ms | slack  +310 ms  [FEASIBLE]
           largest term: endpoint = 450 ms (38% of the allocation)
  capacity 800 concurrent = 800 E | pool 870 workers at safe rho 92% (70 spare, 8% headroom)
           SIP channels at 1% blocking: 829 (utilisation 97%)
  gpus     27 x 24 GB at 30 sessions/GPU (if self-hosting the LLM)
  cost     $31.64 per 1000 call-min | top: telephony $10.00, agent $10.00, tts $6.19
           llm = 0.63% of total, 1.8% of the model layer | $1,093,625/mo at full duty

--- 6. real-time interpreter, two humans
  latency  target  1000 ms | allocated   900 ms | slack  +100 ms  [FEASIBLE]
           largest term: endpoint = 300 ms (33% of the allocation)
  capacity 200 concurrent = 200 E | pool 236 workers at safe rho 85% (36 spare, 15% headroom)
  gpus     7 x 24 GB at 30 sessions/GPU (if self-hosting the LLM)
  cost     $26.59 per 1000 call-min | top: tts $11.14, agent $10.00, asr $4.80
           llm = 0.75% of total, 1.2% of the model layer | $229,774/mo at full duty

cost decomposition, fully managed inbound:
  telephony   $  10.00  31.60%
  agent       $  10.00  31.60%
  tts         $   6.19  19.55%
  asr         $   4.80  15.17%
  media       $   0.40   1.26%
  llm         $   0.20   0.63%
  egress      $   0.06   0.19%
  TOTAL       $  31.64

the same call with prefix caching turned off:
  llm $0.63 vs $0.20 (3.2x), total $32.07

self-hosting the expensive layers instead:
  TTS only             $  25.46 (-20%)
  TTS + agents         $  15.46 (-51%)
  TTS + agents + ASR   $  10.66 (-66%)
```

Three load-bearing details. **`pool_for` searches upward from the concurrency rather than
dividing by a fixed utilisation**, because the safe utilisation is itself a function of pool
size — dividing by 0.7 gives 71 workers for 50 E where the correct answer is 69, and gives
14 286 for 10 000 E where the correct answer is 10 257, a 39% over-provision. **`cache_hit`
defaults to 0.85 and it is the difference between the LLM being 0.63% and 2% of the bill**;
the "caching off" line prints the 3.2× so the assumption cannot hide. And **scenario 4 sets
`cache_hit=0.0` deliberately** — a local model has no vendor prefix cache to hit, which is
part of why the LLM becomes the majority of a very small bill.

---

## 4. How production does it

**Shipped sub-second agents cheat, honestly.** They start speaking before they know the
answer — filler, acknowledgement, a restatement of the question — because `ttfa` is what the
user perceives and answer time is what they tolerate. Every fast commercial agent does this,
and a candidate who proposes it is describing the state of the art rather than cutting a
corner.

**Large inbound deployments self-host the model layer and rent the telephony**, which is
exactly what §2.2's arithmetic recommends: the crossover for self-hosting agents was around
290k call-minutes/month and media around 3.5M, both long past at 10 000 concurrent, while
carrier interconnect is not a thing you build.

**Regulated deployments choose vendors by paperwork, then optimise inside that set.** The BAA
or ZDR tier list *is* the shortlist, and it is usually short.

**Interpreters and companions are where audio-native models are actually deployed**, because
they are the products where prosody is the value and tool calls are absent — precisely the
region where the S2S tradeoff table favours them.

**Edge assistants ship a small local model plus a cloud escalation path**, degrading rather
than failing when connectivity drops, which is the pragmatic reading of "offline-capable".

---

## 5. At scale

**Answer with the dominant term first.** In five of six scenarios that is the endpointer for
latency and telephony-plus-orchestration for cost. Leading with either signals that you have
done the arithmetic; leading with model choice signals that you have not.

**State infeasibility early and precisely.** "780 of 800 ms allocated, and 330 of that is
the endpointer" is a far stronger opening than a component diagram, and it reframes the
conversation onto the requirement.

**Name the assumption that moves the answer.** Prefix-cache hit rate (3.2× on the LLM
term), agent talk fraction (TTS became the top line at 45%), and pool size (25% to 98% safe
utilisation) each swing a result more than most architecture choices.

**Distinguish `ttfa` from answer time**, always. Most "sub-second" requirements are
satisfiable on the first and not the second, and conflating them is how teams commit to
something impossible.

**Carry the crossovers.** Vendor below roughly 15k min/month, managed platform to ~133k,
managed platform with your own agents to ~2.04M, fully self-hosted beyond. Knowing where a
deployment sits on that ladder answers half the questions before they are asked.

---

## 6. Exercises

**E9.1.1** Run the §3 calculator. Change scenario 1's endpointer to a fixed 700 ms timeout
and report whether the design remains feasible. State what you would tell the product owner.

**E9.1.2** Replace `pool_for` with the naive `ceil(concurrent / 0.7)` and report the
over-provision for each of the six scenarios. Express the worst case as a monthly dollar
figure.

**E9.1.3** Add a seventh scenario of your own with real requirements from your work. Report
slack, pool, trunks and cost, and identify the dominant term in each.

**E9.1.4** Sweep `cache_hit` from 0 to 0.95 and plot total cost. State the cache hit rate
below which prompt restructuring for cache stability becomes the highest-value cost work.

**E9.1.5** For scenario 2, compute the cost of splitting into three regional pools instead of
one, in both channels and workers. Present it as the price of data residency.

**E9.1.6** Modify the calculator to model speech-to-speech: replace the endpoint, `stt_final`,
`ttft_llm`, `first_clause` and `ttfb_tts` terms with a frame plus a forward pass, and add
audio-token cost. Report which of the six scenarios it improves and which it makes worse.

**E9.1.7** For scenario 5, list every processor that would need a BAA and check which of your
preferred vendors offers one. Report the shortlist and what it costs.

**E9.1.8** Take scenario 6 and design the session-segmentation scheme required by the
audio-token context tax. State the segment length, what carries across the boundary, and what
the user notices.

---

## 7. Interview drill

> "Design a voice agent for restaurant reservations. Sub-second responses. Go."

I would not start with a diagram. I would start by turning "sub-second" into two numbers,
because the requirement is ambiguous in a way that decides the whole design: sub-second to
*start speaking* is achievable, and sub-second to *deliver the reservation confirmation* is
not, because confirming a booking means a call to a reservation system I do not control.
Those are `ttfa` and answer time, and I would ask which one the requirement means before
allocating anything.

Then the budget, out loud. Endpointing 330 ms, ASR finalisation 90, LLM first token 180,
tokens-to-clause 60, TTS first byte 90, network 30 — 780 of 800 ms, so it is feasible with
20 ms of slack and no room for a mistake. The thing to notice is that the endpointer is 42%
of that, larger than the LLM and TTS together, so the first engineering decision is an
adaptive endpointer rather than a fixed timeout; the measurement I would cite reached 330 ms
at a 2.78% cut-off rate where a fixed 700 ms timeout was worse on both axes. If someone
tells me the endpointer is a detail, the budget says otherwise.

For the tool call, the answer is filler plus speculative execution. Reservations are a
lookup-then-mutate flow, so I would start the availability query *while the user is still
speaking* — the intent is usually clear before the utterance ends — and speak an
acknowledgement while it completes. In the numbers I would bring, filler took `ttfa` p50
from 1815 ms to 551 ms with no change in when the answer actually arrived. That is the single
largest win available and it costs a product decision, not an engineering one.

Barge-in matters here more than in most designs, because people interrupt reservation agents
constantly to correct the party size or the time. That needs a priority interrupt path, not a
flag and not an in-band frame — both of those left 1220 ms of stale audio in the measurement
against 20 ms for a priority path — plus an ordered playback report so the transcript
truncates to what the caller actually heard. Otherwise the next turn contains a time the
agent never successfully spoke, and the model behaves as though it did.

On scale and cost I would give the shape rather than a fake precision: at 50 concurrent, a
69-worker pool at 74% safe utilisation, because a small pool cannot run at 90%; roughly
$22 per 1000 call-minutes, of which orchestration and TTS are three quarters and the LLM is
under 1%. So if we are asked to cut cost, we cut TTS characters — shorter replies — or move
off managed agent minutes, and we do not spend a week choosing a cheaper model.

The premise I would push back on hardest is the requirement itself. Sub-second is expensive
and reservations are not a latency-critical product: callers accept a two-second pause for
"let me check that" far more readily than they accept being cut off mid-sentence. I would
rather spend the budget on entity accuracy for names, times and party sizes — the things that
make the booking correct — and quote the endpointer's cut-off rate as the metric to defend.
If the requirement is genuinely a hard sub-second, then the honest answer includes what we
are giving up to get it.

---

## Sources

- Published prices retrieved 2026-08-22 and used throughout §2 and §3: LiveKit Cloud WebRTC participant minutes $0.0004/min, managed agent minutes $0.01/min, data egress $0.10/GB; US local inbound $0.01/min; Deepgram Nova-3 $0.0048/min; Deepgram Aura-2 $30/M characters; Gemini 2.5 Flash-Lite $0.10 uncached input / $0.01 cached input / $0.40 output per M tokens. Marked `[UNVERIFIED PRICE]` where a vendor page could not be re-confirmed at the time of writing.
- Erlang B, Erlang C and the M/M/n conditional-wait distribution, derived and measured in [`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md), including the safe-utilisation-versus-pool-size result reproduced by `safe_rho`.
- Prior measurements in this curriculum reused rather than repeated: adaptive endpointing at 330 ms / 2.78% cut-off against a fixed 700 ms timeout at 3.04% ([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)); filler speech cutting `ttfa` p50 from 1815 ms to 551 ms with no change in answer time ([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)); priority-path barge-in leaving 20 ms of stale audio against 1220 ms for a flag or an in-band FIFO interrupt ([`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)); full-duplex speech-to-speech at 343 ms against cascaded 1370 ms, and S2S-plus-tool-call at 1499 ms ([`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)); the 212.5 tokens/s dual-stream audio rate filling a 32k context in 2.6 minutes (same chapter); chatty-versus-terse persona changing TTS cost from $6.93 to $29.40 per 1000 calls ([`../05-llm-layer/05-persona-design.md`](../05-llm-layer/05-persona-design.md)); GPU packing headroom from [`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md); and the platform crossovers (~15k, ~133k, ~2.04M call-minutes/month) from [`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md).
- `[MEASURED]`: every number in §2 is the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. The capacity and trunk figures are exact evaluations of Erlang B and Erlang C; the cost figures are exact arithmetic over the published prices above. The *inputs* — per-stage latency allocations, concurrency, mean session durations, 1400 context tokens, 4 turns/min, 40-word replies, a 25% agent talk fraction, an 85% prefix-cache hit rate, and 0.42 GB per session of VRAM — are `[INFERENCE]` values chosen to be representative of each scenario, not measurements of a specific deployment. Substituting your own changes every absolute figure; the structural conclusions (the endpointer dominates the latency allocation, safe utilisation rises with pool size, the LLM is a rounding error unless everything else is self-hosted, and prefix caching moves the LLM term 3.2×) follow from the arithmetic rather than the inputs. The LLM's 0.63% share of a fully managed inbound call reproduces the ~0.6% figure established independently in [`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md).
