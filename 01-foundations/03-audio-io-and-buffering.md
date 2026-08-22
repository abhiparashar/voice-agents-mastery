# Audio I/O, Buffers, and Where Milliseconds Actually Go

**What you'll be able to do after this:** state the real-time audio contract and
recognise every way code violates it; implement a correct single-producer
single-consumer ring buffer and justify its overflow policy; diagnose glitches by
sound alone; compute clock drift between two devices in samples per hour; choose a
resampler from measured alias rejection and cost; and account for every millisecond
between a mouth and a model.

---

## 1. Intuition

There is a thread in your process that is not like the others. The operating
system's audio subsystem calls it every few milliseconds, hands it a buffer, and
expects it filled or emptied before the next deadline. If it is late — even once —
the sound card has nothing to play, and the user hears a click, a pop, or a gap.
The OS will not wait. It will not retry. There is no backpressure mechanism
available to it, because the speaker cone has to move *now*.

This is the mental shift that audio demands from a web engineer. In a request/response
system, slow means slow: the user waits longer and everything still works. In
audio, slow means **broken**, and the failure is audible and immediate. A garbage
collection pause, a lock held by a logging call, a `print` to a blocked terminal, a
memory allocation that triggers a page fault — any of these inside the audio
callback produces an artefact you can hear.

So audio code is organised around a hard rule: the callback does the minimum
possible work — copy bytes into or out of a pre-allocated structure — and hands off
to a normal thread for anything real. Everything else in this chapter is the
consequence of that rule.

The second intuition is about **buffers as stored latency**. A buffer is not a
neutral container; it is a decision to trade delay for safety. Every sample sitting
in a buffer is a sample the user has not heard yet. A 200 ms playout buffer makes
your audio robust to network jitter *and* guarantees that your agent can never
respond in less than 200 ms. Buffers are where latency budgets go to die, usually
because someone increased one to fix a glitch and never wrote down why. The
discipline is to know, at every stage, how many milliseconds you are holding and
what you bought with them.

The third is about **clocks**. Your microphone and your speaker are driven by
separate crystal oscillators, and crystals are not exact. A 50 ppm part is within
spec and drifts 180 ms per hour. On a long call, one device produces more samples
per second than the other consumes, and the difference has to go somewhere: a
buffer grows without bound, or it empties and glitches. This is not a bug you can
fix by being careful. It is physics, and it needs an explicit mechanism.

---

## 2. Rigour

### 2.1 The real-time audio contract

The audio callback runs on a thread with elevated priority, often outside your
runtime's control. Inside it, the following are forbidden:

| Forbidden | Why | What it sounds like |
|---|---|---|
| Blocking I/O (file, socket, `print`) | Unbounded latency; a full pipe blocks indefinitely | Periodic dropouts, worse under load |
| Acquiring a lock a non-RT thread holds | Priority inversion: the RT thread waits on a low-priority thread | Sporadic clicks, unreproducible |
| Memory allocation | `malloc` may take a global lock or fault a page | Occasional clicks that vanish under a profiler |
| Waiting on a condition variable or queue | Exactly the blocking you are trying to avoid | Dropouts |
| Anything with unbounded worst-case time | The deadline is hard, so only worst case matters | Intermittent, load-dependent glitches |

The permitted operations are: reads and writes to pre-allocated memory, atomic
loads and stores, and arithmetic. That is nearly the whole toolkit.

The deadline itself is set by the buffer size the device negotiated. For a
`blocksize` of $B$ samples at rate $f_s$, the callback is invoked every $B/f_s$
seconds and must complete well inside that. For $B = 320$ at 16 kHz, that is 20 ms
— generous. For $B = 64$ at 48 kHz, 1.33 ms — not generous at all. Choosing a
larger block size buys you slack and costs you latency, one for one.

### 2.2 Python, the GIL, and how much of this applies

Python cannot honour the strict contract. The GIL means any other thread holding it
delays your callback, and the garbage collector can run at an arbitrary moment.
PortAudio bindings such as `sounddevice` invoke your Python callback from the RT
thread, which means the GIL is acquired there — a hard violation.

Three honest consequences:

1. **Use a larger block size than a C program would.** 20 ms (320 samples at
   16 kHz) rather than 1–5 ms. This turns "must finish in 1.33 ms" into "must
   finish in 20 ms", which Python can usually manage.
2. **The queue discipline still matters, and more, not less.** Because you cannot
   guarantee the callback's timing, the structure absorbing the jitter must be
   correct and bounded.
3. **For hard-real-time work, the DSP does not belong in Python.** It belongs in
   the C library (PortAudio's own resampler, WebRTC's APM, a Rust extension). Python
   orchestrates; it does not meet microsecond deadlines.

This is a genuine limitation and worth being explicit about: a production voice
agent written in Python is viable precisely because the tight loop lives inside
WebRTC and the model runtimes, and Python only sees 20 ms frames.

### 2.3 Ring buffers and the overflow policy

The standard structure is a fixed-size circular buffer with one producer and one
consumer. Capacity rounded to a power of two makes index wrapping a bitwise AND
rather than a modulo — a real saving when it runs 50 times a second per session,
and more importantly a branch-free operation with no division.

The interesting design question is not the data structure, it is the **policy when
it fills**. Three options, and only one is right for live audio:

| Policy | Latency behaviour | Data loss | Correct for |
|---|---|---|---|
| Block the producer | Unbounded (and blocks the RT thread) | None | Never, in a callback |
| Grow the buffer | Unbounded, silently | None | File processing, never live |
| Drop the oldest | Bounded by capacity | Oldest samples | **Live capture** |
| Drop the newest | Bounded | Newest samples | Rarely; loses the freshest speech |

**Drop-oldest is correct for live audio, and the reason is that stale audio has
negative value.** If your consumer stalled for 300 ms, the 300 ms of speech now
sitting at the head of the queue is speech the user finished saying long ago.
Processing it puts you 300 ms behind and keeps you there for the rest of the call.
Discarding it costs you those words once; keeping it costs you latency forever.

The corollary is that the unbounded queue — the default in most languages, and
`asyncio.Queue()` with no `maxsize` — is the worst choice, because it converts a
transient stall into permanent latency growth **with no error and no log line**.
The system appears healthy and feels broken. Always bound your audio queues, and
always count the drops.

For the *playout* direction the policy differs: on underrun you must produce a
buffer anyway, so you zero-fill and count it. Silence is a small glitch; missing
the deadline is a dropout. And a separate counter matters here, because zero-filled
samples must not be counted as audio the user heard — that distinction is what
barge-in transcript truncation depends on
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)).

### 2.4 Glitch taxonomy: diagnosing by ear

Audio failures are unusually diagnosable, because each mechanism has a signature.

| Symptom | Mechanism | Where to look |
|---|---|---|
| Regular click, exactly periodic | Buffer boundary discontinuity: frames assembled with a gap or overlap | Framing arithmetic; a frame size that is not a divisor of the block size |
| Irregular clicks under load | Callback overrun (RT thread missed its deadline) | Work inside the callback; block size too small |
| Short gaps of silence | Underrun on playout: buffer empty at callback time | Producer too slow; playout buffer too shallow |
| Audio arrives in bursts after a pause | TCP retransmission stall, or unbounded queue draining | Transport ([`../06-realtime-systems/01-transports.md`](../06-realtime-systems/01-transports.md)) |
| Speech slowly becomes delayed over minutes | Clock drift, or a growing queue | §2.5; queue depth metrics |
| Robotic, metallic timbre | Sample-rate mismatch (playing 16 k as 8 k or vice versa) | Format plumbing; wrong `samplerate` on the stream |
| Chipmunk or slow-motion voice | Wrong rate by an integer factor | Same |
| Buzzy, tonal distortion at low levels | Undithered quantisation | [`01-sound-and-sampling.md`](01-sound-and-sampling.md) §3.3 |
| High-frequency content mirrored down | Resampling without an anti-alias filter | §2.6 |

Committing this table to memory is worth more than any debugging tool, because it
turns "the audio sounds bad" into a specific hypothesis in seconds.

### 2.5 Clock drift

Two devices at nominally the same rate differ by their oscillators' tolerance,
expressed in parts per million. Consumer crystals are typically 20–100 ppm. The
accumulated offset after time $T$ is

$$\Delta t = \text{ppm} \times 10^{-6} \times T$$

Computed exactly `[MEASURED]`:

| Tolerance | Over 1 hour | Over 8 hours |
|---|---|---|
| 10 ppm | 36.0 ms = 1 728 samples @48 k = 1.8 frames of 20 ms | 288 ms = 13 824 samples = 14.4 frames |
| 50 ppm | 180.0 ms = 8 640 samples = 9.0 frames | 1 440 ms = 69 120 samples = 72.0 frames |
| 100 ppm | 360.0 ms = 17 280 samples = 18.0 frames | 2 880 ms = 138 240 samples = 144.0 frames |

Read the practical implication off the table. For a **3-minute phone call** at
50 ppm the drift is 9 ms — under half a frame, entirely absorbed by any sane
buffer. For an **8-hour always-on desktop assistant** it is 1.44 seconds, which is
72 whole frames that must be created or destroyed. Drift is therefore a
non-problem for call-centre agents and a real one for always-on devices and
meeting recorders.

Four mitigations, in increasing order of quality:

1. **Ignore it.** Correct for short sessions. Say so explicitly in the design.
2. **Drop or duplicate a frame** when the buffer crosses a threshold. Simple,
   causes a small audible discontinuity roughly once per 20 ms of accumulated
   drift.
3. **Adaptive resampling.** Continuously resample by a ratio slightly off 1.0,
   driven by a control loop on buffer depth. Inaudible, and what WebRTC's NetEQ
   effectively does. See [`../06-realtime-systems/02-webrtc-internals.md`](../06-realtime-systems/02-webrtc-internals.md).
4. **Shared clock.** Drive capture and playback from the same device or a common
   word clock. Removes the problem instead of managing it. Not available over a
   network.

### 2.6 Resampling: measured, not asserted

Rate conversion is where an anti-alias filter earns its cost. Downsampling
48 kHz → 16 kHz drops the Nyquist limit from 24 kHz to 8 kHz, so everything above
8 kHz must be removed *before* decimation, or it folds back into the audible band.

Measured on a 2-second 48 kHz signal containing a 1 kHz tone plus a 10 kHz tone,
resampled to 16 kHz. A correct resampler removes the 10 kHz tone; an incorrect one
aliases it to $|10000 - 16000| = 6000$ Hz. Levels are relative to the surviving
1 kHz peak; throughput is a multiple of real time `[MEASURED]`:

| Method | 1 kHz | Alias at 6 kHz | Time (2 s audio) | × real time |
|---|---|---|---|---|
| `x[::3]` (naive) | 0.0 dB | **0.0 dB** | 0.00 ms | 2 181 017× |
| `np.interp` (linear) | 0.0 dB | **0.0 dB** | 0.61 ms | 3 292× |
| `scipy.signal.resample_poly` | 0.0 dB | $-57.3$ dB | 0.64 ms | 3 127× |
| `soxr` quality `QQ` | 0.0 dB | **0.0 dB** | 0.15 ms | 13 746× |
| `soxr` quality `LQ` | 0.0 dB | $-111.1$ dB | 0.16 ms | 12 490× |
| `soxr` quality `MQ` | 0.0 dB | $-119.4$ dB | 0.17 ms | 12 024× |
| `soxr` quality `HQ` | 0.0 dB | $-137.3$ dB | 0.17 ms | 11 823× |
| `soxr` quality `VHQ` | 0.0 dB | $-153.9$ dB | 0.51 ms | 3 903× |

Four conclusions, all of which contradict something an engineer might reasonably
have assumed:

- **Naive decimation and linear interpolation do not attenuate the alias at all.**
  Not "a bit worse" — the 10 kHz tone arrives at 6 kHz at full amplitude, sitting
  squarely in the speech band. `np.interp` costs 4× more than `x[::3]` and buys
  literally nothing in alias rejection. If you have ever "resampled" with array
  striding or `np.interp`, you were injecting a phantom tone into your features.
- **`soxr QQ` is also 0.0 dB.** The lowest quality setting of a good library is
  *not* a slightly worse filter; it is effectively no filter. Quality settings are
  not a smooth dial, and defaults matter.
- **`LQ` already gives 111 dB of rejection at essentially `QQ`'s cost.** The step
  from unusable to excellent costs 0.01 ms per 2 seconds of audio. There is no
  scenario in a voice agent where you should choose less than `HQ`.
- **`VHQ` costs 3× the time of `HQ` for 17 dB you cannot hear.** 137 dB is already
  30 dB below a 16-bit noise floor. Stop at `HQ`.

Throughput deserves a sanity note: 11 823× real time means resampling costs about
0.008% of a core per stream. At 1000 concurrent sessions that is 0.08 of a core.
Resampling is free; aliasing is not. Choose on quality.

A subtlety on **group delay**: measured with an impulse, `soxr` at `LQ`, `HQ` and
`VHQ` all placed the output peak at exactly the input time (delay $+0.000$ ms)
`[MEASURED]`, because the library compensates for its own filter delay. Do not
generalise this. A raw FIR anti-alias filter of length $L$ introduces
$(L-1)/2$ samples of delay that you must either compensate or account for in the
latency budget; libraries that hide it are doing you a favour you should verify
rather than assume.

### 2.7 The buffering ladder

Every stage from mouth to model holds audio. Accounting, with the canonical 20 ms
frame at 16 kHz and typical settings:

| Stage | Holds | Why it exists | Typical |
|---|---|---|---|
| Device capture block | 1 block | The OS hands you whole blocks | 10–20 ms |
| Client processing (AEC/AGC/NS) | 1–2 frames | Filters need context | 10–20 ms |
| Encoder framing (Opus) | 1 frame | Codec frame size | 20 ms |
| Network | in flight | Physics | 5–50 ms one way |
| Jitter buffer | 2–10 frames | Absorbs arrival variance | 40–200 ms |
| Server framing / resample | 1 frame | Rate conversion at the edge | 20 ms |
| VAD lookahead | 1–2 frames | Some VADs need a fixed window | 0–64 ms |
| Model input window | model-specific | Whisper wants 30 s; streaming models want 100–500 ms | 100 ms–30 s |

Two observations that change designs.

**The jitter buffer is the largest controllable term.** It is also the one most
often left at a library default. Halving it from 200 ms to 100 ms is worth more
than any model optimisation you are likely to attempt, and costs you robustness to
network variance — a tradeoff you should make deliberately and measure. Adaptive
jitter buffers exist precisely so this can be tuned automatically.

**Frame-size mismatches silently add a frame each.** If your device gives 10 ms
blocks, your VAD wants 32 ms windows, and your codec wants 20 ms frames, each
boundary holds a partial frame waiting for completion. Three mismatched stages cost
you roughly three extra frames of latency for no functional reason. This is why the
curriculum fixes one canonical frame size (20 ms) and converts only at the edges:
not aesthetics, but 40–60 ms of budget.

---

## 3. From scratch

A correct bounded ring buffer with the drop-oldest policy and explicit accounting,
plus a demonstration of why the unbounded alternative fails. Standalone, numpy only.

```python
"""Bounded SPSC ring buffer for live audio, with explicit loss accounting."""
import numpy as np

class RingBuffer:
    """Fixed-capacity int16 ring buffer. Capacity rounds up to a power of two so
    index wrapping is a mask, not a modulo (no division, no branch)."""

    __slots__ = ("_buf", "_mask", "_w", "_r", "overruns", "underruns")

    def __init__(self, capacity_samples: int):
        cap = 1 << max(1, capacity_samples - 1).bit_length()
        self._buf = np.zeros(cap, dtype=np.int16)
        self._mask = cap - 1
        self._w = self._r = 0          # monotonic counters, never wrapped
        self.overruns = self.underruns = 0

    @property
    def capacity(self): return self._buf.size
    def __len__(self):  return self._w - self._r      # readable samples

    def write(self, x: np.ndarray) -> int:
        """Drop-oldest on overflow: stale audio has negative value, so advancing
        the read pointer keeps end-to-end delay bounded by capacity."""
        n = x.size
        if n > self.capacity:                  # a write larger than the buffer
            x = x[-self.capacity:]; n = x.size # keep the freshest tail
        free = self.capacity - len(self)
        if n > free:
            drop = n - free
            self._r += drop                    # discard the oldest
            self.overruns += drop
        start = self._w & self._mask
        first = min(n, self.capacity - start)  # may wrap: two contiguous copies
        self._buf[start:start + first] = x[:first]
        if first < n:
            self._buf[:n - first] = x[first:]
        self._w += n
        return n

    def read(self, n: int) -> np.ndarray:
        """Always returns exactly n samples. Zero-fills a shortfall and counts it:
        the playout path must never miss its deadline, so silence beats blocking."""
        avail = len(self)
        take = min(n, avail)
        out = np.zeros(n, dtype=np.int16)
        if take:
            start = self._r & self._mask
            first = min(take, self.capacity - start)
            out[:first] = self._buf[start:start + first]
            if first < take:
                out[first:take] = self._buf[:take - first]
            self._r += take
        if take < n:
            self.underruns += n - take
        return out

    def clear(self) -> int:
        """Discard everything pending; returns samples dropped. The barge-in
        primitive: on interruption, queued speech must not be played."""
        dropped = len(self); self._r = self._w; return dropped


if __name__ == "__main__":
    SR, FRAME = 16_000, 320                      # 20 ms frames
    # Capacity 400 ms. Producer runs at real time; consumer stalls for 30 frames.
    rb = RingBuffer(SR * 400 // 1000)
    unbounded = []                               # the tempting wrong answer
    frame = np.ones(FRAME, dtype=np.int16)

    for i in range(100):
        rb.write(frame); unbounded.append(frame)
        stalled = 20 <= i < 50                   # consumer blocked for 600 ms
        if not stalled:
            rb.read(FRAME)
            if unbounded: unbounded.pop(0)

    print(f"ring: capacity={rb.capacity} samples ({1000*rb.capacity//SR} ms)")
    print(f"ring: held={len(rb)} samples ({1000*len(rb)//SR} ms latency), "
          f"dropped={rb.overruns} samples ({1000*rb.overruns//SR} ms of speech)")
    held = sum(f.size for f in unbounded)
    print(f"unbounded: held={held} samples ({1000*held//SR} ms latency), dropped=0")
```

Measured output `[MEASURED]`:

```
ring: capacity=8192 samples (512 ms)
ring: held=7872 samples (492 ms latency), dropped=1728 samples (108 ms of speech)
unbounded: held=9600 samples (600 ms latency), dropped=0
```

That is the entire argument in two lines of output. Both structures survived the
stall. The ring buffer held its latency at 492 ms — one frame under its 512 ms
capacity, because a read follows the final write — and reported exactly how much
speech it sacrificed: 108 ms, one loud number you can alert on. The unbounded list
lost nothing and is now permanently 600 ms behind, with no counter, no log, and no
way for an operator to discover it except by noticing the agent feels slow.

Note also that the ring buffer's latency is *bounded by capacity*, not growing: a
stall twice as long would drop twice as much audio and add no further delay. That
bounded-delay property is the whole reason to accept the loss, and it is why
capacity is the knob that sets your worst-case buffering latency.

---

## 4. How production does it

**PortAudio and `sounddevice`.** PortAudio is the cross-platform C layer over
CoreAudio, WASAPI and ALSA; `sounddevice` is its Python binding. It offers both a
callback API (your function is invoked from the RT thread) and a blocking API
(`stream.read(n)`), which is simply a callback plus an internal ring buffer.
`blocksize=0` lets the host choose, which on macOS commonly yields 512 samples —
at 16 kHz that is 32 ms, not the 20 ms you wanted, and the mismatch costs you a
partial frame at every boundary. Set `blocksize` explicitly to your frame size.

**WebRTC's audio processing module.** `modules/audio_processing` in the WebRTC
source is the reference implementation of the client-side chain: AEC3, noise
suppression, AGC, and a high-pass filter, operating on fixed 10 ms frames. It is
the code path behind the browser's `getUserMedia` constraints, and the reason your
browser-based agent gets echo cancellation for free while your Python desktop
script does not. Covered in [`../03-turn-taking/05-echo-and-aec.md`](../03-turn-taking/05-echo-and-aec.md).

**Browser `AudioWorklet`.** The browser's answer to the real-time contract:
`AudioWorkletProcessor.process()` runs on a dedicated audio thread in 128-sample
quanta (2.67 ms at 48 kHz), with no DOM access and no ability to block. The
architectural pattern is identical to the native one — accumulate 128-sample
quanta into your canonical frame, post to the main thread via a `SharedArrayBuffer`
ring or `postMessage`, never do work in `process()`. Its predecessor,
`ScriptProcessorNode`, ran on the main thread and is deprecated precisely because
that violated the contract.

**Resamplers in the wild.** `libsoxr` (measured in §2.6) and `libsamplerate` are
the standard C choices; WebRTC ships its own fixed-ratio resamplers for the rates it
cares about; `av`/FFmpeg exposes `swresample`. On Apple platforms, CoreAudio will
resample transparently if you open a stream at a rate the hardware does not support
— convenient, and it means you may be paying for a resample you never wrote. For
measurement work, open at the hardware rate and resample explicitly so the stage is
visible in your budget.

**Frame sizes in real stacks.** Opus supports 2.5/5/10/20/40/60 ms and 20 ms is the
near-universal default for speech. WebRTC's APM works in 10 ms frames. Silero VAD
requires exactly 512 samples at 16 kHz (32 ms). Whisper wants 30 s. Every one of
these is a boundary where a partial frame waits, which is precisely the argument in
§2.7 for a single canonical internal frame size.

---

## 5. At scale

**Per-session CPU is dominated by the things you thought were free.** Per active
stream: Opus decode, one or two resamples, VAD on every 20 ms frame, and frame
reassembly. Individually microseconds; multiplied by 1000 sessions and 50
frames/second, that is 50 000 invocations per second of each stage. The measured
resampler figures in §2.6 put rate conversion at roughly 0.08 of a core for 1000
streams — genuinely negligible. The costs that are *not* negligible are the ones
with per-call Python overhead: a pure-Python VAD, a `np.frombuffer` →`astype`
→arithmetic chain allocating three temporaries per frame, or a logging call per
frame. Profile per-frame work at 50 Hz × N sessions, not per session.

**One blocking call poisons every session on the worker.** In an asyncio agent
hosting many sessions in one process, a synchronous model call or a blocking file
read stalls the event loop, and every other session's frames queue behind it. This
is the single most common cause of "latency is fine in testing, terrible in
production" — the symptom scales with concurrency because the *cause* does. Offload
every blocking call to a thread or process pool, and monitor event-loop lag
directly (schedule a no-op every 100 ms and measure how late it runs); it is the
highest-signal metric a Python voice worker can emit.

**Bound every queue and export its depth.** Queue depth is stored latency, so it is
a first-class SLI, not a debug counter. The two metrics that matter per session are
maximum queue depth and cumulative dropped samples. A rise in the first predicts a
latency regression before users notice; a rise in the second says you are already
losing speech. Both are cheap to compute and neither is exported by default in any
framework, so you must add them
([`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md)).

**Memory arithmetic.** A 400 ms int16 ring buffer at 16 kHz is 12.8 kB; a 2-second
playout buffer is 64 kB. Even with a dozen buffers per session, audio buffering is
well under 1 MB per session — trivial next to model weights. Audio memory is never
your scaling limit; audio *deadlines* are.

**Where the tight loop must not be Python.** The pattern that scales is: C/Rust for
the per-sample work (codec, APM, resample), Python for per-frame orchestration at
50 Hz, and a separate process for model inference. Any design that puts per-sample
arithmetic in Python has a concurrency ceiling set by the interpreter rather than
by the hardware.

---

## 6. Exercises

**E1.3.1** Open an input stream with `blocksize` set to 64, 320 and 2048 samples at
16 kHz. For each, compute the callback deadline in milliseconds, then measure the
actual distribution of inter-callback intervals over 30 seconds. At which block
size do you first observe missed deadlines, and what does the OS report?

**E1.3.2** Deliberately violate the contract: add a `time.sleep(0.05)` inside an
audio callback. Predict the audible result before running it, then record the output
and identify the artefact in the waveform. Now move the sleep to a consumer thread
behind a bounded ring buffer and explain why the artefact changes character.

**E1.3.3** Extend the §3 `RingBuffer` with a drop-*newest* policy as an option. Run
the same stall scenario under both policies and describe, in terms of what a
listener would perceive, why drop-oldest is preferred for capture. Construct one
scenario where drop-newest is the better choice.

**E1.3.4** Reproduce the §2.6 alias table for upsampling 8 kHz → 16 kHz instead of
downsampling. Which methods are now acceptable, and why does the answer differ from
the downsampling case? State the general rule about which direction needs the
filter.

**E1.3.5** Simulate 50 ppm clock drift by generating audio at 16 000.8 Hz and
consuming it at 16 000 Hz. Run for a simulated hour and plot buffer depth over
time. Then implement the drop/duplicate-a-frame mitigation and measure how often it
fires. Compare your measured rate against the §2.5 arithmetic.

**E1.3.6** Instrument a two-stage pipeline (capture → process) with event-loop lag
measurement as described in §5. Introduce a 200 ms synchronous call in the
processing stage and show that lag detects it. Then verify that moving the call to
`asyncio.to_thread` removes the lag while leaving throughput unchanged.

**E1.3.7** Build the §2.7 buffering ladder for a specific configuration of your
choosing, with a number in every row, and compute the total. Then find the 100 ms
you could remove with the least risk, and state what robustness you traded away.

---

## 7. Interview drill

> "Our voice agent is fine for the first minute of a call, then responses start
> arriving later and later. By minute ten it is two seconds behind. It never
> recovers, and there are no errors in the logs. Diagnose it."

The distinguishing features are monotonic growth, no recovery, and no errors. That
combination points at a queue, not at a model: model latency is roughly stationary,
and a slow model would be slow from the first turn. Something is accumulating.

Two candidate mechanisms, and the candidate should name both. **An unbounded queue
plus a consumer that is slightly slower than the producer.** If the pipeline
consumes 20 ms frames in 20.5 ms, it falls behind by 2.5% forever — 1.5 seconds per
minute — and an unbounded queue converts that deficit into latency silently, which
explains the absent errors exactly. **Clock drift** is the other, but §2.5 rules it
out on magnitude: 50 ppm gives 180 ms per *hour*, three orders of magnitude too
small to produce two seconds in ten minutes. Being able to reject a hypothesis with
arithmetic rather than experiment is the point of that table.

So the diagnosis is a slow consumer behind an unbounded buffer, and the immediate
question is what makes the consumer slow — most likely a synchronous call on the
event loop, whose cost scales with concurrency, which also explains why it did not
appear in single-session testing.

The fix has two parts, and offering only one is the weak answer. **Bound the queue**
so the failure becomes visible and latency stays capped: the agent will now drop
audio and report it instead of drifting, which is a strictly better failure mode.
**Then fix the consumer**, because dropping audio is a symptom. Offload the blocking
work, and verify with event-loop lag rather than end-to-end latency, since lag
isolates the cause.

Close on prevention: export maximum queue depth and cumulative dropped samples per
session as SLIs, and alert on the first derivative of queue depth. This class of bug
is undetectable without those two metrics and trivial to spot with them.

---

## Sources

- PortAudio documentation, callback and blocking APIs, `http://www.portaudio.com/docs.html`; `sounddevice` documentation for the Python binding and `blocksize` semantics.
- W3C Web Audio API specification, `AudioWorklet` and `AudioWorkletProcessor` — the 128-sample render quantum and the deprecation rationale for `ScriptProcessorNode`.
- `libsoxr` (the SoX resampler library) quality settings `QQ`/`LQ`/`MQ`/`HQ`/`VHQ`, exercised via the `soxr` Python package; alias-rejection and throughput figures in §2.6 measured locally.
- WebRTC source, `modules/audio_processing` — AEC3, NS, AGC operating on 10 ms frames.
- IETF RFC 6716, *Definition of the Opus Audio Codec* — supported frame sizes 2.5–60 ms.
- `snakers4/silero-vad` — the 512-sample-at-16 kHz window requirement referenced in §4; treated in detail in [`../03-turn-taking/01-vad.md`](../03-turn-taking/01-vad.md).
- All `[MEASURED]` values in §2.5, §2.6 and §3 were produced locally on Apple M5 / macOS 26.5.2 via `uv run --python 3.12` with numpy 2.5.2, soxr and scipy.
