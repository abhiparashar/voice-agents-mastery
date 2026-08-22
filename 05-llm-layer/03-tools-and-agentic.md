# Tools and Agentic Behaviour

**What you'll be able to do after this:** say precisely what makes a voice system an agent
rather than a talking FAQ; separate the latency instruments that fix perception from the ones
that fix the actual wait, with measured numbers for each; make tool calls safe under
at-least-once execution; turn failures into speech a caller can act on; and choose between a
constrained state machine and open LLM agency on evidence rather than taste.

---

## 1. Intuition

An agent is a system that **chooses its own next step and can change the world**. A model that
only answers questions is a talking FAQ, however good the answers are. Two capabilities make
the difference: tools, which give it effects, and state, which lets one turn depend on the
last ten. Everything hard in this chapter comes from adding those two things to a system with
a ~300 ms deadline and no screen.

**A text agent has a spinner. A voice agent has silence.** In a chat UI, a five-second tool
call shows a progress indicator and the user waits calmly. On a phone call, five seconds of
silence reads as a dropped line, and the caller says "hello?" — which your VAD detects as a
new turn, which cancels or corrupts the reply you were about to give. Latency does not merely
annoy; it actively breaks the turn-taking machinery
([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)).

**A tool call costs two model round trips, not one.** The model must first emit the call, then
be re-invoked with the result. `ttft_llm` is paid twice, and the second prefill is larger
because the tool output is now in the context
([`02-context-and-memory.md`](02-context-and-memory.md) §2.2). Any turn that calls a tool is
structurally slower than any turn that does not, before the tool itself does any work.

**Everything runs at least once.** Retries, hedged requests, a user repeating "yes, book it",
and an ASR duplicate all produce the same call twice. In text this is a nuisance; in voice it
is two charges on a card. Idempotency is not a nicety here, it is the difference between a
demo and a system you can point at production.

---

## 2. Rigour

### 2.1 Levels of agency

"Agentic" is used loosely. Four distinguishable levels, with the property that matters:

| Level | Control flow | Tools | Failure mode | Where it fits |
|---|---|---|---|---|
| **Scripted IVR** | fixed graph | none/fixed | cannot handle anything unanticipated | menus, DTMF |
| **Slot filler** | fixed graph, LLM fills slots | per-state | rigid, but predictable | booking, payments |
| **Tool-using LLM** | model decides each step | flat tool list | calls the wrong tool, loops | support, lookup |
| **Planning agent** | model decomposes and re-plans | tools + sub-agents | unbounded latency and cost | rarely appropriate live |

The fourth level is mostly wrong for real-time voice: a planner that takes four steps takes
four times the deadline. The productive design is the hybrid in §2.8 — a state machine that
owns the *process* and an LLM that owns the *language* and picks among the tools legal in the
current state.

### 2.2 Where a tool-calling turn spends its time

```mermaid
sequenceDiagram
    participant U as User
    participant S as STT
    participant L as LLM
    participant T as Tool
    participant Y as TTS
    U->>S: speech ends (t_eou)
    S->>L: stt_final
    L->>L: prefill + decode to the tool call
    L->>T: reschedule_appointment(...)
    Note over U,Y: silence starts here and the caller cannot see why
    T-->>L: result (median 400 ms, p95 2.5 s)
    L->>L: second prefill, now including the tool output
    L->>Y: first clause
    Y-->>U: ttfa
```

Two properties of that timeline drive every design decision below. The silent window is
bounded below by `ttft_llm` twice plus the tool, so it cannot be prompted away. And the tool
latency distribution is **heavy-tailed** — an internal API with a 400 ms median routinely has
a 2.5 s p95, because of connection setup, a cold cache, a slow shard, or a downstream retry.
Designing to the median produces a system that is unusable one turn in twenty.

### 2.3 Five instruments, and what each one actually fixes

Two different metrics get conflated. `ttfa` is time to *any* audio; the answer time is when
the caller learns the thing they asked for. Filler speech moves the first and not the second.
From the Monte Carlo in §3, 20 000 turns, two tool calls per turn `[MEASURED]`:

| Policy | ttfa p50 | ttfa p95 | answer p50 | answer p95 | answer p99 | gap > 800 ms | wasted calls | degraded |
|---|---|---|---|---|---|---|---|---|
| Naive serial | 1815 | 4964 | 1815 | 4964 | 8498 | 98.7% | 0.00 | 0.0% |
| + filler | **551** | **701** | 1815 | 4964 | 8498 | 34.0% | 0.00 | 0.0% |
| + parallel tools | 551 | 701 | 1539 | 4322 | 7677 | 23.8% | 0.00 | 0.0% |
| + speculative read | 491 | 660 | **540** | 3288 | 6930 | 10.2% | 0.20 | 0.0% |
| + hedged call | 471 | 655 | 483 | **2351** | 4956 | 5.9% | 1.20 | 0.0% |
| + deadline 2500 ms | 471 | 655 | 483 | 2351 | **2961** | 5.9% | 1.20 | 3.1% |

Read it as five separate lessons.

**Filler is a perception fix and nothing else.** It cuts `ttfa` p50 from 1815 ms to 551 ms and
leaves the answer time bit-identical. That is still the highest-value single change, because
the caller stops thinking the line dropped — but a team that ships only filler has made the
dashboard look better without making the system faster, and 34% of turns still contain a
silence over 800 ms (the gap *after* the filler finishes; see §2.4).

**Parallelism is free and under-used.** Running two independent tools concurrently instead of
sequentially cuts answer p50 by 15% and costs nothing. The obstacle is that most agent loops
execute tool calls in a `for` loop; providers emit parallel calls precisely so you do not have
to.

**Speculation is the biggest win on the median**, taking answer p50 from 1539 ms to 540 ms,
because it moves the whole tool latency into the window while the user is still talking
(§2.5). It costs 0.20 wasted calls per turn at an 80% validity rate.

**Hedging is the instrument for the tail.** A duplicate request fired at the median cuts
answer p95 from 3288 ms to 2351 ms, at the cost of 1.2 extra calls per turn — a real capacity
decision (§5), and one that requires idempotency (§2.6).

**Deadlines only show up at p99**, which is exactly the point: p95 is unchanged, p99 drops
from 4956 ms to 2961 ms, and 3.1% of turns now carry a degraded answer. That trade — a bounded
worse answer instead of an unbounded wait — is nearly always correct on a live call.

### 2.4 Filler speech done right

Five rules, each from a failure that ships regularly.

**Fire on a dwell timer, not on tool start.** Speaking "let me check" before every tool call
makes fast tools feel slow. Wait for a threshold of continuous silence — 400–600 ms is the
usable band, below the ~700 ms at which callers start prompting.

**Re-arm.** The measured 34% of turns with an >800 ms gap after adding filler is almost
entirely the gap *between* the filler ending and the answer starting. A single filler covers
one window; a long tool needs a second utterance. This is why LiveKit's API has both a `delay`
and an `interval` (§4).

**Never assert the outcome.** "I've booked that for you" said while the booking API is still
in flight is a lie 3% of the time and a lawsuit occasionally. Filler must be
outcome-free: "let me check that", "one moment".

**Keep it interruptible.** A caller who says "actually, make it Thursday" during the filler
must be able to. Filler is ordinary speech and follows the ordinary barge-in path
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)) — and if the barge-in
cancels the turn, the in-flight tool must be cancelled with it, or you get the zombie-tool
version of the zombie-TTS bug.

**Vary it and cap it.** The same phrase four times in one call is worse than silence. Rotate a
small pool, and cap the number of fires per call.

### 2.5 Speculative and optimistic execution

Speculative execution starts a tool from an interim transcript, before `t_eou`. Optimistic
execution is the stronger relative: assume the likely branch and act on it. Both are only
safe for calls with a specific profile.

| Property | Required? | Why |
|---|---|---|
| Read-only | yes | a discarded speculation must leave no trace |
| Idempotent | yes | it may be re-run reactively when the guess was wrong |
| Cancellable | yes | otherwise a barge-in leaves work in flight |
| Cheap | strongly | you pay for the 20% you throw away |
| Fast relative to the turn | yes | a 5 s tool started 1.2 s early saves only 1.2 s |

Read-only is the load-bearing one. A speculative *write* is a real appointment booked from a
sentence the user had not finished saying. The rule is simple and absolute: **speculate reads,
never writes**. Writes may be prepared — validated, priced, staged behind an idempotency key —
and committed only after the user's turn ends.

The expected saving is $p \cdot \min(t_{\text{tool}}, t_{\text{head start}})$ with $p$ the
probability the guess survives the final transcript; the same formula as speculative retrieval
in [`02-context-and-memory.md`](02-context-and-memory.md) §2.7. Instrument $p$; below roughly
0.5 the waste stops being worth it for anything but the cheapest calls.

### 2.6 Idempotency, because everything runs at least once

There are five independent sources of duplicate execution in a voice agent, and every one of
them fires in production:

1. Client retry after a timeout where the request actually succeeded.
2. Hedged requests (§2.3) — duplicates by construction.
3. The model emitting the same call twice in one turn, or again on the next turn because the
   first result was ambiguous.
4. The user repeating themselves because the agent was slow, and the agent treating it as a
   new instruction.
5. A reconnect that replays the last turn.

The mitigation is a key the *caller* generates and the *server* enforces:

```sql
CREATE TABLE tool_idempotency (
  key         text PRIMARY KEY,   -- deterministic: session + tool + canonical args
  request_hash text NOT NULL,     -- detects key reuse with different arguments
  status      text NOT NULL,      -- 'in_flight' | 'done' | 'failed'
  result      jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL
);
```

Three details decide whether this works. The key must be **deterministic from the intent**
(session id + tool name + canonically serialised arguments), so a retry computes the same key
without coordination. `in_flight` must be inserted before the call so a *concurrent* duplicate
— the hedge — blocks or joins rather than executing. And `request_hash` catches the dangerous
case of the same key with different arguments, which means your canonicalisation is wrong and
you are about to return the wrong result.

Deduplication in the agent framework (§4) is a useful first line and is explicitly **not** an
exactly-once guarantee; LiveKit's own documentation says its argument comparison "fails open".
The guarantee belongs in the tool body, next to the database transaction.

Frame the boundary as a decision: **reversible + cheap → just do it; irreversible or expensive
→ idempotency key plus explicit spoken confirmation** before the call
([`01-prompting-for-speech.md`](01-prompting-for-speech.md) §2.4).

### 2.7 Errors are speech

Every failure mode ends up in the caller's ear, so map them deliberately.

| Failure | Model should see | Caller should hear |
|---|---|---|
| Validation error (bad slot) | the specific field and why | a question that re-collects that field |
| Not found | "no appointment with that id" | "I can't find a booking under that number — can you read it again?" |
| Transient 5xx / timeout | after one silent retry, "temporarily unavailable" | "I'm having trouble reaching the booking system — shall I take a message?" |
| Permission denied | "not permitted for this caller" | no detail: "I'm not able to do that on this line" |
| Ambiguous result | the candidates | a disambiguating question, at most three options |
| Deadline exceeded | "timed out, result unknown" | never "it failed" — "I'm not sure that went through; let me confirm" |

Three rules. **Retry transient failures once, silently, with a jittered backoff** that fits
inside the deadline; a second retry costs more than it recovers on a live call.
**Never let raw error text reach the TTS** — stack traces, JSON and HTTP codes are
unspeakable, and a status code read aloud is a small security leak. And the last row is the
subtle one: when a write times out, you do not know whether it happened, so the honest and
correct behaviour is to say so and re-check, which is only possible because the idempotency
key from §2.6 lets you look it up.

### 2.8 State machines versus open agency

| Axis | Constrained state machine | Open LLM agency |
|---|---|---|
| Predictability | high; enumerable paths | low; emergent |
| Auditability | a state trace | a token trace |
| Latency | one LLM call per turn | potentially many |
| Handles the unanticipated | badly | well |
| Prompt size | small — only this state's tools | large — every tool, every turn |
| Regression risk on model upgrade | low | high |
| Dev cost | high up front | low up front, high in the tail |

The prompt-size row has a consequence people miss: exposing only the tools legal in the
current state shortens the prompt on every turn, and the tool schemas are near the front of
the context, so a per-state tool list that *changes* invalidates the prefix cache
([`02-context-and-memory.md`](02-context-and-memory.md) §2.4). Group states so the tool block
changes rarely.

The hybrid that works in production: the state machine owns process and permissions — which
slots are filled, which tools are legal, what must be confirmed — and the LLM owns language
and selection within that. Regulated flows (payment, identity, medication) are pure state
machine; discovery and small talk are open. Draw the boundary at the point where being wrong
becomes expensive.

### 2.9 Handoff and human escalation

Escalation is a feature, not an admission of failure, and it needs explicit triggers rather
than model discretion:

- The caller asks for a human. Immediate, no negotiation, no retention attempt.
- Two consecutive non-understanding turns
  ([`01-prompting-for-speech.md`](01-prompting-for-speech.md) §2.4).
- The same tool fails twice, or a tool the flow depends on is circuit-broken.
- A high-risk intent: self-harm, legal threat, fraud, medical urgency.
- The caller has repeated the same request three times — a loop the agent cannot see from
  inside a single turn.

Warm transfer beats cold: hand the human a **context packet** — caller identity, verified
slots, what the agent already promised, the last few turns, and the reason for escalation.
Cold transfer forces the caller to repeat everything, which is the experience people cite when
they say they hate voice agents. Two systems constraints follow: the transfer must survive the
agent's own failure (so the packet is written to durable storage, not held in the worker), and
telephony transfer has its own protocol machinery
([`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)).

---

## 3. From scratch

A discrete-event Monte Carlo of one tool-calling turn under each policy. Standalone, stdlib
only, deterministic.

```python
"""Tool calling under a deadline: what filler, concurrency and hedging actually buy.

Discrete-event Monte Carlo over one agent turn that requires a tool call. Reports
the two metrics that matter and are usually conflated: ttfa (any audio, which is
what stops the call feeling dead) and the answer time (the real reply, which is
what the user is waiting for), plus the longest continuous silence.

Latency distributions are lognormal, parameterised by median and p95 so they can be
replaced with your own measurements.
"""

import math
import random
import statistics

N_TRIALS = 20000
SEED = 11

# (median_ms, p95_ms) -- replace with measurements from your own traces.
STT_FINAL = (100, 180)      # t_eou -> stt_final
LLM_TTFT = (220, 500)       # decision to call the tool, and again after the result
TOOL = (400, 2500)          # the heavy tail is the whole problem
TTS_TTFB = (150, 300)       # ttfb_tts

FILLER_THRESHOLD = 400      # silence tolerated before saying "let me check"
FILLER_DURATION = 900       # "one moment, let me look that up"
FILLER_INTERVAL = 1200      # re-arm: say something again after this much new silence
TOOL_DEADLINE = 2500        # give up and speak a degraded answer
P_SPEC_VALID = 0.80         # speculative launch still valid at t_eou
SPEC_HEAD_START = 1200      # how early the interim fires, before t_eou


def lognormal(median, p95, rng):
    """Sample from the lognormal with the given median and 95th percentile."""
    sigma = math.log(p95 / median) / 1.6448536269514722   # z(0.95)
    return math.exp(rng.gauss(math.log(median), sigma))


def silences(speech, horizon):
    """Longest gap in a timeline of (start, end) speech intervals, from t=0."""
    gap, cursor = 0.0, 0.0
    for s, e in sorted(speech):
        gap = max(gap, s - cursor)
        cursor = max(cursor, e)
    return max(gap, horizon - cursor)


def run_turn(rng, *, filler, parallel, speculative, hedge, deadline):
    """Return (ttfa, answer_time, max_gap, wasted_calls, degraded) for one turn, in ms."""
    stt = lognormal(*STT_FINAL, rng)
    ttft1 = lognormal(*LLM_TTFT, rng)
    ttft2 = lognormal(*LLM_TTFT, rng)
    tts = lognormal(*TTS_TTFB, rng)
    tool_a = lognormal(*TOOL, rng)
    tool_b = lognormal(*TOOL, rng)   # a second, independent tool this turn
    wasted = 0

    if hedge:  # fire a duplicate at the median and take whichever returns first
        tool_a = min(tool_a, TOOL[0] + lognormal(*TOOL, rng))
        wasted += 1

    tool_time = max(tool_a, tool_b) if parallel else tool_a + tool_b

    tool_start = stt + ttft1
    if speculative:
        if rng.random() < P_SPEC_VALID:
            # launched from an interim SPEC_HEAD_START ms before t_eou, so by t_eou it
            # already has that much progress; the negative start time is the point
            tool_start = -SPEC_HEAD_START
        else:
            wasted += 1  # speculation discarded, the tool is re-run reactively

    tool_done = max(0.0, tool_start + tool_time)
    degraded = False
    if deadline and tool_done > TOOL_DEADLINE:
        tool_done = TOOL_DEADLINE
        degraded = True

    answer_audio = tool_done + ttft2 + tts
    speech = [(answer_audio, answer_audio + 2000)]

    if filler:
        t = FILLER_THRESHOLD
        while t + tts < answer_audio:            # only if it would not collide
            speech.append((t + tts, t + tts + FILLER_DURATION))
            t = t + tts + FILLER_DURATION + FILLER_INTERVAL
            if not FILLER_INTERVAL:
                break

    ttfa = min(s for s, _ in speech)
    return ttfa, answer_audio, silences(speech, answer_audio), wasted, degraded


POLICIES = [
    ("naive serial",        dict(filler=0, parallel=0, speculative=0, hedge=0, deadline=0)),
    ("+ filler",            dict(filler=1, parallel=0, speculative=0, hedge=0, deadline=0)),
    ("+ parallel tools",    dict(filler=1, parallel=1, speculative=0, hedge=0, deadline=0)),
    ("+ speculative read",  dict(filler=1, parallel=1, speculative=1, hedge=0, deadline=0)),
    ("+ hedged call",       dict(filler=1, parallel=1, speculative=1, hedge=1, deadline=0)),
    ("+ deadline 2500ms",   dict(filler=1, parallel=1, speculative=1, hedge=1, deadline=1)),
]


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


if __name__ == "__main__":
    print(f"{N_TRIALS} turns per policy, two tool calls per turn\n")
    print(f"{'policy':20s} {'ttfa p50':>9} {'ttfa p95':>9} {'ans p50':>8} "
          f"{'ans p95':>8} {'ans p99':>8} {'gap>800ms':>10} {'waste':>7} {'degraded':>9}")
    for name, cfg in POLICIES:
        rng = random.Random(SEED)
        ttfas, answers, gaps, wastes, degs = [], [], [], [], 0
        for _ in range(N_TRIALS):
            ttfa, ans, gap, waste, deg = run_turn(rng, **cfg)
            ttfas.append(ttfa); answers.append(ans); gaps.append(gap)
            wastes.append(waste); degs += deg
        bad = sum(g > 800 for g in gaps) / N_TRIALS
        print(f"{name:20s} {pct(ttfas,.5):9.0f} {pct(ttfas,.95):9.0f} "
              f"{pct(answers,.5):8.0f} {pct(answers,.95):8.0f} {pct(answers,.99):8.0f} "
              f"{bad:9.1%} {statistics.mean(wastes):7.2f} {degs/N_TRIALS:8.1%}")
```

Output `[MEASURED]`:

```
20000 turns per policy, two tool calls per turn

policy                ttfa p50  ttfa p95  ans p50  ans p95  ans p99  gap>800ms   waste  degraded
naive serial              1815      4964     1815     4964     8498     98.7%    0.00     0.0%
+ filler                   551       701     1815     4964     8498     34.0%    0.00     0.0%
+ parallel tools           551       701     1539     4322     7677     23.8%    0.00     0.0%
+ speculative read         491       660      540     3288     6930     10.2%    0.20     0.0%
+ hedged call              471       655      483     2351     4956      5.9%    1.20     0.0%
+ deadline 2500ms          471       655      483     2351     2961      5.9%    1.20     3.1%
```

Three load-bearing details. **The speculative branch uses a negative start time** — the tool
began before `t_eou`, so at `t_eou` it already holds `SPEC_HEAD_START` ms of progress; clamping
that start to zero (the natural-looking bug) understates the benefit by roughly a second and
would have made speculation look barely better than parallelism. **The distributions are
parameterised by median and p95, not by mean and variance**, because that is what your
dashboards report and because the p95/median ratio *is* the tail weight you are designing
against. And **`silences()` measures the longest gap rather than the total silence**: two 400 ms
gaps are fine and one 800 ms gap is not, so summing them would hide the failure.

---

## 4. How production does it

**LiveKit turns each of §2's rules into API surface.** All verified in `livekit/agents`, main
branch, retrieved 2026-08-22.

`llm/tool_context.py` defines `@function_tool`, and two exceptions with different semantics:
`ToolError(message)` — the message is *deliberately* shown to the LLM so it can explain the
failure in its own words (§2.7's middle column) — and `StopResponse()`, which suppresses the
reply entirely, for tools whose effect is the answer. `ToolFlag` carries `IGNORE_ON_ENTER` and
`CANCELLABLE`; the second is §2.4's rule that a barge-in must cancel in-flight tool work.

Duplicate suppression is first-class: `@function_tool(on_duplicate=...)` accepts
`"allow" | "reject" | "replace" | "confirm"`, with `duplicate_scope` of `"name"` (default) or
`"name_and_args"`, and `on_duplicate="confirm"` injects a
`lk_agents_confirm_duplicate` parameter so the model must affirm. The source is explicit that
this is not enough: comparison "fails open — an unrepresentable argument or a validation error
leaves the call treated as sent rather than blocking it — so don't rely on this as an
exactly-once guarantee; put that in the tool body." That is §2.6, written by the framework
authors.

`voice/events.py:RunContext` is where the latency instruments live.
`with_filler(source, *, delay=0, interval=None, max_steps=None)` is an async context manager
implementing §2.4 exactly: `delay` is the continuous-idle dwell before firing, `interval` is
the re-arm cooldown (and `None` means fire once — the default that produces the measured 34%
residual gap), `max_steps` caps the fires, and `source` may be a callable
`(step) -> SpeechHandle | str | None` so the wording can vary by iteration.
`RunContext.update(message)` pushes a progress update into the conversation, where "the first
update releases control to the LLM with `message` as the tool's synthetic return" — a
long-running tool can speak partial results while it continues, and the code explicitly resets
any pending filler dwell so an update does not race a filler to the speech queue. Also
present: `disallow_interruptions()`, `wait_for_playout()`, and `foreground()` for holding the
floor while interactive work runs.

Observability is per-call rather than per-turn: `ToolCallStarted`, `ToolCallUpdated`,
`ToolCallEnded`, `ToolExecutionUpdatedEvent`, and `FunctionToolsExecutedEvent`
([`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md)).

**Pipecat models long tools as a message protocol instead.** `pipecat-ai` 1.7.0,
`processors/aggregators/async_tool_messages.py`: registering a function with
`cancel_on_interruption=False` makes the aggregator append a `started` message (`role="tool"`)
when the tool begins, an `intermediate` message (`role="developer"`) for each
`FunctionCallResultProperties(is_final=False)`, and a `final` message when it settles — with a
cancelled task settling the same way, carrying a cancellation notice. The design difference is
worth internalising: LiveKit models progress as *speech scheduling*, Pipecat models it as
*context mutation*, and the second composes better with realtime models that own their own
conversation state.

**Providers give you parallelism if you take it.** OpenAI-style APIs return an array of tool
calls; executing them with `asyncio.gather` rather than a `for` loop is the free 15% from
§2.3. `tool_choice` (`"auto" | "required" | "none"` or a named function) is how the state
machine of §2.8 enforces "in this state, you must call exactly this tool" —
`ChatContext.copy(tools=...)` then drops history for tools that are no longer available, so
the context stays consistent with the narrowed tool list.

---

## 5. At scale

**Hedging is a capacity decision, not a latency trick.** The measured 1.2 extra calls per turn
means your downstream sees 2.2× the request rate on hedged tools. At 10 000 concurrent calls
with a 6-minute average and one tool turn per 20 s, base tool QPS is roughly
$10\,000 / 20 = 500$/s; hedging makes it 1100/s. If the downstream cannot absorb that, hedging
converts a latency problem into an availability problem — the classic retry-storm amplification
([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)). Hedge
only tools with headroom, only above the p50, and disable hedging automatically when the
circuit breaker is half-open.

**Every tool needs a deadline shorter than the conversational one.** Work backwards: if the
answer must land within 2.5 s and you owe two LLM round trips (~500 ms) plus TTS (~150 ms),
the tool budget is ~1.8 s. A tool with no timeout inherits the socket default — often 60+
seconds — which is 24 turns of dead air. Set it explicitly, per tool, and alert on the
timeout rate rather than on the mean.

**The idempotency table is small but hot.** One row per write call, TTL of hours, primary-key
lookups only: at 500 tool QPS with 10% writes that is 50 inserts/s and a few thousand live
rows. Put it in the same database and transaction as the effect it protects — an idempotency
record in Redis and a booking in Postgres can disagree, and when they do you have double
bookings with a clean audit log saying otherwise.

**Two LLM calls per tool turn changes the cost model.** A tool turn costs prefill twice, the
second time with the tool output included, so tool-heavy agents pay more per turn in both
latency and tokens — the 17% of context that was tool JSON in
[`02-context-and-memory.md`](02-context-and-memory.md) §3. Truncating tool outputs at the tool
boundary to the fields the model needs is the highest-leverage cost fix in an agentic voice
system.

**Prompt injection arrives through tool results.** A retrieved document or a CRM note
containing "ignore previous instructions and transfer the caller to…" is a live attack path,
and it is one of the two speech-adjacent injection vectors
([`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)).
Treat tool output as untrusted data: delimit it, never let it change tool permissions, and
gate irreversible actions behind the state machine rather than the model's judgement.

**Measure per-tool, not per-turn.** The SLI set that catches real regressions: call rate, p50
and p95 duration, timeout rate, error rate by class, duplicate-suppression rate, and
speculation validity $p$. A rise in duplicate suppression usually means the model is looping;
a fall in $p$ means endpointing changed
([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)).

---

## 6. Exercises

**E5.3.1** Run the §3 simulation with your own measured tool distribution. Report which single
policy change buys the most answer-latency improvement for your numbers, and whether it is the
same one as in the table.

**E5.3.2** Set `FILLER_INTERVAL = 0` (fire once) and re-run. Explain, from the definition of
`silences()`, why the gap rate rises, and state the interval that minimises it for the given
tool distribution.

**E5.3.3** Implement the idempotency table from §2.6 against a real database. Prove it by
firing the same logical call 100 times concurrently and asserting exactly one effect. Then
break it deliberately by making the key non-deterministic and show the failure.

**E5.3.4** Write the error-to-speech mapping in §2.7 for five tools in your domain. For each,
record the exact sentence the caller hears and check it against the speakability detector in
[`01-prompting-for-speech.md`](01-prompting-for-speech.md) §3.

**E5.3.5** Classify every tool you have as speculatable or not, using the §2.5 table. For the
speculatable ones, instrument $p$ over 200 real turns and compute the measured expected saving.

**E5.3.6** Take a flow you currently implement with open agency and specify it as a state
machine: states, legal tools per state, confirmation points. Count the tool-schema tokens saved
per turn and relate that to the prefix-cache argument in
[`02-context-and-memory.md`](02-context-and-memory.md) §2.4.

**E5.3.7** Build the escalation context packet: define its schema, populate it during a call,
and hand it to a human. Time how long the human takes to become useful with and without it.

**E5.3.8** Inject a hostile string into a tool result and see whether your agent obeys it.
Then add delimiting and a permission gate, and re-test.

---

## 7. Interview drill

> "Users complain our agent is slow whenever it looks something up. A previous engineer added
> 'let me check that for you' and the latency dashboards did not move. What do you do?"

The dashboard is right and so are the users, because they are measuring different things. Say
that first. Filler speech changes `ttfa` — time to any audio — and changes nothing about when
the answer arrives; in the measurement in §2.3 it took `ttfa` p50 from 1815 ms to 551 ms while
the answer time stayed at 1815 ms p50 and 4964 ms p95. If the latency dashboard tracks the
answer, it correctly did not move. The immediate action is to split the metric into `ttfa` and
answer time, because a team that cannot see both will keep making this mistake.

Then decompose the wait. A tool turn is two LLM round trips plus the tool, and the second
prefill is larger because the tool output is now in the context, so a tool turn is
structurally slower than a plain turn. Get the tool's own distribution, and get p95 rather
than the mean, because these distributions are heavy-tailed — a 400 ms median with a 2.5 s p95
is entirely normal and is what the complaints are about.

The fixes go in order of cost. Execute independent tool calls concurrently — free, and worth
15% on the median in the measurement. Speculate the read-only lookups from an interim
transcript, which was the largest single win (answer p50 1539 ms to 540 ms) because it hides
the tool behind the user's own speech; that requires the calls to be read-only, idempotent and
cancellable, and it must never be applied to writes. Hedge the tail if downstream capacity
allows, noting it costs 1.2 extra calls per turn. And put a deadline with a degraded spoken
fallback on every tool, which moved p99 from 4956 ms to 2961 ms at the price of 3.1% of turns
getting a hedged answer — a trade that is nearly always right on a live call. Also re-arm the
filler, since a single utterance leaves a second gap that accounted for most of the remaining
34% of turns with silence over 800 ms.

What distinguishes a senior answer is questioning whether this is a latency problem at all.
"Slow whenever it looks something up" is also the signature of a *turn-taking* failure: during
the silence the caller says "hello?", the VAD fires, the agent treats it as a new turn and
either cancels the reply or answers the wrong thing, and the call now feels broken rather than
merely slow. The distinguishing evidence is in the transcripts — user speech during the tool
window — and if it is there, the fix is filler plus interruption policy rather than raw speed.
The other premise worth challenging is the tool itself: a 2.5 s p95 on an internal lookup is
often one missing index or one connection pool away from 200 ms, and fixing that beats every
instrument in this chapter.

---

## Sources

- `livekit/agents`, `livekit-agents/livekit/agents/llm/tool_context.py` (main branch, retrieved 2026-08-22) — `function_tool`, `ToolError`, `StopResponse`, `ToolFlag.{IGNORE_ON_ENTER,CANCELLABLE}`, `DuplicateMode = "allow"|"reject"|"replace"|"confirm"`, `DuplicateScope = "name"|"name_and_args"`, `CONFIRM_DUPLICATE_PARAM = "lk_agents_confirm_duplicate"`, and the "fails open … put that in the tool body" note quoted in §2.6 and §4.
- `livekit/agents`, `livekit-agents/livekit/agents/voice/events.py` (retrieved 2026-08-22) — `RunContext.with_filler(source, delay, interval, max_steps)`, `RunContext.update(message, template=...)`, `disallow_interruptions()`, `wait_for_playout()`, `foreground()`, and the `ToolCallStarted` / `ToolCallUpdated` / `ToolCallEnded` / `ToolExecutionUpdatedEvent` / `FunctionToolsExecutedEvent` set.
- `pipecat-ai/pipecat` 1.7.0, `src/pipecat/processors/aggregators/async_tool_messages.py` (retrieved 2026-08-22) — the `started` / `intermediate` / `final` / cancelled async-tool message protocol under `cancel_on_interruption=False`.
- Speculative-execution expected-saving formula and the retrieval measurement it generalises: [`02-context-and-memory.md`](02-context-and-memory.md) §2.7.
- Barge-in cancellation semantics: [`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md).
- `[MEASURED]`: the §2.3 and §3 tables are the output of the §3 listing, 20 000 trials per policy, seed 11, CPython 3.12 on Apple M5 / macOS 26.5.2. They are a simulation over stated input distributions, not a trace of a live system; substitute your own measured medians and p95s before drawing conclusions about your stack.
