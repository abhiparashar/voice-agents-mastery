# Reliability

**What you'll be able to do after this:** compute call-level reliability from per-stage
availability and show why per-request SLOs mislead; know why a circuit breaker keyed on the
wrong signal never opens, and why one that does open can make user outcomes worse; design
the fallback ladder that upholds a never-dead-air invariant; and run the six drills that
find these bugs before your users do.

---

## 1. Intuition

Reliability for a voice agent is not "the service was up". A call is a **series system in
two dimensions**: it is clean only if every turn is clean, and a turn is clean only if every
stage worked. Multiply those and the arithmetic is brutal. Measured below, five stages at
individually respectable availability — 99.995% transport, 99.9% ASR, 99.7% LLM, 99.5%
tool API, 99.8% TTS — give a per-turn availability of 98.899%. Over a twenty-turn call that
is **80.14% of calls completing cleanly**. One call in five hits something.

That is the number your dashboard hides, because your dashboard reports per-request
availability, and per-request availability is the input to this calculation rather than the
answer to the question.

The second intuition is about *how* things fail. A web request fails and the user retries.
A voice call fails and the user hears **silence**, which they interpret as the agent being
broken, stupid, or gone — and then they start talking, which collides with your recovery
and turns one failure into a barge-in race. So the invariant is not "never fail", it is
**never leave dead air**: something must be said within a few hundred milliseconds of any
failure, even if what it says is a hedge.

The third is a correction. Retries and circuit breakers are not straightforwardly good.
Measured below, retrying twice cuts user-visible failures from 528 to 86 while sending
**64% more traffic to the already-sick provider**; a breaker keyed on call outcomes **never
opens at all**; and a breaker keyed correctly cuts provider load by 87% while raising
user-visible failures from 86 to **1152**. A breaker does not improve outcomes. It converts
slow failures into fast failures, and it is only a win when you have somewhere to fall back
to.

---

## 2. Rigour

### 2.1 A call is a series system

Let stage $j$ have availability $a_j$. A turn touching $m$ stages, and a call of $n$ turns:

$$
A_{\text{turn}} = \prod_{j=1}^{m} a_j, \qquad A_{\text{call}} = A_{\text{turn}}^{\,n}
$$

`[MEASURED]` from §3:

| Stage | Availability | Failures / 1000 turns |
|---|---|---|
| transport | 0.99995 | 0.05 |
| asr | 0.99900 | 1.00 |
| llm | 0.99700 | 3.00 |
| tool api | 0.99500 | 5.00 |
| tts | 0.99800 | 2.00 |
| **per turn** | **0.98899** | **11.01** |

| Turns / call | Clean calls | Bad calls / 1000 | With LLM+tool hedged |
|---|---|---|---|
| 1 | 98.90% | 11.0 | 99.69% |
| 5 | 94.62% | 53.8 | 98.47% |
| 10 | 89.52% | 104.8 | 96.96% |
| 20 | **80.14%** | 198.6 | **94.01%** |
| 40 | 64.22% | 357.8 | 88.39% |

Four conclusions, each of which changes a decision.

**Conversation length is a reliability parameter.** A 40-turn call is twice as likely to
break as a 20-turn call. That makes response conciseness and successful task completion
reliability features, not just UX ones — an agent that resolves the issue in eight turns is
measurably more reliable than one that takes twenty, with identical infrastructure.

**Per-stage targets must be set from the call target, not chosen per team.** For 99% of
20-turn calls to be clean across five stages you need $0.99^{1/100} = 0.999900$ per stage —
**100 failures per million stage calls**. That is four nines *per stage*, which is a much
harder ask than any single team would set for itself, and it is the honest number.

**Redundancy beats reliability, per unit of effort.** Hedging just the two worst stages —
LLM and tool API — takes a 20-turn call from 80.14% to 94.01%. Getting the same improvement
by making those stages individually better would require roughly an order-of-magnitude
reduction in their failure rates. Parallel redundancy on a bad stage is nearly always
cheaper than perfecting it ([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)).

**The tool API is the weakest link and it is usually not yours.** 5 failures per 1000 turns
from a third-party API dominates the product. Your reliability work is mostly about
tolerating other people's systems.

### 2.2 Failure taxonomy

Classify by *what the user experiences*, because that determines the correct response:

| Failure | Detection | User experience if unhandled | Correct response |
|---|---|---|---|
| Provider 5xx / 429 | immediate, explicit | dead air, then nothing | hedge or fail over; respect `Retry-After` |
| Provider brownout (slow, not down) | latency, not errors | growing dead air | deadline, then fall back (§2.4) |
| LLM timeout | your deadline fires | 2+ s of silence | filler already speaking; degrade to a shorter model |
| TTS dies mid-utterance | stream ends early | sentence cut off mid-word | secondary TTS or cached audio; never repeat from the start |
| ASR stream drops | no finals arriving | agent ignores the user | reconnect with resume; buffer audio meanwhile |
| GPU OOM | process death | call drops | admission control to prevent it; session migration if not |
| ICE restart / network change | ICE state | 1–3 s glitch | let WebRTC handle it; do not tear down ([`02-webrtc-internals.md`](02-webrtc-internals.md)) |
| SIP trunk loss | signalling | call drops, no recovery | secondary trunk, different carrier |
| Agent process crash | supervisor | call drops | process isolation limits it to one call ([`05-scale-and-orchestration.md`](05-scale-and-orchestration.md)) |
| Deploy / drain | intentional | call drops if mishandled | drain, never kill ([`05-scale-and-orchestration.md`](05-scale-and-orchestration.md)) |

The distinction that matters most operationally is **down versus slow**. A 500 is easy: you
know immediately and can act. A provider that has gone from 200 ms to 4 s returns success,
so error-rate alerts stay green while every call degrades. Brownouts need **deadlines**, and
a deadline is a reliability mechanism, not a performance one.

### 2.3 Retries, breakers, and the two ways to get them wrong

`[MEASURED]` from §3 — a provider degrades to 45% per-attempt failure for 1200 of 4000
calls, two retries permitted:

| Policy | Requests during brownout | Amplification | User failures | Breaker opened |
|---|---|---|---|---|
| no retry | 1200 | 1.00× | 528 | 0 |
| retry ×2, no breaker | 1972 | 1.64× | 86 | 0 |
| breaker on **call** outcome | 1972 | 1.64× | 86 | **0** |
| breaker on **attempt** outcome | 158 | **0.13×** | **1152** | 1 |

Three results, and two of them are counterintuitive.

**Retries work, and they cost the provider.** 528 → 86 user-visible failures is a real
improvement, bought with 64% more load on a system that is already failing. That is the
amplification that turns a partial outage into a total one, and it is why retry budgets and
jitter exist. Retry at most once or twice, add jitter, and cap the fraction of your traffic
that may be retries.

**A circuit breaker keyed on call outcomes never opens.** This is the subtle bug and it is
common. If the breaker counts a failure only when a call fails *after all retries*, then at
45% per-attempt failure a call fails only $0.45^3 \approx 9\%$ of the time, so five
consecutive failures essentially never happen. The retries hide the failures from the
breaker — the two mechanisms are fighting. **Feed the breaker attempt-level outcomes**, or
an error *rate* over a sliding window, never the post-retry result.

**A working breaker makes user outcomes worse, on its own.** 86 → 1152 user failures, in
exchange for cutting provider load by 87%. The breaker is doing exactly its job: it protects
the dependency and gives up on the caller. It is the right mechanism *only* when paired with
a fallback that can serve those 1152 calls — a second provider, a cached response, or a
graceful degradation. **A circuit breaker without a fallback is a faster way to fail.** That
is the single most useful thing in this chapter, and it is why §2.4 exists.

Worth quoting for calibration: LiveKit's plugin defaults are
`APIConnectOptions(max_retry=3, retry_interval=2.0, timeout=10.0)` for model calls, and
`max_retry=16` for the worker's *connection to the server* — two different jobs with
appropriately different numbers. A 10 s timeout on a model call is far beyond a
conversational deadline, which tells you the framework's default is tuned for "eventually
succeed", and you must tighten it for "answer within the budget".

### 2.4 The never-dead-air invariant

State it as an invariant so it can be tested: **at no point during a call does the user hear
more than $D$ milliseconds of unexplained silence**, where $D$ is around 1000–1500 ms —
below the threshold at which people say "hello?" and begin talking over your recovery.

Upholding it needs a **fallback ladder** per failure mode: detect fast, then say *something*
cheap while the real recovery proceeds. `[MEASURED]` from §3, dead air in ms:

| Failure mode | No handling | Retry primary | Fallback ladder | Saved |
|---|---|---|---|---|
| tts dies mid-utterance | 8120 | 1020 | **300** | 7820 |
| llm timeout | 10000 | 3400 | **2150** | 7850 |
| tool api 5xx | 8800 | 1900 | **950** | 7850 |
| asr stream drops | 8400 | 1100 | **650** | 7750 |
| gpu OOM (session lost) | 8200 | 3400 | **450** | 7750 |
| sip trunk loss | 8000 | 8000 | **3000** | 5000 |
| **total** | **51520** | — | **7500** | **44020** |

The ladder's rungs, in order of preference:

1. **Pre-synthesised audio held in memory.** "One moment", "Let me check that", "Sorry, I
   missed that". Zero latency because it never touches TTS, and it is the only rung
   guaranteed to work when TTS is the thing that died. Every production voice agent should
   ship with a dozen of these.
2. **A secondary provider on the same stage.** Real recovery, at the cost of a second
   integration you must keep tested.
3. **Degrade the request.** A smaller model, a shorter answer, skip the retrieval, answer
   from the cache. Worse but present.
4. **Admit it and hand off.** "I'm having trouble with that — let me get you to someone who
   can help." A clean escalation is a successful outcome, not a failure
   ([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)).

Note the `llm timeout` row stays at 2150 ms even with the ladder, because detection itself
costs 2000 ms — you cannot fill silence you have not noticed yet. **Detection latency is the
floor on dead air**, which is the argument for aggressive deadlines and for starting filler
speech *speculatively* rather than after a failure is confirmed. Filler was previously
measured to cut `ttfa` p50 from 1815 ms to 551 ms with no change in answer time; here it is
the same mechanism doing reliability work.

Two rules that follow. **Never restart an utterance from the beginning** — the user already
heard the first half, and repeating it is worse than an abrupt continuation; resume from the
playback position ([`03-pipeline-architecture.md`](03-pipeline-architecture.md)). And
**fallback audio must be uninterruptible-safe**: if the user barges in over "one moment",
that is a real interruption and must be honoured, so the filler goes through the same
interrupt path as everything else.

### 2.5 SLOs for a call

Per-request SLOs do not compose into a promise about conversations, so define the SLIs at
call granularity:

| SLI | Definition | Suggested SLO |
|---|---|---|
| Call completion | call ended by a participant, not by an error | 99.5% |
| Clean call | no turn required a fallback rung | 95% |
| Dead-air violations | turns with unexplained silence > 1.5 s | < 0.5% of turns |
| Turn latency | `eou_to_ttfa` p95 | < 1.5 s |
| Task success | the user's goal was achieved | domain-specific, measured offline |
| Truncation correctness | logged assistant turn is a prefix of what was heard | 100% (an invariant, not an SLO) |

The last row is deliberately not a percentage. Some properties are invariants — violating
them is a bug, and an error budget for them is a category mistake.

Error budgets need one voice-specific adjustment: **budget in call-minutes, not calls**, and
weight by position in the call. Failing a caller in the first ten seconds is recoverable —
they redial. Failing them at minute nine, after they have given you their details, loses the
task and the customer. Weighting the budget by elapsed session time makes the priority
explicit.

### 2.6 Drills

Reliability claims are worthless untested, and every one of these has found a real bug:

1. **Kill TTS mid-utterance.** Does the user hear silence, a restart from the beginning, or
   a clean continuation? Does the transcript record what was heard?
2. **Make the LLM slow, not down.** 8 s latency, 200 responses. Does the deadline fire? Does
   filler cover it? Does the breaker stay closed (correctly, since nothing is erroring)?
3. **Return 429 with `Retry-After`.** Is it honoured, or does your retry loop ignore it and
   get you banned?
4. **Drop the ASR WebSocket.** Does it reconnect with resume, and what happens to the audio
   captured during the gap?
5. **Force TURN-only.** Blocks UDP, forces relay, doubles bandwidth, adds latency
   ([`02-webrtc-internals.md`](02-webrtc-internals.md)). Do calls still work?
6. **Deploy under load.** Drain the fleet with live calls. Count sessions that ended
   non-naturally; the answer must be zero.

Run them in CI where possible and as a scheduled game day where not
([`../08-eval-safety/02-simulation-and-load.md`](../08-eval-safety/02-simulation-and-load.md)).

---

## 3. From scratch

Series-system arithmetic, breaker dynamics under a brownout, and the dead-air ladder.
Standalone, stdlib only, deterministic.

```python
"""Reliability for calls, not requests.

Part A -- the arithmetic nobody does. A call is a series system: it is clean
only if every turn is clean, and a turn is clean only if every stage worked.
Per-request availability therefore lies about calls, and the lie grows with
conversation length.

Part B -- circuit breakers under a brownout (partial, not total, failure).
Naive retries amplify load on an already-sick provider; a breaker sheds it.
Measured: requests sent to the sick provider, user-visible failures, and how
long recovery takes.

Part C -- the never-dead-air invariant. When a stage dies mid-utterance the
user hears silence. Measure the dead air for each failure mode, with and
without a fallback ladder.

Deterministic: fixed seed, stdlib only.
"""

import random

SEED = 57

# --------------------------------------------------------------- Part A
STAGES = [
    ("transport", 0.99995),
    ("asr", 0.9990),
    ("llm", 0.9970),
    ("tool api", 0.9950),
    ("tts", 0.9980),
]


def turn_availability(stages, hedged=()):
    """Series product, except hedged stages fail only if both attempts fail."""
    a = 1.0
    for name, p in stages:
        a *= (1 - (1 - p) ** 2) if name in hedged else p
    return a


def part_a():
    print(f"{'stage':12s} {'availability':>13} {'failures / 1000 turns':>23}")
    for name, p in STAGES:
        print(f"{name:12s} {p:12.5f} {(1-p)*1000:22.2f}")
    a_turn = turn_availability(STAGES)
    print(f"\nper-turn availability = product = {a_turn:.5f} "
          f"({(1-a_turn)*1000:.2f} bad turns per 1000)\n")
    print(f"{'turns/call':>11} {'clean calls':>12} {'bad calls/1000':>15} "
          f"{'+ hedged llm+tool':>18}")
    hedged = turn_availability(STAGES, hedged={"llm", "tool api"})
    for n in (1, 5, 10, 20, 40):
        clean = a_turn ** n
        clean_h = hedged ** n
        print(f"{n:11d} {clean:11.2%} {(1-clean)*1000:14.1f} {clean_h:17.2%}")
    print(f"\nper-stage availability needed for 99% clean 20-turn calls, "
          f"5 stages:")
    # a^(5*20) = 0.99  ->  a = 0.99 ** (1/100)
    need = 0.99 ** (1 / 100)
    print(f"  {need:.6f}  = {(1-need)*1e6:.0f} failures per million stage calls")


# --------------------------------------------------------------- Part B
def part_b(n_calls=4000, brownout=(1000, 2200), sick_fail=0.45, retries=2):
    """A provider degrades to 45% failure for a window. Four policies.

    The subtle one: a breaker fed CALL outcomes never trips, because retries
    hide the failures from it. It must be fed ATTEMPT outcomes.
    """
    lo, hi = brownout
    print(f"provider brownout: calls {lo}-{hi} of {n_calls}, "
          f"{sick_fail:.0%} attempt failure, {retries} retries allowed\n")
    print(f"{'policy':30s} {'reqs in brownout':>17} {'amplif.':>8} "
          f"{'user failures':>14} {'breaker opened':>15}")

    def run(policy):
        rng = random.Random(SEED)
        in_window = 0
        user_fail = 0
        state, streak, opened_at, probes = "closed", 0, None, 0
        opens = 0
        for i in range(n_calls):
            sick = lo <= i < hi
            p_fail = sick_fail if sick else 0.001

            if policy.startswith("breaker") and state == "open":
                if i - opened_at >= 50:
                    state, probes = "half_open", 0
                else:
                    user_fail += 1            # fail fast; fallback speaks
                    continue

            attempts = 1 + (retries if policy != "no_retry" else 0)
            if policy.startswith("breaker") and state == "half_open":
                attempts = 1                  # one probe, never retried
            ok = False
            attempt_fails = 0
            for _ in range(attempts):
                if sick:
                    in_window += 1
                if rng.random() >= p_fail:
                    ok = True
                    break
                attempt_fails += 1
            if not ok:
                user_fail += 1

            if policy == "breaker_call":
                # WRONG: only a fully failed call counts as a failure
                streak = streak + 1 if not ok else 0
                if streak >= 5:
                    state, opened_at, streak = "open", i, 0
                    opens += 1
            elif policy == "breaker_attempt":
                # RIGHT: every failed attempt counts
                streak += attempt_fails
                if ok and attempt_fails == 0:
                    streak = max(0, streak - 1)
                if state == "half_open":
                    if ok:
                        probes += 1
                        if probes >= 5:
                            state, streak = "closed", 0
                    else:
                        state, opened_at = "open", i
                elif streak >= 12:
                    state, opened_at, streak = "open", i, 0
                    opens += 1
        return in_window, user_fail, opens

    baseline = None
    for policy, label in (("no_retry", "no retry"),
                          ("retry", "retry x2, no breaker"),
                          ("breaker_call", "breaker on CALL outcome"),
                          ("breaker_attempt", "breaker on ATTEMPT outcome")):
        win, uf, opens = run(policy)
        if baseline is None:
            baseline = win
        print(f"{label:30s} {win:17d} {win/baseline:7.2f}x {uf:14d} "
              f"{opens:15d}")


# --------------------------------------------------------------- Part C
LADDER = {
    # failure mode          : (detect_ms, primary_fix_ms, canned_fix_ms)
    "tts dies mid-utterance": (120, 900, 180),
    "llm timeout":            (2000, 1400, 150),
    "tool api 5xx":           (800, 1100, 150),
    "asr stream drops":       (400, 700, 250),
    "gpu OOM (session lost)": (200, 3200, 250),
    "sip trunk loss":         (1500, 0, 0),
}


def part_c():
    print(f"{'failure mode':24s} {'no handling':>12} {'retry primary':>14} "
          f"{'fallback ladder':>16} {'saved':>8}")
    tot_none = tot_lad = 0
    for mode, (detect, primary, canned) in LADDER.items():
        none = 8000 if primary == 0 else detect + 8000   # user hangs up
        retry = detect + primary if primary else 8000
        ladder = detect + min(canned, primary) if primary or canned else 3000
        tot_none += none
        tot_lad += ladder
        print(f"{mode:24s} {none:9d}ms {retry:11d}ms {ladder:13d}ms "
              f"{none-ladder:6d}ms")
    print(f"\n{'total dead air':24s} {tot_none:9d}ms {'':11s}  {tot_lad:13d}ms "
          f"{tot_none-tot_lad:6d}ms")
    print(f"\ndead air over 2000 ms is when users say 'hello?' and start talking")
    print(f"over the recovery, which turns one failure into a barge-in race")


if __name__ == "__main__":
    print("PART A -- a call is a series system\n")
    part_a()
    print("\n\nPART B -- retries amplify a brownout; breakers shed it\n")
    part_b()
    print("\n\nPART C -- the never-dead-air invariant\n")
    part_c()
```

Output `[MEASURED]`:

```
PART A -- a call is a series system

stage         availability   failures / 1000 turns
transport         0.99995                   0.05
asr               0.99900                   1.00
llm               0.99700                   3.00
tool api          0.99500                   5.00
tts               0.99800                   2.00

per-turn availability = product = 0.98899 (11.01 bad turns per 1000)

 turns/call  clean calls  bad calls/1000  + hedged llm+tool
          1      98.90%           11.0            99.69%
          5      94.62%           53.8            98.47%
         10      89.52%          104.8            96.96%
         20      80.14%          198.6            94.01%
         40      64.22%          357.8            88.39%

per-stage availability needed for 99% clean 20-turn calls, 5 stages:
  0.999900  = 100 failures per million stage calls


PART B -- retries amplify a brownout; breakers shed it

provider brownout: calls 1000-2200 of 4000, 45% attempt failure, 2 retries allowed

policy                          reqs in brownout  amplif.  user failures  breaker opened
no retry                                    1200    1.00x            528               0
retry x2, no breaker                        1972    1.64x             86               0
breaker on CALL outcome                     1972    1.64x             86               0
breaker on ATTEMPT outcome                   158    0.13x           1152               1


PART C -- the never-dead-air invariant

failure mode              no handling  retry primary  fallback ladder    saved
tts dies mid-utterance        8120ms        1020ms           300ms   7820ms
llm timeout                  10000ms        3400ms          2150ms   7850ms
tool api 5xx                  8800ms        1900ms           950ms   7850ms
asr stream drops              8400ms        1100ms           650ms   7750ms
gpu OOM (session lost)        8200ms        3400ms           450ms   7750ms
sip trunk loss                8000ms        8000ms          3000ms   5000ms

total dead air               51520ms                       7500ms  44020ms

dead air over 2000 ms is when users say 'hello?' and start talking
over the recovery, which turns one failure into a barge-in race
```

Three load-bearing details. **The `breaker_call` and `retry` rows are byte-identical, and
that is the finding, not a copy-paste error** — the breaker's counter is fed post-retry
outcomes, so it observes a 9% failure rate instead of 45% and never reaches its threshold.
If you take one thing from this listing, it is that retries and breakers must not share a
signal. **`turn_availability` models hedging as $1-(1-p)^2$**, which assumes the two
attempts fail *independently*; that is exactly the assumption that breaks when both hit the
same overloaded provider or the same region, so treat the hedged column as an upper bound.
And **Part C's `llm timeout` row is dominated by `detect_ms`, not by the fix** — 2000 ms of
the 2150 ms is noticing, which is why the useful lever is the deadline, not the recovery.

---

## 4. How production does it

**LiveKit** separates the two retry jobs cleanly:
`APIConnectOptions(max_retry=3, retry_interval=2.0, timeout=10.0)` for plugin model calls
and `max_retry=16` for the worker's control connection to the server. It also has the
pieces §2.4 needs — `resume_false_interruption=True` with
`false_interruption_timeout=2.0` is precisely a recovery from a spurious stop
([`../07-livekit/02-agents-framework.md`](../07-livekit/02-agents-framework.md)). What it
does not give you is the fallback ladder; the pre-synthesised audio and the provider
failover are yours to build.

**Every mature voice product ships canned audio.** Listen carefully to a commercial agent
under load and you will hear the same three filler phrases with identical prosody — that is
rung 1 of §2.4, and the reason the prosody is identical is that it is a cached WAV, not a
synthesis.

**`Retry-After` is respected by the good clients and ignored by most hand-rolled ones.**
Providers rate-limit precisely during the incidents when you most want to retry, and
ignoring the header converts a throttle into a ban.

**Deadlines beat timeouts, and propagate.** A per-stage timeout does not bound the turn; a
turn-level deadline, decremented and passed down, does. This is the same discipline gRPC
formalises, and it is worth reimplementing even when your calls are HTTP.

**Process isolation is the cheapest reliability mechanism available.** One process per
session turns "a native library segfaulted" from an outage into a single dropped call
([`05-scale-and-orchestration.md`](05-scale-and-orchestration.md)).

---

## 5. At scale

**Correlated failures are the only ones that matter.** §2.1's independence assumption is
the weak point: one provider outage, one region loss, or one bad deploy fails every session
simultaneously, and no amount of per-stage availability helps. Diversify the *dimension* of
the redundancy — a second vendor beats a second instance of the same vendor, which beats a
retry to the same endpoint.

**Hedging costs money linearly and helps sub-linearly.** Previously measured, hedging took
p95 from 3288 ms to 2351 ms at the cost of 1.2 wasted calls per turn. Hedge the stages that
dominate §2.1's failure budget, not everything.

**Retry budgets, not retry counts.** Cap retries as a fraction of total traffic (a few
percent) so that a widespread brownout cannot produce §2.3's amplification across your
whole fleet at once.

**Fail open on non-essential paths.** Guardrails, logging, analytics and memory writes must
not be able to fail a call. Anything not on the critical path gets a short deadline and a
shrug ([`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)).

**Health checks must exercise the real path.** A worker that reports healthy because its
HTTP endpoint answers, while its GPU is wedged, is worse than one that crashes. Check the
thing you depend on.

**Drills must run automatically or they rot.** The six drills in §2.6 have a half-life; put
the mechanisable ones in CI and schedule the rest, or you will discover on the day that the
secondary TTS integration stopped working three months ago.

---

## 6. Exercises

**E6.7.1** Run the §3 listing with your own measured per-stage availabilities and your own
median turns per call. Report clean-call rate and the per-stage target implied by a 99%
clean-call goal.

**E6.7.2** Extend Part A to model *correlated* failure: with probability $q$ all stages fail
together. Show how quickly the hedged column loses its advantage as $q$ grows, and state the
$q$ at which hedging stops being worth its cost.

**E6.7.3** Fix the `breaker_call` policy so the breaker sees attempt-level outcomes, and
confirm it now opens. Then measure the combination of a working breaker *plus* a fallback and
report user failures — the row this chapter argues you should actually ship.

**E6.7.4** Add jitter and a retry budget (max 5% of traffic may be retries) to Part B.
Report the amplification during the brownout and the user-failure count.

**E6.7.5** Implement rung 1 of the ladder: pre-synthesised fallback audio, played through
the normal interrupt path. Prove a user barge-in over the filler is honoured.

**E6.7.6** Instrument dead air directly — silence between `t_eou` and `ttfa`, and gaps
within agent speech — and report the distribution from a day of real calls. State your
`D` and your violation rate.

**E6.7.7** Run drill 2 from §2.6 (LLM slow, not down) against your system. Report the dead
air, whether any alert fired, and which of the two your on-call would have noticed.

**E6.7.8** Write the call-level SLO document for your agent: SLIs, targets, error budget in
call-minutes weighted by session position, and the invariants that are not SLOs.

---

## 7. Interview drill

> "Every service in our voice stack reports over 99.5% availability, and our SLO dashboard
> is green. Yet roughly one call in five has a visible glitch. Where's the discrepancy?"

There is no discrepancy — the dashboard and the complaint are both correct, and reconciling
them is arithmetic. A call is a series system in two dimensions: a turn is clean only if
every stage worked, and a call is clean only if every turn was clean. With five stages at
99.5% to 99.995%, per-turn availability multiplies out to about 98.9%, and over a twenty-turn
conversation that gives roughly 80% of calls completing cleanly. One in five. The number
they are seeing is exactly what their per-service numbers predict; the mistake is reporting
per-request availability and reading it as a promise about calls.

So the first change is to measure the thing customers experience: a call-level SLI. Call
completion, clean-call rate — no turn needed a fallback — and dead-air violations per turn.
Those compose downward into per-stage targets rather than upward from them, and the implied
targets are sobering: for 99% of twenty-turn calls to be clean across five stages you need
about 99.99% per stage, a hundred failures per million. No individual team would have set
that target for itself, which is precisely why it has to be derived from the call target.

Second, I would fix it with redundancy rather than perfection, because the leverage is much
better. Hedging just the two worst stages — the LLM and the third-party tool API — takes the
twenty-turn clean rate from about 80% to about 94% in the same model. Achieving that by
making those two stages individually better would need roughly an order-of-magnitude
reduction in their failure rates, which is a multi-quarter project against a vendor we do
not control. I would also point out that shortening conversations is a reliability lever
nobody thinks of as one: a forty-turn call is twice as likely to break as a twenty-turn call
on identical infrastructure, so response conciseness and first-contact resolution show up
directly in this arithmetic.

Third, and this is where I would spend the most time, I would look at what "glitch" means,
because the fix depends on it. If it is dead air, the invariant to enforce is that the user
never hears more than about a second and a half of unexplained silence, and the mechanism is
a fallback ladder — pre-synthesised audio first, because it is the only rung that still works
when TTS is what failed, then a secondary provider, then a degraded answer, then a clean
handoff. In the model I would bring, that ladder takes total dead air across six failure
modes from about 51 s to about 7.5 s. And notably the LLM-timeout row is dominated by
*detection*, 2000 of its 2150 ms, so the lever there is a tighter deadline and speculative
filler, not a faster recovery.

The senior addition is scepticism about two things. The independence assumption in that
arithmetic is doing a lot of work, and real failures are correlated — one vendor outage,
one region, one bad deploy — so I would want the redundancy to differ in *kind*, a second
vendor rather than a second instance. And I would audit our circuit breakers before trusting
them, because a breaker fed post-retry outcomes never opens: with two retries at a 45%
per-attempt failure rate, a call fails only about 9% of the time, so a five-consecutive-
failure threshold is never reached, and in the measurement that policy behaved identically
to having no breaker at all. Worse, a breaker that *does* work makes user outcomes worse on
its own — it cut provider load by 87% while raising user-visible failures from 86 to 1152 —
so it is only correct paired with the fallback. A breaker without a fallback is just a
faster way to fail.

The premise worth questioning is whether all five glitches per twenty-five calls are the
same event. I would classify them before spending: dead air, self-interruption, misheard
entities and dropped calls have entirely different owners, and the series-system argument
only explains the first and the last.

---

## Sources

- `livekit/agents` 1.7.0 — `APIConnectOptions(max_retry=3, retry_interval=2.0, timeout=10.0)` for plugin model calls and `max_retry=16` for the worker control connection, quoted in §2.3 and §4; `resume_false_interruption=True` with `false_interruption_timeout=2.0` from `voice/turn.py`, cited in §4 as a recovery mechanism.
- Nygard, M., *Release It!*, 2nd ed., Pragmatic Bookshelf 2018 — the circuit-breaker and bulkhead patterns, and the "stability antipatterns" (integration points, cascading failure, retry storms) that §2.3 measures.
- Beyer, Jones, Petoff & Murphy (eds.), *Site Reliability Engineering*, O'Reilly 2016 — error budgets, and the retry-budget-as-a-fraction-of-traffic discipline recommended in §5 rather than per-request retry counts.
- Dean, J. & Barroso, L. A., "The Tail at Scale", *Communications of the ACM* 56(2), 2013 — hedged requests and the general argument that tail latency in a series system dominates user experience; the basis for §2.1's hedging column.
- RFC 9110 §10.2.3 (`Retry-After`) — the header whose neglect in §4 converts a throttle into a ban.
- Prior measurements in this curriculum reused rather than repeated: hedging taking p95 from 3288 ms to 2351 ms at 1.2 wasted calls per turn, and deadline enforcement taking p99 from 4956 ms to 2961 ms at 3.1% degraded answers ([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)); filler speech cutting `ttfa` p50 from 1815 ms to 551 ms with no change in answer time, cited in §2.4.
- `[MEASURED]`: all three tables are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only, `SEED = 57`. Part A is exact arithmetic, but its five per-stage availability figures are `[INFERENCE]` representative values rather than measurements of a specific deployment, and it assumes independent failures — an assumption §5 argues is the weakest link. Part B is a discrete simulation of one brownout shape (45% per-attempt failure over 30% of the call sequence); the breaker thresholds are chosen to be conventional, and the qualitative findings (retries amplify load, a call-outcome-keyed breaker never opens, a working breaker trades provider load for user failures) are robust to those choices while the exact counts are not. Part C's per-mode detection and recovery times are `[INFERENCE]` estimates chosen to be defensible for a cascaded pipeline, not measurements; the structural result — that detection latency, not recovery, dominates the LLM-timeout row — follows from the arithmetic rather than the specific numbers.
