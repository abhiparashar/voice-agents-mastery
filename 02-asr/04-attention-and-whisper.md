# Attention, and What Whisper Actually Is

**What you'll be able to do after this:** explain the attention encoder-decoder for
speech and why it does not stream; describe Whisper's design decision by decision,
including every decoding threshold and the specific failure each one exists to
suppress; predict its failure modes before you observe them; and choose between
Whisper, faster-whisper, whisper.cpp, Distil-Whisper, WhisperX and MLX for a given
deployment with a stated reason.

Everything in §2 was read from `openai/whisper` source (main branch, retrieved
2026-08-22) rather than from documentation.

---

## 1. Intuition

CTC and RNN-T both build a monotonic alignment into the architecture: audio moves
forward, output moves forward, never backwards. The attention encoder-decoder (AED)
throws that constraint away. Its decoder, at every output step, looks at **all**
encoder frames and decides for itself which ones matter.

That is simultaneously the source of its accuracy and of every problem it has.

Discarding the monotonicity constraint means the model can learn arbitrary
input-output relationships — including translation, where output order genuinely
differs from input order, and including punctuation and casing, which depend on words
that have not been spoken yet. It is why Whisper can transcribe, translate,
punctuate, detect language and mark timestamps with one set of weights. No monotonic
architecture can do that with one model.

It also means nothing prevents the model from producing output unrelated to the
audio. A monotonic model must consume frames to emit symbols; an AED decoder is a
language model with an audio-shaped hint. When the hint is weak — silence, music,
noise — it does what language models do: it generates fluent, plausible, entirely
invented text. Whisper's notorious hallucinations are not a training defect, they are
a direct consequence of removing the alignment constraint.

And it means the model does not stream. Cross-attention over the whole encoder output
is in the architecture, so the canonical form must have all the audio before it
produces the first token. Everything people do to "stream Whisper" is a workaround
outside the model ([`05-streaming-asr.md`](05-streaming-asr.md)).

The second thing to internalise: **Whisper's design is dominated by one decision —
scale over architecture.** It is a conventional Transformer AED trained on a very
large weakly-supervised corpus, and its robustness comes from data diversity rather
than modelling cleverness. The practical consequence is that Whisper's *architecture*
is unremarkable and its *decoding loop* is where all the interesting engineering
lives. That loop is a stack of heuristics, each one a scar from a specific failure.
§2.4 reads them as such.

---

## 2. Rigour

### 2.1 From LAS to Transformer AED

Listen, Attend and Spell (Chan et al., 2015) established the shape: a pyramidal
encoder that subsamples the acoustic sequence, and an autoregressive decoder that
attends over encoder states while emitting characters. Attention weights $\alpha_{u,t}$
over encoder frames $t$ for output step $u$ form a soft alignment, and for speech that
alignment should be roughly diagonal and monotonic.

Should be. Nothing enforces it, which yields the classic AED failure modes:

| Failure | Attention pathology | Symptom |
|---|---|---|
| Deletion | Attention skips a region | Words missing from the middle |
| Repetition | Attention re-attends to a region already consumed | A phrase loops |
| Truncation | Decoder emits end-of-sequence early | Transcript stops mid-utterance |
| Hallucination | Attention diffuse; decoder falls back on its LM prior | Fluent text unrelated to audio |

Replacing recurrence with self-attention (Transformer AED) improved everything except
this: the alignment is still unconstrained, so the failures persist. Whisper inherits
all four.

### 2.2 Whisper's input geometry

Verified from `whisper/audio.py`:

| Constant | Value | Consequence |
|---|---|---|
| `SAMPLE_RATE` | 16000 | 8 kHz telephony must be upsampled; the top half of the spectrum is then empty |
| `N_FFT` | 400 | 25 ms analysis window |
| `HOP_LENGTH` | 160 | 10 ms hop → `FRAMES_PER_SECOND = 100` |
| `CHUNK_LENGTH` | 30 | **every input is a 30-second window** |
| `N_SAMPLES` | 480000 | 30 s × 16 kHz, pad or trim to exactly this |
| `N_FRAMES` | 3000 | mel frames per window |
| `N_SAMPLES_PER_TOKEN` | 320 | the front-end conv has stride 2 |
| `TOKENS_PER_SECOND` | 50 | so one audio token spans 20 ms |

The 30-second window is the single most consequential design choice. It is *not* a
maximum, it is a fixed size: a 1.2-second utterance is zero-padded to 30 seconds and
costs the encoder exactly as much as a 30-second one. That is a 25× waste on short
turns and the dominant inefficiency in naive Whisper serving
([`08-serving-asr.md`](08-serving-asr.md)).

It also creates a subtle quality issue. The model saw padded audio during training,
so it tolerates it — but the padding is silence, and silence is where hallucination
lives (§2.5). Feeding Whisper a 1-second clip padded with 29 seconds of zeros is
asking for invented text.

The mel front end, its `stft[..., :-1]` truncation and its per-chunk normalisation
are derived and reproduced in
[`../01-foundations/02-time-frequency.md`](../01-foundations/02-time-frequency.md) §3.

### 2.3 Model sizes and the token vocabulary

From the repository README:

| Size | Parameters | English-only | Multilingual | Approx. VRAM | Relative speed |
|---|---|---|---|---|---|
| tiny | 39 M | `tiny.en` | `tiny` | ~1 GB | ~10× |
| base | 74 M | `base.en` | `base` | ~1 GB | ~7× |
| small | 244 M | `small.en` | `small` | ~2 GB | ~4× |
| medium | 769 M | `medium.en` | `medium` | ~5 GB | ~2× |
| large | 1550 M | — | `large` | ~10 GB | 1× |
| turbo | 809 M | — | `turbo` | ~6 GB | ~8× |

`turbo` is the interesting entry: 809 M parameters at roughly 8× the speed of
`large`, achieved by cutting decoder depth. It is transcription-only — the reduced
decoder gives up translation quality — which is a clean illustration that in an AED
the decoder carries the linguistic work while the encoder carries the acoustic work.

The `ModelDimensions` dataclass in `whisper/model.py` makes the two-tower structure
explicit: `n_mels`, `n_audio_ctx`, `n_audio_state`, `n_audio_head`, `n_audio_layer`
for the encoder, and `n_vocab`, `n_text_ctx`, `n_text_state`, `n_text_head`,
`n_text_layer` for the decoder.

**The task is specified by tokens, not by flags.** From `whisper/tokenizer.py`, the
special tokens begin `<|endoftext|>`, `<|startoftranscript|>`, then one token per
language, then task and control tokens (`<|translate|>`, `<|transcribe|>`,
`<|startoflm|>`, `<|startofprev|>`, `<|nospeech|>`, `<|notimestamps|>`), followed by
**timestamp tokens generated as `<|{i * 0.02:.2f}|>` for `i` in `range(1501)`** — that
is 1501 tokens covering 0.00 to 30.00 seconds at **20 ms granularity**.

Three practical consequences fall directly out of that:

- **Timestamp resolution is hard-capped at 20 ms**, matching `TOKENS_PER_SECOND = 50`.
  Any word-level timing finer than that is an interpolation, not a measurement — which
  is why WhisperX exists (§4).
- **Language detection is a token prediction**, so it is a probability distribution
  and can be wrong. Pinning the language when you know it removes a whole class of
  error, particularly on short or accented audio.
- **`<|notimestamps|>` changes the output distribution**, so transcripts with and
  without timestamps are not merely formatted differently — they are different
  decodes.

### 2.4 The decoding loop: every heuristic as a scar

These are the verified defaults from `whisper/transcribe.py`. Read each as "the
failure this prevents".

| Parameter | Default | The failure it suppresses |
|---|---|---|
| `temperature` | `(0.0, 0.2, 0.4, 0.6, 0.8, 1.0)` | Greedy decoding gets stuck in a repetition loop; resampling at higher temperature escapes it |
| `compression_ratio_threshold` | `2.4` | Repetition loops. If the gzip compression ratio of the text exceeds 2.4, it is too repetitive to be real speech → retry hotter |
| `logprob_threshold` | `-1.0` | Low-confidence garbage. Mean token log-probability below −1.0 → retry, or mark the segment silent |
| `no_speech_threshold` | `0.6` | Transcribing silence. If `<|nospeech|>` probability exceeds 0.6 and confidence is low, emit nothing |
| `condition_on_previous_text` | `True` | Loss of context across 30 s windows — at the cost described below |
| `hallucination_silence_threshold` | `None` | Opt-in skipping of silent regions suspected of producing hallucinations |

The **temperature fallback** loop is the load-bearing mechanism, and it is worth
being explicit that it is a *sampling* strategy dressed as error handling: decode at
temperature 0; if the compression-ratio or log-probability check fails, decode again
at 0.2, and so on up to 1.0. A confident, wrong, repetitive decode is thereby
replaced by a less confident, more varied one. It also means Whisper's latency is
**non-deterministic and multi-modal**: a segment that triggers three fallbacks costs
four decodes. In a latency budget
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md))
this shows up as a heavy tail that no amount of hardware fixes.

The compression-ratio test is a genuinely elegant hack, and it is easy to see why the
threshold sits at 2.4. Measured with `zlib` `[MEASURED]`:

| Text | Length | Compression ratio | Flagged at 2.4? |
|---|---|---|---|
| `I would like to reschedule my appointment for next Tuesday afternoon please.` | 76 | 1.01 | no |
| `Thank you. Thank you. Thank you. Thank you.` | 43 | 1.95 | no |
| `Thank you.` × 20 | 219 | 9.95 | **yes** |
| `Thank you.` × 50 | 549 | 21.96 | **yes** |
| `Subscribe to my channel!` × 30 | 749 | 18.73 | **yes** |
| `yeah` × 100 | 499 | 27.72 | **yes** |

Normal speech sits near 1.0; a genuine four-fold repetition (which a real speaker
might say) reaches 1.95 and is correctly *not* flagged; a pathological loop is
10–28 and is caught with enormous margin. The threshold is well placed, and the
detector costs one `zlib.compress` call.

**`condition_on_previous_text=True` is the setting to think hardest about.** Feeding
the previous window's transcript as decoder context improves coherence, punctuation
and speaker-consistent style. It also creates a feedback path: if window $n$
hallucinated "Subscribe to my channel", window $n+1$ receives that as context and is
now *more* likely to continue the theme. Errors compound across the recording, which
is why a long file can degrade progressively while each 30-second window looks
individually plausible. Turning it off costs coherence and buys error isolation, and
for unattended batch transcription that is usually the right trade.

### 2.5 Failure modes, mechanistically

**Hallucination on silence and music.** With no speech to attend to, the decoder falls
back on its language-model prior and generates fluent text. Because the training
corpus was scraped audio with weak labels, it contains large amounts of subtitle
boilerplate — so the priors it falls back to are exactly the phrases everyone
recognises. The structural fix is not a threshold, it is **not sending silence to the
model at all**: gate with a VAD ([`../03-turn-taking/01-vad.md`](../03-turn-taking/01-vad.md)).

**Repetition loops.** Autoregressive decoding with a strong LM prior can enter a
cycle where the most likely continuation is the phrase just emitted. Beam search does
not prevent it; the compression-ratio check plus temperature fallback is the
mitigation, and it is a mitigation rather than a cure.

**First-word truncation and boundary loss.** Whisper's sequential algorithm decodes a
window, reads the last timestamp token to decide where the next window starts, and
continues. Words straddling that boundary can be clipped or duplicated. This is why
naive chunking of long audio produces errors at regular intervals, and why VAD-based
segmentation on silence is strictly better than fixed-size chunking.

**Timestamp drift.** Timestamps are predicted tokens, not alignment measurements
(§2.3), so they can be internally inconsistent — occasionally non-monotonic or
detached from the audio, especially after a temperature fallback. Treat them as a hint
with 20 ms resolution at best.

**The 8 kHz telephony gap.** Trained overwhelmingly on wideband audio, Whisper on
upsampled 8 kHz phone audio sees an empty band above 4 kHz — out of distribution, and
precisely where the fricative cues live
([`../01-foundations/01-sound-and-sampling.md`](01-sound-and-sampling.md)). Expect a
measurable WER penalty and confusions among /s/, /f/ and /θ/
([`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)).

---

## 3. From scratch

Whisper is not something to reimplement in a chapter; the instructive exercise is to
reimplement the *decoding heuristics*, because they are where the engineering is and
they are model-independent. The two checks below are the ones that matter, and they
are worth having in your own pipeline regardless of which recogniser you use.

```python
"""Whisper's two quality gates, standalone, with the real default thresholds."""
import zlib
from dataclasses import dataclass

COMPRESSION_RATIO_THRESHOLD = 2.4     # whisper/transcribe.py default
LOGPROB_THRESHOLD = -1.0
NO_SPEECH_THRESHOLD = 0.6
TEMPERATURES = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)

def compression_ratio(text: str) -> float:
    """Repetition detector. Repetitive text compresses far better than speech.
    Whisper uses this rather than an n-gram check because it needs no tuning
    per language and costs one zlib call."""
    data = text.encode("utf-8")
    return len(data) / len(zlib.compress(data))

@dataclass
class DecodeResult:
    text: str
    avg_logprob: float
    no_speech_prob: float

def needs_fallback(r: DecodeResult) -> str | None:
    """Return the reason to retry hotter, or None to accept.
    Mirrors the accept/reject logic in whisper's decode_with_fallback."""
    if compression_ratio(r.text) > COMPRESSION_RATIO_THRESHOLD:
        return f"repetitive (cr={compression_ratio(r.text):.2f})"
    if r.avg_logprob < LOGPROB_THRESHOLD:
        return f"low confidence (avg_logprob={r.avg_logprob:.2f})"
    return None

def is_silence(r: DecodeResult) -> bool:
    """Whisper treats a segment as silent only when BOTH signals agree: the
    no-speech token is confident AND the transcript itself is low-confidence.
    Either alone is too noisy to act on."""
    return (r.no_speech_prob > NO_SPEECH_THRESHOLD
            and r.avg_logprob < LOGPROB_THRESHOLD)

def decode_with_fallback(decode_fn) -> DecodeResult:
    """decode_fn(temperature) -> DecodeResult. Escalates temperature until a
    result passes the gates, then returns the last attempt regardless.
    Note the cost model: a bad segment costs up to len(TEMPERATURES) decodes."""
    result = None
    for i, t in enumerate(TEMPERATURES):
        result = decode_fn(t)
        reason = needs_fallback(result)
        if reason is None:
            return result
        print(f"  fallback {i}: T={t} rejected -- {reason}")
    return result

if __name__ == "__main__":
    for label, text in [
        ("normal", "I would like to reschedule my appointment for next Tuesday."),
        ("mild repeat", "Thank you. Thank you. Thank you. Thank you."),
        ("loop", " ".join(["Thank you."] * 20)),
        ("subtitle spam", " ".join(["Subscribe to my channel!"] * 30)),
    ]:
        r = DecodeResult(text, avg_logprob=-0.35, no_speech_prob=0.05)
        print(f"{label:15s} cr={compression_ratio(text):6.2f}  "
              f"verdict={needs_fallback(r) or 'accept'}")

    # A segment that only escapes the loop at higher temperature.
    attempts = [" ".join(["yeah"] * 60), " ".join(["yeah"] * 20), "Yeah, that works."]
    it = iter(attempts)
    print("\nfallback ladder:")
    final = decode_with_fallback(
        lambda T: DecodeResult(next(it), avg_logprob=-0.4, no_speech_prob=0.02))
    print(f"  accepted: {final.text!r}")
```

Measured output `[MEASURED]`:

```
normal          cr=  0.91  verdict=accept
mild repeat     cr=  1.95  verdict=accept
loop            cr=  9.95  verdict=repetitive (cr=9.95)
subtitle spam   cr= 18.73  verdict=repetitive (cr=18.73)

fallback ladder:
  fallback 0: T=0.0 rejected -- repetitive (cr=17.59)
  fallback 1: T=0.2 rejected -- repetitive (cr=6.19)
  accepted: 'Yeah, that works.'
```

Two things to notice. The gate accepts genuine mild repetition (1.95) and rejects
pathological loops with a large margin — the threshold is not marginal. And the
ladder shows the real cost model: this segment consumed **three decodes**, so its
latency is 3× the nominal. When you see a p99 latency spike in a Whisper-based
pipeline, this is usually why, and no amount of GPU fixes it — only avoiding the
conditions that trigger fallback (silence, music, noise) does.

---

## 4. How production does it

**`openai/whisper`** is the reference and the slowest option; use it to check
behaviour, not to serve traffic.

**`SYSTRAN/faster-whisper`** reimplements inference on CTranslate2, a runtime built
for Transformer inference with int8 and int8-float16 quantisation, layer fusion and
its own memory management. It is the default choice for CPU or single-GPU serving,
and it exposes the same decoding parameters as §2.4, so the heuristics carry over.
The rule from [`08-serving-asr.md`](08-serving-asr.md) applies: re-measure WER after
quantising rather than assuming int8 is free.

**`ggml-org/whisper.cpp`** is a C/C++ implementation over `ggml` with Metal support,
which makes it the natural fit for Apple Silicon and for embedding in applications
with no Python runtime. It also ships the most practical streaming approximation
available out of the box.

**Distil-Whisper** (Gandhi et al., arXiv:2311.00430) distils the large model into a
much shallower decoder — the design insight being that the decoder is where the depth
is spent and where it can be cut, the same insight as `turbo`. Verify the exact layer
counts and claimed speedups from the paper or model card for the variant you deploy;
they differ between releases.

**`m-bain/whisperX`** addresses two Whisper weaknesses at once: it VAD-segments the
audio before transcription — which both avoids feeding silence to the model (§2.5)
and enables batching of similar-length segments — and then forced-aligns the output
with a separate phoneme model to obtain word-level timestamps far finer than the 20 ms
token grid. If you need word timing, this is the architecture: Whisper for words,
classical alignment for time ([`01-from-hmm-to-e2e.md`](01-from-hmm-to-e2e.md) §2.6).

**`mlx-whisper`** targets Apple's MLX framework and unified memory, which on an M-series
Mac is the most direct path to GPU-accelerated Whisper without CUDA.

### Choosing on an M5 Mac

| Need | Choice | Why |
|---|---|---|
| Highest accuracy, offline, latency tolerant | `large-v3` via `mlx-whisper` or `faster-whisper` int8 | Unified memory holds it; accuracy dominates |
| Balanced local voice agent | `faster-whisper` `small`/`distil` int8 | Best accuracy per millisecond on CPU |
| Embedding in an app, no Python | `whisper.cpp` + Metal | Single binary, good streaming approximation |
| Word-level timestamps | WhisperX | Forced alignment beats timestamp tokens |
| Lowest latency, short commands | `tiny.en`/`base.en` | 39–74 M parameters; accuracy is adequate for constrained grammars |

---

## 5. At scale

**Padding is the dominant waste, and VAD is the fix.** Every input costs a 30-second
encoder pass (§2.2). For a voice agent whose turns average 3 seconds, that is roughly
90% waste. The mitigation is the WhisperX pattern: VAD-segment, then batch segments
of similar length. This changes serving cost by close to an order of magnitude and is
the first thing to implement, ahead of any quantisation.

**The fallback ladder gives you a heavy latency tail.** Most segments decode once;
some decode up to six times (§2.4, §3). Report p99 separately and know that the tail
is driven by *input conditions* — silence, music, crosstalk — not by load. The
operational lever is upstream gating, not capacity.

**`condition_on_previous_text` couples segments, which breaks parallelism.** With it
enabled, segment $n+1$ depends on segment $n$'s output, so a long recording must be
transcribed sequentially. Disabling it makes the work embarrassingly parallel and
isolates hallucination. For batch transcription of long media this is often the single
biggest throughput decision, and it is a one-line change.

**Language pinning is free accuracy and free latency.** Auto-detection is a decode
pass and a probability distribution that can be wrong (§2.3). If you know the
language — and in a phone deployment you usually know it per number or per customer —
pin it.

**Whisper is a poor fit for barge-in-sensitive agents, and this is architectural.**
No partial hypotheses, no incremental emission, 30-second windows, and a
non-deterministic fallback loop. You can bolt streaming on
([`05-streaming-asr.md`](05-streaming-asr.md)), and teams do, but a transducer
([`03-rnnt-transducer.md`](03-rnnt-transducer.md)) is the architecture that was
designed for the job. Choose Whisper for accuracy and multilingual breadth on
turn-based interaction; choose a transducer when emission latency is the product.

---

## 6. Exercises

**E2.4.1** Compute the encoder cost ratio between a 2-second utterance and a
30-second utterance under Whisper's fixed-window design. Then compute the effective
waste for a call whose turn durations are distributed uniformly over 1–6 seconds.
State the throughput gain from perfect VAD segmentation.

**E2.4.2** Take the §3 gate and calibrate `compression_ratio_threshold` yourself:
collect twenty genuine repetitive utterances (a person saying "no no no no") and
twenty synthetic loops, then find the threshold that separates them. Does 2.4 hold up?
Report the false-positive and false-negative counts.

**E2.4.3** Transcribe the same 10-minute recording with
`condition_on_previous_text` on and off. Compare WER, wall-clock time, and the
position of the first error. Explain any progressive degradation you observe.

**E2.4.4** Feed Whisper 30 seconds of pure silence, then 30 seconds of instrumental
music, and record the output over ten runs each. Categorise the hallucinations.
Then repeat with a VAD gate in front and confirm the output is empty.

**E2.4.5** Derive the finest possible word timestamp resolution from
`TOKENS_PER_SECOND` and the timestamp-token grid. Then measure the actual error of
Whisper's timestamps against forced alignment on ten utterances, and report the
distribution.

**E2.4.6** Downsample wideband speech to 8 kHz, upsample back to 16 kHz, and measure
the WER change on a fixed set. Break the errors down by phoneme class and check
whether the fricative prediction from §2.5 holds.

**E2.4.7** Quantise a Whisper model to int8 with faster-whisper and measure both
speedup and WER on your own golden set. State whether you would ship it, with the
numbers that justify the decision.

---

## 7. Interview drill

> "Your product transcribes support calls with Whisper large-v3. Accuracy is good,
> but 2% of calls come back with a paragraph of unrelated text — recipe instructions,
> 'subscribe to my channel', song lyrics — inserted in the middle. Explain and fix."

The candidate should identify the mechanism immediately and precisely: this is
hallucination on non-speech input, and it is not random corruption. An AED decoder
with weak acoustic evidence falls back on its language-model prior, and Whisper's
prior was shaped by weakly-labelled scraped audio containing subtitle boilerplate. The
specific *content* of the hallucination is the tell — the model is reproducing its
training distribution, which is why everyone sees the same phrases.

The next step is to name the trigger, because support calls contain exactly the
conditions that produce it: hold music, IVR tones, long silences, and dead air after
a transfer. So the diagnosis is testable in minutes — correlate the affected segments
against energy and VAD output, and you should find the insertions land in non-speech
regions.

The fix should be ordered by leverage, and the ordering matters more than the list.
**First, do not send non-speech to the model**: VAD-segment and transcribe only speech
regions. This removes the cause rather than filtering the symptom, and it makes
serving cheaper by eliminating padded silence. **Second, disable
`condition_on_previous_text`** so one hallucination cannot seed the next window —
this converts a spreading failure into an isolated one. **Third, keep the existing
gates and consider tightening them**, noting from §3 that the compression-ratio check
catches loops but *not* a single fluent hallucinated paragraph, which compresses like
normal prose. That limitation is the key insight: the built-in defences do not cover
this failure, which is why the upstream fix is mandatory rather than optional.

A strong close adds detection: hallucinated segments typically have low average token
log-probability and high `no_speech_prob`, so log those per segment and alert on the
rate. And note the residual risk honestly — a confident hallucination over genuine
background speech (a television in the room) defeats all of these, and the only real
answer there is a diarization or speaker-conditioning step
([`09-diarization-and-speaker-id.md`](09-diarization-and-speaker-id.md)).

---

## Sources

- Radford, A., Kim, J. W., Xu, T., Brockman, G., McLeavey, C. & Sutskever, I. (2022). *Robust Speech Recognition via Large-Scale Weak Supervision.* arXiv:2212.04356.
- `openai/whisper`, main branch, retrieved 2026-08-22: `whisper/audio.py` (all constants in §2.2), `whisper/model.py` (`ModelDimensions` fields in §2.3), `whisper/tokenizer.py` (special-token list and the `<|{i * 0.02:.2f}|>` timestamp tokens for `i in range(1501)`), `whisper/transcribe.py` (every default in §2.4: `temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0)`, `compression_ratio_threshold=2.4`, `logprob_threshold=-1.0`, `no_speech_threshold=0.6`, `condition_on_previous_text=True`, `hallucination_silence_threshold=None`), and the repository README model-size table in §2.3.
- Chan, W., Jaitly, N., Le, Q. & Vinyals, O. (2015). *Listen, Attend and Spell.* arXiv:1508.01211.
- Gandhi, S., von Platen, P. & Rush, A. M. (2023). *Distil-Whisper: Robust Knowledge Distillation via Large-Scale Pseudo Labelling.* arXiv:2311.00430.
- Bain, M., Huh, J., Han, T. & Zisserman, A. (2023). *WhisperX: Time-Accurate Speech Transcription of Long-Form Audio.* arXiv:2303.00747.
- `SYSTRAN/faster-whisper` (CTranslate2 runtime), `ggml-org/whisper.cpp` (ggml/Metal), `m-bain/whisperX`, `ml-explore/mlx-examples` (mlx-whisper) — the production references in §4, checked 2026-08.
- All `[MEASURED]` values in §2.4 and §3 were produced locally on Apple M5 / macOS 26.5.2 with CPython 3.12 and the standard-library `zlib`.
