# Testing

**What you'll be able to do after this:** write timing assertions about audio that do not
flake, and show that a real-clock version cannot even assert the pipeline's true bound;
calibrate a CI latency gate from the sampling distribution of its own statistic instead of a
round number; gate golden audio with a metric that survives a re-run; and know the one case
where golden audio cannot work at all.

---

## 1. Intuition

A voice pipeline is concurrent, timing-dependent, and driven by nondeterministic models.
Every one of those properties breaks a naive test, and they break it in a specific way:
**the test fails sometimes**. A test that fails sometimes is worse than no test, because the
team learns to re-run it, and then it stops being a signal at all.

Three measured examples, all of them the kind of thing a competent engineer writes on the
first attempt:

- A two-stage pipeline doing 2 ms of work per 20 ms frame has a **true worst-case lateness of
  5.00 ms**, and a virtual clock returns exactly that on every one of 80 runs. The same
  measurement on a real `asyncio` clock reports a **p50 of 16.48 ms** — it adds ~11 ms of
  scheduler overhead — so the *correct* assertion, `lateness <= 6 ms`, fails **100%** of the
  time on the real clock and **0%** on the virtual one. And the real clock's spread is
  load-dependent: across trials on an idle machine its maximum ranged 18.04 → 48.17 ms, so
  the flake rate of any looser assertion is not reproducible either.
- A latency gate on a 50-utterance corpus has **279.8 ms of noise in its own p95**, so it
  cannot detect any regression smaller than +744 ms. Whatever round number you picked as
  the threshold, it is either always failing or never firing.
- Golden audio compared by RMS ranks a **62-microsecond shift (0.05298) as a bigger change
  than a real 2% formant shift (0.04586)**. The inaudible difference scores worse than the
  audible one.

The discipline that fixes all three is the same: **make time and randomness inputs, not
ambient conditions.** Fake the clock, fix the seeds, stub the models, replay recorded audio.
Then what remains is your logic, and your logic is deterministic.

---

## 2. Rigour

### 2.1 The test pyramid for a voice agent

| Level | What it covers | Determinism | Speed | Run when |
|---|---|---|---|---|
| Unit | aggregator splitting, WER normalisation, token accounting | full | ms | every commit |
| Frame-graph | queue policy, backpressure, interrupt propagation, cancellation | full, via fake clock | ms | every commit |
| Pipeline replay | WAV in → transcript + events out, stubbed models | full, via cached model responses | seconds | every commit |
| Golden audio | TTS output stability | tolerance-based (§2.5) | seconds | every commit |
| Latency gate | `eou_to_ttfa` distribution on a fixed corpus | statistical (§2.4) | minutes | every PR |
| Model quality | WER, endpoint F1, entity accuracy | statistical | minutes | nightly |
| Simulated conversation | task success, adversarial personas | low | minutes | nightly ([`02-simulation-and-load.md`](02-simulation-and-load.md)) |
| Live canary | real calls, real everything | none | continuous | production |

The load-bearing rows are the middle three, because they are where voice-specific bugs live
and where most teams have nothing. Turn-taking, barge-in and cancellation logic is
**fully testable** — it is ordinary state-machine code — and it is the code most likely to
be wrong ([`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)).

### 2.2 Fake clocks, and why real ones cannot work

`[MEASURED]` from §3 — worst per-run lateness of any frame, 80 runs each, on this machine:

| Clock | min | p50 | p95 | max | Spread | Reproducible |
|---|---|---|---|---|---|---|
| real `asyncio` | 14.37 ms | 16.48 ms | 17.38 ms | 20.43 ms | 6.06 ms | no |
| virtual | **5.00 ms** | **5.00 ms** | **5.00 ms** | **5.00 ms** | **0.00 ms** | **yes** |

The virtual clock's answer is the *correct* one: two stages of 2 ms plus a 1 ms polling
granularity is 5 ms, exactly, and it returns 5.00 ms at every quantile on every run. The real
clock reports **16.48 ms at p50** — it is not measuring your pipeline, it is measuring your
pipeline plus about 11 ms of event-loop scheduling. Hence the flake rates for
`assert lateness <= budget` over the same runs:

| Budget | Real clock | Virtual clock |
|---|---|---|
| 6 ms | **100.0%** | **0.0%** |
| 18 ms | 2.5% | 0.0% |
| 20 ms | 2.5% | 0.0% |
| 25 ms | 0.0% | 0.0% |
| 50 ms | 0.0% | 0.0% |

Read the first row carefully, because it is the whole argument. The assertion that states the
*truth about the system* — lateness is at most 6 ms — fails every single time on a real clock
and never on a virtual one. You cannot fix that by choosing a better threshold: you can only
loosen the assertion until it stops saying anything, which is what the 25 ms row is.

And the middle rows do not reproduce. Across three trials on an otherwise idle machine the
real clock's maximum ranged **18.04 → 48.17 ms** and its spread **3.36 → 34.01 ms**, so the
flake rate at 18 ms was 0% on two trials and 2% on another. **A test whose failure rate is
itself irreproducible cannot be triaged**, which is why these get retried and then deleted.

A virtual clock is thirty lines: a monotonic counter, a list of waiters, and a driver that
advances time to the next due waiter **only when every task is blocked**. That last condition
is what makes it exact — time cannot advance while any task is runnable, so there is no race
to observe.

Three rules for using one. **Never mix real and virtual sleeps** in the same test; one
`asyncio.sleep(0.1)` reintroduces all the noise. **Assert on logical time, not wall time** —
`clock.now`, not `time.perf_counter()`. And **keep cancellation real**: the point is to
remove scheduler noise, not to stub out the concurrency you are testing, so real
`Task.cancel()` and real `CancelledError` propagation must still happen.

The virtual clock is also *unboundedly* faster as durations grow: a 10-minute session soak
runs in milliseconds of logical time because nothing actually waits.

### 2.3 WAV-driven pipelines and stubbed engines

The replay test is the highest-value test in the suite: feed recorded audio in, assert on
the event sequence out.

**Stub at the ABC boundary, not with a mocking library.** Your STT, TTS, LLM and VAD already
have interfaces ([`../07-livekit/03-writing-plugins.md`](../07-livekit/03-writing-plugins.md)),
so implement them:

| Stub | Behaviour | Tests |
|---|---|---|
| `ScriptedSTT` | emits interim/final transcripts at specified logical times | endpointing, turn logic |
| `ScriptedVAD` | emits speech start/end at specified frames | barge-in, false interruption |
| `ScriptedLLM` | returns fixed token streams, with injectable delay and failure | deadlines, filler, cancellation |
| `ScriptedTTS` | emits N frames, can die at frame K | mid-utterance failure, flush |
| `SlowLLM`, `FlakyTTS` | inject latency and 5xx | the reliability drills ([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)) |

The tests worth writing against these are the ones that encode invariants rather than
behaviour:

- **Truncation correctness**: the logged assistant turn is a **prefix** of the synthesised
  text, cut at the playback position. This is an invariant, not an SLO, and it is the single
  most valuable assertion in the suite — a violation means the LLM's context contains
  sentences the user never heard.
- **No dead air**: no gap between `t_eou` and `ttfa` exceeds `D`, for every injected
  failure mode.
- **Cancellation completes**: after an interrupt, no stage emits another audio frame. Assert
  it by counting frames after the interrupt, which is exactly the measurement in
  [`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md).
- **No zombie tasks**: after a session ends, `asyncio.all_tasks()` contains nothing from it.
  This catches the leak class that soak tests find twelve hours later.
- **Idempotency**: a retried tool call with the same idempotency key executes once.

For the real models, **cache responses keyed by input hash**. A cached LLM response makes the
replay deterministic and free; a cache miss in CI is a signal that the prompt changed, which
is itself worth failing on.

### 2.4 Latency gates that are hypothesis tests

A CI gate compares a statistic computed on a corpus against a threshold. It is therefore a
hypothesis test with a false-positive rate, and the only defensible threshold comes from the
**sampling distribution of the statistic under no change**.

`[MEASURED]` from §3 — 400 resamples per configuration, gate set at the 99th percentile of
the baseline's own distribution (a 1% false-failure rate):

| Corpus | Statistic | Baseline | Noise (sd) | Gate | Min detectable |
|---|---|---|---|---|---|
| 50 | p50 | 587 ms | 44.5 ms | 712 ms | +124 ms |
| 50 | p95 | 1822 ms | 279.8 ms | 2566 ms | **+744 ms** |
| 200 | p50 | 581 ms | 20.5 ms | 633 ms | +52 ms |
| 200 | p95 | 1822 ms | 155.2 ms | 2221 ms | +399 ms |
| 1000 | p50 | 579 ms | 9.4 ms | 601 ms | **+22 ms** |
| 1000 | p95 | 1818 ms | 62.7 ms | 1969 ms | +151 ms |
| 5000 | p50 | 579 ms | 4.2 ms | 589 ms | +11 ms |
| 5000 | p95 | 1818 ms | 29.8 ms | 1884 ms | +66 ms |

Three design rules fall out.

**Gate on p50, monitor p95.** At every corpus size the p50 detects a regression roughly six
times smaller than the p95 does, because the p95 is estimated from 5% of the sample and
carries the tail's variance. A uniform slowdown moves both, so p50 is the sensitive
detector; p95 remains the thing you promise users, monitored in production
([`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md)).

**Corpus size buys sensitivity at a known rate.** Noise falls roughly as $1/\sqrt{n}$: 50 →
1000 utterances (20×) cuts p50 noise from 44.5 ms to 9.4 ms (4.7×). If you need to catch
20 ms, you need about a thousand utterances, and no cleverness substitutes.

**State the false-positive rate explicitly.** A gate at the 99th percentile fails one clean
build in a hundred. That is a deliberate cost — the alternative is a looser gate that misses
real regressions. Pick the rate, write it in the gate's comment, and re-baseline
deliberately rather than nudging the threshold when it fires.

Because CI corpora are small, **run the gate deterministically**: fixed corpus, fixed seeds,
fake clock, cached model responses. Then the only variance is the one you are testing for,
and you can use a much tighter gate than production monitoring allows.

### 2.5 Golden audio, and its limit

TTS is not bit-reproducible, so a checksum fails on every benign re-run. But the naive fix —
compare waveforms — is worse than useless. `[MEASURED]` from §3:

| Case | Bytes equal | RMS diff | Mel dB | Gate @ 0.10 dB |
|---|---|---|---|---|
| identical bytes | yes | 0.00000 | 0.000 | pass |
| float32 kernel drift (~2e−5) | NO | 0.00000 | 0.025 | pass |
| **1-sample shift (62 µs)** | NO | **0.05298** | **0.010** | pass |
| formants +2% (**regression**) | NO | 0.04586 | 0.857 | **FAIL** |
| sampling TTS, new draw | NO | 0.04618 | 1.086 | **FAIL** |

Row three is the argument. A one-sample shift at 16 kHz is **62.5 microseconds** — utterly
inaudible, the kind of difference a different buffer boundary produces — and its RMS
difference of 0.05298 is **larger** than the real 2% formant regression's 0.04586. A
waveform-domain metric cannot distinguish "shifted imperceptibly" from "sounds different",
because it is phase-sensitive and hearing is not.

The mel-band log distance separates them by 86× (0.010 versus 0.857), and a gate at 0.10 dB
passes all three benign cases and catches the regression. Mel bands work here specifically
because **averaging many FFT bins suppresses the per-bin noise-floor variance** that makes a
raw log-spectral distance useless — an earlier attempt at this measurement using per-bin
log-magnitude ranked the benign re-run as *more* changed than the regression, which is how
the bug was found.

Row five is the important limit. A **sampling-based TTS** — a codec-LM that draws tokens
rather than computing them deterministically
([`../04-tts/02-codec-lm-tts.md`](../04-tts/02-codec-lm-tts.md)) — produces a benign redraw
that differs by 1.086 dB, *more* than the real regression's 0.857 dB. **When benign variance
exceeds the effect size, golden audio cannot work at all**, at any tolerance. For those
engines the gate must move up a level of abstraction:

- **ASR round-trip**: synthesise, transcribe, assert WER against the input text. Catches
  intelligibility regressions, ignores voice identity.
- **Distributional**: generate $k$ samples, compare summary statistics (duration, F0
  contour, band energies) against the baseline distribution rather than a single reference.
- **Fix the seed** if the engine permits it, which converts the problem back into row two.
- **Human evaluation**, batched and infrequent, for voice quality
  ([`02-simulation-and-load.md`](02-simulation-and-load.md)).

Either way, **golden audio tests intelligibility and gross regressions, never subjective
quality.** Asserting on quality is what nightly human evaluation is for.

### 2.6 What not to test

Anti-patterns that generate maintenance and no signal:

- **Asserting exact LLM output.** It changes with temperature, model version and prompt.
  Assert structure: a tool was called with these arguments, the reply is under N words, no
  markdown reached the TTS.
- **Testing against live vendor APIs in CI.** Slow, flaky, expensive, and it fails when
  their status page is red. Cache, or use a contract test run separately.
- **`sleep()` to wait for a condition.** Await the condition, or advance the fake clock.
- **Asserting on wall-clock durations in unit tests.** §2.2.
- **A WER gate on ten utterances.** §2.4 applies to quality metrics too; ten utterances
  cannot detect anything.
- **Snapshot-testing prompts.** The diff is unreadable and the test teaches nothing; version
  the prompt as an artefact instead ([`../06-realtime-systems/08-deployment.md`](../06-realtime-systems/08-deployment.md)).

---

## 3. From scratch

A real flake rate measured on this machine, gate calibration from sampling distributions,
and golden-audio metrics. `numpy` for Part C, stdlib elsewhere.

```python
"""Testing a voice pipeline without flakiness.

Part A is not a simulation. It measures, on this machine, the worst per-frame
lateness of the same two-stage pipeline under a real asyncio clock and under a
virtual clock. The real clock adds ~11 ms of scheduler overhead on top of the
pipeline's true 5 ms, and its spread is load-dependent -- so the flake rate of
any fixed assertion is itself irreproducible. The virtual clock returns the
true value, exactly, every run.

Part B calibrates a CI latency gate. A gate is a hypothesis test: with a fixed
corpus of N utterances, which threshold keeps false failures rare while still
catching a regression worth catching? Answer from the sampling distribution of
the statistic, not from a round number.

Part C is golden audio. TTS is not bit-reproducible, so a checksum fails on
benign runs. Measure which metric separates "same audio, different run" from
"actually changed" -- and find the case where golden audio cannot work at all.

numpy for Part C; stdlib elsewhere.
"""

import asyncio
import math
import random
import time

import numpy as np

FRAME_MS = 20
SR = 16000
RUNS = 80


# --------------------------------------------------------------- Part A
async def lateness_realclock(n_frames=12, work_ms=2.0):
    """Worst lateness of any frame vs its ideal capture+pipeline time, real clock."""
    inq, mid, outq = asyncio.Queue(), asyncio.Queue(), asyncio.Queue()

    async def stage(iq, oq):
        while True:
            f = await iq.get()
            if f is None:
                await oq.put(None)
                return
            await asyncio.sleep(work_ms / 1000.0)
            await oq.put(f)

    t0 = time.perf_counter()
    tasks = [asyncio.ensure_future(stage(inq, mid)),
             asyncio.ensure_future(stage(mid, outq))]

    async def feed():
        for i in range(n_frames):
            await inq.put(i)
            await asyncio.sleep(FRAME_MS / 1000.0)
        await inq.put(None)

    feeder = asyncio.ensure_future(feed())
    worst, got = -1e9, 0
    while got < n_frames:
        f = await outq.get()
        if f is None:
            break
        worst = max(worst, (time.perf_counter() - t0) * 1000.0 - f * FRAME_MS)
        got += 1
    feeder.cancel()
    for t in tasks:
        t.cancel()
    await asyncio.gather(feeder, *tasks, return_exceptions=True)
    return worst


class VClock:
    """Virtual clock: time advances only when every task is blocked on it."""

    def __init__(self):
        self.now = 0.0
        self._waiters = []

    async def sleep(self, ms):
        if ms <= 0:
            await asyncio.sleep(0)
            return
        ev = asyncio.Event()
        self._waiters.append((self.now + ms, ev))
        await ev.wait()

    async def drive(self, done, limit=100_000.0):
        while not done() and self.now < limit:
            for _ in range(60):          # let every runnable task settle first
                await asyncio.sleep(0)
            if done() or not self._waiters:
                break
            self.now = min(t for t, _ in self._waiters)
            due = [e for t, e in self._waiters if t <= self.now]
            self._waiters = [(t, e) for t, e in self._waiters if t > self.now]
            for e in due:
                e.set()
        for _ in range(60):
            await asyncio.sleep(0)


async def lateness_vclock(n_frames=12, work_ms=2.0):
    """The same quantity on a virtual clock."""
    clk = VClock()
    inq, mid, outq = asyncio.Queue(), asyncio.Queue(), asyncio.Queue()
    finished, results = asyncio.Event(), []

    async def stage(iq, oq):
        while True:
            if iq.empty():
                await clk.sleep(1)
                continue
            f = iq.get_nowait()
            if f is None:
                oq.put_nowait(None)
                return
            await clk.sleep(work_ms)
            oq.put_nowait(f)

    async def feed():
        for i in range(n_frames):
            inq.put_nowait(i)
            await clk.sleep(FRAME_MS)
        inq.put_nowait(None)

    async def sink():
        while len(results) < n_frames:
            if outq.empty():
                await clk.sleep(1)
                continue
            f = outq.get_nowait()
            if f is None:
                break
            results.append((f, clk.now))
        finished.set()

    ts = [asyncio.ensure_future(stage(inq, mid)),
          asyncio.ensure_future(stage(mid, outq)),
          asyncio.ensure_future(feed()), asyncio.ensure_future(sink())]
    await clk.drive(finished.is_set)
    for t in ts:
        t.cancel()
    await asyncio.gather(*ts, return_exceptions=True)
    return max(now - f * FRAME_MS for f, now in results)


async def part_a():
    print(f"worst per-run lateness of any frame, {RUNS} runs each")
    print(f"two stages x 2 ms of work per 20 ms frame\n")
    real = sorted([await lateness_realclock() for _ in range(RUNS)])
    virt = sorted([await lateness_vclock() for _ in range(RUNS)])
    print(f"{'clock':16s} {'min':>8} {'p50':>8} {'p95':>8} {'max':>8} "
          f"{'spread':>8} {'reproducible':>13}")
    for name, xs in (("real asyncio", real), ("virtual", virt)):
        spread = xs[-1] - xs[0]
        print(f"{name:16s} {xs[0]:7.2f}ms {xs[len(xs)//2]:7.2f}ms "
              f"{xs[int(.95*len(xs))]:7.2f}ms {xs[-1]:7.2f}ms {spread:7.2f}ms "
              f"{'YES' if spread == 0.0 else 'no':>13}")
    print(f"\nflake rate of 'assert lateness <= budget', same {RUNS} runs:")
    print(f"{'budget':>8} {'real clock':>12} {'virtual clock':>15}")
    for b in (6, 18, 20, 25, 30, 50):
        fr = sum(1 for x in real if x > b) / len(real)
        fv = sum(1 for x in virt if x > b) / len(virt)
        print(f"{b:6d}ms {fr:11.1%} {fv:14.1%}")
    print(f"\nVERDICT  virtual spread == 0.00 ms: "
          f"{'PASS' if virt[-1] - virt[0] == 0.0 else 'FAIL'}"
          f"   real spread > 0: "
          f"{'PASS' if real[-1] - real[0] > 0 else 'FAIL'}")
    print("NOTE     the real-clock rows above are load-dependent and will NOT")
    print("         reproduce; across three trials on an idle M5 the max ranged")
    print("         18.04 -> 48.17 ms and the spread 3.36 -> 34.01 ms. that")
    print("         irreproducibility IS the finding: no fixed budget gives a")
    print("         stable pass. the virtual clock returned 5.00 ms every run.")



# --------------------------------------------------------------- Part B
def turn_latency(rng, shift=0.0):
    if rng.random() < 0.22:
        return rng.lognormvariate(math.log(1400), 0.35) + shift
    return rng.lognormvariate(math.log(520), 0.30) + shift


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def part_b():
    print(f"{'corpus':>8} {'stat':>6} {'baseline':>10} {'noise sd':>10} "
          f"{'gate (1% FP)':>13} {'min detectable':>15}")
    for n in (50, 200, 1000, 5000):
        for q, label in ((0.50, "p50"), (0.95, "p95")):
            draws = []
            for w in range(400):
                rng = random.Random(500 + w)
                draws.append(pct([turn_latency(rng) for _ in range(n)], q))
            mu = sum(draws) / len(draws)
            sd = (sum((x - mu) ** 2 for x in draws) / (len(draws) - 1)) ** 0.5
            gate = pct(draws, 0.99)          # accept a 1% false-failure rate
            print(f"{n:8d} {label:>6} {mu:9.0f}ms {sd:9.1f}ms {gate:12.0f}ms "
                  f"{gate-mu:+14.0f}ms")
    print("\ngate = the 99th percentile of the baseline's OWN sampling")
    print("distribution, so 1% of clean runs fail. a round number cannot know this")


# --------------------------------------------------------------- Part C
def resonator(x, f, bw):
    """One formant: a two-pole IIR resonance at f with bandwidth bw."""
    r = math.exp(-math.pi * bw / SR)
    a1, a2 = -2 * r * math.cos(2 * math.pi * f / SR), r * r
    y = np.zeros_like(x)
    for n in range(len(x)):
        y[n] = x[n] - a1 * (y[n - 1] if n else 0) - a2 * (y[n - 2] if n > 1 else 0)
    return y * (1 - r)


def synth(seed, f0=120.0, dur=0.5, formants=(700, 1220, 2600),
          new_draw=False, changed=False):
    """A source-filter 'TTS rendering': pulse train through three formants."""
    rng = np.random.default_rng(seed)
    n = int(SR * dur)
    t = np.arange(n) / SR
    exc = np.zeros(n)
    k = rng.uniform(0, 1) if new_draw else 0.0      # sub-sample pulse placement
    period = SR / f0
    while k < n - 1:                                 # fractional-delay impulses
        i, frac = int(k), k - int(k)
        exc[i] += 1 - frac
        exc[i + 1] += frac
        k += period
    exc += rng.normal(0, 0.02, n)                    # aspiration noise
    y = exc.copy()
    for f, bw in zip((f * (1.02 if changed else 1.0) for f in formants),
                     (80, 90, 120)):
        y = resonator(y, f, bw)
    y = y * np.clip(np.minimum(t / 0.04, (dur - t) / 0.04), 0, 1)
    return (y / np.sqrt(np.mean(y ** 2)) * 0.15).astype(np.float32)


def melbank(n_fft=512, n_mels=32, fmin=50, fmax=7600):
    h2m = lambda f: 2595 * np.log10(1 + f / 700)
    m2h = lambda m: 700 * (10 ** (m / 2595) - 1)
    pts = m2h(np.linspace(h2m(fmin), h2m(fmax), n_mels + 2))
    b = np.floor((n_fft + 1) * pts / SR).astype(int)
    fb = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(n_mels):
        l, c, r = b[i], max(b[i + 1], b[i] + 1), max(b[i + 2], b[i + 1] + 1)
        fb[i, l:c] = np.linspace(0, 1, c - l, endpoint=False)
        fb[i, c:r] = np.linspace(1, 0, r - c, endpoint=False)
    return fb


FB = melbank()


def mel_db_distance(a, b, n_fft=512, floor=1e-6):
    """Mean absolute log-mel difference in dB.

    Mel bands average many FFT bins, which is what suppresses the per-bin
    noise-floor variance that makes a raw log-spectral distance useless here.
    """
    def logmel(x):
        hop, w = n_fft // 4, np.hanning(n_fft)
        fr = np.array([x[i:i + n_fft] * w for i in range(0, len(x) - n_fft, hop)])
        P = np.abs(np.fft.rfft(fr, axis=-1)) ** 2
        return 10 * np.log10(np.maximum(P @ FB.T, floor))
    A, B = logmel(a), logmel(b)
    m = min(len(A), len(B))
    return float(np.mean(np.abs(A[:m] - B[:m])))


def part_c():
    ref = synth(1)
    rng = np.random.default_rng(7)
    cases = [
        ("identical bytes", synth(1)),
        # different BLAS kernel order on another machine: float32 rounding
        ("float32 kernel drift (~2e-5)",
         (ref * (1 + rng.normal(0, 2e-5, len(ref)))).astype(np.float32)),
        # one sample at 16 kHz is 62.5 us: inaudible
        ("1-sample shift (62 us)",
         np.concatenate([[0.0], ref[:-1]]).astype(np.float32)),
        ("formants +2% (REGRESSION)", synth(1, changed=True)),
        # a sampling-based codec-LM TTS: same text, genuinely new realisation
        ("sampling TTS, new draw", synth(2, new_draw=True)),
    ]
    print(f"{'case':32s} {'bytes eq':>9} {'rms diff':>10} {'mel dB':>9} "
          f"{'gate @0.10 dB':>14}")
    for name, other in cases:
        n = min(len(ref), len(other))
        a, b = ref[:n], other[:n]
        rms = float(np.sqrt(np.mean((a - b) ** 2)))
        mel = mel_db_distance(a, b)
        print(f"{name:32s} {'yes' if np.array_equal(a, b) else 'NO':>9} "
              f"{rms:10.5f} {mel:9.3f} {'FAIL' if mel > 0.10 else 'pass':>14}")
    print("\nthe 1-sample shift is inaudible and scores WORSE on rms than the")
    print("real regression -- waveform metrics cannot gate golden audio. the")
    print("last row is worse news: a sampling TTS's benign redraw exceeds the")
    print("regression on every metric, so golden audio cannot work for it at all")



async def main():
    print("PART A -- real clock vs virtual clock, measured on this machine\n")
    await part_a()
    print("\n\nPART B -- a CI latency gate is a hypothesis test\n")
    part_b()
    print("\n\nPART C -- golden audio without brittleness\n")
    part_c()


if __name__ == "__main__":
    asyncio.run(main())
```

Output `[MEASURED]`:

```
PART A -- real clock vs virtual clock, measured on this machine

worst per-run lateness of any frame, 80 runs each
two stages x 2 ms of work per 20 ms frame

clock                 min      p50      p95      max   spread  reproducible
real asyncio       14.37ms   16.48ms   17.38ms   20.43ms    6.06ms            no
virtual             5.00ms    5.00ms    5.00ms    5.00ms    0.00ms           YES

flake rate of 'assert lateness <= budget', same 80 runs:
  budget   real clock   virtual clock
     6ms      100.0%           0.0%
    18ms        2.5%           0.0%
    20ms        2.5%           0.0%
    25ms        0.0%           0.0%
    30ms        0.0%           0.0%
    50ms        0.0%           0.0%

VERDICT  virtual spread == 0.00 ms: PASS   real spread > 0: PASS
NOTE     the real-clock rows above are load-dependent and will NOT
         reproduce; across three trials on an idle M5 the max ranged
         18.04 -> 48.17 ms and the spread 3.36 -> 34.01 ms. that
         irreproducibility IS the finding: no fixed budget gives a
         stable pass. the virtual clock returned 5.00 ms every run.


PART B -- a CI latency gate is a hypothesis test

  corpus   stat   baseline   noise sd  gate (1% FP)  min detectable
      50    p50       587ms      44.5ms          712ms           +124ms
      50    p95      1822ms     279.8ms         2566ms           +744ms
     200    p50       581ms      20.5ms          633ms            +52ms
     200    p95      1822ms     155.2ms         2221ms           +399ms
    1000    p50       579ms       9.4ms          601ms            +22ms
    1000    p95      1818ms      62.7ms         1969ms           +151ms
    5000    p50       579ms       4.2ms          589ms            +11ms
    5000    p95      1818ms      29.8ms         1884ms            +66ms

gate = the 99th percentile of the baseline's OWN sampling
distribution, so 1% of clean runs fail. a round number cannot know this


PART C -- golden audio without brittleness

case                              bytes eq   rms diff    mel dB  gate @0.10 dB
identical bytes                        yes    0.00000     0.000           pass
float32 kernel drift (~2e-5)            NO    0.00000     0.025           pass
1-sample shift (62 us)                  NO    0.05298     0.010           pass
formants +2% (REGRESSION)               NO    0.04586     0.857           FAIL
sampling TTS, new draw                  NO    0.04618     1.086           FAIL

the 1-sample shift is inaudible and scores WORSE on rms than the
real regression -- waveform metrics cannot gate golden audio. the
last row is worse news: a sampling TTS's benign redraw exceeds the
regression on every metric, so golden audio cannot work for it at all
```

Three load-bearing details. **Part A's `VERDICT` line is the only reproducible claim in that
section, and it is deliberately the one that matters** — `virtual spread == 0.00 ms` and
`real spread > 0` hold on every machine, while the specific milliseconds do not; a listing
that measures the scheduler has to distinguish what it proves from what it merely observed,
and printing the `NOTE` inside the output is how it does that. **The virtual clock's `drive`
loop yields sixty times before advancing**, and that bound is the whole correctness argument:
time may only move when every task is genuinely blocked, so an under-count reintroduces
exactly the race the clock exists to remove. And **Part C's `float32 kernel drift` row has an
RMS difference that prints as 0.00000 while its mel distance is 0.025** — the metric that
looks more sensitive is the one that misses, because RMS is dominated by the loudest samples
while the mel distance integrates the quiet bands where a codec regression shows up first.

---

## 4. How production does it

**`pytest-asyncio` plus a hand-rolled virtual clock** is the working combination. There is no
standard fake clock for `asyncio` audio pipelines, so §3's thirty lines is what teams write;
the important part is that it lives in your test fixtures and every timing test uses it.

**LiveKit's plugin ABCs are the stub boundary.** `STT`, `TTS`, `LLM` and `VAD` with their
streaming contracts are exactly the interfaces to implement as scripted fakes, and
`StreamAdapter(stt=, vad=)` is a reminder that the framework already composes these
([`../07-livekit/03-writing-plugins.md`](../07-livekit/03-writing-plugins.md)).

**Recorded calls are the corpus.** The three artefacts from
[`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md) —
unmixed audio, the event log, the decision inputs — are precisely what a replay test consumes,
which is why recording is a testing decision as much as an observability one. Production
failures become regression tests by promotion, not by re-implementation.

**ASR round-trip is the standard TTS gate** in the wild, because §2.5's row five means
spectral comparison is unavailable for sampling engines. Synthesise, transcribe with a fixed
ASR model, assert WER — it catches the regressions that matter (unintelligible output,
mispronounced entities, truncation) and ignores the ones that do not.

**The metrics that need labels run nightly, not per-commit.** WER, endpoint F1 and entity
accuracy against a labelled set are batch jobs whose corpus is large enough for §2.4's
arithmetic to work ([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)).

---

## 5. At scale

**Test suite wall time is a real constraint, and virtual clocks are the lever.** A soak test
of a thousand 10-minute sessions is milliseconds of virtual time and hours of real time. Every
duration-dependent test should be virtual; reserve real time for the handful of integration
tests that genuinely exercise the network.

**Corpus curation beats corpus size, up to a point.** §2.4 says you need ~1000 utterances to
detect 22 ms. Getting there with *stratified* real audio — accents, noise conditions, phone
versus headset, entity-heavy utterances — makes the same corpus serve the quality gates too.

**Quarantine flaky tests, do not delete them.** A test moved to a quarantine suite with a
tracking issue keeps its signal; a deleted test does not. And measure the flake rate rather
than arguing about it — §2.2's irreproducible 0–2.5% at an 18 ms budget, against a virtual
clock's exact 0.00 ms spread, is the kind of evidence that ends the discussion.

**Contract-test vendors on a schedule.** Their APIs change without your deploy. A nightly
suite that exercises the real endpoints catches a breaking change before your customers do,
and it must be separate from PR CI so their outage is not your outage.

**Gate on the invariants at 100%.** Truncation correctness, no-dead-air and no-zombie-tasks
are not statistical; a single violation fails the build. Reserve statistical gates for
statistical quantities.

**Budget for re-baselining.** Latency gates drift as the system legitimately changes, so the
process needs a deliberate "accept new baseline" step with a recorded reason, or engineers
will loosen thresholds silently until the gate means nothing.

---

## 6. Exercises

**E8.1.1** Run the §3 listing. Sweep the Part A budget from 20 to 35 ms and plot the
real-clock flake rate against it. Report the budget at which the flake rate is 50%, and
explain why no budget gives both a reliable pass and a tight bound.

**E8.1.2** Break the virtual clock deliberately: reduce the yield count in `drive` from 60 to
1 and re-run. Report the flake rate and explain the race you reintroduced.

**E8.1.3** Implement `ScriptedSTT` and `ScriptedVAD` against your framework's ABCs, then
write the truncation-correctness invariant test: the logged assistant turn is a prefix of the
synthesised text, cut at the playback position. Make it fail by removing the truncation.

**E8.1.4** Calibrate a latency gate for your own corpus: measure the sampling distribution of
your p50 over 200 resamples, set the gate at the 99th percentile, and report the minimum
detectable regression. State whether it is small enough to be useful.

**E8.1.5** Show empirically that the p50 gate is more sensitive than the p95 gate at the same
corpus size, then find a regression shape that the p95 catches and the p50 misses. What kind
of change is it?

**E8.1.6** Add a `1-frame shift (20 ms)` case to Part C and report both metrics. At what shift
does the mel distance exceed the 0.10 dB gate, and is that the threshold you would want?

**E8.1.7** Build the ASR round-trip gate for a sampling TTS engine: synthesise a fixed
sentence set, transcribe, assert WER. Report the run-to-run variance of that WER and the gate
it implies.

**E8.1.8** Take one production incident from your own history and write the replay test that
would have caught it. State which of the three recorded artefacts you were missing.

---

## 7. Interview drill

> "Our CI has a latency regression gate on the voice pipeline. It's been failing on and off
> for a month, so the team added a retry and now it passes. What's wrong and how would you
> fix it?"

The retry is the bug being reported, not the fix — a gate that passes on retry is a gate
that has been converted into a coin flip, and the team has correctly diagnosed that it was
not telling them anything, but chosen the wrong remedy. So I would ask what the gate measures
and on how much data, because there are two separate ways this fails and they need different
answers.

The first possibility is that the gate is timing-sensitive against a real clock. Async audio
tests are flaky by construction, and the measurement I would bring makes the mechanism
concrete: a two-stage pipeline whose *true* worst-case lateness is 5.00 ms reads as 16.48 ms
at p50 on a real `asyncio` clock, because the clock is measuring the pipeline plus about
11 ms of event-loop scheduling. So the assertion that states the truth about the system —
lateness at most 6 ms — fails 100% of runs on a real clock and 0% on a virtual one, and no
threshold repairs that; you can only loosen it until it stops saying anything. Worse, the
real clock's spread is load-dependent: across trials its maximum ranged 18 to 48 ms, so the
flake rate of a looser assertion is not reproducible either, which is exactly why this one
cannot be triaged and got a retry instead. If our gate contains any real `sleep`, that is
where I would start.

The second possibility, and the more likely one for a *latency* gate, is that the threshold
is a round number chosen by a human rather than derived from the statistic's own sampling
distribution. A gate is a hypothesis test and it has a false-positive rate whether or not
anyone computed it. On a 50-utterance corpus the p95 has about 280 ms of standard deviation,
so any threshold within a few hundred milliseconds of the baseline will fire on clean builds
routinely, and one that does not fire cannot detect a regression smaller than about 750 ms.
Both settings are useless, which is exactly the experience the team is describing.

So the fix is threefold. Make the run deterministic — fixed corpus, fixed seeds, fake clock,
cached model responses — so the only remaining variance is what we are testing for. Derive
the threshold from the baseline's resampled distribution and state the false-positive rate
explicitly; at the 99th percentile, one clean build in a hundred fails, and that is a
deliberate cost rather than an accident. And gate on the p50 rather than the p95: at a
thousand utterances the p50 detects a 22 ms regression where the p95 needs 151 ms, because
the p95 is estimated from five per cent of the sample and inherits the tail's variance. The
p95 is what we promise users, so it stays on the production dashboard; the p50 is what
detects change, so it goes in the gate.

What distinguishes a senior answer is naming the corpus-size requirement honestly. If we
only have fifty utterances, no threshold choice rescues the gate — we need about a thousand
to see tens of milliseconds, and the work is corpus curation, ideally stratified so the same
audio serves the WER and endpointing gates too. I would also separate the invariants from
the statistics: truncation correctness, no-dead-air and no-zombie-tasks are not statistical
and should fail the build on a single violation, and mixing them into a flaky statistical
gate is how a real bug gets retried away.

The premise worth questioning is whether the gate ever caught anything. I would look at its
history: if in a month of firing it never once corresponded to a real regression, it is
measuring noise and should be turned off *deliberately* while we rebuild it, rather than left
running with a retry that quietly disables it.

---

## Sources

- CPython `asyncio` documentation, 3.12 — event-loop scheduling, `Task.cancel()` semantics and `asyncio.all_tasks()`, used in §2.2 and §2.3.
- `pytest-asyncio` — the harness convention referenced in §4; no standard virtual clock is provided, which is why §3 implements one.
- `livekit/agents` 1.7.0 — the `STT` / `TTS` / `LLM` / `VAD` ABCs and streaming contracts that form the stub boundary in §2.3, and `StreamAdapter(stt=, vad=)`; detailed in [`../07-livekit/03-writing-plugins.md`](../07-livekit/03-writing-plugins.md).
- Mel filterbank construction follows the derivation in [`../01-foundations/02-time-frequency.md`](../01-foundations/02-time-frequency.md) (HTK-style $2595\log_{10}(1+f/700)$), reimplemented standalone in §3 rather than imported.
- WER methodology, normalisation traps and bootstrap confidence intervals: [`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md) — the statistics in §2.4 apply to quality gates as well as latency gates.
- Prior measurements in this curriculum reused rather than repeated: the bimodal `eou_to_ttfa` shape and the p95 detection-power result from [`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md); the frames-after-interrupt measurement from [`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md), which §2.3 turns into an assertion.
- `[MEASURED]`: all three sections are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, `numpy` 2.5.2. **Part A is a genuine measurement of this machine and is only partly reproducible**, which is the point it makes. Reproducible on any machine: the virtual clock's lateness is exactly 5.00 ms with 0.00 ms spread at every quantile, and the printed `VERDICT` asserts that. Not reproducible: the real-clock min/p50/p95/max and therefore the flake rates — across three trials on an otherwise idle machine the real clock's maximum ranged 18.04 → 48.17 ms and its spread 3.36 → 34.01 ms, so the 18 ms flake rate was 0% twice and 2.5% once. The listing prints that caveat itself rather than presenting one run as reproducible. Part B resamples an `[INFERENCE]` bimodal latency model (78% at median 520 ms, 22% at median 1400 ms); the $1/\sqrt{n}$ noise scaling and the p50-versus-p95 sensitivity ratio are properties of the estimators and hold regardless, while the absolute milliseconds depend on the model. Part C's audio is a synthetic source-filter rendering, not a real TTS engine; the ordering it demonstrates — that an inaudible 1-sample shift exceeds a real formant change under RMS, and that a sampling engine's benign redraw exceeds a real regression under every metric tried — is the robust finding. An earlier version of this measurement used per-bin log-magnitude distance and ranked the benign re-run as *more* changed than the regression; that error is what motivated the mel-band formulation, and is recorded here because the failure mode is easy to repeat.
