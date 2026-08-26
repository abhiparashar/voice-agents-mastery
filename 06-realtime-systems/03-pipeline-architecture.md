# Pipeline architecture

**What you'll be able to do after this:** derive the frame taxonomy every voice framework
converges on instead of memorising one; size queue depths and pick a backpressure policy
from measured latency rather than instinct; explain why an in-band interrupt is correct and
still too slow; and read Pipecat's `frames.py` and LiveKit's `AgentSession` as two answers
to the same problem, knowing which parts are taste and which are forced.

---

## 1. Intuition

A voice agent is a chain of stages passing 20 ms frames: transport → VAD → ASR → turn
detection → LLM → text aggregation → TTS → transport. Written naively it is eight
coroutines connected by eight queues, and it will work beautifully in a demo and behave
badly in production for two reasons that have nothing to do with the models.

**The first is that queues store latency.** A queue is a place where a frame waits, and
waiting is exactly the thing your budget cannot afford
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md)). If
any stage is even slightly slower than real time, an unbounded queue in front of it
converts that shortfall into monotonically growing delay: measured below, one stage doing
26 ms of work per 20 ms frame produces a **p50 end-to-end latency of 476 ms and a maximum
of 920 ms** across a three-second utterance, with a queue 35 frames deep. Nothing crashed;
nothing logged an error; the agent simply became unusable a second at a time. The same
pipeline with a two-frame bounded queue holds latency **flat at 84 ms**.

**The second is that a conversation needs to be cancellable mid-sentence.** When the user
barges in, audio for the reply already exists in four places at once — text in the
aggregator, tokens in the TTS request, PCM in the output queue, and samples in the
client's jitter buffer ([`02-webrtc-internals.md`](02-webrtc-internals.md)). Stopping
"the pipeline" means reaching all four, in the right order, and then knowing *where* you
stopped so the transcript reflects what the user actually heard
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)).

Those two forces produce the entire design. Frames need **ordering** so that "stop after
this word" is expressible, and interrupts need **immediacy** so that stopping does not
wait behind the thing it is stopping. You cannot get both from one FIFO, and that — not
taste — is why every mature framework has at least two frame classes.

---

## 2. Rigour

### 2.1 The frame taxonomy, derived

Suppose every message travels one FIFO per edge. Then an interrupt sent at time $t$ is
processed after everything already queued, so its effective latency is the queue's
occupancy in time — the very backlog it exists to discard. Measured in §3: an in-band
interrupt behind a playback backlog let the user hear **61 more frames, 1220 ms** of a
reply they had already interrupted. Correct, ordered, and useless.

Now suppose interrupts travel a separate channel that every stage checks *before* its data
queue. Immediacy is solved — the same test drops to **20 ms** of stale audio — but
ordering is lost: a message on the fast path cannot say "stop after the word *transfer*",
because it does not know where the slow path had got to.

So you need both, and the minimum viable taxonomy has three kinds plus one modifier:

| Kind | Path | Ordered w.r.t. audio | Survives interrupt | Examples |
|---|---|---|---|---|
| **Data** | in-band | yes | no | PCM frames, transcripts, LLM text |
| **Control** | in-band | yes | no | settings updates, end-of-response, flush |
| **System** | priority | no | yes | interrupt, cancel, user-started-speaking, errors |
| **Uninterruptible** (modifier) | in-band | yes | **yes** | tool-call results, summaries, end-of-pipeline |

The fourth row is the one people discover late. A function call that has already charged a
credit card must not be discarded because the user interrupted while it was in flight; it
is ordered like data but must be delivered like a system frame
([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)).

This is not a proposal. It is what Pipecat 1.7.0 actually has, and its docstrings state
the contract precisely: `SystemFrame` is "a frame that takes higher priority than other
frames … not affected by user interruptions"; `DataFrame` is "processed in order … 
cancelled by user interruptions"; `ControlFrame` is like data but carries "control
information such as update settings or to end the pipeline after everything is flushed";
and the `UninterruptibleFrame` mixin marks frames that "are still ordered normally, but …
are preserved during interruptions: they remain in internal queues and any task processing
them will not be cancelled."

### 2.2 Edges, depth, and what a queue depth means

Model each edge as a queue with capacity $K$ frames. At the frame contract of 20 ms
([`../00-setup/03-canonical-formats.md`](../00-setup/03-canonical-formats.md)), $K$ is not
a memory decision, it is a **latency decision**:

$$
\text{added latency}_{\max} = K \times 20\ \text{ms}
$$

A 50-frame queue that sounded harmless is one second of delay. And because latency
accumulates along the path, the pipeline's worst-case added delay is $20\,\text{ms}\sum_e
K_e$ — so depth budgets must be assigned globally, not per stage by whoever wrote it.

The stability condition is Little's law applied per edge: if stage $i$ has service rate
$\mu_i$ frames/s and the input rate is $\lambda = 50$ frames/s, the queue in front of it
is stable only while $\lambda < \mu_i$. There is no depth that fixes $\mu_i < \lambda$;
depth only decides **how you fail** — as latency (unbounded), as backpressure (block), or
as loss (drop). The chapter on utilisation and p95 explains why you must leave headroom
rather than run at $\rho \to 1$
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md)).

### 2.3 Backpressure policies, measured

`[MEASURED]` from §3 — 150 frames of 20 ms audio through one stage that needs 26 ms per
frame ($\rho = 1.3$), queue depth 2 where bounded:

| Queue policy | Produced | Played | Dropped | Peak depth | Lat p50 | Lat p95 | Lat max |
|---|---|---|---|---|---|---|---|
| unbounded | 150 | 150 | 0 | 35 | 476 | 878 | **920** |
| block (backpressure) | 150 | 150 | 0 | 2 | **84** | 84 | 84 |
| drop oldest | 150 | 117 | 33 | 2 | **56** | 66 | 66 |

Three readings, and they generalise. **Unbounded queues do not absorb overload, they
convert it into latency** — and into latency that never recovers, because there is no
mechanism to shed the backlog. **Blocking is the right default** for stages where every
frame matters (ASR input: dropping audio costs you words), and it is honest, because
backpressure propagates upstream to where a decision can be made. **Dropping oldest is
the right default on the playback path**, where a stale frame has negative value: it beats
blocking on latency (56 ms vs 84 ms p50) precisely because it refuses to carry history.

The fourth policy worth knowing is **coalescing**: for idempotent state (a partial
transcript, a VAD probability, a level meter) keep only the newest value and drop the
rest. It is drop-oldest with depth 1, and it is the correct policy for every "current
value" edge in the graph — using a queue there at all is usually a bug.

### 2.4 Interrupt propagation, measured

`[MEASURED]` from §3 — three stages plus a real-time playback sink, TTS generating 4×
faster than playback (so a backlog exists), user interrupts at 400 ms:

| Design | Heard before | Heard after | Stale audio | Knows cut point |
|---|---|---|---|---|
| shared flag, source stops | 19 | 61 | **1220 ms** | no |
| in-band interrupt frame (FIFO) | 19 | 61 | **1220 ms** | yes |
| in-band on a priority path | 19 | 1 | **20 ms** | yes |
| `Task.cancel()` on the subtree | 19 | 0 | 0 ms | **no** |

This table is the chapter. **Setting a flag is the bug everyone writes first**: the
generator stops, the queues drain anyway, and the user listens to 1.2 seconds of a reply
they interrupted — while your logs say the interrupt was handled at 400 ms. **An in-band
interrupt frame is semantically correct and equally slow**, because it queues behind the
backlog it is meant to discard; this is the result that surprises people, and it is why
Pipecat's interrupt is a `SystemFrame` and not a `ControlFrame`. **A priority path fixes
immediacy** and lands within one frame of ideal. And **cancellation is fastest and knows
nothing** — zero stale audio, but no stage got the chance to report where it stopped, so
you cannot truncate the transcript to what was heard, which is the input the LLM needs for
the next turn to make sense.

The design that works is therefore both: a **system-priority interrupt** for immediacy,
plus an **ordered acknowledgement** — a mark, a `stopped_at` sample index, or a playback
position report — for truth. Twilio's `clear` + `mark` pair is exactly this, and so is
LiveKit's truncation of the assistant turn to the audio actually played
([`01-transports.md`](01-transports.md)).

### 2.5 asyncio cancellation, precisely

Cancellation is where correct-looking pipelines rot, because `Task.cancel()` does not stop
a task. It **schedules a `CancelledError` to be raised at the task's next suspension
point**. Four consequences worth internalising:

- **Cancellation is not synchronous.** After `task.cancel()` the task is still running.
  You must `await` it (`asyncio.gather(*tasks, return_exceptions=True)`) before you may
  assume its side effects have stopped. Code that cancels a TTS task and immediately
  starts a new one gets two TTS streams writing to the same output — the zombie-TTS bug.
- **A task with no `await` in its hot loop cannot be cancelled.** A CPU-bound stage
  (resampling a long buffer, a synchronous model call) will run to completion. Anything on
  the critical path must either be genuinely async or live on a thread/process boundary
  with its own cancellation protocol.
- **`finally` blocks run, and may not await freely.** Cleanup that awaits during
  cancellation can itself be cancelled; wrap the parts that must complete in
  `asyncio.shield`, and keep them short. This is where the "uninterruptible" work belongs.
- **Swallowing `CancelledError` breaks the world.** `except Exception` does not catch it
  in Python 3.8+ (it derives from `BaseException`), which is a deliberate gift — do not
  undo it with a bare `except:`.

The rule that follows: **cancel tasks, but flush queues explicitly.** Cancellation
governs the code that is running; it does nothing about the frames already sitting on
edges, which is why §2.4's `cancel` row has zero stale audio only because the sink itself
was cancelled. In a real system the client's jitter buffer is beyond your reach entirely,
so the flush must be sent to it as a message.

### 2.6 Pipecat's model versus LiveKit's `AgentSession`

| Axis | Pipecat 1.7.0 | LiveKit Agents 1.7.0 |
|---|---|---|
| Unit of composition | `FrameProcessor` in a `Pipeline` | `AgentSession` with node overrides on `Agent` |
| Frame graph | explicit, yours to build | implicit, fixed shape, extended at named nodes |
| Frame taxonomy | explicit: `SystemFrame` / `DataFrame` / `ControlFrame` + `UninterruptibleFrame` | internal; you see events and callbacks |
| Interrupt | `InterruptionFrame(SystemFrame)` pushed through the graph | `AgentSession` interruption policy with tunable thresholds |
| Tuning surface | write a processor | constructor options (`min_duration`, `min_words`, `false_interruption_timeout`, …) |
| Transport | pluggable input/output pair | WebRTC room membership |
| Cost of a novel topology | low | high — you are fighting the shape |
| Cost of a standard agent | moderate — you assemble it | very low — it is the default |

The honest comparison is that these are different products for different questions.
Pipecat hands you the frame graph, which is the right tool when your pipeline is not
shaped like a standard voice agent — parallel classifiers, two ASRs racing, a custom
audio tap, an in-house transport. LiveKit hands you a tuned agent and a very deep set of
knobs, which is the right tool when your pipeline *is* shaped like a standard voice agent
and the work is in the domain logic. The knobs are real, not marketing: `voice/turn.py`
1.7.0 ships interruption defaults of `min_duration=0.5`, `min_words=0`,
`resume_false_interruption=True`, `false_interruption_timeout=2.0`,
`discard_audio_if_uninterruptible=True`, and a `backchannel_boundary` of `(1.0, 1.0)`
([`../07-livekit/02-agents-framework.md`](../07-livekit/02-agents-framework.md)).

Where the comparison usually goes wrong is treating the choice as permanent. Both are
libraries around the same frame-graph physics measured in §2.3 and §2.4. Keep your domain
logic — tools, state machine, prompts, persona — in code that imports neither, and the
question becomes reversible.

---

## 3. From scratch

Queue policy and interrupt propagation, measured on a virtual clock so the numbers are
reproducible. Standalone, stdlib only.

```python
"""Frame graphs: what bounded queues and in-band control frames actually buy you.

A voice pipeline is a chain of coroutines passing 20 ms frames. Two design
decisions dominate its behaviour under load, and both are measurable.

Part A: queue policy. A stage slower than real time cannot keep up. With an
unbounded queue the backlog -- and therefore end-to-end latency -- grows all
call. With a bounded queue the producer blocks (backpressure) or the stalest
frame is dropped, and latency stays flat.

Part B: interrupt propagation. Barge-in must stop audio already in flight. The
generator runs ahead of playback, so a backlog exists at the moment the user
speaks. Four designs are compared by the only metric that matters: how many
frames the user still hears afterwards -- and whether the pipeline can say
where it stopped.

Deterministic: a virtual clock advances in 1 ms ticks, so every number is
reproducible. asyncio task cancellation is real, not simulated.
"""

import asyncio

FRAME_MS = 20
N_FRAMES = 150            # 3 s of audio


class Clock:
    """Virtual monotonic clock in ms. Tasks wait on ticks, not on wall time."""

    def __init__(self):
        self.now = 0
        self._waiters = []                       # (due_ms, asyncio.Event)

    async def sleep(self, ms):
        if ms <= 0:
            await asyncio.sleep(0)
            return
        ev = asyncio.Event()
        self._waiters.append((self.now + ms, ev))
        await ev.wait()

    async def run_until(self, done, limit_ms=60_000):
        """Advance to the next due waiter until `done()` or the limit."""
        while not done() and self.now < limit_ms:
            for _ in range(120):                 # let runnable tasks settle first
                await asyncio.sleep(0)
            if done() or not self._waiters:
                break
            self.now = min(t for t, _ in self._waiters)
            due = [e for t, e in self._waiters if t <= self.now]
            self._waiters = [(t, e) for t, e in self._waiters if t > self.now]
            for e in due:
                e.set()
        for _ in range(120):
            await asyncio.sleep(0)


class Frame:
    __slots__ = ("kind", "seq", "born")

    def __init__(self, kind, seq, born):
        self.kind, self.seq, self.born = kind, seq, born


# --------------------------------------------------------------- Part A
async def part_a(policy, slow_ms=26, depth=2):
    """Producer at real time -> one stage slower than real time -> sink.

    policy: 'unbounded' | 'block' | 'drop_oldest'
    """
    clk = Clock()
    q = asyncio.Queue()                          # depth enforced by policy below
    lat, dropped, peak = [], 0, 0
    produced = 0
    finished = asyncio.Event()

    async def producer():
        nonlocal produced, dropped, peak
        for i in range(N_FRAMES):
            f = Frame("audio", i, clk.now)
            if policy == "unbounded":
                q.put_nowait(f)
            elif policy == "drop_oldest":
                if q.qsize() >= depth:
                    q.get_nowait()               # discard the stalest frame
                    dropped += 1
                q.put_nowait(f)
            else:                                # 'block': real backpressure
                while q.qsize() >= depth:
                    await clk.sleep(1)
                q.put_nowait(f)
            produced += 1
            peak = max(peak, q.qsize())
            await clk.sleep(FRAME_MS)
        q.put_nowait(None)

    async def stage():
        while True:
            if q.empty():
                await clk.sleep(1)
                continue
            f = q.get_nowait()
            if f is None:
                break
            await clk.sleep(slow_ms)             # 26 ms of work per 20 ms frame
            lat.append(clk.now - f.born)
        finished.set()

    ts = [asyncio.ensure_future(producer()), asyncio.ensure_future(stage())]
    await clk.run_until(finished.is_set)
    for t in ts:
        t.cancel()
    await asyncio.gather(*ts, return_exceptions=True)
    return lat, produced, len(lat), dropped, peak


# --------------------------------------------------------------- Part B
async def part_b(design, interrupt_at_ms=400, stages=3, stage_ms=1, gen_ms=5):
    """Barge-in through a 3-stage graph whose sink plays in real time.

    The generator (TTS) emits a frame every 5 ms while playback consumes one
    every 20 ms, so a backlog builds downstream. That backlog is what the user
    keeps hearing after an interrupt.

    design:
      'flag_source'     -- set a bool; the source stops, queues keep draining
      'inband_fifo'     -- push an InterruptFrame; it queues BEHIND the backlog
      'inband_priority' -- interrupt on a priority channel, checked before audio
      'cancel'          -- asyncio.Task.cancel() the whole subtree
    """
    clk = Clock()
    qs = [asyncio.Queue() for _ in range(stages + 1)]      # qs[stages] = playout
    prio = [asyncio.Queue() for _ in range(stages + 1)]    # priority channel
    heard, done = [], asyncio.Event()
    stop = False
    before = None
    truncation = None

    def flush(i):
        while not qs[i].empty():
            qs[i].get_nowait()

    async def source():
        for i in range(N_FRAMES):
            if stop:
                break
            qs[0].put_nowait(Frame("audio", i, clk.now))
            await clk.sleep(gen_ms)              # 4x faster than playback
        qs[0].put_nowait(Frame("eos", -1, clk.now))

    async def worker(i):
        while True:
            if not prio[i].empty():              # immediacy: jumps the backlog
                ctl = prio[i].get_nowait()
                flush(i)
                prio[i + 1].put_nowait(ctl)
                continue
            if qs[i].empty():
                await clk.sleep(1)
                continue
            f = qs[i].get_nowait()
            if f.kind == "interrupt":            # in-band: strict FIFO order
                flush(i)
                qs[i + 1].put_nowait(f)
                continue
            await clk.sleep(stage_ms)
            qs[i + 1].put_nowait(f)

    async def playout():
        nonlocal truncation
        while True:
            if not prio[stages].empty():
                prio[stages].get_nowait()
                flush(stages)
                truncation = heard[-1] if heard else -1
                done.set()
                return
            if qs[stages].empty():
                await clk.sleep(1)
                continue
            f = qs[stages].get_nowait()
            if f.kind == "interrupt":
                flush(stages)
                truncation = heard[-1] if heard else -1
                done.set()
                return
            if f.kind == "eos":
                done.set()
                return
            await clk.sleep(FRAME_MS)            # real-time playback
            heard.append(f.seq)

    async def user_interrupts():
        nonlocal stop, before
        await clk.sleep(interrupt_at_ms)
        before = len(heard)
        stop = True
        if design == "inband_fifo":
            qs[0].put_nowait(Frame("interrupt", -2, clk.now))
        elif design == "inband_priority":
            prio[0].put_nowait(Frame("interrupt", -2, clk.now))
        elif design == "cancel":
            for w in workers + [player]:
                w.cancel()
            done.set()

    tasks = [asyncio.ensure_future(source()), asyncio.ensure_future(user_interrupts())]
    workers = [asyncio.ensure_future(worker(i)) for i in range(stages)]
    player = asyncio.ensure_future(playout())
    await clk.run_until(done.is_set, limit_ms=20_000)
    for t in tasks + workers + [player]:
        t.cancel()
    await asyncio.gather(*tasks + workers + [player], return_exceptions=True)
    return before or 0, len(heard) - (before or 0), truncation is not None


async def main():
    print("PART A -- one stage slower than real time (26 ms of work per 20 ms frame)\n")
    print(f"{'queue policy':13s} {'produced':>9} {'played':>7} {'dropped':>8} "
          f"{'peak q':>7} {'lat p50':>8} {'lat p95':>8} {'lat max':>8}")
    for policy in ("unbounded", "block", "drop_oldest"):
        lat, prod, deliv, drop, peak = await part_a(policy)
        s = sorted(lat)
        print(f"{policy:13s} {prod:9d} {deliv:7d} {drop:8d} {peak:7d} "
              f"{s[len(s)//2]:7.0f} {s[int(.95 * len(s))]:8.0f} {max(s):8.0f}")

    print("\n\nPART B -- barge-in at 400 ms; TTS generates 4x faster than playback\n")
    print(f"{'design':17s} {'heard before':>13} {'heard after':>12} "
          f"{'stale audio':>12} {'knows cut point':>16}")
    for design in ("flag_source", "inband_fifo", "inband_priority", "cancel"):
        before, after, knows = await part_b(design)
        print(f"{design:17s} {before:13d} {after:12d} {after * FRAME_MS:9d} ms "
              f"{'yes' if knows else 'NO':>16}")


if __name__ == "__main__":
    asyncio.run(main())
```

Output `[MEASURED]`:

```
PART A -- one stage slower than real time (26 ms of work per 20 ms frame)

queue policy   produced  played  dropped  peak q  lat p50  lat p95  lat max
unbounded           150     150        0      35     476      878      920
block               150     150        0       2      84       84       84
drop_oldest         150     117       33       2      56       66       66


PART B -- barge-in at 400 ms; TTS generates 4x faster than playback

design             heard before  heard after  stale audio  knows cut point
flag_source                  19           61      1220 ms               NO
inband_fifo                  19           61      1220 ms              yes
inband_priority              19            1        20 ms              yes
cancel                       19            0         0 ms               NO
```

Three load-bearing details. **The virtual clock is what makes this reproducible** —
measuring queue behaviour with `asyncio.sleep` and wall time gives you scheduler noise
instead of policy differences, and the temptation to average it away hides exactly the
tail you are hunting. **`inband_fifo` and `flag_source` produce identical stale audio, and
that is the point**: correctness of *ordering* buys you the cut point (`knows cut
point: yes`) and nothing at all in latency, so an interrupt must travel a priority path.
And **`cancel` reports `NO` for the cut point on purpose** — cancellation destroys the
stage that knew how much it had played, which is why a real barge-in path pairs a priority
flush with an ordered position report rather than choosing one.

---

## 4. How production does it

**Pipecat 1.7.0** (`src/pipecat/frames/frames.py`, ~2400 lines defining the taxonomy) is
the reference implementation of §2.1, and reading it is the fastest way to internalise the
model. `SystemFrame` for immediacy, `DataFrame`/`ControlFrame` for ordering,
`UninterruptibleFrame` as a mixin, and the interrupt itself as
`InterruptionFrame(SystemFrame)` — "used to interrupt the pipeline … to cancel any
in-progress bot output". Note the `Urgent` variants
(`FrameProcessorPauseUrgentFrame`, `OutputTransportMessageUrgentFrame`,
`OutputDTMFUrgentFrame`): a second escalation tier for messages that must not even wait
for the system-frame queue. That is §2.4's priority path, twice.

`FunctionCallResultFrame(DataFrame, UninterruptibleFrame)` and
`LLMContextSummaryResultFrame(ControlFrame, UninterruptibleFrame)` are worth pausing on —
they are the taxonomy earning its keep, encoding "this is ordered payload that survives a
barge-in" in the type rather than in a comment.

**LiveKit Agents 1.7.0** takes the opposite bet: the graph is fixed and the tuning is
declarative. `AgentSession` owns interruption, endpointing and preemptive generation, with
defaults quoted in §2.6, and you extend it at named nodes rather than by inserting
processors. Its equivalent of the priority path is internal — `discard_audio_if_
uninterruptible=True` and the truncation of the assistant's turn to what was actually
played are the same two mechanisms under different names
([`../07-livekit/02-agents-framework.md`](../07-livekit/02-agents-framework.md)).

**Both frameworks bound their queues, and neither documents it prominently**, which is the
practical lesson: when you write a custom processor you inherit the framework's policy on
its edges and own it on yours.

---

## 5. At scale

**Depth budgets must be global.** Eight stages each choosing a "safe" 10-frame queue is
1.6 seconds of latency nobody authorised. Publish the per-edge depths as configuration,
sum them, and assert the total against your latency budget in a test
([`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md)).

**One event loop per session does not scale; one process per session mostly does.** A
single Python event loop hosting 50 sessions couples them: one stage doing 30 ms of
synchronous work stalls every other session's frame cadence for 30 ms. Process isolation
per session is why LiveKit's worker forks job processes, and it converts a correlated
cross-session failure into an isolated one
([`05-scale-and-orchestration.md`](05-scale-and-orchestration.md)).

**Queue depth is your best overload signal.** CPU tells you the machine is busy; a rising
queue depth tells you *which edge* is losing and how long you have. Export per-edge depth
and per-edge wait time as histograms and alert on the derivative, not the level
([`06-observability.md`](06-observability.md)).

**Drop policy is a product decision at scale.** Under a surge you will shed something.
Deciding in advance that playback drops oldest, ASR input blocks, and partial transcripts
coalesce is a design; discovering it from an incident is not.

**Cancellation storms are real.** A deploy that drains 500 sessions cancels thousands of
tasks at once, each running `finally` blocks that may await I/O. Bound that work and shield
only what must complete, or draining becomes its own outage
([`07-reliability.md`](07-reliability.md)).

---

## 6. Exercises

**E6.3.1** Run the §3 listing. Add a `drop_newest` policy and explain, from the measured
latency and drop counts, which of the four policies belongs on the ASR input edge and which
belongs on the playback edge.

**E6.3.2** Sweep queue depth from 1 to 20 for the `block` policy and plot p50 latency
against depth. Derive the relationship analytically and confirm it matches.

**E6.3.3** Set `slow_ms = 18` so the stage is *faster* than real time and re-run all three
policies. Explain why the policies converge, and what that says about testing a pipeline
only under light load.

**E6.3.4** Implement the correct barge-in design: a priority interrupt plus an ordered
position report. Report both the stale audio and the recovered cut point, and show the
transcript truncation it enables.

**E6.3.5** Add an `UninterruptibleFrame` equivalent to Part B — a tool-call result that
must survive the interrupt — and prove it is delivered while audio frames are discarded.

**E6.3.6** Write a stage with a CPU-bound loop containing no `await` and show that
`Task.cancel()` does not stop it. Then fix it two ways (chunk the loop with `await
asyncio.sleep(0)`, and move it to a thread) and compare the interrupt latency.

**E6.3.7** Instrument your own pipeline: export per-edge queue depth and wait time, run a
realistic call, and identify the edge with the largest p95 wait. State what you would
change and what it costs.

**E6.3.8** Take one non-standard topology — two ASRs racing, or a classifier running in
parallel with the LLM — and write down how you would build it in Pipecat and in LiveKit
Agents. Which parts of §2.6's table did you actually feel?

---

## 7. Interview drill

> "Our agent stops speaking about a second after the user interrupts, and the transcript
> we send back to the LLM includes sentences the user never heard. Walk me through the
> fix."

These are two failures with one root cause, and saying so is the first move. Both are
symptoms of an interrupt that travels the same path as the audio it is trying to cancel.
The generator is ahead of playback — TTS produces faster than real time, deliberately, so
that speech is smooth — which means at the moment the user speaks there is a backlog of
already-synthesised audio sitting in queues and in the client's jitter buffer. If the
interrupt is a flag that stops the generator, or an in-band frame that queues behind that
backlog, the backlog still plays. In the measurement I would cite, both designs let 61
frames through: 1220 ms of audio the user had already interrupted, which matches the
reported symptom almost exactly.

The transcript bug is the same event seen from the other side. If we log "the assistant
said X" from what the LLM generated, or from what TTS synthesised, we are recording
something that was cancelled mid-flight. The next turn then contains a promise the user
never heard, and the model behaves as though it did — which produces the uncanny failures
where the agent references information it never delivered.

So the fix is two mechanisms, not one. First, the interrupt must travel a **priority path**
that every stage checks before its data queue, and each stage must **flush** its own queue
when it sees it. That is what takes stale audio from 1220 ms to 20 ms in the measurement,
and it is why Pipecat models interruption as a `SystemFrame` — "higher priority than other
frames" — rather than as a control frame. Second, we need an **ordered report of what was
actually played**: a playback position or a mark echoed by the sink, used to truncate the
assistant turn before it enters the context. Cancellation alone cannot give us this — in
the same table, `Task.cancel()` produced zero stale audio and no cut point, because it
destroyed the stage that knew the answer.

What separates a senior answer is knowing the client is outside your process. Even a
perfect server-side flush leaves audio in the browser's or the carrier's buffer, so the
protocol needs an explicit clear-and-mark exchange — which is precisely why Twilio Media
Streams has `clear` and `mark`, and why we should be sending both rather than trusting
that stopping our writes stops the sound. I would also make the invariant testable:
assert that the logged assistant turn is a prefix of the synthesised text, with the
truncation point taken from playback, and put that assertion in CI against a recorded
barge-in.

The premise worth questioning is "a second". If it is consistently near one second, that
smells like a fixed buffer or a single timeout rather than a drain, and I would want the
distribution before I believe the architecture story. And if the user's complaint is
actually that the agent stops too *eagerly* — reacting to a backchannel or an "mm-hm" —
then the interrupt path is fine and the problem is the interruption policy: minimum
duration, minimum words, and false-interruption resume, which is a different chapter.

---

## Sources

- `pipecat-ai/pipecat` 1.7.0 (PyPI, `requires_python >= 3.11`; `src/pipecat/frames/frames.py` retrieved from `main`, 2026-08-26) — the frame taxonomy quoted in §2.1 and §4: `SystemFrame` ("a frame that takes higher priority than other frames … not affected by user interruptions"), `DataFrame` ("processed in order … cancelled by user interruptions"), `ControlFrame` ("control information such as update settings or to end the pipeline after everything is flushed"), and the `UninterruptibleFrame` mixin ("still ordered normally, but … preserved during interruptions: they remain in internal queues and any task processing them will not be cancelled"); `InterruptionFrame(SystemFrame)`, `CancelFrame(SystemFrame)` ("stop right away without processing remaining queued frames"), `FunctionCallResultFrame(DataFrame, UninterruptibleFrame)`, `LLMContextSummaryResultFrame(ControlFrame, UninterruptibleFrame)`, and the `*UrgentFrame` escalation tier.
- `livekit/agents` 1.7.0 — `voice/turn.py` interruption defaults (`min_duration=0.5`, `min_words=0`, `resume_false_interruption=True`, `false_interruption_timeout=2.0`, `discard_audio_if_uninterruptible=True`, `backchannel_boundary=(1.0, 1.0)`) cited in §2.6; `voice/agent_session.py` for the fixed-graph node model.
- CPython `asyncio` documentation, 3.12 — `Task.cancel()` requesting a `CancelledError` at the next suspension point, `asyncio.shield`, and `CancelledError` inheriting from `BaseException` since 3.8, all used in §2.5.
- Little's law, applied per edge in §2.2; the utilisation-versus-p95 consequence is derived in [`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md).
- Twilio, "Media Streams — WebSocket Messages", retrieved 2026-08-22 — the `clear` + `mark` pair cited in §2.4 and §7 as the client-side half of the flush.
- `[MEASURED]`: both tables are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. Time is a virtual 1 ms-tick clock, so results are exactly reproducible and contain no scheduler noise; asyncio task cancellation is genuine. The Part B backlog is produced by a 4× generator-to-playback ratio, which is representative of streaming TTS but not calibrated against a specific engine — the ranking of the four designs is the robust result, not the precise 1220 ms.
