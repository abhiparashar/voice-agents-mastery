# TTS Architectures: From Text to Waveform

**What you'll be able to do after this:** trace the full synthesis pipeline from
graphemes to samples and say which stage owns which failure; explain why attention-based
TTS skipped and repeated words and what replaced it; demonstrate that a magnitude
spectrogram does not determine a waveform, and therefore why neural vocoders exist; and
state what Piper and Kokoro actually are architecturally.

---

## 1. Intuition

Text-to-speech looks like the inverse of recognition and is a different problem in an
important way: **it is one-to-many.** There is exactly one correct transcription of an
utterance, but there are unboundedly many correct readings of a sentence — faster, higher,
warmer, with the emphasis in a different place. A recogniser can be scored against a
reference; a synthesiser producing something different from its reference may be equally
good.

That under-determination shapes every architectural decision. It is why TTS models are
generative rather than discriminative, why they use adversarial or likelihood-based
training rather than a simple regression loss, and why the naive approach — predict the
mean of all valid readings — produces the characteristic muffled, lifeless voice of early
neural TTS. Averaging over many valid prosodies gives you none of them.

The pipeline decomposes into three problems that fail independently:

| Stage | Input → Output | Owns |
|---|---|---|
| **Front end** | text → phonemes + prosodic hints | pronunciation, numbers, names, abbreviations |
| **Acoustic model** | phonemes → mel spectrogram | duration, pitch, rhythm, timbre |
| **Vocoder** | mel spectrogram → waveform | audio quality, artefacts, speed |

Attributing a complaint to the right stage is most of the diagnostic skill here. "It said
'Dr.' as 'doctor' when it meant 'Drive'" is the front end. "It rushed the last word" is
the acoustic model. "It sounds metallic and buzzy" is the vocoder. Teams routinely
attempt to fix front-end problems by changing models.

The second intuition, and the one §2.5 measures, is that **the mel spectrogram thrown
around as "the intermediate representation" is a lossy, phase-free summary**. You cannot
invert it exactly. A vocoder is not a decoder performing arithmetic; it is a generative
model *inventing* plausible phase. Understanding that explains why vocoders were the
hard part of neural TTS and why they dominate inference cost.

---

## 2. Rigour

### 2.1 The front end

Everything before the neural network, and the source of most user-visible errors.

**Text normalisation** expands non-orthographic tokens: `$42.50` → "forty two dollars
fifty", `Dr.` → "doctor" or "drive" depending on context, `2026` → "twenty twenty six" as
a year but "two thousand and twenty six" as a quantity. This is the inverse of the ITN
problem in [`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md)
§2.4, and it is locale-dependent in ways that are correctness issues rather than style —
covered in [`04-prosody-and-voice.md`](04-prosody-and-voice.md).

**Grapheme-to-phoneme conversion** maps orthography to a phoneme sequence. English is
hostile to this: *through, though, tough, thought, thorough* share four letters and no
pronunciation. The standard approach is a pronunciation dictionary (CMUdict, or
`espeak-ng`'s rules) with a learned model for out-of-vocabulary words, which is where
names fail. Phoneme sets are ARPAbet or IPA.

`espeak-ng` deserves specific mention because it appears in the dependency tree of both
Piper and Kokoro: it is a rule-based multilingual phonemiser, not a neural model, and it
is the reason those systems handle many languages with a small footprint. It also means
their pronunciation errors are *rule* errors, which are inspectable and fixable with a
lexicon entry rather than retraining.

**Prosody prediction** — phrase boundaries, emphasis, intonation — was an explicit stage
in classical systems and is now mostly implicit in the acoustic model. That is a
capability regression as well as a simplification: an explicit prosody stage could be
*controlled*, and an implicit one can only be nudged.

### 2.2 Acoustic models: the lineage

**Concatenative / unit selection.** Record hours of a single speaker, cut into units
(diphones or larger), select and splice at synthesis time. Sounded remarkably good when
the target sentence resembled the corpus, and degraded audibly at unit joins. Fatal flaw:
a new voice means a new studio recording, and control means recording more data.

**Statistical parametric (HMM-based).** Model spectral parameters with HMMs and generate
them, then vocode. Small, flexible, controllable — and unmistakably robotic, because
generating the *mean* of a distribution over spectra plus a simple source-filter vocoder
loses everything that makes speech sound alive. This is the averaging problem from §1 in
its purest form.

**Tacotron / Tacotron 2 (2017).** Sequence-to-sequence with attention: an encoder over
characters, an autoregressive decoder producing mel frames, attention aligning them. The
first system to sound genuinely natural, and its failure mode is instructive — **attention
is unconstrained**, so it could skip words, repeat words, or fail to terminate. Exactly the
pathology of attention-based ASR
([`../02-asr/04-attention-and-whisper.md`](../02-asr/04-attention-and-whisper.md) §2.1),
in the other direction. For a voice agent reading account numbers aloud, a model that
occasionally skips a digit is not deployable.

**FastSpeech / FastSpeech 2 (2019–2020).** Replace attention with an explicit **duration
predictor**: predict how many mel frames each phoneme occupies, expand accordingly, and
generate all frames in parallel. This is the decisive architectural fix. Robustness
becomes structural — every phoneme gets a duration, so nothing can be skipped or repeated
— and inference becomes non-autoregressive, hence fast. FastSpeech 2 adds explicit pitch
and energy prediction, which restores some of the *controllability* the parametric era had.

**VITS (2021).** End-to-end text to waveform, trained with a conditional variational
autoencoder plus adversarial loss, using a normalising flow for the prior and **monotonic
alignment search** to learn alignments without external durations. It removes the separate
vocoder and the need for a pretrained aligner. VITS is the workhorse of open-source TTS,
and the direct answer to "what is Piper".

### 2.3 What Piper and Kokoro actually are

Verified from PyPI metadata, retrieved 2026-08-22:

| | Piper | Kokoro |
|---|---|---|
| Package / version | `piper-tts` 1.7.0 | `kokoro` 0.9.4 |
| Python requirement | `>=3.9` | `<3.13,>=3.10` |
| Self-description | "Fast and local neural text-to-speech engine" | inference library for Kokoro-82M |
| Parameters | per-voice VITS models | **82 million** |
| Weights licence | permissive per voice | **Apache** |
| Phonemisation | `espeak-ng` | `espeak-ng` via misaki |

Kokoro's own description is worth quoting because it states the design goal precisely: an
"open-weight TTS model with 82 million parameters" that "delivers comparable quality to
larger models while being significantly faster and more cost-efficient", with
Apache-licensed weights deployable "anywhere from production environments to personal
projects".

Two practical notes. **The `<3.13` constraint on `kokoro` is why this curriculum pins
Python 3.12** ([`../00-setup/01-environment.md`](../00-setup/01-environment.md)) — a
dependency constraint driving an environment decision, which is worth noticing as a
pattern. And both depend on `espeak-ng`, so both need it installed as a system package
and both inherit its pronunciation behaviour.

Architecturally these are the *small, fast, non-cloning* branch of TTS. They do not do
zero-shot voice cloning; they render a fixed set of trained voices very quickly on a CPU.
For a voice agent that needs a consistent brand voice at low latency and zero marginal
cost, that is exactly the right trade — the cloning branch is
[`02-codec-lm-tts.md`](02-codec-lm-tts.md), and it costs latency.

### 2.4 Vocoders

The vocoder turns a mel spectrogram into samples, and it dominates both audio quality and
inference cost.

**Griffin-Lim (1984).** Iterative phase reconstruction, no learning: start from random
phase, repeatedly STFT and replace the magnitude with the target while keeping the
estimated phase. §2.5 measures what it can and cannot do.

**WaveNet (2016).** Autoregressive over raw samples, one sample at a time, with dilated
causal convolutions. Transformative quality, and at 16 000 or 24 000 sequential forward
passes per second of audio it was orders of magnitude too slow for real-time use.

**HiFi-GAN (2020).** A generator that upsamples mel to waveform in one pass, trained
adversarially against **multi-period** and **multi-scale** discriminators. The multi-period
discriminator is the key idea: it reshapes the waveform by different prime periods so
discriminators see periodic structure at several scales, which is what makes voiced speech
sound right. Fast, high quality, and the default for the mel-based branch.

The general lesson: replacing an autoregressive-over-samples model with a one-shot
generator plus a good discriminator converted vocoding from the bottleneck into a rounding
error.

### 2.5 A magnitude spectrogram does not determine a waveform

This is the measurement that explains why vocoders are generative. Take a synthetic
harmonic signal, compute its STFT ($N = 1024$, hop 256), discard the phase, and
reconstruct with Griffin-Lim. Two metrics: **spectral convergence** (how closely the
reconstruction's magnitude spectrogram matches the target — lower is better) and **SNR
against the original waveform** `[MEASURED]`:

| Griffin-Lim iterations | Spectral convergence | SNR vs original waveform |
|---|---|---|
| 0 (random phase) | 0.6609 | −3.10 dB |
| 1 | 0.3841 | −3.06 dB |
| 4 | 0.2352 | −2.95 dB |
| 16 | 0.1366 | −3.04 dB |
| 64 | 0.0455 | −3.06 dB |
| 256 | **0.0128** | **−3.05 dB** |
| — with **true** phase | **0.000000** | **+36.8 dB** |

Read the two columns against each other, because the contrast is the whole point.
Griffin-Lim **is** working: spectral convergence improves by a factor of 50, and after 256
iterations the reconstruction's magnitude spectrogram is a near-perfect match to the
target. And the waveform SNR **never improves at all** — it sits at roughly −3 dB from
random phase through 256 iterations.

Meanwhile, supplying the true phase gives exact spectral convergence and +36.8 dB.

The conclusion is unavoidable: **the magnitude spectrogram does not determine the
waveform.** Griffin-Lim converges to *a* signal with the right magnitude spectrogram, and
that signal is not the original one, and no number of iterations changes that because the
information is not present in the input. The lost phase is not a small residual; it is the
difference between −3 dB and +37 dB.

Three consequences, and they explain the shape of the whole field:

- **A vocoder cannot be a deterministic inverse.** It must *generate* plausible phase, and
  "plausible" is a learned property of speech. That is why vocoding is a modelling problem
  rather than a signal-processing one.
- **Griffin-Lim's artefacts are structural.** The characteristic hollow, metallic, phasey
  quality is what a signal with correct magnitudes and incorrect phase sounds like. More
  iterations reduce spectral error and do not remove that character.
- **Spectrogram-domain losses are weak supervision.** An L1 or L2 loss on mel frames
  cannot distinguish a good waveform from a bad one with the same magnitudes, which is
  precisely why HiFi-GAN's discriminators operate on the *waveform*.

### 2.6 Choosing a family

| Family | Latency | Quality | Cloning | Controllable | Local on M5 |
|---|---|---|---|---|---|
| Concatenative | very low | good in-domain | no | poorly | yes (large corpus) |
| Parametric HMM | very low | robotic | no | yes | yes |
| Tacotron 2 + HiFi-GAN | medium (autoregressive) | high | with adaptation | somewhat | yes |
| FastSpeech 2 + HiFi-GAN | low (parallel) | high | with adaptation | yes (pitch/duration) | yes |
| VITS end-to-end (Piper) | very low | high | no | limited | **yes, comfortably** |
| StyleTTS-lineage (Kokoro) | very low | high | reference style | style vector | **yes, comfortably** |
| Codec-LM (VALL-E lineage) | high | very high | **zero-shot** | prompt-based | large models struggle |

For a voice agent the decisive column is usually latency, and the second is whether you
need cloning. If you do not, the VITS/StyleTTS branch dominates: it runs locally, costs
nothing per character, and has a time-to-first-byte a codec-LM cannot approach. Detailed
selection criteria are in [`05-engine-selection.md`](05-engine-selection.md).

---

## 3. From scratch

Griffin-Lim, plus the measurement that makes the phase argument concrete. Standalone,
numpy only.

```python
"""Griffin-Lim phase reconstruction, and proof that magnitude is not enough."""
import numpy as np

SR, N_FFT, HOP = 16_000, 1024, 256

def stft(y):
    w = np.hanning(N_FFT + 1)[:-1]
    n_frames = 1 + (len(y) - N_FFT) // HOP
    idx = np.arange(N_FFT)[None, :] + HOP * np.arange(n_frames)[:, None]
    return np.fft.rfft(y[idx] * w, axis=1)

def istft(S):
    """Weighted overlap-add. Dividing by the summed squared window makes this a
    proper inverse when COLA holds -- see 01-foundations/02-time-frequency.md."""
    w = np.hanning(N_FFT + 1)[:-1]
    frames = np.fft.irfft(S, axis=1) * w
    n = (len(S) - 1) * HOP + N_FFT
    out, wsum = np.zeros(n), np.zeros(n)
    for i, f in enumerate(frames):
        out[i*HOP:i*HOP + N_FFT] += f
        wsum[i*HOP:i*HOP + N_FFT] += w ** 2
    return out / np.maximum(wsum, 1e-8)

def griffin_lim(magnitude, iters, seed=0):
    """Alternate between: synthesise with current phase, re-analyse, keep the new
    phase but restore the target magnitude. Converges on magnitude, not on signal."""
    rng = np.random.default_rng(seed)
    S = magnitude * np.exp(1j * rng.uniform(-np.pi, np.pi, magnitude.shape))
    for _ in range(iters):
        y = istft(S)
        S = magnitude * np.exp(1j * np.angle(stft(y)))
    return istft(S)

def spectral_convergence(magnitude, y):
    """Relative error between the reconstruction's magnitude and the target."""
    M = np.abs(stft(y))
    n = min(len(M), len(magnitude))
    return np.linalg.norm(M[:n] - magnitude[:n]) / np.linalg.norm(magnitude[:n])

def waveform_snr(x, y):
    """SNR after gain matching -- we do not penalise a pure level difference."""
    n = min(len(x), len(y))
    y = y[:n] * np.std(x[:n]) / max(np.std(y[:n]), 1e-12)
    err = x[:n] - y
    return 10 * np.log10((x[:n] ** 2).mean() / max((err ** 2).mean(), 1e-20))

if __name__ == "__main__":
    # Synthetic voiced speech: harmonic stack, vibrato-ish f0, syllabic envelope.
    t = np.arange(SR * 2) / SR
    f0 = 140 + 20 * np.sin(2 * np.pi * 1.5 * t)
    phase = 2 * np.pi * np.cumsum(f0) / SR
    x = sum(np.sin(k * phase) / k for k in range(1, 25))
    x = x * (0.5 + 0.5 * np.sin(2 * np.pi * 4 * t))
    x /= np.abs(x).max()

    S = stft(x)
    magnitude = np.abs(S)          # this is what a vocoder receives: no phase

    print(f"{'iters':>6} {'spec_conv':>10} {'SNR_vs_orig_dB':>15}")
    for iters in (0, 1, 4, 16, 64, 256):
        y = griffin_lim(magnitude, iters)
        print(f"{iters:6d} {spectral_convergence(magnitude, y):10.4f} "
              f"{waveform_snr(x, y):15.2f}")

    # The control: same magnitudes, but with the phase we threw away.
    y_true = istft(magnitude * np.exp(1j * np.angle(S)))
    print(f"\nwith TRUE phase: spec_conv={spectral_convergence(magnitude, y_true):.6f}  "
          f"SNR={waveform_snr(x, y_true):.1f} dB")
    print("-> magnitude converges to ~0 error while waveform SNR never improves.")
    print("-> the mel/magnitude spectrogram does not determine the signal.")
```

The two-metric design is the point of this listing. Reporting only spectral convergence
would show Griffin-Lim "working beautifully", which is how the algorithm gets
misrepresented. Reporting only SNR would show it failing without explaining why. Together
they isolate exactly what is missing, and the true-phase control proves the missing thing
is recoverable *in principle* but not *from this input*.

---

## 4. How production does it

**Piper** (`piper-tts` 1.7.0, verified) is per-voice VITS exported to ONNX, phonemised by
`espeak-ng`. Its properties for agent work: runs comfortably on CPU, tiny memory
footprint, many languages and voices, no cloning, and pronunciation fixable via lexicon
because the phonemiser is rule-based. This is the sensible default for a local or
cost-sensitive deployment.

**Kokoro** (`kokoro` 0.9.4, Kokoro-82M, Apache weights, verified) is the current
small-model quality leader in open TTS, in the StyleTTS lineage. 82 M parameters is small
enough to run on a laptop CPU and permissive enough to embed commercially. Note the
`<3.13` Python constraint.

**Coqui TTS** (`coqui-ai/TTS`) is the research toolkit: many architectures including
Tacotron 2, VITS, FastSpeech-family and XTTS, with training recipes. The right choice for
training or fine-tuning your own voice; heavier than Piper or Kokoro for pure inference.
Note that the company behind it shut down, so treat maintenance status as a risk factor
rather than assuming ongoing development.

**HiFi-GAN** appears as the vocoder inside many of these stacks, and where a system exposes
a separate vocoder that is usually what it is.

**Hosted engines** (ElevenLabs, Cartesia, Azure, Google, PlayHT, Rime) do not publish
architectures, but their behaviour is diagnostic: engines with sub-100 ms
time-to-first-byte and no cloning are almost certainly in the parallel/VITS branch, while
zero-shot cloning with higher latency indicates the codec-LM branch
([`02-codec-lm-tts.md`](02-codec-lm-tts.md)).

**`espeak-ng`** is worth installing and running by hand once, because seeing the phoneme
string for your product names tells you immediately whether a pronunciation problem is a
front-end issue you can fix with a lexicon entry or an acoustic-model issue you cannot.

---

## 5. At scale

**Front-end errors are the ones users report, and they are the cheapest to fix.**
Mispronounced names and misread numbers come from text normalisation and G2P, not the
neural model. A per-tenant pronunciation lexicon is a small amount of code and typically
resolves the majority of complaints — the mirror image of the biasing argument in
[`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md).

**Vocoder cost dominates inference, so it sets your concurrency.** The acoustic model
produces a few hundred mel frames per second of audio; the vocoder produces 16 000–24 000
samples. When sizing capacity, benchmark the *vocoder* at your target chunk size, not the
end-to-end model on long files, for the same reason streaming RTF differs from offline RTF
([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md) §2.1).

**Small local models change the cost structure entirely.** An 82 M-parameter model on CPU
means TTS has no marginal cost per character and no per-request network hop. For a
high-volume agent this can be a larger cost lever than any LLM optimisation, and it also
removes a dependency that can fail mid-utterance
([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).

**Cache aggressively, and be careful with keys.** Greetings, hold messages, disclosures and
menu prompts are fixed strings synthesised thousands of times. Cache the audio keyed on
`(text, voice, speed, engine version)` — omitting the version from the key is how a voice
change silently fails to roll out. Discussed further in
[`03-streaming-tts.md`](03-streaming-tts.md).

**Voice consistency across providers is a real constraint.** If your fallback engine has a
different voice, a mid-call failover changes who the caller is talking to. Either keep a
matched fallback voice or accept the discontinuity deliberately; the failure mode is
jarring enough that users comment on it.

---

## 6. Exercises

**E4.1.1** Run the §3 code. Then repeat with hop sizes of 128 and 512 at the same
`N_FFT`. Report spectral convergence at 64 iterations for each and explain the trend in
terms of STFT redundancy.

**E4.1.2** Replace the synthetic harmonic signal with a recording of your own voice.
Report both metrics and listen to the 4-iteration and 256-iteration reconstructions.
Describe the perceptual difference and reconcile it with the SNR column.

**E4.1.3** Implement the mel projection: reduce the magnitude spectrogram to 80 mel bins,
then pseudo-invert back to linear before Griffin-Lim. Measure the additional degradation
and state which loss — mel compression or phase — costs more.

**E4.1.4** Install `espeak-ng` and phonemise ten proper nouns relevant to your domain.
Identify which are wrong, and for each state whether a lexicon entry can fix it.

**E4.1.5** Construct a text input that would make an unconstrained attention-based TTS
skip or repeat content (long digit strings, heavy repetition). Explain precisely why a
duration-predictor architecture cannot exhibit that failure.

**E4.1.6** Benchmark a local engine's real-time factor at 1-clause, 1-sentence and
1-paragraph inputs. Show that RTF measured on long inputs overstates streaming
performance, and quantify by how much.

**E4.1.7** Build the cache from §5 with a correct key, then demonstrate the failure that
occurs when the engine version is omitted from the key.

---

## 7. Interview drill

> "Our agent mispronounces customer surnames and reads '£1,250.00' as 'one two five zero
> zero zero'. Product wants us to switch to a more expensive TTS vendor. What do you say?"

Both symptoms are **front-end** failures — G2P and text normalisation (§2.1) — and neither
is caused by the acoustic model or the vocoder. So changing vendors addresses neither
directly and may not change them at all, since every vendor has a front end with the same
class of problem. Saying that clearly, and locating each symptom in the pipeline, is the
substance of the answer.

The currency reading is the more diagnostic of the two: reading the digits individually
means the normaliser did not recognise the token as currency at all — likely because of the
symbol, the thousands separator, or a locale mismatch. That is a rule, not a model, and it
is testable in a minute by passing the string through the front end alone.

Surnames are G2P on out-of-vocabulary words. Rule-based phonemisers such as `espeak-ng`
produce a deterministic and *inspectable* guess (§4), which means the fix is a
pronunciation lexicon keyed on the name — the same per-tenant data structure as the ASR
biasing lexicon in
[`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md), and often
literally the same list read in both directions.

So the proposal is: verbalise numbers, dates and currency **in your own code** before the
text reaches the engine, so the behaviour is testable and locale-correct rather than
vendor-dependent; add a per-tenant pronunciation lexicon with phoneme overrides for names;
and measure the result on a fixed set of surnames and monetary amounts. That is a few days
of work against a permanent per-minute cost increase, and it produces a regression test
the vendor switch would not.

The senior close is to grant when switching *is* right, so the answer is not reflexively
contrarian: if the requirement is zero-shot voice cloning, expressive emotional range, or a
language the current engine does not cover, that is an architecture change and a vendor
question ([`02-codec-lm-tts.md`](02-codec-lm-tts.md)). Pronunciation is not. And it is
worth noting that a vendor switch has its own costs the request has not accounted for —
voice discontinuity for existing users, a new latency profile, and a per-character bill
([`05-engine-selection.md`](05-engine-selection.md)).

---

## Sources

- `piper-tts` 1.7.0 and `kokoro` 0.9.4 PyPI metadata (retrieved 2026-08-22) — versions, Python requirements (`>=3.9` and `<3.13,>=3.10` respectively), Piper's "Fast and local neural text-to-speech engine" description, and Kokoro's statement of 82 million parameters with Apache-licensed weights, all quoted in §2.3.
- Griffin, D. & Lim, J. (1984). *Signal estimation from modified short-time Fourier transform.* IEEE TASSP 32(2) — the algorithm implemented in §3.
- van den Oord, A. et al. (2016). *WaveNet: A Generative Model for Raw Audio.* arXiv:1609.03499.
- Shen, J. et al. (2018). *Natural TTS Synthesis by Conditioning WaveNet on Mel Spectrogram Predictions* (Tacotron 2). arXiv:1712.05884.
- Ren, Y. et al. (2019, 2020). *FastSpeech* arXiv:1905.09263 and *FastSpeech 2* arXiv:2006.04558 — the duration predictor in §2.2.
- Kim, J., Kong, J. & Son, J. (2021). *VITS: Conditional Variational Autoencoder with Adversarial Learning for End-to-End Text-to-Speech.* arXiv:2106.06103.
- Kong, J., Kim, J. & Bae, J. (2020). *HiFi-GAN.* arXiv:2010.05646 — multi-period and multi-scale discriminators, §2.4.
- Li, Y. A. et al. (2023). *StyleTTS 2.* arXiv:2306.07691 — the lineage Kokoro belongs to.
- `rhasspy/espeak-ng`, `OHF-Voice/piper1-gpl`, `hexgrad/kokoro`, `coqui-ai/TTS` — the implementations discussed in §4, checked 2026-08.
- All `[MEASURED]` values in §2.5 were produced by the code in §3 on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2, on a synthetic harmonic signal. The phase-versus-magnitude conclusion is a property of the STFT and transfers; the absolute SNR figures depend on the signal.
