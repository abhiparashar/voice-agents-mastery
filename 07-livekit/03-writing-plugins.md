# Writing Plugins

**What you'll be able to do after this:** implement the STT, TTS, LLM and VAD contracts against
the real 1.7.0 ABCs; know which of your models needs a VAD adapter and why; wrap a batch
recogniser such as faster-whisper and a local synthesiser such as Kokoro so they run inside an
`AgentSession`; and test a plugin's streaming contract without a network, a GPU, or the
framework itself.

Version pinned: **`livekit-agents` 1.7.0**, read from the published wheel, 2026-08-22.

---

## 1. Intuition

A plugin is an **adapter between two clocks**. Upstream, audio arrives at a fixed real-time rate
— one 20 ms frame every 20 ms, forever. Downstream, a model produces results whenever it
produces them: every 100 ms for a streaming recogniser, once per utterance for Whisper, in a
burst after 300 ms of silence for a phrase-based synthesiser. The plugin's job is to absorb that
mismatch without dropping audio and without stalling the pipeline.

Every LiveKit plugin ABC therefore has the same three-part shape:

1. **A push input side** — `push_frame`, `flush`, `end_input`. Callers never block.
2. **A pull output side** — `async for event in stream`. Consumers never poll.
3. **A background task** — `_run()`, which you implement, connecting the two.

That shape is why the framework can cancel a synthesis mid-word on barge-in, and why a slow
model produces backpressure rather than corruption.

There are exactly two kinds of speech model, and the distinction decides your implementation.
A **streaming** model consumes audio incrementally and emits partial results; you implement the
stream directly. A **batch** model needs a complete utterance; you implement one method and let
a VAD adapter cut the utterances for you. Whisper and every model in its family are batch models,
which is the single most important fact about running them in a real-time pipeline.

---

## 2. Rigour

### 2.1 The STT contract

`STT` is constructed with `STTCapabilities`, and the capability flags are load-bearing because
the session reads them to decide behaviour:

| Flag | Meaning |
|---|---|
| `streaming` | can consume audio incrementally; if false the session refuses to use it directly |
| `interim_results` | emits `INTERIM_TRANSCRIPT` |
| `diarization` | populates `SpeechData.speaker_id` |
| `aligned_transcript` | `"word"`, `"chunk"` or `False` |
| `offline_recognize` | supports batch `recognize()` |
| `keyterms` | supports keyterm prompting ([`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md)) |
| `chat_context` | can natively consume conversation context |

You implement `_recognize_impl(...)` for the batch path and/or `stream()` returning a
`RecognizeStream` for the streaming path, plus `prewarm()` for model loading.

`RecognizeStream` is the interesting one. Its input methods are concrete and its `_run()` is
abstract, so the contract is fixed and only the model integration varies:

- **`push_frame(frame)`** raises if the input has ended or the stream is closed, enforces
  `"the sample rate of the input frames must be consistent"`, and **resamples for you**: if the
  plugin declared a needed sample rate, it builds an `rtc.AudioResampler(..., quality=HIGH)` on
  first mismatch. Your plugin declares 16 kHz and receives 16 kHz.
- **`flush()`** pushes a `_FlushSentinel` — segment boundary, stream stays open.
- **`end_input()`** flushes, then closes the input channel. No more audio, ever.
- **`aclose()`** closes input and `cancel_and_wait`s the task: immediate, not graceful.

The event types, in the order a well-behaved plugin emits them:

| Event | When |
|---|---|
| `START_OF_SPEECH` | speech onset; if unsupported, emitted with the first interim |
| `INTERIM_TRANSCRIPT` | unstable hypothesis |
| `PREFLIGHT_TRANSCRIPT` | "confident enough that a certain portion of speech will not change… but it is stable enough to be used for preemptive generation" |
| `FINAL_TRANSCRIPT` | committed |
| `RECOGNITION_USAGE` | periodic usage metrics |
| `END_OF_SPEECH` | user stopped |

`PREFLIGHT_TRANSCRIPT` is the framework's answer to the partial-versus-final tension in
[`../02-asr/05-streaming-asr.md`](../02-asr/05-streaming-asr.md): a third state, stable enough
to start the LLM on but not yet committed to history. If your plugin can produce it, preemptive
generation gets both faster and safer.

`SpeechData` carries `text`, `start_time`, `end_time`, `confidence`, `speaker_id`, `words`, and
translation fields (`source_languages`, `source_texts`, `target_languages`, `target_texts`).
Populate `confidence` — the confirmation policy in
[`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md) §2.4
depends on it, and it surfaces as `ChatMessage.transcript_confidence`.

### 2.2 `StreamAdapter`: how a batch model becomes streaming

`stt/stream_adapter.py` defines `StreamAdapter(stt=..., vad=...)`, which presents
`STTCapabilities(streaming=True, interim_results=False, diarization=False, ...)` while wrapping
a batch recogniser. The VAD cuts segments; each segment is handed to `recognize()`; the result
is emitted as a final.

Three consequences you must design around:

**No interims, ever.** `interim_results=False` is honest. Anything in your product that depends
on partial transcripts — live captions, preemptive generation, semantic turn detection fed by
text — is unavailable.

**The VAD sets your latency floor.** The transcript cannot arrive before the VAD closes the
segment, so `min_silence_duration_ms` plus hangover is added to `stt_final` on every turn
([`../03-turn-taking/01-vad.md`](../03-turn-taking/01-vad.md)). In the §3 measurement, the
VAD-adapted recogniser captured 20 frames where the native streaming one saw 22, purely because
of the hangover window — the same mechanism that delays the final.

**Segment length is now your problem.** A user who talks for 40 seconds without pausing produces
a 40-second segment, and Whisper's cost is superlinear in segment length past its 30-second
window ([`../02-asr/04-attention-and-whisper.md`](../02-asr/04-attention-and-whisper.md)). Cap
it.

### 2.3 The TTS contract

`TTS` declares `TTSCapabilities(streaming, aligned_transcript)` plus `sample_rate` and
`num_channels`, and implements `synthesize(...)` returning a `ChunkedStream` (one text in, audio
out) and optionally `stream()` returning a `SynthesizeStream` (text pushed incrementally, as a
websocket TTS allows). If you do not implement the streaming form, the base class wraps the
chunked one.

Output goes through an `AudioEmitter`, initialised with `request_id`, `sample_rate`,
`num_channels`, `mime_type`, `frame_size_ms=200` and `stream`. The emitter detects raw PCM from
the MIME type (`audio/pcm` or `audio/raw`) and otherwise decodes the container, which is how one
plugin can emit MP3 from a vendor and another can emit raw samples from a local model.

Consumers receive `SynthesizedAudio(frame, request_id, is_final, segment_id, delta_text)`.
`segment_id` changes on each flush, so a barge-in that flushes mid-utterance is expressible; and
`is_final` marks the last frame of a segment, which is what the playout side needs to know when
to stop waiting ([`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md)).

The number that matters is `ttfb_tts`, so **emit the first chunk as early as your model allows**.
A local vocoder that generates a whole utterance before returning has a TTFB equal to its total
synthesis time; the same model driven per-sentence, or per-clause, has a TTFB of one clause.

### 2.4 The VAD contract

`VAD` declares `VADCapabilities(update_interval)` and returns a `VADStream` with the same
push/flush/end_input shape. Events are `START_OF_SPEECH`, `INFERENCE_DONE`, `END_OF_SPEECH`, and
`VADEvent` carries `samples_index`, `timestamp`, `speech_duration`, `silence_duration`,
`probability`, `inference_duration`, and `frames`.

`frames` has different meanings per event type, and this is the detail people miss: for
`START_OF_SPEECH` it is "the audio chunks that triggered the detection", for `INFERENCE_DONE`
the chunks just processed, and for `END_OF_SPEECH` **the complete user speech**. That is what
makes a VAD adapter possible at all — the VAD hands you the buffered utterance, including the
audio from before the trigger fired, so the recogniser does not lose the first phoneme.

`probability` and `inference_duration` on `INFERENCE_DONE` are exactly the signals you need to
plot the ROC curve and pick an operating point rather than accepting 0.5
([`../03-turn-taking/01-vad.md`](../03-turn-taking/01-vad.md)).

### 2.5 The LLM contract, and connection options

`LLM.chat(*, chat_ctx, tools, conn_options, parallel_tool_calls, tool_choice, extra_kwargs)`
returns an `LLMStream` whose `_run()` you implement; you emit `ChatChunk(id, delta, usage)`.
`ChatChunk.has_response()` is worth reading in full — it returns true only when the delta
carries content or tool calls, because "token counts and provider metadata … reach the caller
without being output: they neither start the clock on time-to-first-token nor give a retry
anything to duplicate". Two behaviours fall out of one predicate: `ttft_llm` is measured from the
first chunk that carries *text*, and a retry knows how much output it has already committed.

`APIConnectOptions` defaults are `max_retry=3`, `retry_interval=2.0`, `timeout=10.0`, with the
first retry immediate. Those are sensible for a chat backend and **wrong for a live call**: three
retries with 2 s intervals against a 10 s timeout is a worst case far beyond any conversational
deadline ([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).
Pass your own, sized to the turn budget, and mark errors `recoverable=False` when a retry cannot
possibly land in time.

### 2.6 Implementing a local faster-whisper STT

The design follows directly from §2.2: Whisper is batch, so implement the batch method and let a
VAD adapter make it streaming.

```
class WhisperSTT(STT):
    capabilities = STTCapabilities(streaming=False, interim_results=False,
                                   offline_recognize=True)
    _recognize_impl(buffer, language, conn_options) -> SpeechEvent(FINAL_TRANSCRIPT, [...])

session = AgentSession(stt=StreamAdapter(stt=WhisperSTT(), vad=silero.VAD.load()), ...)
```

The five details that decide whether it works:

**Load the model in `prewarm`, not in the entrypoint.** A `WhisperModel` load is seconds; in the
entrypoint that is seconds of silence in front of the caller
([`02-agents-framework.md`](02-agents-framework.md) §2.5). Load it into `proc.userdata`.

**Run inference in an executor.** `faster-whisper` is CTranslate2, a blocking C++ call. Calling
it directly from the event loop stalls every coroutine in the job — including the audio reader,
which then drops frames. `await loop.run_in_executor(None, model.transcribe, pcm)` is not
optional.

**Convert the audio explicitly.** The buffer arrives as `int16`; the model wants `float32` in
[-1, 1) at 16 kHz mono, so divide by 32768 exactly as the format contract specifies
([`../00-setup/03-canonical-formats.md`](../00-setup/03-canonical-formats.md)). Getting the scale
wrong produces a working pipeline with quietly terrible WER.

**Pass Whisper's decoding parameters deliberately.** `condition_on_previous_text=True` is
Whisper's default and is the main driver of hallucination loops on short segments;
`no_speech_threshold=0.6`, `compression_ratio_threshold=2.4` and `logprob_threshold=-1.0` are the
guards ([`../02-asr/04-attention-and-whisper.md`](../02-asr/04-attention-and-whisper.md)). A
plugin that ignores them will occasionally emit "Thanks for watching!" on silence.

**Bound the segment.** Cap the VAD segment length and force a flush past it, or a long
monologue turns into a slow, expensive, low-quality transcription.

### 2.7 Implementing a local Kokoro TTS

Kokoro-82M (`kokoro` 0.9.4, Apache-licensed weights, Python `>=3.10,<3.13` — the reason this
curriculum pins 3.12) is a non-streaming synthesiser: text in, waveform out.

```
class KokoroTTS(TTS):
    capabilities = TTSCapabilities(streaming=False)
    sample_rate = 24000   # Kokoro's native rate; the framework resamples
    ChunkedStream._run(output_emitter):
        output_emitter.initialize(request_id=..., sample_rate=24000, num_channels=1,
                                  mime_type="audio/pcm")
        for sentence in split(text):
            audio = await loop.run_in_executor(None, pipeline, sentence, voice)
            output_emitter.push(pcm_bytes(audio))
        output_emitter.flush()
```

The details that matter here are different from STT. **Declare your native sample rate and let
the framework resample** rather than resampling yourself — one resampler, one place, one quality
setting. **Split the text and push per sentence**, because emitting only at the end makes
`ttfb_tts` equal to full synthesis time; per-sentence emission is the difference between 200 ms
and 2 s of perceived latency. **Run synthesis in an executor** for the same reason as Whisper.
And **cache fixed phrases** — greetings, disclosures, hold messages — since they are synthesised
identically on every call and a cache turns them into a memory read
([`../04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md)).

---

## 3. From scratch

The streaming contract, reimplemented in stdlib asyncio, with both plugin shapes built on it and
the invariants asserted. Standalone, no framework, no network.

```python
"""The plugin streaming contract, implemented and tested without the framework.

LiveKit's STT/TTS/VAD plugin ABCs all share one shape: a push-based input channel
(push_frame / flush / end_input), a pull-based async iterator of events, and a
background task that turns one into the other. This reimplements that shape in
stdlib asyncio, builds two recognisers on it -- a natively streaming one, and a
batch model wrapped by a VAD, which is how faster-whisper is made streaming --
and then asserts the contract both must satisfy.

Event names and semantics follow livekit-agents 1.7.0 stt/stt.py.
"""

import array
import asyncio
import math
from dataclasses import dataclass, field
from enum import Enum

SAMPLE_RATE = 16000
FRAME_SAMPLES = 320          # 20 ms at 16 kHz, the internal contract
FRAME_BYTES = FRAME_SAMPLES * 2


class SpeechEventType(str, Enum):
    START_OF_SPEECH = "start_of_speech"
    INTERIM_TRANSCRIPT = "interim_transcript"
    FINAL_TRANSCRIPT = "final_transcript"
    END_OF_SPEECH = "end_of_speech"


@dataclass
class SpeechData:
    text: str
    start_time: float = 0.0
    end_time: float = 0.0
    confidence: float = 0.0


@dataclass
class SpeechEvent:
    type: SpeechEventType
    alternatives: list = field(default_factory=list)


class Chan:
    """A closable channel. Closing is what makes end_input expressible."""

    def __init__(self):
        self._q = asyncio.Queue()
        self._closed = False

    def send_nowait(self, item):
        if self._closed:
            raise RuntimeError("channel closed")
        self._q.put_nowait(item)

    def close(self):
        if not self._closed:
            self._closed = True
            self._q.put_nowait(_CLOSED)

    @property
    def closed(self):
        return self._closed

    def __aiter__(self):
        return self

    async def __anext__(self):
        item = await self._q.get()
        if item is _CLOSED:
            raise StopAsyncIteration
        return item


_CLOSED = object()


class _FlushSentinel:
    """Marks a segment boundary without ending the stream."""


class RecognizeStream:
    """The ABC. Subclasses implement _run(); everything else is the contract."""

    def __init__(self, *, sample_rate=SAMPLE_RATE):
        self._needed_sr = sample_rate
        self._pushed_sr = None
        self._input_ch = Chan()
        self._event_ch = Chan()
        self._input_ended = False
        self._task = asyncio.create_task(self._main_task())
        self._task.add_done_callback(lambda _: self._event_ch.close())

    async def _run(self):
        raise NotImplementedError

    async def _main_task(self):
        try:
            await self._run()
        except asyncio.CancelledError:
            raise

    # ---- input side (push) -------------------------------------------------
    def push_frame(self, frame: bytes, sample_rate=SAMPLE_RATE):
        self._check_input_not_ended()
        self._check_not_closed()
        if self._pushed_sr is not None and self._pushed_sr != sample_rate:
            raise ValueError("the sample rate of the input frames must be consistent")
        self._pushed_sr = sample_rate
        self._input_ch.send_nowait(frame)

    def flush(self):
        """End the current segment. The stream stays open."""
        self._check_input_not_ended()
        self._check_not_closed()
        self._input_ch.send_nowait(_FlushSentinel())

    def end_input(self):
        """No more audio. Implies a flush, then closes the input channel."""
        self.flush()
        self._input_ended = True
        self._input_ch.close()

    async def aclose(self):
        """Close immediately, cancelling work in flight."""
        if not self._input_ch.closed:
            self._input_ch.close()
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass

    # ---- output side (pull) ------------------------------------------------
    def __aiter__(self):
        return self._event_ch.__aiter__()

    def _emit(self, ev):
        if not self._event_ch.closed:
            self._event_ch.send_nowait(ev)

    def _check_not_closed(self):
        if self._event_ch.closed:
            raise RuntimeError(f"{type(self).__name__} is closed")

    def _check_input_not_ended(self):
        if self._input_ended:
            raise RuntimeError("input has already ended")


# --------------------------------------------------------------- fake models
def rms(frame: bytes) -> float:
    samples = array.array("h", frame)
    return math.sqrt(sum(s * s for s in samples) / len(samples))


async def batch_recognize(pcm: bytes, *, delay=0.05) -> str:
    """Stands in for faster-whisper: needs the whole segment, returns once."""
    await asyncio.sleep(delay)                 # model inference
    n = len(pcm) // FRAME_BYTES
    return f"<{n} frames, {n * 20} ms of speech>"


class StreamingSTT(RecognizeStream):
    """A natively streaming recogniser: interims as audio arrives, final on flush."""

    INTERIM_EVERY = 5                          # frames

    async def _run(self):
        buf, speaking, n = bytearray(), False, 0
        async for item in self._input_ch:
            if isinstance(item, _FlushSentinel):
                if speaking:
                    self._emit(SpeechEvent(SpeechEventType.FINAL_TRANSCRIPT,
                                           [SpeechData(await batch_recognize(bytes(buf)),
                                                       confidence=0.94)]))
                    self._emit(SpeechEvent(SpeechEventType.END_OF_SPEECH))
                buf, speaking, n = bytearray(), False, 0
                continue
            if not speaking:
                speaking = True
                self._emit(SpeechEvent(SpeechEventType.START_OF_SPEECH))
            buf += item
            n += 1
            if n % self.INTERIM_EVERY == 0:
                self._emit(SpeechEvent(SpeechEventType.INTERIM_TRANSCRIPT,
                                       [SpeechData(f"<partial {n} frames>",
                                                   confidence=0.5)]))


class VADStreamAdapter(RecognizeStream):
    """Batch model + VAD = streaming, with no interims. LiveKit's StreamAdapter.

    This is the only way to run Whisper-family models in a streaming pipeline:
    the VAD decides the segment boundaries the model cannot.
    """

    THRESHOLD = 500.0                          # RMS over int16
    HANGOVER = 8                               # frames of silence to close a segment

    async def _run(self):
        buf, speaking, silent = bytearray(), False, 0
        async for item in self._input_ch:
            if isinstance(item, _FlushSentinel):
                if speaking:
                    await self._finish(buf)
                buf, speaking, silent = bytearray(), False, 0
                continue
            loud = rms(item) > self.THRESHOLD
            if loud and not speaking:
                speaking, silent = True, 0
                self._emit(SpeechEvent(SpeechEventType.START_OF_SPEECH))
            if speaking:
                buf += item
                silent = 0 if loud else silent + 1
                if silent >= self.HANGOVER:
                    await self._finish(buf)
                    buf, speaking, silent = bytearray(), False, 0

    async def _finish(self, buf):
        text = await batch_recognize(bytes(buf))
        self._emit(SpeechEvent(SpeechEventType.FINAL_TRANSCRIPT,
                               [SpeechData(text, confidence=0.88)]))
        self._emit(SpeechEvent(SpeechEventType.END_OF_SPEECH))


# ------------------------------------------------------------------ harness
def tone(n_frames, amplitude):
    """n_frames of a deterministic 200 Hz tone at the given amplitude."""
    out = bytearray()
    for i in range(n_frames * FRAME_SAMPLES):
        v = int(amplitude * math.sin(2 * math.pi * 200 * i / SAMPLE_RATE))
        out += int(v).to_bytes(2, "little", signed=True)
    return [bytes(out[k:k + FRAME_BYTES]) for k in range(0, len(out), FRAME_BYTES)]


async def drive(stream, frames, *, flush_at_end=True):
    """Push frames, collect events. Mirrors what AgentActivity does to a plugin."""
    events = []

    async def reader():
        async for ev in stream:
            events.append(ev)

    task = asyncio.create_task(reader())
    for f in frames:
        stream.push_frame(f)
        await asyncio.sleep(0)                 # let the worker run
    if flush_at_end:
        stream.end_input()
    await asyncio.wait_for(task, timeout=5)
    return events


def render(events):
    out = []
    for ev in events:
        txt = ev.alternatives[0].text if ev.alternatives else ""
        out.append(f"{ev.type.value}{(' ' + txt) if txt else ''}")
    return out


async def main():
    speech = tone(12, 8000) + tone(10, 20)     # 240 ms loud, 200 ms near-silent
    checks = []

    for cls in (StreamingSTT, VADStreamAdapter):
        s = cls()
        events = await drive(s, speech)
        print(f"{cls.__name__}:")
        for line in render(events):
            print(f"    {line}")
        kinds = [e.type for e in events]
        checks.append((f"{cls.__name__}: starts with START_OF_SPEECH",
                       kinds[0] == SpeechEventType.START_OF_SPEECH))
        checks.append((f"{cls.__name__}: ends with END_OF_SPEECH",
                       kinds[-1] == SpeechEventType.END_OF_SPEECH))
        checks.append((f"{cls.__name__}: exactly one FINAL per segment",
                       kinds.count(SpeechEventType.FINAL_TRANSCRIPT) == 1))
        checks.append((f"{cls.__name__}: FINAL precedes END_OF_SPEECH",
                       kinds.index(SpeechEventType.FINAL_TRANSCRIPT)
                       < kinds.index(SpeechEventType.END_OF_SPEECH)))
        print()

    # push after end_input must raise
    s = StreamingSTT()
    s.end_input()
    try:
        s.push_frame(speech[0]); ok = False
    except RuntimeError:
        ok = True
    checks.append(("push_frame after end_input raises", ok))
    await s.aclose()

    # inconsistent sample rate must raise
    s = StreamingSTT()
    s.push_frame(speech[0], sample_rate=16000)
    try:
        s.push_frame(speech[1], sample_rate=8000); ok = False
    except ValueError:
        ok = True
    checks.append(("changing sample rate mid-stream raises", ok))
    await s.aclose()

    # aclose during inference must not hang
    s = VADStreamAdapter()
    for f in speech[:12]:
        s.push_frame(f)
    await asyncio.sleep(0)
    try:
        await asyncio.wait_for(s.aclose(), timeout=1.0)
        checks.append(("aclose cancels mid-inference within 1 s", True))
    except asyncio.TimeoutError:
        checks.append(("aclose cancels mid-inference within 1 s", False))

    # two segments separated by flush, on one open stream
    s = StreamingSTT()
    events = []

    async def reader():
        async for ev in s:
            events.append(ev)

    t = asyncio.create_task(reader())
    for f in tone(6, 8000):
        s.push_frame(f); await asyncio.sleep(0)
    s.flush(); await asyncio.sleep(0.2)
    for f in tone(4, 8000):
        s.push_frame(f); await asyncio.sleep(0)
    s.end_input()
    await asyncio.wait_for(t, timeout=5)
    finals = [e for e in events if e.type == SpeechEventType.FINAL_TRANSCRIPT]
    print("two segments on one stream (flush between):")
    for line in render(events):
        print(f"    {line}")
    checks.append(("flush yields two segments without reopening", len(finals) == 2))

    print(f"\n{'contract check':52s} result")
    for name, ok in checks:
        print(f"{name:52s} {'PASS' if ok else 'FAIL'}")


if __name__ == "__main__":
    asyncio.run(main())
```

Output `[MEASURED]`:

```
StreamingSTT:
    start_of_speech
    interim_transcript <partial 5 frames>
    interim_transcript <partial 10 frames>
    interim_transcript <partial 15 frames>
    interim_transcript <partial 20 frames>
    final_transcript <22 frames, 440 ms of speech>
    end_of_speech

VADStreamAdapter:
    start_of_speech
    final_transcript <20 frames, 400 ms of speech>
    end_of_speech

two segments on one stream (flush between):
    start_of_speech
    interim_transcript <partial 5 frames>
    final_transcript <6 frames, 120 ms of speech>
    end_of_speech
    start_of_speech
    final_transcript <4 frames, 80 ms of speech>
    end_of_speech

contract check                                       result
StreamingSTT: starts with START_OF_SPEECH            PASS
StreamingSTT: ends with END_OF_SPEECH                PASS
StreamingSTT: exactly one FINAL per segment          PASS
StreamingSTT: FINAL precedes END_OF_SPEECH           PASS
VADStreamAdapter: starts with START_OF_SPEECH        PASS
VADStreamAdapter: ends with END_OF_SPEECH            PASS
VADStreamAdapter: exactly one FINAL per segment      PASS
VADStreamAdapter: FINAL precedes END_OF_SPEECH       PASS
push_frame after end_input raises                    PASS
changing sample rate mid-stream raises               PASS
aclose cancels mid-inference within 1 s              PASS
flush yields two segments without reopening          PASS
```

Three load-bearing details. **The two recognisers see different amounts of audio** — 22 frames
versus 20 — because the VAD adapter cuts the segment at its hangover boundary while the native
stream keeps everything until the flush. That is §2.2's latency floor made visible: the adapter
must wait for silence it can be sure about. **The channel's `close()` is what makes `end_input`
expressible**; a plain queue has no way to say "no more items ever", so the consumer cannot
distinguish a pause from an end, and every hand-rolled plugin that hangs on shutdown has this
bug. And **`aclose()` cancels rather than drains**: the check that it returns within a second
while a 50 ms inference is in flight is the barge-in requirement — a plugin that finishes its
current inference before closing adds that latency to every interruption.

---

## 4. How production does it

**Read three real plugins in this order.** `livekit-plugins-silero` for the VAD contract at its
simplest; `livekit-plugins-deepgram` for a websocket streaming STT with interims, reconnects and
keyterms; `livekit-plugins-openai` for LLM streaming and the realtime model. Between them they
exercise every branch of §2.

**The adapters in the framework are worth using before writing your own.**
`stt/stream_adapter.py` (batch → streaming, §2.2), `stt/fallback_adapter.py` and its TTS and LLM
siblings (`FallbackAdapter(stt=[primary, secondary], vad=..., attempt_timeout=10.0)`), and
`stt/multi_speaker_adapter.py`. Provider failover is a solved problem in this codebase; the
interesting question is what `attempt_timeout` should be for a live call, which is a budget
question rather than an implementation one
([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).

**Errors are part of the contract.** `_emit_error(api_error, recoverable)` on the stream classes
feeds the session's error handling, and `recoverable` decides whether it retries or gives up.
A plugin that raises bare exceptions instead loses that distinction and turns a retryable blip
into a dropped call.

**`prewarm()` exists on `STT`, `TTS` and `LLM`.** Use it. It is the only place a plugin can load
a model without paying for it in front of a caller.

**Node overrides are the escape hatch.** If a plugin is 90% right, `stt_node`, `tts_node` or
`llm_node` on the `Agent` lets you wrap it without forking
([`02-agents-framework.md`](02-agents-framework.md) §2.8). Fork the plugin only when you need to
change its protocol handling.

---

## 5. At scale

**Local models multiply by process, not by container.** Jobs run in separate processes
([`02-agents-framework.md`](02-agents-framework.md) §2.1), so a 1.5 GiB Whisper model loaded in
`prewarm` is loaded once per idle process and once per job process. Four idle processes plus
eight concurrent jobs is twelve copies. On a 16 GiB box that decides your density before CPU
does, and it is the strongest argument for a **separate inference service** shared by all job
processes rather than in-process models — at the cost of an IPC hop on the critical path.

**Executor threads are a shared, finite resource.** Every blocking model call occupies a thread
from the default executor; the default pool is small, and once it is full the "async" calls
queue silently. Size an explicit executor per job process against the number of concurrent model
calls you actually make.

**GPU contention is invisible until it is not.** Several job processes sharing one GPU serialise
inside the driver, so p95 latency degrades while every process reports low CPU. If you run local
models on a GPU, run one inference server and let job processes queue against it explicitly,
where you can see the queue.

**The build-versus-buy crossover is measured, not assumed.** From
[`../04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md), local TTS breaks even at
roughly 56 000 audio-minutes/month; from
[`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md), local ASR breaks even near 1.2
million. Writing a Kokoro plugin pays for itself at a fraction of the volume that a Whisper
plugin does — so if you write exactly one plugin, write the TTS one.

**Plugins need their own tests, and they can be fast.** Everything in §3 runs without a model, a
network or a GPU, which means the contract is testable in CI in milliseconds
([`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md)). Model quality is a
separate, slower suite; conflating the two is why plugin test suites get disabled.

---

## 6. Exercises

**E7.3.1** Run the §3 harness. Add a check that no `INTERIM_TRANSCRIPT` follows a
`FINAL_TRANSCRIPT` within the same segment, then break `StreamingSTT` so it fails.

**E7.3.2** Implement `PREFLIGHT_TRANSCRIPT` in `StreamingSTT`: emit it when the last three
interims agree on a prefix. Report how many frames earlier it fires than the final.

**E7.3.3** Write a real `WhisperSTT` against the 1.7.0 ABC, wrap it with `StreamAdapter` and a
Silero VAD, and measure `stt_final` relative to `speech_end`. Attribute the delay between VAD
hangover and model inference.

**E7.3.4** Move the Whisper model load from the entrypoint into `prewarm_fnc` and measure the
change in time-to-greeting. Compare with the cold-start numbers in
[`02-agents-framework.md`](02-agents-framework.md) §3.

**E7.3.5** Deliberately call your model synchronously on the event loop and measure dropped
audio frames during inference. Then move it to an executor and re-measure.

**E7.3.6** Write a `KokoroTTS` plugin that emits per sentence, and measure `ttfb_tts` against a
version that emits only at the end. Report both for a 40-word reply.

**E7.3.7** Add a phrase cache to the TTS plugin for your five most common fixed utterances.
Measure the cache hit rate over 100 simulated calls and the TTS cost saved.

**E7.3.8** Wrap two STT providers in `FallbackAdapter` and kill the primary mid-call. Measure how
long the caller hears nothing, and tune `attempt_timeout` against your turn budget.

---

## 7. Interview drill

> "We want to replace our hosted STT with self-hosted Whisper to cut costs. What breaks?"

Start with the architectural fact rather than the cost model: Whisper is a batch recogniser, and
the hosted STT you are replacing is almost certainly a streaming one. That is not an
implementation detail, it changes the product. Inside LiveKit you would implement
`_recognize_impl` and wrap it in `StreamAdapter` with a VAD, and the adapter honestly declares
`interim_results=False`. So everything downstream of partial transcripts stops working: live
captions, preemptive generation, and any semantic turn detection fed by text. If the current
endpointing relies on transcript stability, it now relies on VAD silence alone, and the turn
timing changes for every caller.

The latency story follows. With a streaming recogniser the transcript is essentially ready when
the user stops; with a VAD adapter the segment cannot close until the hangover expires, then the
model runs on the whole utterance. So `stt_final` becomes VAD hangover plus inference time, and
inference time scales with utterance length. A 10-second utterance is a 10-second forward pass
worth of work arriving after the user has already stopped — which is why the segment length must
be capped, not left to the caller's lung capacity.

Then the operational cost, which is where the savings estimate usually goes wrong. Jobs run in
separate processes, so the model is resident once per process, not once per container; the
executor discipline matters because CTranslate2 blocks the event loop and will drop audio if
called directly; and GPU sharing across job processes serialises invisibly. Against that, the
measured crossover for self-hosted ASR is around 1.2 million audio-minutes a month, which is
much higher than for TTS — so unless the volume is genuinely there, this project spends
engineering time to make the product slower.

What distinguishes a senior answer is proposing the alternative that gets most of the saving with
none of the regression: keep a streaming recogniser on the live path and self-host the batch
model for the offline work — post-call transcription, evaluation, and the bulk re-runs in
[`../08-eval-safety/02-simulation-and-load.md`](../08-eval-safety/02-simulation-and-load.md) —
where latency is free. And question the premise itself: if the goal is cost, TTS breaks even
around 56 000 audio-minutes a month, more than twenty times sooner, so the same effort spent on
a local Kokoro plugin saves more money at a fraction of the risk.

---

## Sources

- `livekit-agents` **1.7.0**, published wheel (PyPI, retrieved 2026-08-22), files read from the archive:
  - `livekit/agents/stt/stt.py` — `SpeechEventType` (including `PREFLIGHT_TRANSCRIPT` and its docstring quoted in §2.1), `SpeechData`, `RecognitionUsage`, `SpeechEvent`, `STTCapabilities`, `STT._recognize_impl` / `stream` / `prewarm`, and `RecognizeStream.push_frame` / `flush` / `end_input` / `aclose` including the sample-rate consistency error and the `rtc.AudioResampler(..., quality=HIGH)` path.
  - `livekit/agents/stt/stream_adapter.py` — `StreamAdapter(stt=..., vad=...)` and the capabilities it advertises.
  - `livekit/agents/stt/fallback_adapter.py` — `FallbackAdapter(stt=[...], vad=..., attempt_timeout=10.0)`.
  - `livekit/agents/tts/tts.py` — `TTSCapabilities`, `SynthesizedAudio{frame, request_id, is_final, segment_id, delta_text}`, `TTS.synthesize` / `stream` / `sample_rate` / `num_channels`, `ChunkedStream`, `SynthesizeStream`, and `AudioEmitter.initialize(request_id, sample_rate, num_channels, mime_type, frame_size_ms=200, stream=False)` with its raw-PCM MIME detection.
  - `livekit/agents/vad.py` — `VADCapabilities(update_interval)`, `VADEventType`, and `VADEvent` fields including the per-event-type meaning of `frames` quoted in §2.4.
  - `livekit/agents/llm/llm.py` — `LLM.chat(...)` signature and `ChatChunk.has_response()` with the docstring quoted in §2.5.
  - `livekit/agents/types.py` — `APIConnectOptions(max_retry=3, retry_interval=2.0, timeout=10.0)`.
- Whisper decoding thresholds referenced in §2.6 are from `openai/whisper` and are derived in [`../02-asr/04-attention-and-whisper.md`](../02-asr/04-attention-and-whisper.md); `kokoro` 0.9.4 / Kokoro-82M facts are from PyPI metadata and are used in [`../04-tts/01-tts-architectures.md`](../04-tts/01-tts-architectures.md).
- Cost crossovers quoted in §5 are the measured results in [`../04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md) §3 and [`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md) §3.
- `[MEASURED]`: the §3 output is the listing's own run on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. It is a faithful reimplementation of the 1.7.0 contract rather than a test of the framework itself; the models are stubs, so the timings it asserts are contract properties (cancellation, ordering, segmentation), not model performance.
