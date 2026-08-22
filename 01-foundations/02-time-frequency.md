# Time, Frequency, and the Features a Recogniser Actually Sees

**What you'll be able to do after this:** explain why every speech model consumes a
spectrogram rather than a waveform; derive the DFT and predict spectral leakage
before you plot it; choose a window and hop from a stated requirement; state the
time–frequency resolution limit as an inequality with numbers in it; and build
Whisper's exact 80×3000 log-mel input from scratch, byte-geometry included.

---

## 1. Intuition

A waveform is 16 000 numbers per second describing air pressure. Almost none of the
structure a listener perceives is *locally* visible in it. The difference between
"see" and "she" is not in any individual sample; it is in how energy is distributed
across frequency during the first 100 ms. Two recordings of the same word by the
same speaker at the same volume can be sample-for-sample uncorrelated — shift one
by half a period and their samples anti-correlate — yet be perceptually identical.

That is the whole motivation. Speech identity lives in the **short-time frequency
content**, and a representation that exposes it directly saves the model from
having to learn the Fourier transform from data. This is not a hypothesis; it is
observable in architecture choices. Whisper, Conformer, wav2vec2's front end and
every production recogniser either consume log-mel features or begin with strided
convolutions whose learned filters converge to something spectrogram-like.

The engineering tension is equally simple to state. To know a signal's frequency
precisely you must observe it for a long time; to know *when* something happened
you must observe a short interval. You cannot have both, and the product of the two
uncertainties has a floor. Speech forces you to pick a point on that curve: too
short a window and a vowel's formants smear together; too long and a plosive's
20 ms burst is averaged into its neighbours. The industry converged on **25 ms
windows every 10 ms**, and §2 shows that this is not folklore — it is the
resolution needed to separate formants while still resolving a stop consonant.

One more intuition worth carrying: the mel scale is not a psychoacoustic nicety
bolted on for realism. It is a **compression scheme**. A 201-bin power spectrum
becomes 80 mel bins, a 2.5× reduction, and the bins you discard are the ones where
human speech carries the least discriminative information — fine frequency detail
at high frequencies. It buys you a smaller model input for almost no loss in what
matters.

---

## 2. Rigour

### 2.1 The DFT

For a finite sequence $x[0..N-1]$, the discrete Fourier transform is

$$X[k] = \sum_{n=0}^{N-1} x[n]\, e^{-j 2\pi k n / N}, \qquad k = 0, \dots, N-1$$

Each $X[k]$ is the inner product of the signal with a complex exponential at
frequency $f_k = k f_s / N$. The bin spacing is therefore

$$\Delta f = \frac{f_s}{N}$$

and for real input, $X[N-k] = \overline{X[k]}$, so only $\lfloor N/2 \rfloor + 1$
bins carry information. That is why `np.fft.rfft` on a 400-point frame returns
**201** bins, a number you will see again in §3.

Direct evaluation is $O(N^2)$. The Cooley–Tukey FFT recursively splits even and odd
indices to reach $O(N \log N)$. For $N = 400$ that is roughly 160 000 versus 3 500
operations — a factor of 45, and the reason real-time spectral analysis is
computationally free compared to the neural network that follows it.

### 2.2 Leakage: the artefact everyone rediscovers

The DFT assumes the $N$ samples are one period of a periodic signal. If your
sinusoid does not complete an integer number of cycles in the frame, the implied
periodic extension has a discontinuity at the wrap-around point, and a
discontinuity is broadband. Energy from one true frequency appears across many
bins. This is **spectral leakage**, and it is a property of the analysis, not of the
signal.

Measured on a 512-point frame at 16 kHz, reporting the fraction of total energy
falling outside ±3 bins of the peak `[MEASURED]`:

| Signal | Window | Energy outside ±3 bins |
|---|---|---|
| Bin-centred (exactly 8.0 cycles) | rectangular | $-294$ dB |
| Bin-centred (exactly 8.0 cycles) | Hann | $-296$ dB |
| Off-bin (8.5 cycles) | rectangular | $-13.0$ dB |
| Off-bin (8.5 cycles) | Hann | $-41.3$ dB |

Read that table carefully, because it contains the entire argument for windowing.
On a bin-centred tone both windows are perfect — the $-294$ dB is floating-point
noise, not physics. Move the tone half a bin off centre, the rectangular window
leaks 5% of the signal's energy outside the main lobe, and the Hann window reduces
that by 28 dB. Real speech is never bin-centred. Therefore you always window.

### 2.3 Windows, quantified

A window $w[n]$ multiplies the frame before transformation; in frequency this
convolves the true spectrum with the window's own transform. The design tradeoff is
**main-lobe width against side-lobe level**: a narrower main lobe resolves closer
frequencies, lower side lobes hide weaker ones less badly.

Measured on 64-point windows via a $2^{16}$-point zero-padded FFT, with widths in
units of DFT bins $(f_s/N)$ `[MEASURED]`:

| Window | Main-lobe width (null-to-null) | Peak side lobe | ENBW | Coherent gain |
|---|---|---|---|---|
| Rectangular | 2.0 bins | $-13.3$ dB | 1.00 bins | 1.000 |
| Hann | 4.0 bins | $-31.5$ dB | 1.50 bins | 0.500 |
| Hamming | 4.0 bins | $-42.4$ dB | 1.36 bins | 0.540 |
| Blackman | 6.0 bins | $-58.1$ dB | 1.73 bins | 0.420 |

Four things to extract:

- **Hamming dominates Hann on side lobes at identical main-lobe width** ($-42.4$
  vs $-31.5$ dB). That is why classical speech processing — and Kaldi's
  `compute-fbank-feats` — defaults to Hamming (or its "povey" variant).
- **Hann is chosen anyway in modern pipelines** because of §2.4: it satisfies the
  overlap-add reconstruction condition exactly at 50% and 75% overlap, which
  matters if you ever need to go back to a waveform.
- **Coherent gain is the amplitude scale factor.** A Hann window halves a
  sinusoid's amplitude, so a spectrum computed with it is 6 dB low unless you
  divide by 0.5. Forgetting this is the standard cause of "my dB values are all
  wrong".
- **ENBW (equivalent noise bandwidth)** tells you how much wider than one bin the
  window's noise-collecting aperture is. It is the correct denominator for
  noise-floor calculations, e.g. estimating a VAD's noise estimate.

### 2.4 The STFT and the COLA condition

Slide the window in steps of $H$ (the **hop**) and transform each frame:

$$X[m, k] = \sum_{n=0}^{N-1} x[mH + n]\, w[n]\, e^{-j2\pi kn/N}$$

The result is a matrix — the spectrogram — indexed by frame $m$ and bin $k$. The
**overlap** is $1 - H/N$. For $N = 400$, $H = 160$ at 16 kHz: 25 ms windows every
10 ms, 60% overlap, 100 frames per second.

If you intend to invert the STFT, the window and hop must satisfy the
**constant-overlap-add** (COLA) condition: the shifted windows must sum to a
constant,

$$\sum_{m} w[n - mH] = c \quad \text{for all } n$$

Measured for a 400-point Hann window `[MEASURED]`:

| Hop | Overlap | Overlap-add sum | Ratio max/min |
|---|---|---|---|
| 200 ($N/2$) | 50% | exactly 1.000000 | 1.000000 |
| 100 ($N/4$) | 75% | exactly 2.000000 | 1.000000 |
| 160 (Whisper) | 60% | 1.190983 – 1.309017 | 1.099106 |

So Whisper's own hop of 160 is **not** COLA-compliant: reconstructing a waveform
from that STFT with naive overlap-add applies a 10% amplitude ripple at 100 Hz —
an audible buzz. This is entirely fine, because Whisper is an *analysis* front end
that never inverts. But it is exactly the trap that bites you the first time you
try to build a vocoder or an audio-editing tool by copying an ASR feature
extractor's parameters. Analysis geometry and synthesis geometry are different
problems.

### 2.5 The resolution limit, with numbers

For a window of length $T = N/f_s$ seconds, two equal-amplitude tones separated by
$\Delta f$ are resolvable only when $\Delta f$ is at least of order the window's
main-lobe width — for Hann, $4/T$. Below that they merge into a single lobe.

Measured as the dip depth between the two peaks (a dip of a few dB or more counts
as resolved) `[MEASURED]`:

| Window length | Hann main lobe $4/T$ | $\Delta f = 30$ Hz | 80 Hz | 160 Hz | 320 Hz |
|---|---|---|---|---|---|
| 25 ms | 160 Hz | 0.1 dB | 0.2 dB | 112.6 dB | 139.7 dB |
| 50 ms | 80 Hz | 0.4 dB | 112.6 dB | 127.9 dB | 152.7 dB |
| 100 ms | 40 Hz | 39.0 dB | 128.0 dB | 140.6 dB | 302.5 dB |
| 200 ms | 20 Hz | 87.6 dB | 140.7 dB | 287.2 dB | 288.0 dB |

The transition is sharp and it lands exactly where theory says: resolution appears
precisely when $\Delta f \gtrsim 4/T$. At 25 ms, 30 Hz and 80 Hz separations are
invisible (0.1–0.2 dB); 160 Hz is resolved emphatically.

Now connect that to speech, using the vowel statistics from
[`01-sound-and-sampling.md`](01-sound-and-sampling.md). Formants F1–F3 are hundreds
of Hz apart, so a 25 ms window resolves them comfortably. The harmonics of a male
voice at $F_0 \approx 120$ Hz are 120 Hz apart — borderline at 25 ms, resolved by
50 ms. This gives the two classical analysis regimes a precise meaning:

- **Wide-band analysis** (short window, ~5–25 ms): resolves *time*, smears
  harmonics into a formant envelope. You see vertical striations for each glottal
  pulse and clear formant bands. This is what ASR wants.
- **Narrow-band analysis** (long window, ~50–100 ms): resolves *harmonics*, smears
  time. You see horizontal lines at multiples of $F_0$. This is what pitch and
  music analysis want.

25 ms is therefore not a compromise; it is a deliberate choice of the wide-band
regime, where phonetic identity is legible and pitch is not. And the 10 ms hop is
set by the *other* end of the tradeoff: a plosive burst lasts 5–20 ms, so sampling
the spectrum every 10 ms is the coarsest grid that still places at least one frame
inside a stop consonant.

### 2.6 The mel scale

Perceived pitch is roughly logarithmic in frequency above a few hundred Hz. The
common analytic approximation (the "HTK" formula) is

$$m = 2595 \log_{10}\!\left(1 + \frac{f}{700}\right), \qquad
f = 700\left(10^{m/2595} - 1\right)$$

A **mel filterbank** places $M$ triangular filters with centres evenly spaced in
mel, each spanning from the previous centre to the next, and integrates the power
spectrum under each triangle. Two filterbank conventions exist and they are not
interchangeable: HTK-style (triangles of unit peak height) and Slaney-style
(triangles normalised to unit *area*, so low filters are taller). librosa's default
is Slaney; Kaldi is HTK-style. Mixing a Slaney-trained model with an HTK extractor
shifts every low-frequency coefficient and degrades accuracy silently.

Measured for the Whisper geometry, $M = 80$, $N_{\text{FFT}} = 400$, $f_s = 16$ kHz,
$0$–$8000$ Hz `[MEASURED]`:

| Quantity | Value |
|---|---|
| Filterbank shape | $80 \times 201$ |
| Filter 0 support / bandwidth | 0.0 – 44.9 Hz / 44.9 Hz |
| Filter 79 support / bandwidth | 7475.2 – 8000.0 Hz / 524.8 Hz |
| Bandwidth ratio (highest : lowest) | 11.7× |
| rfft bins contributing per filter | min 1, max 14 |
| Empty filters | 0 |

The "min 1" entry is the interesting one. Bin spacing is $16000/400 = 40$ Hz, and
the lowest mel filters are narrower than that, so they are fed by a *single* FFT
bin. Below roughly 80 Hz the mel filterbank is not really averaging anything — it
is aliasing one bin into several outputs. That is harmless for speech (there is
little useful energy below 80 Hz, and 8 kHz telephony has none below 300 Hz) but it
means the bottom few mel channels are nearly redundant, and it explains why models
tolerate high-pass filtering of their input.

### 2.7 Log-mel versus MFCC

The classical front end went one step further: apply a discrete cosine transform to
the log-mel vector and keep the first ~13 coefficients. These are **MFCCs**, and
the DCT served two purposes in a GMM-HMM world:

1. **Decorrelation.** Adjacent mel bins are highly correlated. Diagonal-covariance
   Gaussians model correlated features badly, so the DCT approximately
   diagonalised the covariance for free.
2. **Compression.** 13 numbers instead of 40, which mattered when the acoustic
   model was a mixture of Gaussians per state.

Neural networks removed both motivations. A network's first layer can learn any
linear transform, including the DCT, so decorrelation is not a favour you need to do
for it; and 80 inputs is not a burden. Worse, truncating to 13 coefficients throws
away spectral detail that a deep model can exploit. Hence the modern default is
**log-mel, un-DCT'd, 80 or 128 channels**. MFCCs survive in speaker-recognition
baselines, in keyword spotters where every multiply counts, and in legacy Kaldi
recipes.

One detail that persists: the **log** is not optional. It compresses the enormous
dynamic range of speech power into something with roughly stationary variance, and
it turns multiplicative channel effects (microphone response, room colouration)
into additive offsets that mean-normalisation can remove. Removing the log is the
fastest way to make a recogniser fail to converge.

---

## 3. From scratch

Below is a complete log-mel extractor that reproduces **Whisper's exact input
geometry**, verified against constants read from `openai/whisper`
`whisper/audio.py` (retrieved 2026-08-22): `SAMPLE_RATE = 16000`,
`N_FFT = 400`, `HOP_LENGTH = 160`, `CHUNK_LENGTH = 30`,
`N_SAMPLES = 480000`, `N_FRAMES = 3000`, and
`FRAMES_PER_SECOND = 100`. Standalone, numpy only.

```python
"""Whisper-geometry log-mel from scratch. numpy only."""
import numpy as np

SR, N_FFT, HOP, N_MELS = 16_000, 400, 160, 80

def hz_to_mel(f):  return 2595.0 * np.log10(1.0 + f / 700.0)
def mel_to_hz(m):  return 700.0 * (10.0 ** (m / 2595.0) - 1.0)

def mel_filterbank(n_mels=N_MELS, n_fft=N_FFT, sr=SR, fmin=0.0, fmax=None):
    """(n_mels, n_fft//2+1) triangular filters, unit peak height (HTK style)."""
    fmax = fmax or sr / 2
    # n_mels+2 edges give n_mels overlapping triangles
    edges = mel_to_hz(np.linspace(hz_to_mel(fmin), hz_to_mel(fmax), n_mels + 2))
    freqs = np.fft.rfftfreq(n_fft, 1 / sr)
    fb = np.zeros((n_mels, freqs.size), dtype=np.float32)
    for m in range(n_mels):
        lo, ctr, hi = edges[m], edges[m + 1], edges[m + 2]
        rising  = (freqs - lo) / (ctr - lo)
        falling = (hi - freqs) / (hi - ctr)
        fb[m] = np.maximum(0.0, np.minimum(rising, falling))
    return fb

def log_mel(x, n_mels=N_MELS):
    """float32 mono 16 kHz waveform -> (n_mels, n_frames) log-mel, Whisper scaling."""
    # torch.stft(center=True) pads by n_fft//2 with reflection. Reflection, not
    # zeros: zero padding injects an artificial discontinuity, i.e. broadband
    # leakage, into the first and last frames.
    xp = np.pad(x, N_FFT // 2, mode="reflect")
    n_frames = 1 + (xp.size - N_FFT) // HOP
    # One strided gather instead of a Python loop over frames.
    idx = np.arange(N_FFT)[None, :] + HOP * np.arange(n_frames)[:, None]
    # periodic Hann, matching torch.hann_window(N_FFT) default periodic=True
    win = np.hanning(N_FFT + 1)[:-1].astype(np.float32)
    power = np.abs(np.fft.rfft(xp[idx] * win, axis=1)) ** 2
    power = power[:-1]                    # whisper: stft[..., :-1]
    mel = power @ mel_filterbank(n_mels).T
    log_spec = np.log10(np.maximum(mel, 1e-10))
    log_spec = np.maximum(log_spec, log_spec.max() - 8.0)   # 80 dB floor
    log_spec = (log_spec + 4.0) / 4.0                       # -> roughly [-1, 1]
    return log_spec.T                                       # (n_mels, n_frames)

if __name__ == "__main__":
    x = (np.random.default_rng(0).standard_normal(30 * SR) * 0.05).astype(np.float32)
    L = log_mel(x)
    print("log-mel shape:", L.shape, "range:", (round(float(L.min()), 3),
                                                round(float(L.max()), 3)))
```

Measured on this machine `[MEASURED]`:

```
raw frames = 3001, after dropping the final frame = 3000   (whisper N_FRAMES = 3000)
log-mel shape (mels, frames) = (80, 3000), value range [-0.295, 1.250]
```

Three implementation details in that code are load-bearing, and each is a bug I
have seen shipped.

**`power = power[:-1]`.** Centre-padding a 480 000-sample chunk and hopping by 160
yields 3001 frames, but Whisper's encoder expects exactly 3000. The source line is
`magnitudes = stft[..., :-1].abs() ** 2` — it discards the final frame. Get this
wrong and you either crash on a shape mismatch or, worse, silently interpolate and
lose 10 ms of alignment on every 30-second window.

**`mode="reflect"`.** `torch.stft` with `center=True` reflect-pads. Zero-padding
instead creates a step discontinuity at both ends of the chunk, which by §2.2 is
broadband energy — a phantom transient in the first and last frames. On a
30-second chunk that is 2 frames of 3000 and you will never notice; on 200 ms
chunks in a streaming pipeline it is 2 of 20, and it degrades the first word of
every chunk.

**`np.hanning(N_FFT + 1)[:-1]`.** numpy's `np.hanning(N)` is the *symmetric*
window (first and last samples both zero); `torch.hann_window(N)` defaults to
`periodic=True`, which is the symmetric window of length $N+1$ with the last
sample dropped. They differ by one sample of phase, and it is exactly the
difference between COLA holding and not holding. Silent, small, and wrong.

The clamp-and-scale tail — `max(log, max-8.0)` then `(log+4)/4` — is Whisper's own
normalisation. The 8.0 is an 80 dB dynamic-range floor, computed **per chunk**,
which has a consequence worth flagging: the normalisation is not causal. In a
streaming setting you do not yet know the chunk maximum, so a faithful streaming
Whisper front end must either buffer the full window or accept a different
normalisation from training. This is one of several reasons Whisper is awkward to
stream, developed in [`../02-asr/05-streaming-asr.md`](../02-asr/05-streaming-asr.md).

---

## 4. How production does it

**`openai/whisper`** — `whisper/audio.py:log_mel_spectrogram` is the reference
implementation and it is 15 lines: `torch.stft` with a Hann window, drop the last
frame, matrix-multiply by a filterbank loaded from a bundled
`assets/mel_filters.npz`, then clamp/log10/scale. The filterbank is *precomputed
and shipped*, not derived at runtime — a deliberate choice that removes any
possibility of a librosa-version difference changing the model's input.
`n_mels` is 80 for all models up to `large-v2` and 128 for `large-v3`.

**`SYSTRAN/faster-whisper`** reimplements the same geometry over CTranslate2 and
computes the filterbank itself; **`ggml-org/whisper.cpp`** has its own C
implementation with an optional SIMD/Metal path. The invariant that matters: all
three must produce the *same* 80×3000 matrix as the training front end, because a
mismatched front end is indistinguishable from a badly trained model. If you ever
port a feature extractor, the acceptance test is a numerical comparison against
the reference on real audio, not a plot that looks similar.

**Kaldi and NeMo** take the classical path: `compute-fbank-feats` and NeMo's
`AudioToMelSpectrogramPreprocessor` default to a Hamming/povey window, per-feature
mean-variance normalisation, and optional dither and pre-emphasis. NeMo also
applies `log(x + 1e-5)` rather than a clamped `log10`, and normalises per
utterance. None of these choices is better in the abstract; all of them must match
what the checkpoint was trained with.

**Where the mel convention bites.** `librosa.filters.mel` defaults to
`norm='slaney'` and `htk=False`, which uses a piecewise linear-then-log mel curve
rather than the single analytic formula in §2.6. Feeding Slaney-normalised
features to an HTK-trained model, or vice versa, produces a model that works but is
measurably worse — the classic "our WER is 2 points higher than the paper and we
cannot find why".

**Feature caching.** For training, features are computed once and stored; the
standard formats are Kaldi archives (`.ark`/`.scp`) or Lhotse manifests. For
inference they are computed on the fly, because storing them costs more bandwidth
than the audio: 80 float32 values every 10 ms is $80 \times 4 \times 100 = 32$
kB/s, versus 32 kB/s for 16-bit PCM at 16 kHz. Exactly break-even in float32, and
4× worse than the audio if you were storing 8-bit compressed speech. Feature
caching is a training optimisation only.

---

## 5. At scale

**Feature extraction is not your bottleneck, and you should still not do it twice.**
One second of audio requires 100 FFTs of length 400, roughly $100 \times 400
\log_2 400 \approx 3.5 \times 10^5$ butterfly operations, plus an
$80 \times 201$ matrix-vector product per frame. That is on the order of a few
million floating-point operations per second of audio — microseconds of a modern
core. The encoder that consumes those features costs three to five orders of
magnitude more. The practical rule: never optimise the front end, but never run it
redundantly either. A pipeline that extracts mels for the ASR, again for a VAD, and
again for a diarizer is paying three times for an identical matrix.

**Numerical precision.** float32 throughout is standard and sufficient; the log
floor at $10^{-10}$ is well above float32's denormal range. Doing the FFT in
float16 is a false economy — the dynamic range of a power spectrum spans more than
float16's ~5 decades, so quiet frames underflow to the log floor and become
indistinguishable from silence. Keep the front end in float32 even when the model
runs in float16 or int8.

**Batching.** Feature extraction is embarrassingly parallel across sessions and
across frames, so it batches perfectly. The subtlety is that batching requires
equal-length inputs, which for a 30-second-window model such as Whisper means
padding every utterance to 480 000 samples. A 2-second utterance therefore costs
the same encoder pass as a 30-second one — a 15× waste that is the single largest
inefficiency in naive Whisper serving, and the reason production systems
VAD-segment and batch by similar duration. See
[`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md).

**Streaming and the normalisation trap.** §3 noted that Whisper's per-chunk
max-based normalisation is non-causal. At scale this shows up as a quality
difference between your offline evaluation (full 30-second chunks, correct
normalisation) and your live traffic (short chunks, different normalisation), which
looks like a mysterious train/serve skew. The fix is to evaluate on chunks of the
same geometry you serve, which is a general principle worth stating once:
**evaluate the front end you deploy, not the one you trained with.**

**Memory arithmetic per session.** A 30-second float32 log-mel buffer is
$80 \times 3000 \times 4 = 960$ kB, plus the 480 000-sample float32 audio buffer at
1.92 MB. At 1000 concurrent sessions that is under 3 GB of feature state — real,
budgetable, and often forgotten when sizing agent workers.

---

## 6. Exercises

**E1.2.1** Synthesise a 1000 Hz sine at 16 kHz in a 512-point frame, then again at
1015.625 Hz (exactly 32.5 bins). Compute the fraction of total energy outside ±3
bins of the peak for rectangular, Hann, Hamming and Blackman windows. Rank the
windows, then explain why the ranking differs from the peak-side-lobe column of the
§2.3 table.

**E1.2.2** Verify the COLA condition numerically for a Hann window at hops
$N/2$, $N/3$, $N/4$ and $N \cdot 0.4$. For each non-compliant hop, compute the
amplitude ripple in dB and the frequency at which that ripple would be heard.
State which hops are safe for a synthesis pipeline.

**E1.2.3** Reproduce the §2.5 resolution table for a Hamming window instead of
Hann. Predict, before measuring, whether the resolution threshold moves, and
justify the prediction from the main-lobe-width column of §2.3.

**E1.2.4** Take the `log_mel` implementation from §3 and deliberately break each of
the three load-bearing details in turn (drop `power[:-1]`, switch to zero padding,
use `np.hanning(N_FFT)` directly). For each, quantify the change: output shape,
maximum absolute difference in the log-mel matrix, and which frames are affected.
Rank the three bugs by how hard they would be to detect in production.

**E1.2.5** Implement the Slaney-normalised filterbank alongside the HTK one and
compute the per-channel ratio between them. Which mel channels differ most, and by
how many dB? Explain why this constitutes a train/serve skew rather than a bug.

**E1.2.6** Add a DCT to produce 13 MFCCs from the 80 log-mels, then reconstruct the
log-mel vector from those 13 coefficients. Report the reconstruction error per mel
channel. Which spectral features are unrecoverable, and name one phoneme
distinction that depends on them.

**E1.2.7** Compute the total float operations per second of audio for the §3
extractor, then measure its actual wall-clock throughput on 60 seconds of audio.
Report the ratio of achieved to theoretical throughput and explain the gap in terms
of memory traffic rather than arithmetic.

---

## 7. Interview drill

> "We fine-tuned Whisper on our call-centre data and offline WER improved from 14%
> to 9%. In production it is 16% — worse than the base model. The model file is
> identical. Where do you look?"

The phrase "the model file is identical" is the hint: if the weights are right and
the output is wrong, the *input* is wrong. This is a front-end mismatch, and the
candidate should reach for that class of explanation before touching the model.

The specific hypotheses, in order of likelihood. First, **chunk geometry**: offline
evaluation almost certainly fed full 30-second windows while production feeds
short VAD-segmented chunks, so Whisper's per-chunk 80 dB normalisation floor is
computed over a completely different distribution — a 1.5-second chunk of quiet
speech normalises differently from a 30-second chunk containing one loud moment.
Second, **resampling path**: if training data arrived as 8 kHz telephony upsampled
to 16 kHz, the spectrum above 4 kHz is empty, and any production audio that
genuinely has content there is out of distribution. Third, **a different extractor
in the serving stack**: faster-whisper, whisper.cpp and the reference
implementation must agree numerically, and a Slaney-vs-HTK filterbank difference or
a periodic-vs-symmetric Hann window is exactly the kind of 1–2 point regression
that never shows up in a code review.

The diagnostic is cheap and should be stated concretely: take ten production
utterances, run them through both front ends, and compare the log-mel matrices
element-wise. If the max absolute difference is not near float32 epsilon, you have
found it. If the matrices match, only then move on to the acoustic hypotheses —
and the next test is to evaluate offline using production chunk geometry, which
converts "mysterious regression" into a reproducible number.

The general principle to close on: **the feature extractor is part of the model.**
Version it, test it numerically, and evaluate with the geometry you serve.

---

## Sources

- `openai/whisper`, `whisper/audio.py` (main branch, retrieved 2026-08-22) — `SAMPLE_RATE=16000`, `N_FFT=400`, `HOP_LENGTH=160`, `CHUNK_LENGTH=30`, `N_SAMPLES=480000`, `N_FRAMES=3000`, `FRAMES_PER_SECOND=100`, `TOKENS_PER_SECOND=50`, and `log_mel_spectrogram` including the `stft[..., :-1]` truncation and the `(log_spec + 4.0) / 4.0` scaling quoted in §3.
- Harris, F. J. (1978). *On the use of windows for harmonic analysis with the discrete Fourier transform.* Proc. IEEE 66(1), 51–83. The canonical source for the window-parameter table in §2.3; the values there were re-measured independently for this chapter.
- Stevens, S. S., Volkmann, J. & Newman, E. B. (1937). *A scale for the measurement of the psychological magnitude pitch.* JASA 8(3), 185–190. Origin of the mel scale.
- Davis, S. & Mermelstein, P. (1980). *Comparison of parametric representations for monosyllabic word recognition in continuously spoken sentences.* IEEE TASSP 28(4), 357–366. The MFCC paper.
- Cooley, J. W. & Tukey, J. W. (1965). *An algorithm for the machine calculation of complex Fourier series.* Math. Comput. 19, 297–301.
- Smith, S. W. *The Scientist and Engineer's Guide to Digital Signal Processing* — chapters 8–11 for the DFT and windowing, freely available; see [`../00-setup/04-reading-list.md`](../00-setup/04-reading-list.md).
- All `[MEASURED]` values in §2.2–§2.6 and §3 were produced locally on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2, float64 except where noted.
