# Answers

Worked answers to all **377 exercises** across 50 chapters.

---

## How to use this

**Do the exercise first.** These answers are written to check your reasoning, not to replace
it. Reading an answer to an exercise you have not attempted feels like understanding and is
not.

**Three kinds of exercise, three kinds of answer.**

| Kind | What the answer gives you |
|---|---|
| **Derivation** | The result, the load-bearing step, and the mistake that produces the wrong constant |
| **Measurement** | The expected magnitude and shape, plus what a surprising result means. Your exact numbers will differ — machines, seeds and data differ — and the answer says which digits should match and which should not |
| **Judgement** | A defensible position with its reasoning, and the strongest counter-argument. There is no single right answer, and an answer that cannot state the counter-argument is not finished |

**Where your number disagrees with the answer, suspect the answer second.** Several
measurements in this curriculum contradicted expectations and the chapters were rewritten
around the measurement, not the other way round — the media-edge latency result in
[`../06-realtime-systems/08-deployment.md`](../06-realtime-systems/08-deployment.md) and the
golden-audio metric in [`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md)
are both cases where the first version was wrong. But check your seed, your units and your
edge trimming first.

**Answers marked `[OPEN]`** have no single correct result — they ask you to measure your own
system or defend a choice. The answer gives the method and the criteria a good answer meets.

---

## 00-setup (23)

### 00-setup/01-environment.md

**E0.1.1** `[OPEN]` On the reference machine: 18 checks, 15 pass, 3 warn, 0 fail. The three
warnings were a wireless default input, missing `ffmpeg`, missing `espeak-ng`. A good answer
names which chapters each warning closes off — `ffmpeg` blocks any non-WAV corpus (so most of
`02-asr`'s evaluation work), `espeak-ng` blocks Piper and Kokoro (so `04-tts/05` and
`07-livekit/03`), and a wireless input silently invalidates every acoustic measurement in
`01-foundations` and `03-turn-taking`. A FAIL you choose to accept is not a choice; fix it.

**E0.1.2** The `c_contract` check catches it, at the round-trip assertion: with a scale of
32767, `-32768 / 32767 = -1.00003` fails the `f32.min() < -1.0` test. `c_struct` does not
catch it because the RIFF header is pure integer arithmetic and never touches the float
scale. The deeper point: 32768 is correct because int16 spans −32768…+32767 asymmetrically,
so dividing by 32768 maps to [−1, +0.99997] — inside the interval — while 32767 maps the
most-negative sample outside it. Clipping later hides the bug and loses the sample.

**E0.1.3** The check is four lines: record 2 s with `sd.rec`, compute
`float(np.sqrt(np.mean(x.astype(np.float64)**2)))`, and fail if it is exactly `0.0`. The
strict equality is deliberate — any real microphone returns a noise floor, so exact digital
zero across ~32000 samples is a permission decision rather than a quiet room. Verify with
`tccutil reset Microphone`, then run without accepting the prompt: you get frames, and they
are zeros. That is the failure mode with no exception attached.

**E0.1.4** Version comparison catches nothing here, because the incompatibility is at the ABI
level: `torch` 2.13.0 with `torchaudio` 2.10.0 may satisfy any version predicate you write and
still fail with `undefined symbol` on the first call into a compiled op. The check that works
is to *call* something — `torchaudio.functional.resample(torch.zeros(160), 16000, 8000)` —
inside a `try`, because loading the extension module is what surfaces the mismatch. Import
alone is sometimes not enough; the extension can be lazily loaded.

**E0.1.5** `[OPEN]` On the reference machine `sd.get_portaudio_version()` returned
`(1246976, 'PortAudio V19.7.0-devel, revision unknown')` and `brew list portaudio` showed
nothing — the library came from the wheel. If your machine has a brew-installed PortAudio,
you may be loading either copy, which is the duplicate-native-library hazard: check with
`otool -L` on `_sounddevice_data`'s library, and prefer removing the brew copy over guessing.

**E0.1.6** Reproduction: `import audioop` warns on 3.12 and raises `ModuleNotFoundError` on
3.13. A correct pure-Python µ-law encoder is the G.711 algorithm: bias the magnitude by 132,
find the segment (the position of the highest set bit above the segment base), take four
mantissa bits, assemble `sign | segment | mantissa`, then invert all bits. Decoding reverses
it. You should reproduce **37.2 dB** SNR on the reference sine at ±20000 amplitude to within a
few tenths of a dB — if you are several dB off, you have almost certainly omitted the bias or
the final complement.

**E0.1.7** `[OPEN]` The answer depends on your hardware, but the shape does not: devices
divide into those that accept 16 kHz mono int16 natively and those with a fixed native rate
(commonly 44100 or 48000) that PortAudio will not resample for you. For the latter, open at
the native rate and resample once, at the edge, with `soxr` — never open at a rate the device
rejects and never resample twice. The rule from
[`03-canonical-formats.md`](../00-setup/03-canonical-formats.md) applies: convert at
boundaries, not in the middle.

**E0.1.8** `[OPEN]` Under load the p95 frame lateness rises from sub-millisecond to
milliseconds or worse, and the connection to
[`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md) is the point: that
chapter measured the *same* quantity as 16.48 ms p50 inside an asyncio pipeline against a
true bound of 5.00 ms, and its spread ranged 18–48 ms across trials. So a timing assertion
tuned on an idle machine fails on a busy one, which is why the fix is a virtual clock rather
than a looser threshold.

### 00-setup/02-hardware-and-cost.md

**E0.2.1** `[OPEN]` On the reference machine: prefill-like 2903.3 GFLOP/s, decode-like 59.7
GFLOP/s on MPS — a **49× collapse** on the same device. The relation to the 69× per-token
prefill/decode gap measured in
[`../05-llm-layer/04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md) is that
they measure the same physics from two directions: a 1-row matmul cannot fill the machine, so
decode is memory- and dispatch-bound while prefill is compute-bound. The two ratios differ
(49 vs 69) because the LLM measurement includes attention and kernel-launch overheads that a
bare matmul does not.

**E0.2.2** Without `torch.mps.synchronize()` you measure *enqueue* time, not execution time,
because Metal dispatch is asynchronous. The reported MPS times collapse toward the cost of
appending to a command buffer, so the speedup becomes large and meaningless — often 10× or
more on the decode-like shape, which is precisely the shape where MPS is genuinely worst.
This is the single most common way GPU benchmarks lie, and the tell is a speedup that grows
as the tensor shrinks.

**E0.2.3** `[OPEN]` Expect fp16 to roughly double MPS throughput on the large shape and to
help much less on the thin one, because the thin shape is not compute-bound. Worth it for LLM
inference (where bf16 is the production default and the numerics are well understood); not
worth it for the DSP and loss-derivation work in `01-foundations` and `02-asr`, where you are
checking agreement to 1e-15 and fp16 destroys the comparison.

**E0.2.4** `[OPEN]` The reference stack — Silero VAD 0.01 + distil-large-v3 int8 0.70 +
Kokoro fp32 0.31 + a 1.7 B LLM int8 1.58 + its 8k KV cache 0.44 — totals **3.04 GiB** against
an 11.2 GiB budget, leaving 8.2 GiB. To leave at least 4 GiB free you can afford roughly
7 GiB, which admits an int8 8 B model (7.48) only if you shrink something else or cap context;
the honest configuration is the 1.7 B model, and the exercise's real lesson is that the *KV
cache at your target context* is what decides, not the weights.

**E0.2.5** The exact formula is
$2 \times \text{layers} \times \text{kv\_heads} \times \text{head\_dim} \times \text{ctx}
\times \text{bytes}$, where the factor 2 is K and V. The §3 approximation folds
`kv_heads × head_dim` into a single `kvdim = 1024`, which is right for a model with 8 KV heads
of 128 dims (GQA) and wrong by the GQA group size for one without it. For Llama 3.1 8B (32
layers, 8 KV heads, 128 head dim) the exact figure matches the approximation; for a
multi-head model with 32 KV heads it is 4× larger. Getting this wrong by the GQA factor is
how capacity plans go wrong by 4×.

**E0.2.6** `[OPEN]` Expect the metric and your ears to disagree, and the disagreement is the
finding. Int8 vocoder artefacts are typically a metallic or gritty quality concentrated in
high mel bands at low energy — exactly where a mean-absolute-log-mel distance under-weights
them. A good answer reports the mel dB delta, states whether it crossed the 0.10 dB gate, and
then says plainly whether it was audible. Where they disagree, trust your ears and add a
band-weighted metric.

**E0.2.7** `[OPEN]` Method: current on-demand price for the smallest GPU that fits your work
(an L4 at roughly $0.80/h is a reasonable anchor), against the purchase price of a used card
plus its electricity. At $0.80/h a $900 used 3090 breaks even at about 1125 hours ≈ 47 days of
continuous use. The honest conclusion for *learning* is that you will never reach it, because
the `[NEEDS GPU]` work here is six hours; the calculation flips only for sustained training or
a permanently-running service.

**E0.2.8** `[OPEN]` `sudo powermetrics --samplers cpu_power -i 1000 -n 20` during a long Part
A run gives package power directly. The 25 W figure is an estimate for sustained mixed
CPU/GPU load on an M5; laptops under GPU-heavy load can exceed it, and idle is far below. Any
value in the 10–40 W range leaves the conclusion intact: at $0.30/kWh the hourly cost is
between $0.003 and $0.012, which is three orders of magnitude below any rented GPU.

### 00-setup/03-canonical-formats.md

**E0.3.1** The statistic is mean $|x_n - x_{n-1}|$ computed under both interpretations: speech
is strongly low-pass, so consecutive correctly-ordered samples are close, while byte-swapping
scrambles the high byte and produces near-random jumps of order $2^{15}$. Pick the
interpretation with the smaller mean absolute difference. Expect near-100% accuracy on 1 s
segments and noticeably worse on 100 ms, because the discriminator has two blind spots: digital
silence is all-zero under both readings, and full-scale noise is high-entropy under both. A
good answer reports the accuracy *conditioned on the segment containing speech*, which is the
honest number.

**E0.3.2** Predicted alias for the 6 kHz tone decimated by 2 to 8 kHz: $|6000 - 8000| =
2000$ Hz, and the FFT peak should land there. With the band-limited `resample`, 6 kHz is above
the new 4 kHz Nyquist and is filtered out — you get near-silence, which is the correct
behaviour and looks like a bug the first time. The 4 kHz case is ambiguous because 4 kHz *is*
the new Nyquist: it maps to itself under $|f - kf_s|$, and a sinusoid sampled exactly at
Nyquist produces alternating $\pm A\cos\phi$ whose amplitude depends entirely on phase — at
$\phi = \pi/2$ every sample is zero. There is no well-defined answer, which is why Nyquist is
an open bound.

**E0.3.3** `[OPEN]` The measured loss for sibilants will be *larger* than the flat-noise
model's −11.1 dB, and the discrepancy is the point: /s/ is not spectrally flat. Its energy
peaks well above 4 kHz — typically 5–8 kHz — so a 3400 Hz lowpass removes a much greater
fraction of a sibilant's energy than it removes of a flat spectrum. That is precisely why the
8 kHz telephony channel produces systematic /s/–/f/–/θ/ confusions rather than uniform
degradation.

**E0.3.4** `[OPEN]` A-law is 13-bit input with A = 87.6, a different segment table from µ-law,
and the same `^ 0x55` even-bit inversion — bit-exactness against `audioop.lin2alaw` over all
65 536 inputs is achievable and is the only acceptable verification. The structural difference
that drives the SNR-versus-level comparison is that A-law's lowest segment is **linear** while
µ-law is logarithmic throughout with a bias, so the two laws differ most at the extremes.
Expect them within a decibel or so at −3 dBFS and to diverge at −50 dBFS; report which wins
from your own table rather than from memory, because the direction is commonly misstated.

**E0.3.5** A parser hardcoding offset 44 reads the first 200 bytes of the `LIST` chunk as
audio, producing loud garbage at the start. A parser that omits the `size & 1` pad byte
desynchronises immediately after the odd-sized `cue ` chunk, so every subsequent chunk header
is read one byte late and the parse fails or silently misinterprets. A correct reader walks the
chunk list, dispatches on the four-character code, and always advances by `size + (size & 1)`.

**E0.3.6** `[OPEN]` The naive framer allocates at least one `bytes` object per emitted frame,
plus whatever the buffer concatenation costs — commonly two allocations and a copy per 640-byte
frame. The `memoryview` version over a pre-allocated backing buffer allocates nothing per
frame. Expect a large throughput factor, because at 640 bytes the allocation and copy dominate
the useful work. Convert to concurrent streams by dividing frames/second by 50, since each
20 ms stream needs 50 frames/s — and note that the answer is usually "far more than you will
ever run on one core", which is the reassuring half of the result.

**E0.3.7** With 320-sample frames and 512-sample windows, $\gcd = 64$ and
$\mathrm{lcm} = 2560$, so the pattern repeats every **8 frames / 5 windows** — the adapter is
periodic, which is what makes it testable. Assert on sample indices: window $i$ must cover
exactly $[512i, 512i + 512)$, so the union of windows is contiguous and non-overlapping, which
is the property that proves no sample is dropped or duplicated. Frame counts cannot prove it,
because a bug that drops 192 samples still emits the right number of windows. Worst-case added
latency is one frame — 20 ms — incurred when the buffer is short of 512 samples and must wait
for the next frame.

### 01-foundations/00-what-is-a-voice-agent.md

**E1.0.1** `[OPEN]` The distinguishing axes that matter: whether turn-taking is *learned or
scripted*, whether input is constrained (DTMF/grammar) or open, whether the system can be
interrupted, and whether state is a dialogue tree or a model's context. An IVR is scripted,
constrained, uninterruptible and tree-structured; a voice agent is none of those. The
diagnostic question for any product claim: "what happens if I interrupt it mid-sentence?"

**E1.0.2** The four hard problems are latency, turn-taking, interruption and error
compounding. Turn-taking and interruption are systems problems wearing ML costumes — both are
decided by policy and plumbing, and both were measured in this curriculum to be dominated by
non-model terms (endpointing is 33–44% of the latency budget; barge-in correctness is a
priority-path question). Error compounding is genuinely ML. Latency is both.

**E1.0.3** Batch is 3851 ms against 744 ms streaming — a **5.2×** difference — and the
mechanism is that batch serialises stage completions while streaming overlaps them: TTS starts
on the first clause rather than the last token. The corollary worth stating is that streaming
does not make any stage faster; it removes waiting.

**E1.0.4** `[OPEN]` A correct ecosystem map separates the *layers* (transport, ASR, LLM, TTS,
orchestration, telephony) from the *bundles* that sell several at once, and notes that the
bundles are where lock-in lives. The test of the map is whether it lets you price a swap.

**E1.0.5** `[OPEN]` Error compounding: if ASR is 95% accurate at the entity level and the LLM
is 97% correct given a correct transcript, the joint rate is 92%, and the user experiences the
product of every stage — which is the same series-system argument that
[`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md) makes
for availability, applied to correctness.

**E1.0.6** `[OPEN]` The answer should identify which of the four hard problems the chosen
product actually solved and which it avoided by constraining scope. Most shipped agents avoid
interruption difficulty by being terse.

**E1.0.7** `[OPEN]` A defensible boundary puts everything acoustic and real-time on one side
(VAD, endpointing, AEC, jitter) and everything semantic on the other, with the transcript as
the interface. The argument against it is that prosody carries meaning, which is exactly the
speech-to-speech case.

### 01-foundations/01-sound-and-sampling.md

**E1.1.1** The alias trajectory for naive decimation by 6 from 48 kHz to 8 kHz is the folded
frequency: with $f(t) = 100 + 1560 t$ Hz (a 100→7900 Hz sweep over 5 s) and $f_s = 8000$,
the observed frequency is $f_{\text{alias}}(t) = |f(t) - 8000\,\mathrm{round}(f(t)/8000)|$ —
that is, distance to the nearest multiple of 8 kHz. Because the sweep only reaches 7900 Hz, the
first fold occurs at $f = 4000$ Hz ($t = 2.5$ s), after which the apparent frequency
*descends* at the same 1560 Hz/s rate. Ten checkpoints should agree within 1% except very near
the fold, where the peak is broad. With the anti-alias filter at 3.6 kHz, the sweep simply
disappears above 3.6 kHz instead of folding — the correct behaviour.

**E1.1.2** Sampling $\cos(2\pi f n/f_s + \phi)$ and $\cos(2\pi (f_s - f) n / f_s + \phi')$:
the second equals $\cos(2\pi n - 2\pi f n/f_s + \phi') = \cos(2\pi f n/f_s - \phi')$. So the
two sequences are identical iff $\phi' = -\phi$, and for sines (where $\phi = -\pi/2$) they
are identical up to sign in general. The exact condition for identity *including* sign is
$\phi' = -\phi \pmod{2\pi}$; for a pure sine that means the alias is the negation, and for a
pure cosine ($\phi = 0$) the alias is identical with no sign flip. That cosine case is the one
to verify numerically, because it is the counterexample to "aliases are always negated".

**E1.1.3** For a full-scale triangle wave the RMS is $A/\sqrt{3}$ rather than $A/\sqrt{2}$, so
the SNR becomes $6.02b + 1.76 - 10\log_{10}(3/2) = 6.02b + 1.76 - 1.76 = 6.02b$ — the constant
vanishes exactly. For a full-scale square wave the RMS is $A$, giving
$6.02b + 1.76 + 10\log_{10}(2) = 6.02b + 4.77$. The one-sentence explanation of the square
wave: it spends all its time at full scale, so it uses the quantiser's entire range at every
instant and is therefore the best possible case — which is also why it is a useless test
signal.

**E1.1.4** `[OPEN]` Speech crest factors are typically 12–18 dB over speech-active frames, so
the SNR actually available is the theoretical figure minus the crest factor: at 16 bits,
98.1 − 15 ≈ 83 dB; at 12 bits, ≈ 57 dB; at 8 bits, ≈ 33 dB; at 6 bits, ≈ 21 dB. Most listeners
stop hearing a difference on headphones somewhere between 10 and 12 bits for speech, which is
why 16-bit is comfortable and 8-bit linear is not. Report the bit depth, not an impression —
the point of the exercise is the discipline.

**E1.1.5** A-law's structural difference from µ-law is that it is *linear* in its lowest
segment rather than logarithmic, because A-law's compression only begins above $1/A$ of full
scale. The consequence, visible in a level sweep, is that A-law has slightly better SNR at
very low levels and slightly worse near full scale than µ-law — and that A-law has no
"all-zeros" idle code problem. Round-trip idempotence over all 256 codes must hold exactly;
if it does not, you have almost certainly omitted the `^ 0x55` even-bit inversion.

**E1.1.6** `[OPEN]` Expect a substantial WER increase — typically a doubling or worse on
entity-heavy material — and the substitution errors should concentrate on sibilants and
fricatives, because /s/, /f/ and /θ/ are distinguished largely above 4 kHz and narrowband
discards it. If sibilants do *not* dominate, check that your band-limiting is actually
applying (a common bug is filtering after decimation, which does nothing useful).

**E1.1.7** `[OPEN]` Without dither, a fade-out into the noise floor produces harmonic
distortion that rises as the signal falls, because the quantisation error becomes correlated
with the signal — THD at −80 dBFS is typically tens of percent. With TPDF dither the
distortion is replaced by a constant, uncorrelated noise floor and THD collapses. Whether it
belongs in a production TTS path: probably not, because the output is about to be
lossily coded at 8–40 kbit/s and the codec's own noise dwarfs the difference — state that
reasoning explicitly, since it is the correct engineering answer and the opposite of the
audiophile one.

**E1.1.8** `[OPEN]` Using the Hillenbrand F3 distributions, a substantial minority of women's
tokens and a majority of children's have F3 above 3.4 kHz. That makes narrowband /r/ confusion
a real production risk rather than a curiosity — but only for populations skewed toward higher
formants. The measurement that settles it: entity WER on /r/-bearing words, segmented by
speaker group, on your own telephony traffic. A single aggregate WER cannot answer it.

### 01-foundations/02-time-frequency.md

**E1.2.1** `[OPEN]` Leakage falls as the window's sidelobes fall, and the ordering you should
measure is rectangular (worst, −13 dB first sidelobe) → Hann (−31 dB) → Hamming (−43 dB) →
Blackman (−58 dB), with main-lobe width increasing in the same order. That is the tradeoff:
you buy sidelobe suppression with frequency resolution. For speech, Hann is the default
because the tradeoff is balanced and the overlap-add properties are convenient.

**E1.2.2** The uncertainty relation is that a window of $N$ samples at rate $f_s$ resolves
frequencies no finer than roughly $f_s/N$ while localising time no better than $N/f_s$ — the
product is a constant. Concretely at 16 kHz: a 25 ms window (400 samples) resolves ~40 Hz,
enough to separate formants hundreds of Hz apart but marginal for a male $F_0$ of 120 Hz; a
50 ms window resolves ~20 Hz and resolves the harmonics, at the cost of smearing transients.
That is precisely the wideband/narrowband distinction.

**E1.2.3** `[OPEN]` The mel filterbank should be triangular, overlapping at half-power points,
and constructed from `2595·log10(1 + f/700)`. The verification that matters is reproducing
Whisper's `(80, 3000)` log-mel exactly for a 30 s input — which requires the `stft[..., :-1]`
truncation, `n_fft=400`, `hop=160`, and the same normalisation. If your shape is `(80, 3001)`
you have missed the truncation.

**E1.2.4** MFCCs died because the DCT that decorrelates mel energies exists to make diagonal
Gaussian covariances tractable, and neural networks do not need decorrelated inputs — they
learn the transform. Keeping the DCT throws away information for no benefit. What replaced
them is log-mel, and the modern answer to "why not raw waveform" is that log-mel is a cheap,
well-conditioned prior that saves the model from learning a filterbank.

**E1.2.5** `[OPEN]` A correct reading names the formant structure, distinguishes voiced from
unvoiced regions by harmonic structure versus broadband energy, and identifies at least one
transient. The test is whether you can locate a /s/ without being told.

**E1.2.6** `[OPEN]` Expect the FFT to beat a naive DFT by roughly $N/\log_2 N$ — three orders
of magnitude at $N = 4096$. The answer should note that this is why real-time STFT is possible
at all.

**E1.2.7** `[OPEN]` Zero-padding interpolates the spectrum without adding resolution: the
peaks move to finer grid positions but two close tones do not separate. Demonstrating that
distinction — interpolation versus resolution — is the whole exercise.

### 01-foundations/03-audio-io-and-buffering.md

**E1.3.1** `[OPEN]` A correct lock-free single-producer single-consumer ring buffer uses
separate read and write indices with atomic (or, in CPython, GIL-protected) updates and never
blocks. The property to verify is that a full buffer drops or overwrites deterministically
rather than corrupting, and that the callback never allocates.

**E1.3.2** The symptoms map one-to-one: underrun is a gap or click on *output* (the buffer
emptied), overrun is lost samples on *input* (the buffer filled). The diagnostic difference is
which side the discontinuity appears on. Both are almost always caused by doing work in the
callback; the fix is the same for both.

**E1.3.3** 100 ppm of clock drift is 100 µs per second, so 360 ms per hour — enough to
accumulate a full 20 ms frame every 200 seconds. In a call that means the capture and playback
clocks diverge by roughly one frame every three minutes, which a jitter buffer must absorb by
inserting or dropping. That is why NetEQ time-stretches rather than assuming a fixed rate.

**E1.3.4** `[OPEN]` Expect a clear latency/quality frontier: higher-quality resamplers have
longer filters and therefore more delay. The operating point for a voice edge is the shortest
filter whose passband error is inaudible, which in practice means a moderate-quality setting,
not the best available.

**E1.3.5** `[OPEN]` The buffering ladder from microphone to model typically has four or five
stages — hardware buffer, PortAudio buffer, ring buffer, frame assembler, model input — and
the total is the sum. The exercise's lesson is that each stage looks harmless and the total
does not.

**E1.3.6** `[OPEN]` Doing 30 ms of work in a 20 ms callback produces a guaranteed underrun
every callback, and the audible result is periodic clicking at 50 Hz. The fix is to enqueue
and return.

**E1.3.7** `[OPEN]` A good answer measures the actual callback duration distribution and
compares its p99 against the frame period — the only comparison that matters.

### 01-foundations/04-latency-budget.md

**E1.4.1** `[OPEN]` A correct budget for a cascaded agent allocates roughly: endpointing
300–500 ms, ASR finalisation 60–150, LLM first token 150–400, clause assembly 40–120, TTS
first byte 60–200, network and playout 30–150. The check is that the sum is under your target
and that you can name which term you would attack first — which should be endpointing, since
this curriculum measured it at 33–44% of the allocation in six independent designs.

**E1.4.2** Endpointing is a policy cost because the time is spent *waiting to be sure*, not
computing: a faster machine does not shorten it. That is why it is the only term you reduce by
changing a decision rule rather than by buying hardware, and why an adaptive endpointer
reached 330 ms at a *lower* cut-off rate (2.78%) than a fixed 700 ms timeout (3.04%).

**E1.4.3** Human turn-gap distributions centre around 200 ms with a long tail, and gaps of
several hundred milliseconds are unremarkable in natural conversation. The design implication
is that an agent responding in 200 ms is not obviously better than one responding in 500 ms —
but one responding in 1500 ms is clearly worse, and one that *interrupts* is worst of all.
That asymmetry is what justifies spending latency on endpointing certainty.

**E1.4.4** Little's law gives $L = \lambda W$, and for an M/M/1-like queue the wait grows as
$1/(1-\rho)$ — so at $\rho = 0.7$ the multiplier is 3.3 and at $\rho = 0.9$ it is 10. That
matches the measured queue p95 of 141 ms at $\rho = 0.70$ rising to 675 ms at $\rho = 0.90$, a
4.8× increase for a 1.29× increase in load. The lesson is that utilisation is not a linear
knob.

**E1.4.5** `[OPEN]` The three regimes — local, WebRTC and telephony — differ mainly in the
network and codec terms: local adds almost nothing, WebRTC adds jitter buffer plus RTT, and
telephony adds carrier delay plus an 8 kHz transcode. Expect 100–400 ms of spread between
them for identical model choices.

**E1.4.6** `[OPEN]` The measurement should show that the perceived latency is `eou_to_ttfa`,
not total response time, and that filler speech decouples them — which is the mechanism
measured at 1815 → 551 ms in
[`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md).

**E1.4.7** `[OPEN]` A defensible answer picks a target from the human turn-gap literature
(under about 800 ms to feel responsive), allocates it, and states which stage would have to be
cut if the target were halved.

**E1.4.8** `[OPEN]` The point of instrumenting your own pipeline is discovering that the
dominant term is not the one you assumed. Report the ranking, and check it against §2's
prediction that endpointing leads.

---

## 02-asr (64)

### 02-asr/01-from-hmm-to-e2e.md

**E2.1.1** `[OPEN]` A hand-worked Viterbi on a 3-state, 4-observation HMM should produce a
trellis where each cell is `max(prev * transition) * emission`, and the backpointer path is
the answer. The two places people err: forgetting that Viterbi maximises (forward-backward
sums), and working in linear probability until it underflows — do it in log space and the
arithmetic stays readable.

**E2.1.2** WFST composition buys you a single, statically-optimisable search graph:
H (HMM topology) ∘ C (context dependency) ∘ L (lexicon) ∘ G (grammar) collapses four
knowledge sources into one automaton that can be determinised and minimised offline. What
end-to-end removed is the explicit composition and the hand-built lexicon; what it silently
kept is *all four functions* — they are now implicit in the model's weights, which is why
contextual biasing had to be reinvented as shallow fusion.

**E2.1.3** Forced alignment is still used for: training data preparation (segmenting long
audio against a known transcript), evaluation of emission latency, and building word-level
timestamps for products — which is exactly what WhisperX does, because Whisper's own
timestamps are unreliable.

**E2.1.4** `[OPEN]` An n-gram LM's contribution shows up most on rare words and least on
function words. Expect a modest overall WER improvement and a large one on domain entities,
which is the same asymmetry that makes entity WER the better metric.

**E2.1.5** GMM-HMM to DNN-HMM replaced the emission model and kept everything else — the
topology, the lexicon, the decoder. That is why it was adopted so quickly: it was a drop-in
improvement to one component of a system nobody had to rebuild.

**E2.1.6** `[OPEN]` The lexicon's role is to define which phone sequences are legal words. Its
failure mode is out-of-vocabulary: a word absent from the lexicon literally cannot be
recognised, which is why end-to-end models' open vocabulary was such a practical win and why
they instead *hallucinate* plausible words.

**E2.1.7** `[OPEN]` A good answer names what a modern system still owes to WFSTs: beam search
with an LM, the notion of a decoding graph, and every biasing technique.

### 02-asr/02-ctc-from-scratch.md

**E2.2.1** Replacing `_logsumexp` with integer addition and dropping the emission term turns
the forward recursion into a **path counter** — it counts valid CTC alignments rather than
summing their probabilities, which is the clearest way to see that the recursion is a
combinatorial object with probabilities bolted on. The count should match
$\binom{T + U - r}{2U}$ across the 500 random pairs, where $r$ is the number of adjacent
repeats in $y$. The count is exactly zero when $T$ is too small to fit the extended label
sequence: you need $T \ge U + r$, because every adjacent repeat requires an intervening blank.
The smallest example is $y = \texttt{aa}$ ($U = 2$, $r = 1$) at $T = 2$ — one frame short.

**E2.2.2** (a) Dropping `z[s] != blank` lets a path skip *over a blank*, so two distinct
labels can be emitted on consecutive frames without the separating blank the extended sequence
requires. It inflates the alignment count and therefore *lowers* the loss; it disagrees on the
very first two-label target, e.g. `ab` at small $T$. (b) Dropping `z[s] != z[s-2]` lets a path
skip between two *identical* labels, so `aa` becomes reachable without the blank that stops it
collapsing to `a` — it disagrees on the first target containing an adjacent repeat, e.g. `aa`,
and again lowers the loss. (c) Allowing the skip unconditionally is both bugs at once and
disagrees on whichever of the two appears first. In every case the loss is too *low*, which is
the tell: a CTC bug that makes training look better is almost always an over-permissive lattice.

**E2.2.3** The finite-difference error is U-shaped because it is the sum of two terms moving in
opposite directions: truncation error falls as $O(h^2)$ for central differences, while
cancellation error from subtracting two nearly-equal floats grows as $O(\varepsilon/h)$.
Minimising the sum gives $h \approx \varepsilon^{1/3}$, which for float64
($\varepsilon \approx 2.2 \times 10^{-16}$) is about $6 \times 10^{-6}$ — so of
$\{10^{-3}, 10^{-5}, 10^{-7}\}$ the minimum is at **$10^{-5}$**, with $10^{-3}$ dominated by
truncation and $10^{-7}$ by cancellation.

**E2.2.4** The linear-probability version underflows because it multiplies $T$ per-frame
probabilities, each on the order of $1/|V|$. With float32's smallest subnormal at about
$1.4 \times 10^{-45}$ — $\log_2 \approx -149$ — and roughly 2 bits lost per frame at
$|V| = 4$, expect an exact 0.0 somewhere near $T \approx 75$, and a >1% disagreement
considerably earlier, once the trailing mantissa bits are gone. The comparison to
$\log_2(\text{min subnormal})$ is the point: the failure $T$ is predictable from the float
format, which is why log-space is not an optimisation but a correctness requirement.

**E2.2.5** `[OPEN]` The construction needs a **decoy prefix that dominates early and dies
late**: give the decoy high probability in the first few frames so it occupies both beam slots
at width 2, then make its continuations near-zero while the true winner — ranked third early
on — has strong continuations. At width 2 the winner is pruned before it recovers; at width 4
it survives. Greedy beats width 2 here because the per-frame argmax path happens to follow the
winner, which is exactly the case that makes people distrust beam search. Report the matrix and
all three transcripts; the value is in seeing that beam search is not monotone in width unless
you keep enough hypotheses.

**E2.2.6** $\beta$ is needed because $\log p_{\text{lm}}$ is negative and accumulates *per
symbol*, so adding it to the acoustic score systematically penalises longer hypotheses — the
classic length bias of any per-token log-probability. Without a $+\beta|y|$ bonus, shallow
fusion shortens transcripts and deletes words, and the WER improvement you expected becomes a
deletion-heavy regression. The region where the top hypothesis changes is a wedge in
$(\alpha, \beta)$: too little $\beta$ for a given $\alpha$ deletes, too much inserts.

**E2.2.7** `[OPEN]` Expect (a) a blank fraction of roughly 70–90% of output frames and (b) a
spike width at half maximum of one to two frames — that is peaky posteriors made concrete, and
it is why CTC timestamps are poor. The signed offset should show the spike **lagging** the
acoustic onset, typically by tens to low hundreds of milliseconds, because the model must
observe enough of the phone to commit and a streaming encoder adds its lookahead on top. A lead
would indicate you had mis-aligned your reference.

**E2.2.8** CTC factorises the path probability as $\prod_t P(z_t \mid x)$ — the frames are
conditionally independent given the input. Suppose it assigns positive probability to both
`ab` and `ba`. Then some frame must have positive probability on `a` and some on `b`, and by
independence *every* combination of those per-frame choices has positive probability —
including paths that collapse to `a`, `b`, `aa` or `bb`. So $P(\text{something else}) > 0$
necessarily, and the required distribution is unreachable for any $T$ and any posteriors. The
smallest fix is to make the output distribution depend on previously emitted labels, which
breaks the factorisation; the model family that made exactly that change is the **transducer**
(RNN-T), whose predictor network conditions on the emitted prefix.

### 02-asr/03-rnnt-transducer.md

**E2.3.1** The RNN-T lattice is $T \times U$ because at each point you may either emit a label
(move in $U$) or advance time (move in $T$), and the loss sums over all monotonic paths from
$(0,0)$ to $(T,U)$. The recursion is
$\alpha(t,u) = \alpha(t-1,u)\,\varnothing(t-1,u) + \alpha(t,u-1)\,y(t,u-1)$, and the
anti-diagonal identity — that the sum along any anti-diagonal is conserved — is the check
worth implementing; the reference matched to 1.8e-15.

**E2.3.2** Agreement with `torchaudio.functional.rnnt_loss` should reach ~3e-7 in float32,
which is the reference figure. Better than that means you are in float64; worse usually means
a blank-index or a padding-mask error.

**E2.3.3** The memory blow-up is $O(B \cdot T \cdot U \cdot V)$ for the joint network's output
— every lattice cell holds a full vocabulary distribution. At $B=16$, $T=500$, $U=50$,
$V=1000$ that is 400 M floats, 1.6 GB in fp32, for one batch. The mitigations are pruned loss
(compute only a band around a trial alignment, cutting $U$ to a constant) and a stateless
predictor (which shrinks the predictor but not the joint).

**E2.3.4** `[OPEN]` A stateless predictor conditions on only the last one or two labels rather
than the full history. It costs a little accuracy and buys a large simplification in streaming
decoding, because the decoder state becomes trivially cacheable.

**E2.3.5** `[OPEN]` Streaming RNN-T decoding emits when the joint network's argmax is
non-blank, and the emission-latency knob is the encoder's lookahead. Expect a monotone
frontier: more lookahead, better WER, worse latency.

**E2.3.6** `[OPEN]` Expect pruned loss to cut peak memory by an order of magnitude with
negligible WER change — that is why it is the default in icefall.

**E2.3.7** `[OPEN]` The comparison against CTC should show RNN-T winning on output-dependency-
sensitive material (spelled words, numbers) and costing more to train.

### 02-asr/04-attention-and-whisper.md

**E2.4.1** Every Whisper decoding heuristic is a defence: `temperature` fallback
`(0.0, 0.2, 0.4, 0.6, 0.8, 1.0)` escapes a degenerate greedy loop;
`compression_ratio_threshold = 2.4` detects repetition by gzip ratio;
`logprob_threshold = -1.0` detects low confidence; `no_speech_threshold = 0.6` detects
silence being transcribed; `condition_on_previous_text = True` improves coherence *and* is the
mechanism by which a hallucination propagates. Each one exists because the model fails in that
specific way.

**E2.4.2** The constants: `SAMPLE_RATE = 16000`, `N_FFT = 400` (25 ms), `HOP_LENGTH = 160`
(10 ms), `CHUNK_LENGTH = 30`, `N_SAMPLES = 480000`, `N_FRAMES = 3000`,
`TOKENS_PER_SECOND = 50`. The 30 s chunk is the architectural constraint that everything else
works around — Whisper cannot see less or more, so short audio is padded and long audio is
windowed.

**E2.4.3** `[OPEN]` Hallucination shows as fluent text unsupported by the audio, often
repeating a phrase or emitting a training-set artefact ("Thank you for watching") on silence.
Repetition shows as a loop. Both are visible in the transcript alone: check the compression
ratio and look for text during known-silent spans.

**E2.4.4** `[OPEN]` Expect faster-whisper (CTranslate2 int8) to be several times faster than
`openai-whisper` on the same hardware, whisper.cpp competitive with Metal, and
distil-large-v3 roughly twice the speed of large-v3 at a small WER cost. Measure on your own
audio; the ordering is stable, the ratios are not.

**E2.4.5** `[OPEN]` The 30 s window means a 2 s utterance costs the same forward pass as a
28 s one, so batching short utterances is the optimisation — which is exactly what a streaming
wrapper cannot do.

**E2.4.6** `[OPEN]` Timestamp tokens are `<|{i*0.02:.2f}|>` for `i in range(1501)`, giving
20 ms granularity over 30 s. Their unreliability is why WhisperX exists.

**E2.4.7** `[OPEN]` `EnglishTextNormalizer` deletes fillers via `\b(hmm|mm|mhm|mmm|uh|um)\b`,
which changes WER whenever your reference keeps them. Report both normalised and
un-normalised WER, always.

### 02-asr/05-streaming-asr.md

**E2.5.1** Chunked ASR runs a non-streaming model on overlapping windows; truly streaming ASR
has a causal (or bounded-lookahead) encoder and emits incrementally. The observable difference
is that chunked output can *change* arbitrarily far back when a new chunk arrives, while
streaming output stabilises. That is why partial-versus-final needs to be an explicit API
contract.

**E2.5.2** `[OPEN]` Lookahead should trade monotonically: expect WER to improve and emission
latency to worsen as you add frames, with diminishing returns after a few hundred
milliseconds.

**E2.5.3** LocalAgreement emits the longest prefix on which the last $n$ hypotheses agree. It
converts an unstable stream into a stable one at the cost of one extra hypothesis-interval of
latency, and its parameter $n$ is exactly a stability/latency knob.

**E2.5.4** The contract that matters: partials may be revised, finals may not. Downstream
consumers must be told which they are receiving, and anything that triggers an action (a tool
call, an endpoint decision) must consume finals only — or must be idempotent under revision.

**E2.5.5** `[OPEN]` Expect Conformer/Zipformer to dominate on the WER/latency frontier and
Emformer to win on bounded memory.

**E2.5.6** `[OPEN]` The emission-latency measurement needs forced alignment as ground truth:
for each word, the delay between when it was spoken and when it was emitted.

**E2.5.7** `[OPEN]` A good answer notes that stabilisation and endpointing interact — a
stabiliser that holds text back delays the endpoint decision too.

### 02-asr/06-decoding-and-biasing.md

**E2.6.1** `[OPEN]` Beam width should improve WER with diminishing returns and linear cost;
beyond about 8–16 the gain is usually negligible for speech.

**E2.6.2** Shallow fusion adds $\lambda \log P_{\text{LM}}(y)$ to the acoustic score during
beam search. The two failure modes: too large $\lambda$ makes the model hallucinate fluent
text unsupported by audio, and an LM trained on mismatched text makes everything worse.

**E2.6.3** `[OPEN]` Contextual biasing on your own entity list should show a large entity-WER
improvement and a small overall-WER change — which is the whole point, and the reason to
measure entity WER separately.

**E2.6.4** ITN, punctuation and truecasing are separate problems because each has a different
ground truth and a different failure cost: ITN errors change meaning ("four one five" →
"4:15"), punctuation errors change parsing, truecasing errors are cosmetic. Bundling them into
one model makes the expensive errors invisible.

**E2.6.5** `[OPEN]` The measurement should show that biasing a term also raises its false-
positive rate — you will hear your product name where it was not said. Report both.

**E2.6.6** `[OPEN]` A good answer sets $\lambda$ by sweeping it against entity WER *and*
overall WER, and picks the knee rather than the entity optimum.

**E2.6.7** `[OPEN]` For spoken numbers the correct pipeline is ASR → ITN with context, and the
failure to plan for is that "one two three four" is a PIN, a year, or a quantity depending on
the carrier phrase — the same problem [`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)
measures at 14% → 86% recall.

### 02-asr/07-evaluation.md

**E2.7.1** WER is the Levenshtein distance over words divided by reference length, and the
normalisation trap is that the *normaliser* can change WER by more than a model upgrade —
deleting fillers, expanding contractions and folding numbers all move it. Report the
normaliser with the number, or the number is meaningless.

**E2.7.2** `[OPEN]` A bootstrap CI over utterances (resample with replacement, recompute WER,
take the 2.5th and 97.5th percentiles) typically gives ±1–2 points absolute on a few hundred
utterances — wide enough that most published model comparisons are not significant on small
sets.

**E2.7.3** Entity WER predicts task success better because task success depends on getting the
order number right, not the article. A 5% overall WER with every entity correct is a working
product; 5% concentrated in entities is not.

**E2.7.4** `[OPEN]` Latency-to-final should be reported as a distribution; its p95 is what
couples to the endpointing budget.

**E2.7.5** Endpoint F1 needs labelled turn boundaries, and the subtlety is that a "correct"
endpoint has a tolerance window — typically a few hundred milliseconds — so F1 depends on the
window you choose. State it.

**E2.7.6** `[OPEN]` Task success must be defined per domain and measured on outcomes, not
transcripts. If you cannot define it, you cannot claim it.

**E2.7.7** `[OPEN]` The comparison should show that WER on read speech (LibriSpeech-like) is a
poor predictor of WER on your telephony traffic — often off by a factor of two or more.

### 02-asr/08-serving-asr.md

**E2.8.1** `[OPEN]` Expect CTranslate2 int8 on CPU to be the strongest local option for
Whisper-family models, ONNX competitive, and TensorRT unavailable without CUDA. The ordering
is hardware-dependent; measure.

**E2.8.2** The quantisation caveat is that you must **re-measure WER**, because published
numbers are for published precisions. Int8 encoder quantisation is usually near-free; int8
everywhere is sometimes not.

**E2.8.3** Batching a streaming model is hard because each stream has its own state and its
own arrival time, so you are batching *across* sessions at each step — which is continuous
batching, and it needs the runtime to support ragged state.

**E2.8.4** `[OPEN]` GPU concurrency arithmetic: sessions per GPU = (VRAM − weights) / per-
session state, then check compute rather than memory. The same two-constraint structure as
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md).

**E2.8.5** `[OPEN]` Cold start dominated by weight loading; the fix is prewarming, and the
measured effect elsewhere in this curriculum was 2.74 s per call versus zero.

**E2.8.6** `[OPEN]` The self-host crossover for ASR was measured at roughly 1.2 M audio-
minutes/month — much later than TTS's ~56k — because vendor ASR is comparatively cheap at
$0.0048/min.

**E2.8.7** `[OPEN]` A defensible answer picks vendor below the crossover and states the
non-cost reasons that might override it: residency, latency, and vendor risk.

### 02-asr/09-diarization-and-speaker-id.md

**E2.9.1** `[OPEN]` The pipeline is VAD → segmentation → embedding → clustering, and the
failure that dominates real calls is overlapped speech, which classical clustering cannot
represent at all.

**E2.9.2** DER sums missed speech, false alarm and speaker confusion, and the collar
(typically 250 ms) around boundaries is what makes published numbers comparable — omit it and
your DER looks much worse.

**E2.9.3** `[OPEN]` Streaming diarization must commit to speaker labels before it has seen the
whole call, so it cannot re-cluster; expect materially worse DER than offline.

**E2.9.4** `[OPEN]` x-vectors versus ECAPA-TDNN: expect ECAPA to win clearly, and note that
embedding quality dominates clustering choice.

**E2.9.5** Speaker verification is an auth anti-pattern because a 2% EER is not an
access-control policy — at 1% FRR the false-accept rate is 4%, so 25 attempts — and because a
replay attack defeats it outright rather than statistically. Measured in
[`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md).

**E2.9.6** `[OPEN]` For a two-party phone call, channel separation beats diarization whenever
you have it — which is why SIP's two-leg structure is worth preserving.

**E2.9.7** `[OPEN]` A good answer notes that enrolling voiceprints creates biometric data
under GDPR Art. 9, adding a compliance burden in exchange for a weak factor.

---

## 03-turn-taking (35)

### 03-turn-taking/01-vad.md

**E3.1.1** `[OPEN]` Energy/ZCR is trivially cheap and fails on noise; the WebRTC GMM adds a
statistical model of speech versus noise spectra and holds up better; Silero adds a learned
representation and dominates both. Expect the ordering to be stable and the gap between
WebRTC and Silero to widen as SNR falls.

**E3.1.2** `[OPEN]` The ROC/DET curve makes the threshold a product decision because the two
error types have different costs: a false negative clips speech, a false positive triggers on
noise. Neither is symmetric with the other, so there is no "optimal" point without a cost
ratio — which is the same argument endpointing makes explicitly.

**E3.1.3** Optimising frame-level F1 produced 265 segments from 33 utterances because
frame-level accuracy rewards a threshold that flickers within a pause, and every flicker is a
segment boundary. The metric is right and the objective is wrong: what you want is *utterance*
segmentation, and the fix is a hangover — hold the speech state for a fixed period after the
probability drops — which reached F1 0.962 at 34 segments. Hysteresis (separate on/off
thresholds) does not fix it, because the problem is temporal, not a threshold-boundary
oscillation.

**E3.1.4** The Silero defaults are window `512 if sr == 16000 else 256`, `threshold = 0.5`,
`min_speech_duration_ms = 250`, `min_silence_duration_ms = 100`, `speech_pad_ms = 30`,
`max_speech_duration_s = inf`, plus a `neg_threshold`. Note that `min_silence_duration_ms` and
`speech_pad_ms` together *are* a hangover — the library ships the fix from E3.1.3 as a default.

**E3.1.5** `[OPEN]` Expect Silero to degrade gracefully with SNR while energy-based detection
collapses around 10–15 dB. The interesting measurement is at what SNR your production audio
actually sits.

**E3.1.6** `[OPEN]` The 512-sample window at 16 kHz is 32 ms, which is *not* the 20 ms frame
contract — so a frame-based pipeline must buffer. Noticing that mismatch is the exercise.

**E3.1.7** `[OPEN]` A defensible threshold choice states the cost ratio it assumes and shows
the segment count, not just F1.

### 03-turn-taking/02-endpointing.md

**E3.2.1** The asymmetric cost is that cutting a user off is far worse than dead air of the
same duration — users repeat themselves, lose confidence, and often talk over the recovery.
So the decision rule should be biased toward waiting, and the metric that matters is the
cut-off rate at a given latency, not latency alone.

**E3.2.2** The measured frontier: a fixed 700 ms timeout gave 3.04% cut-off; the adaptive
endpointer gave **2.78% at 330 ms**. That is better on *both* axes simultaneously, which is
what makes it a genuine improvement rather than a tradeoff — the fixed timeout is not on the
efficient frontier at all.

**E3.2.3** `[OPEN]` Prosodic features (falling pitch, final lengthening) help, and the honest
finding is that they help less than the literature suggests on real telephony audio, because
the pitch tracker degrades exactly where you need it.

**E3.2.4** `[OPEN]` The adaptive rule should shorten the timeout when the transcript looks
syntactically complete and lengthen it mid-clause. Report cut-off rate and mean delay
together; either alone is gameable.

**E3.2.5** `[OPEN]` A mid-sentence 900 ms pause is the input that separates a real endpointer
from a demo one. Expect a fixed timeout under 900 ms to cut it off every time.

**E3.2.6** `[OPEN]` The decision-theoretic framing: choose the wait $w$ minimising
$C_{\text{cut}} P(\text{still speaking} \mid w) + C_{\text{delay}} w$. Writing that down makes
the cost ratio explicit, which is the point.

**E3.2.7** `[OPEN]` Your own distribution of inter-word gaps is the input the policy needs;
expect a long tail and a mode around 100–200 ms.

### 03-turn-taking/03-semantic-turn-detection.md

**E3.3.1** A detector at AUC 0.510 is indistinguishable from a coin flip, so it is *worse*
than a fixed timeout — it adds latency and inference cost for no discriminative power. The
implication for buying one: demand the AUC on *your* audio, because a model trained on clean
read speech can be near-chance on 8 kHz telephony.

**E3.3.2** `[OPEN]` Fusion should be: run the semantic detector only during VAD silence (as
Smart Turn does), and use it to shorten an otherwise-conservative timer rather than to trigger
directly. That way a bad detector degrades to the timer instead of breaking the agent.

**E3.3.3** `[OPEN]` Calibration matters because the fused rule needs a probability, not a
score; expect the raw output to be badly calibrated and to need Platt scaling or isotonic
regression on held-out data.

**E3.3.4** `[OPEN]` The measurement should compare three policies — timer only, detector only,
fused — on cut-off rate and delay. Fused should dominate; if it does not, the detector is not
earning its place.

**E3.3.5** LiveKit's `livekit-plugins-turn-detector` is deprecated in favour of
`livekit.agents.inference.TurnDetector`, a unified *audio* end-of-turn detector replacing the
older English/multilingual text models. It needs `python -m livekit.agents download-files`,
stays under 500 MB of RAM, and its code is Apache-2.0 while the **weights are under the
LiveKit Model License** — which is the licensing detail to check before shipping.

**E3.3.6** Smart Turn v3.2 is BSD 2-clause with open datasets, training code and weights, 23
languages, audio-native on PCM, 8 MB int8 and 32 MB fp32 builds, and runs only during VAD
silence. The comparison against LiveKit's detector is mostly a licensing and portability
decision rather than an accuracy one.

**E3.3.7** `[OPEN]` A defensible answer refuses to ship any semantic detector without an
AUC measurement on production-representative audio, given E3.3.1.

### 03-turn-taking/04-barge-in.md

**E3.4.1** The four candidate signals are VAD speech-start, ASR partial text, a semantic
turn/interrupt classifier, and the client's own mute/PTT state. Act on **VAD plus a minimum
duration and word count** — VAD alone fires on coughs and backchannels — and treat ASR text as
confirmation rather than trigger, because waiting for text costs hundreds of milliseconds.

**E3.4.2** The TTS-flush race is that the interrupt and the audio it cancels travel the same
path, so the flush arrives behind the backlog. The zombie-TTS bug is cancelling a TTS task and
immediately starting another without awaiting the first, so two streams write to the same
output. Fixes: a priority interrupt path, and `await`ing cancellation before starting the
replacement — `Task.cancel()` is not synchronous.

**E3.4.3** Truncating to what was *heard* matters because the LLM's context otherwise contains
sentences the user never received, and the model then behaves as though they did — referencing
information it never delivered. The measured case: 14 words generated, 14 synthesised, **5
heard**. The correct truncation point comes from playback position, not from synthesis.

**E3.4.4** `[OPEN]` Backchannel discrimination needs duration and word-count minima; LiveKit's
defaults are `min_duration = 0.5`, `min_words = 0`, with a `backchannel_boundary` of
`(1.0, 1.0)`. Expect `min_words = 1` or 2 to help materially on noisy audio.

**E3.4.5** `[OPEN]` False-interruption recovery: `resume_false_interruption = True` with
`false_interruption_timeout = 2.0` resumes the agent's turn if the "interruption" produced no
transcript. That converts a spurious stop into a hesitation, which users forgive.

**E3.4.6** `[OPEN]` The async cancellation test should assert that no audio frame is emitted
after the interrupt, which is exactly the frames-after-interrupt measurement in
[`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md).

**E3.4.7** `[OPEN]` The client-side buffer is beyond your process, so the protocol needs an
explicit clear-and-mark exchange — Twilio's `clear` and `mark` are exactly this.

### 03-turn-taking/05-echo-and-aec.md

**E3.5.1** NLMS updates the filter as
$\mathbf{w} \leftarrow \mathbf{w} + \mu \frac{e \mathbf{x}}{\|\mathbf{x}\|^2 + \epsilon}$ —
the normalisation by input power is what makes the step size scale-invariant and the algorithm
usable on speech, whose level varies by tens of dB. Omitting $\epsilon$ makes it explode on
silence.

**E3.5.2** Without double-talk detection the adaptive filter treats the near-end speaker as
error to be cancelled, so it attenuates them by about **−10 dB**; with DTD holding adaptation
during double-talk, echo suppression reaches **+30.6 dB**. That 40 dB swing is why DTD is not
optional.

**E3.5.3** AEC must live on the client because it needs the *reference* signal — what was
played — time-aligned with what was captured, and only the device has both without a network
delay in between. Server-side AEC would need to model an unknown, varying delay.

**E3.5.4** `[OPEN]` `getUserMedia` with `echoCancellation`, `noiseSuppression` and
`autoGainControl` gives you libwebrtc's tuned APM free. Disabling them "for audio quality" is
the most common self-inflicted cause of an agent interrupting itself.

**E3.5.5** `[OPEN]` The telephony echo cases are hybrid echo from the analogue tail and
acoustic echo from a speakerphone; the carrier usually handles the former and nobody handles
the latter.

**E3.5.6** `[OPEN]` Expect convergence within a few hundred milliseconds of speech and
re-convergence after any path change; a moved microphone resets it.

**E3.5.7** `[OPEN]` A defensible answer notes that AEC failure and barge-in failure present
identically — the agent talks over the user — and gives the diagnostic that separates them:
does it happen only while the agent is speaking?

---

## 04-tts (35)

### 04-tts/01-tts-architectures.md

**E4.1.1** `[OPEN]` G2P failures are the ones users notice: proper nouns, homographs ("read",
"lead"), and acronyms. The acoustic model controls prosody; the vocoder controls timbre and
artefacts. Diagnosing which stage broke is a matter of listening for *what kind* of wrongness.

**E4.1.2** The lineage fixed successive problems: concatenative had perfect segments and
audible joins; parametric was smooth and buzzy; Tacotron learned prosody end-to-end and
inherited attention failures (skips, repeats); FastSpeech removed attention with explicit
durations; VITS unified the acoustic model and vocoder. Each step traded one failure mode for a
smaller one.

**E4.1.3** Griffin-Lim's spectral convergence improves 0.66 → 0.013 while waveform SNR stays
at **−3 dB** because the algorithm optimises magnitude agreement and phase is unconstrained —
a signal can match the target spectrogram closely and be waveform-wise unrelated. With true
phase the SNR is +36.8 dB. The lesson generalises: spectral metrics do not bound perceptual or
waveform error, which is the same trap the golden-audio measurement in
[`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md) falls into from the other
direction.

**E4.1.4** Piper is VITS in ONNX with espeak-ng for phonemisation; Kokoro is an 82 M-parameter
model with Apache-licensed weights, `<3.13,>=3.10`. Both are small enough to run in real time
on a laptop CPU, which is what makes local TTS a genuine option rather than a demo.

**E4.1.5** `[OPEN]` Expect HiFi-GAN-class vocoders to be dramatically better than Griffin-Lim
and dramatically cheaper than WaveNet — that combination is what made real-time neural TTS
practical.

**E4.1.6** `[OPEN]` The measurement should show that phoneme-level input beats grapheme-level
on proper nouns and that a lexicon fixes the specific words you care about.

**E4.1.7** `[OPEN]` A defensible engine choice states the licence, the phonemiser dependency,
and the measured `ttfb_tts` — in that order, because the licence can disqualify before the
quality matters.

### 04-tts/02-codec-lm-tts.md

**E4.2.1** RVQ achieves 17.29 dB from six small codebooks against about 1.4 dB per bit for
flat VQ because each stage quantises the *residual* of the previous one, so error falls
multiplicatively rather than requiring an exponentially larger codebook. The check that your
implementation is right: SNR should rise roughly linearly with the number of stages.

**E4.2.2** Semantic tokens carry linguistic content and are usually distilled from a
self-supervised model; acoustic tokens carry timbre and detail and come from the codec. The
reason the distinction matters is that an LM over semantic tokens generalises, while an LM over
acoustic tokens preserves voice — which is why the hierarchy exists, and why SpeechTokenizer's
distillation trick (making codebook 1 semantic) simplified everything.

**E4.2.3** `[OPEN]` Frame rate is the first-order decision: Mimi at 12.5 Hz gives 100 tokens/s
with 8 codebooks, EnCodec at 75 Hz gives 600. That 6× difference is 6× the autoregressive
steps and 6× the context consumption, which is why Mimi's design note says the low frame rate
exists "to limit the number of autoregressive steps in Moshi".

**E4.2.4** `[OPEN]` Zero-shot cloning latency is dominated by the reference encoding plus the
autoregressive generation; expect it to be materially worse than a fine-tuned single-speaker
model, which is the tradeoff.

**E4.2.5** `[OPEN]` Flow-matching TTS (Voicebox, F5-TTS) is non-autoregressive, so it is fast
per utterance and *not* streamable in the same way — you generate a whole span. That makes it
excellent for pre-rendered audio and awkward for a live agent.

**E4.2.6** `[OPEN]` Verify the bitrate arithmetic: frame rate × codebooks × bits per code.
Mimi's 12.5 × 8 × 11 = 1100 bit/s reproduces the published 1.1 kbit/s exactly, which is how
you know you read the config correctly.

**E4.2.7** `[OPEN]` The ethics answer must cover consent for the source voice, disclosure to
the listener (AI Act Art. 50), and watermarking — and note that Art. 50(2)'s machine-readable
marking obligation falls on the *provider* of the generating system.

### 04-tts/03-streaming-tts.md

**E4.3.1** `ttfb_tts` is the metric because it is the only TTS term on the critical path: once
audio is flowing, the rest is amortised. Total synthesis time matters for cost, not for
perceived latency.

**E4.3.2** The aggregator's adversarial cases: abbreviations ("Dr.", "St.", "e.g."), decimals
("3.14"), ellipses, quoted speech, and any token stream that ends mid-word. The rule that
survives them is to split on sentence-final punctuation *followed by whitespace and a capital*,
with a minimum clause length and a maximum wait — and to flush on a timeout regardless.

**E4.3.3** `[OPEN]` Bad splits damage prosody because the engine assigns sentence-final
intonation to a fragment, so "I can help you with" gets a falling contour. The measurement is
to synthesise the same text split well and badly and compare F0 contours.

**E4.3.4** `[OPEN]` Mid-utterance flush requires the engine to support cancellation and the
transport to support a clear; without both you get the 1220 ms of stale audio measured in
[`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md).

**E4.3.5** `[OPEN]` Phrase caching works because agents repeat themselves — greetings,
confirmations, fillers. Expect a high hit rate on a small cache, and note it is the only rung
of the fallback ladder that still works when TTS is what failed.

**E4.3.6** `[OPEN]` The `SynthesizedAudio` contract carries `frame`, `request_id`, `is_final`,
`segment_id` and `delta_text`; `AudioEmitter.initialize(..., frame_size_ms=200)` sets the
emission granularity, which trades `ttfb_tts` against per-chunk overhead.

**E4.3.7** `[OPEN]` A defensible aggregator states its maximum wait explicitly, because that
bound is what guarantees the agent eventually speaks.

### 04-tts/04-prosody-and-voice.md

**E4.4.1** `[OPEN]` Lexicon entries are the reliable fix for a specific mispronunciation; SSML
is the unreliable one, because support varies by engine and most modern neural engines ignore
most of it. Prefer a lexicon plus phoneme input.

**E4.4.2** `[OPEN]` en-US and en-IN differ on number grouping (lakh/crore), date order, and
currency phrasing. The failure is silent: the audio is fluent and wrong.

**E4.4.3** `[OPEN]` Emotion and style control is either a discrete label, a reference audio, or
a continuous embedding; all three are hard to make consistent across a call, which is the
persona-consistency problem.

**E4.4.4** `[OPEN]` Watermarking should be inaudible, survive codec round-trips, and be
detectable without the original. Most schemes fail the second condition at 8 kHz µ-law, which
is a real problem for telephony.

**E4.4.5** `[OPEN]` AI Act Art. 50(2) requires synthetic audio to be "marked in a
machine-readable format and detectable as artificially generated or manipulated", with
solutions "effective, interoperable, robust and reliable as far as this is technically
feasible" — a standard that acknowledges its own limits. In force 2 August 2026.

**E4.4.6** Even with NATO alphabet words, the residual confusions are within-set: "Mike" and
"November" share a nasal onset, and narrowband loss of high-frequency energy hurts any pair
distinguished by fricative detail. The reason is that narrowband discards content above
~3.4 kHz, where /s/, /f/ and /θ/ live
([`../01-foundations/01-sound-and-sampling.md`](../01-foundations/01-sound-and-sampling.md)).

**E4.4.7** `[OPEN]` The consent implementation plan needs: a consent record with speaker
identity, scope and timestamp; a disclosure utterance in the greeting; a revocation path that
actually deletes the voice model; and an audit trail. The hard part is revocation, because a
trained model does not forget.

### 04-tts/05-engine-selection.md

**E4.5.1** `[OPEN]` The decision table's axes: `ttfb_tts`, quality (MOS or A/B), licence, voice
availability, streaming support, and $/1000 min. Licence first, because it disqualifies.

**E4.5.2** The local TTS breakeven is around **56k audio-minutes/month**, far earlier than
ASR's ~1.2 M, because hosted TTS is priced per character and generates a lot of characters —
at $30/M chars and 25% agent talk time you are paying roughly $6.19 per 1000 call-minutes.

**E4.5.3** `[OPEN]` A fair A/B needs identical text, identical loudness normalisation, blinded
presentation and randomised order. Without loudness matching you are measuring level, not
quality.

**E4.5.4** `[OPEN]` On-prem constraints usually mean no vendor call at all, which restricts you
to Piper, Kokoro or a self-hosted commercial model — and makes voice selection the binding
limitation rather than quality.

**E4.5.5** `[OPEN]` Expect `ttfb_tts` to vary more between engines than steady-state
throughput does, and to be the number that decides the choice for a live agent.

**E4.5.6** `[OPEN]` The cost model should be per 1000 call-minutes, with agent talk fraction as
an explicit parameter — because changing it from 25% to 45% moved TTS from the third-largest to
the largest cost line in
[`01-design-interviews.md`](01-design-interviews.md).

**E4.5.7** `[OPEN]` A defensible recommendation names the traffic volume at which it flips, so
it survives growth.

---

## 05-llm-layer (39)

### 05-llm-layer/01-prompting-for-speech.md

**E5.1.1** `[OPEN]` Text-tuned models produce markdown, bullet lists, parentheticals, URLs and
long paragraphs — all unspeakable. The system prompt must forbid them explicitly and cap
length in *words*, because "be concise" is not a constraint. LiveKit ships
`DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` precisely because prompting
alone does not hold.

**E5.1.2** `[OPEN]` A length policy should be a hard word cap with an explicit escape ("if the
answer needs more, offer to continue"), because unbounded replies cost TTS characters, delay
the next turn, and give the user more to interrupt.

**E5.1.3** `[OPEN]` ASR-error robustness means the prompt tells the model that the transcript
may be wrong and how to recover — confirm entities, ask for spelling on failure, never assert a
misheard value back as fact.

**E5.1.4** `[OPEN]` Confirmation strategy: confirm before *mutations*, not before reads, and
confirm by reading back the parsed value rather than the raw transcript. Confirming everything
doubles the turn count.

**E5.1.5** `[OPEN]` Expect the annotated prompt to be dominated by negative constraints, which
is itself the finding: most of the work is suppressing text-native behaviour.

**E5.1.6** `[OPEN]` `SpeechSteeringOptions(disfluencies=True)` is on by default in LiveKit, with
`NonverbalOptions` covering laughing, breathing, sighing, crying, vocalizing and mouth sounds —
evidence that naturalness is now a configuration surface rather than a prompt trick.

**E5.1.7** `[OPEN]` A good answer measures the prompt change's effect on response length and
`ttfa`, not just on subjective quality.

### 05-llm-layer/02-context-and-memory.md

**E5.2.1** `[OPEN]` The conversation as a state machine means turn state, pending tool calls,
confirmed entities and the escalation flag are explicit fields rather than implicit in the
transcript. The benefit is that you can assert invariants on them.

**E5.2.2** Full history recomputed 62 tokens per turn against sliding-window-12's 213 —
counter-intuitively the *smaller* context recomputed more, because truncating the front
invalidates the prefix cache every turn. The window was 32% smaller and cost 3.4× the prefill.
That is the cache-stability lesson: append-only contexts are cheap, edited contexts are not.

**E5.2.3** RAG prepended cost 609 recomputed tokens against 184 appended, for the same reason —
putting retrieved content *before* the stable prompt destroys the shared prefix. Append
retrieved context, or place it after everything cacheable.

**E5.2.4** Speculative retrieval works because the user's intent is usually clear before they
finish speaking, and the retrieval can complete during the remaining speech and the endpointing
delay — hundreds of milliseconds of free time. The risk is wasted queries, which is cheap.

**E5.2.5** `[OPEN]` Memory tiers: turn-local (the transcript), session (confirmed entities and
state), and durable (per-user preferences and history). Each has a different schema, a different
retention and a different failure cost.

**E5.2.6** `[OPEN]` Summarisation belongs off the critical path — triggered after a turn
completes, not before the next one starts — because a synchronous summarisation adds its full
latency to `eou_to_ttfa`.

**E5.2.7** `[OPEN]` Transcript curation means deciding what enters the context: not raw
partials, not filler, and *truncated to what was heard* for assistant turns.

**E5.2.8** `[OPEN]` `gen_ai.conversation.compacted` exists in the OTel conventions precisely so
you can attribute a quality change to a compaction event — instrument it.

### 05-llm-layer/03-tools-and-agentic.md

**E5.3.1** Filler speech cut `ttfa` p50 from **1815 ms to 551 ms** and changed answer time not
at all. That is the whole argument: the user's perception is governed by when speech starts, and
the tool call proceeds underneath. It is the highest-leverage change available in a
tool-calling agent.

**E5.3.2** Speculative execution took a read from 1539 ms to 540 ms by starting the query on the
predicted intent before the turn ended. Safe for reads, requires idempotency for writes, and
wasteful only in the cheap direction.

**E5.3.3** Hedging took p95 from 3288 ms to 2351 ms at the cost of 1.2 wasted calls per turn;
deadline enforcement took p99 from 4956 ms to 2961 ms at 3.1% degraded answers. Both trade
resources or quality for tail latency, and both are worth it — but hedging is the one that
amplifies load on a struggling dependency, so it needs a retry budget.

**E5.3.4** Idempotency keys make a retried mutation safe. The subtlety in voice is that the
*user* may also retry ("did that go through?"), so the key must be derived from the intent, not
from the attempt — otherwise a re-asked question creates a second charge.

**E5.3.5** `[OPEN]` Spoken error recovery should name what failed in user terms, offer an
alternative, and never expose an error code. "I couldn't reach the booking system — I can take
your details and call you back" is a successful outcome.

**E5.3.6** `[OPEN]` A constrained state machine beats pure LLM agency wherever the set of legal
actions is small and the cost of a wrong one is high — payments, cancellations, medical triage.
Pure agency wins where the space is open and errors are recoverable.

**E5.3.7** `[OPEN]` Handoff needs the transcript, the confirmed entities and the reason —
delivered to the human before they speak, or the handoff makes things worse.

**E5.3.8** `[OPEN]` The capability limit at the tool boundary is the real guardrail: cap
amounts, require the authenticated identity server-side, allow-list transfer destinations. Then
a successful prompt injection costs a bounded amount, which is the assumption
[`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)
builds on.

### 05-llm-layer/04-serving-llms-fast.md

**E5.4.1** Prefill is ~0.09 ms/token and decode ~6.37 ms/token — a **69×** gap — because
prefill processes the whole prompt in parallel while decode is one token per forward pass,
bound by memory bandwidth. So TTFT is dominated by prompt length and TPOT by nothing you can
parallelise except batching.

**E5.4.2** KV-cache hits saved 85.1% at 1024+128 tokens and 94.0% at 2048+64 — the saving grows
with the prefix-to-generation ratio, which for a voice agent with a long system prompt and a
short reply is exactly the favourable regime.

**E5.4.3** Static batching gave `ttft` p50 **489 ms** against continuous batching's **15 ms**,
because static batching makes an arriving request wait for the batch to form and for the
slowest member to finish. For interactive voice the difference is the product.

**E5.4.4** Chunked prefill only paid on a cold cache (tpot p95 41.3 → 33.7 ms). With a warm
prefix cache there is little prefill left to chunk, so the optimisation is redundant — which is
a useful reminder that serving optimisations interact.

**E5.4.5** Speculative decoding failed here: acceptance $\alpha = 0.44$ at $k=2$ with a
draft-to-target cost ratio of 0.56, so the predicted *and* measured speedup was below 1. The
break-even needs the cost ratio below about 0.32. The lesson: speculation is only worth it when
the draft model is much cheaper *and* well-aligned, and a distilled sibling is often neither.

**E5.4.6** `[OPEN]` Structured output without a latency tax means constrained decoding (a
grammar or JSON schema enforced at the sampler) rather than a second pass or a retry loop.

**E5.4.7** `[OPEN]` Model size versus quality for voice: expect a small model to be adequate for
the conversational surface and inadequate for reasoning-heavy tool selection, which argues for
routing rather than a single choice.

**E5.4.8** `[OPEN]` Local Apple Silicon serving via MLX or llama.cpp is viable to about 8 B at
int8; see [`../00-setup/02-hardware-and-cost.md`](../00-setup/02-hardware-and-cost.md) for the
memory arithmetic, and note the KV cache is the binding term.

### 05-llm-layer/05-persona-design.md

**E5.5.1** Chatty versus terse produced **+324% agent speech**, 2× call length, and TTS cost
from $6.93 to $29.40 per 1000 calls. Persona is therefore a cost decision and a latency
decision, not a branding decision — which is the finding worth carrying into any design review.

**E5.5.2** `[OPEN]` Pace interacts with barge-in: a faster agent gives the user a shorter window
to interrupt any given phrase, so the interruption experience changes without touching the
interruption code.

**E5.5.3** `[OPEN]` Register and verbosity should be specified as measurable constraints — words
per turn, sentences per turn, permitted disfluencies — because adjectives do not survive contact
with a model.

**E5.5.4** `[OPEN]` Consistency across providers is hard because voice identity, pace and
disfluency support differ; the portable part is the *text* policy, so keep persona in the prompt
and voice in configuration.

**E5.5.5** `[OPEN]` Error and refusal behaviour is where persona matters most, because it is
where users are already frustrated. Specify it explicitly.

**E5.5.6** `[OPEN]` Narrowband telephony has already removed cues (300–3400 Hz), so a persona
relying on subtle timbre will not survive the channel — design for the worst channel you serve.

**E5.5.7** `[OPEN]` The measurement should show persona changing `interruption_rate` and turns
to resolution, not just perceived warmth.

**E5.5.8** `[OPEN]` A defensible persona document states the metrics it is expected to move and
by how much, so it can be falsified.

---

## 06-realtime-systems (64)

### 06-realtime-systems/01-transports.md

**E6.1.1** `[OPEN]` TCP with a 200 ms application buffer should beat plain RTP on usable frames
at high loss — because it eventually delivers everything and the buffer covers the
retransmission — while costing 200 ms of latency on every frame. The crossover is roughly where
the loss-induced concealment rate exceeds the fraction of frames the buffer cannot cover.

**E6.1.2** Bursty (Gilbert–Elliott) loss at the same mean makes RTP+FEC *better* relative to
plain RTP in one sense and worse in another: FEC recovers isolated losses well and consecutive
losses not at all, so a burst of 3 defeats it. Expect FEC's advantage to shrink but not vanish,
and plain RTP to worsen because PLC degrades across consecutive frames.

**E6.1.3** `[OPEN]` Moving from 20 ms to 40 ms frames halves packet rate (and header overhead)
while doubling the audio lost per packet — RFC 6716's exact tradeoff. At scale the packet-rate
saving is real; for quality under loss it is a regression.

**E6.1.4** `[OPEN]` The binary subprotocol from §2.7 needs version, type, flags, sequence,
timestamp and payload. `clear` proves itself by measuring how much already-sent audio is
discarded — which should be non-zero, or your buffering assumption is wrong.

**E6.1.5** Twilio's `media` message measured 382 bytes of JSON carrying 160 bytes of audio —
2.39× inflation, of which base64 is 1.33× (216 chars) and the envelope adds 166 bytes. Wire cost
is 2.86× the audio. Your `streamSid` length changes the envelope term slightly.

**E6.1.6** `[OPEN]` The TCP late-rate prediction is $n_{\text{damaged}} \approx
\text{RTT}/20\,\text{ms}$ per loss; apply it to your measured loss and RTT and compare with the
observed inter-arrival gaps.

**E6.1.7** `[OPEN]` Expect DTX to remove close to half the packets in a two-party conversation,
since each party is silent roughly half the time.

**E6.1.8** `[OPEN]` Running a sequence-gap detector against a vendor ASR WebSocket for an hour
should find *no* gaps — which is the evidence for §2.6's claim that server-to-server WebSocket
is fine. If you find gaps, your hop is not what you think it is.

### 06-realtime-systems/02-webrtc-internals.md

**E6.2.1** `[OPEN]` NetEQ's policy — 0.95 quantile with `forget_factor = 0.983` — responds more
smoothly than a 100-sample p98 window and recovers more slowly after a spike, because
exponential forgetting has no hard horizon. Expect similar mean delay and a less spiky target
trajectory.

**E6.2.2** `[OPEN]` The `ms_per_loss_percent = 20` knob turns the frontier into a single
choice: accept 1% more loss for 20 ms less delay. Plotting delay against usable frames across
loss budgets from 0.1% to 5% gives you the curve to ship against.

**E6.2.3** Making the buffer shrink as fast as it grows produces dropouts *during* the spike,
because the target falls while the delay is still elevated. Expect usable frames to collapse
toward the fixed-20 ms row. The asymmetry is the algorithm.

**E6.2.4** A 16-bit sequence wraps every 65536 packets — **21.8 minutes** at 50 packets/s. The
fix is to track an extended sequence number: maintain a rollover counter and compare using
signed 16-bit differences, so a jump from 65535 to 0 reads as +1 rather than −65535.

**E6.2.5** The SDP audio section needs `a=rtpmap:111 opus/48000/2`,
`a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1`, `a=ptime:20`, and no video m-line. Omitting
`useinbandfec=1` loses FEC (it defaults to 0); omitting `usedtx=1` loses roughly half the
packet-rate saving; omitting `ptime` leaves frame size to the peer.

**E6.2.6** Host IPv4, component 1: $2^{24}\cdot126 + 2^{8}\cdot65535 + 255 = 2130706431$.
Server-reflexive: $2^{24}\cdot100 + \ldots \approx 1694498815$. Relay: $2^{24}\cdot0 + \ldots$,
which is at most about 16 776 960. Because the type preference occupies the top bits, the
*smallest* possible host priority still exceeds the largest possible relay priority — so no
relay pair can outrank a host pair, which is the ordering guarantee.

**E6.2.7** `[OPEN]` TURN fallback doubles both directions through your infrastructure, so a 10%
fallback rate costs roughly 4× the network of a direct session on those calls. The dedicated-
fleet crossover depends on your managed TURN pricing; compute it, because enterprise traffic
skews the rate badly.

**E6.2.8** The three clocks are the RTP timestamp (48 kHz for Opus regardless of audio rate),
the codec sample clock (your 16 kHz internal contract), and wall time. Expect drift between
sample clock and wall time of tens to hundreds of ppm; latency metrics should use wall time at
well-defined boundaries and never mix in RTP timestamps.

### 06-realtime-systems/03-pipeline-architecture.md

**E6.3.1** `drop_newest` keeps the oldest frames, which is exactly wrong for playback and
sometimes right for a control queue. The assignment: **ASR input blocks** (dropping audio costs
words), **playback drops oldest** (a stale frame has negative value), and partial transcripts
coalesce to depth 1.

**E6.3.2** p50 latency for the blocking policy is approximately $K \times 20$ ms plus the
service time, so it rises linearly with depth — the measured 84 ms at $K=2$ with 26 ms service
is consistent with roughly $2 \times 20 + 26 + $ polling granularity. Confirming linearity is
the exercise.

**E6.3.3** With `slow_ms = 18` the stage is faster than real time, $\rho < 1$, and no queue
forms — so all three policies converge to the same latency and zero drops. That is exactly why
testing a pipeline only under light load tells you nothing about its overload behaviour.

**E6.3.4** `[OPEN]` The correct design is a priority interrupt *plus* an ordered position
report: 20 ms of stale audio and a known cut point. The transcript truncation it enables is
what keeps the LLM's context honest.

**E6.3.5** `[OPEN]` An uninterruptible tool-call result must be delivered while audio frames are
discarded — which is what Pipecat's `FunctionCallResultFrame(DataFrame, UninterruptibleFrame)`
encodes in its type.

**E6.3.6** A CPU-bound loop with no `await` cannot be cancelled at all, because `Task.cancel()`
only raises at a suspension point. Chunking with `await asyncio.sleep(0)` makes it cancellable
at chunk granularity; moving it to a thread makes it cancellable only if the work itself
supports it. Expect interrupt latency to fall from "never" to roughly one chunk.

**E6.3.7** `[OPEN]` The largest p95 wait is usually on the edge in front of the slowest stage,
and the fix is either more capacity or a drop policy — not a deeper queue.

**E6.3.8** `[OPEN]` Two ASRs racing is easy in Pipecat (a parallel branch) and awkward in
LiveKit (you are fighting the fixed graph) — which is §2.6's table becoming concrete.

### 06-realtime-systems/04-speech-to-speech.md

**E6.4.1** A 25 Hz codec with 4 codebooks gives 100 tokens/s — the same as Mimi's 12.5 Hz × 8 —
so the *product* is what matters for context, while the frame rate alone determines
autoregressive steps and therefore latency. For a 10-minute call in a 32k window you need under
about 53 tokens/s, so neither works without segmentation: that is the real answer.

**E6.4.2** Mimi: $8 \times 11 \times 12.5 = 1100$ bit/s, reproducing the published 1.1 kbit/s
exactly. A mismatch would mean you had misread the codebook count, the bin count (2048 = 11
bits) or the frame rate — which is why the check is worth doing before trusting any downstream
arithmetic.

**E6.4.3** With a perfect 0 ms endpointer, cascaded p50 drops from 1370 to roughly 890 ms and
S2S half-duplex from 814 to about 340 ms. So roughly *none* of half-duplex S2S's advantage
survives as an architectural claim — most of it was the endpointer, which both architectures
pay. That is the exercise's point.

**E6.4.4** `[OPEN]` Cascaded-with-filler sets `ttfa` by the filler (~550 ms) rather than the
answer, which beats `S2S + text tool call` at 1499 ms decisively. For a booking agent, cascaded
with filler is the right choice — and that is the conclusion the chapter argues.

**E6.4.5** `[OPEN]` The blended crossover is $p \cdot t_{\text{tool}} + (1-p) \cdot
t_{\text{plain}}$ for each architecture; solve for the $p$ where they cross. With the chapter's
numbers the crossover is at a fairly low tool-call rate, which is why transactional agents stay
cascaded.

**E6.4.6** `[OPEN]` Expect S2S to win on `eou_to_ttfa` and lose on entity WER for numbers and
IDs, because a cascade lets you bias the ASR and an audio-native model gives you no such hook.

**E6.4.7** Gemini Live is 16 kHz in and **24 kHz out**, so the return path needs a 24 → 16 kHz
resample (or 24 → 48 for a WebRTC edge). It belongs at the transport boundary, costs a few
milliseconds, and must happen exactly once.

**E6.4.8** `[OPEN]` At 212.5 tokens/s a 10-minute call is 127 500 tokens, so a 32k window needs
segmentation roughly every 2.5 minutes. Enforce it as a session limit with an explicit summary
carried across, and tell the user nothing — the seam should be inaudible.

### 06-realtime-systems/05-scale-and-orchestration.md

**E6.5.1** `[OPEN]` Trunks at 1% versus 0.1% blocking differ by roughly 5–10% more channels,
which is usually cheap enough to just buy. Report both and state which you chose.

**E6.5.2** Two pools of 50 E need 64 + 64 = 128 channels; one pool of 100 E needs 117. That is a
**9.4% tax** on capacity for isolation. Whether it is worth it depends on whether isolation is a
contractual requirement or a preference — but it should be priced either way.

**E6.5.3** `[OPEN]` A 30 s mean session makes queueing far less catastrophic (the queue drains
30× faster), so the safe utilisation rises substantially at the same pool size; a 900 s session
makes it worse. Holding time is the parameter that decides whether "queue a little" is even
coherent.

**E6.5.4** `[OPEN]` A lognormal per-session footprint with the same mean and sd is
right-skewed, so the sum's upper tail is heavier and the safe packing density *falls*. Lognormal
is the more believable model for KV cache, because context length is itself right-skewed.

**E6.5.5** `[OPEN]` With age-dependent footprints, admission must reserve for the *projected*
peak, not the current usage — otherwise a GPU that was safe at admission overflows twenty
minutes later. The rule: admit against the footprint at your p95 session length.

**E6.5.6** `[OPEN]` Expect telephony and orchestration to lead, TTS third, and the LLM under
1%. Optimise the largest term, which is almost never the model.

**E6.5.7** `[OPEN]` Peak-to-mean for voice is typically 3–5×, so the provisioning schedule
follows the diurnal curve with the safe-ρ headroom applied at each hour.

**E6.5.8** `[OPEN]` The drain measurement should report zero non-natural terminations. If it
does not, compute the required timeout from your session-duration p99 — and check
`terminationGracePeriodSeconds`, which defaults to 30 s and silently truncates everything.

### 06-realtime-systems/06-observability.md

**E6.6.1** `[OPEN]` A boundary exactly at your SLO threshold makes compliance measurable;
expect under 1% p95 error with roughly 60–100 well-placed buckets, and 0.0% with linear 100 ms
buckets over a 10 s range.

**E6.6.2** With a unimodal distribution the log-spaced layouts look fine, because the p95 no
longer falls in a wide bucket between two modes. That is precisely why testing bucket layouts
on synthetic unimodal data is misleading — real voice latency becomes bimodal the moment the
agent calls tools.

**E6.6.3** The maximum relative error of an OTel exponential histogram is
$(\text{base} - 1)/2$ where $\text{base} = 2^{2^{-\text{scale}}}$: scale 2 gives base 1.189 and
~9.4% worst-case error, scale 3 gives 1.091 and ~4.5%, scale 4 gives 1.044 and ~2.2%. The
measured p95 errors (1.1% at scale 2, 0.0% at scale 4) are well inside those bounds, because
worst case requires the quantile to land at a bucket edge.

**E6.6.4** `[OPEN]` p50 detection needs far fewer calls than p95 — roughly the ratio of their
sampling variances. Expect 80% detection of the same shift at a fraction of the window size,
which is why the gate should watch p50.

**E6.6.5** `[OPEN]` The two-alert design: a static threshold on p95 for the SLO (ticket, not
page) and a control limit on p50 for change detection (page). Only the second should wake
someone, because only it indicates something new.

**E6.6.6** `[OPEN]` A weighted quantile using known sampling rates recovers most of the bias,
but not all — and you still should not compute an SLO this way, because the weights are
estimates and the metric path is free.

**E6.6.7** `[OPEN]` The span tree needs call → turn → stage, with `gen_ai.*` on the model spans
and namespaced `voice.*` names for endpointing, barge-in and `heard_ms`, which the conventions
do not cover.

**E6.6.8** `[OPEN]` Replay should reproduce turn boundaries exactly with a fake clock and cached
model responses. If it does not, the non-determinism is usually an un-awaited task or a real
`sleep`.

### 06-realtime-systems/07-reliability.md

**E6.7.1** `[OPEN]` The per-stage target implied by a 99% clean-call goal is
$0.99^{1/(m \cdot n)}$ — for five stages and 20 turns, 0.999900, or 100 failures per million.
Most teams discover their real per-stage availability is an order of magnitude worse.

**E6.7.2** `[OPEN]` With correlated failure probability $q$, the hedged column's advantage
collapses toward $1-q$ regardless of per-stage quality, because both attempts fail together.
Hedging stops being worth its cost roughly when $q$ approaches the independent failure rate it
was protecting against.

**E6.7.3** `[OPEN]` Fixed to see attempt outcomes, the breaker opens. Combined with a fallback,
user failures should fall well below both the 86 (retry-only) and 1152 (breaker-only) figures —
that combination is the row to ship, and the exercise exists to make you build it.

**E6.7.4** `[OPEN]` Jitter plus a 5% retry budget should cut the 1.64× amplification to near
1.05× while retaining most of the user-facing benefit, because the budget caps the aggregate
rather than the individual.

**E6.7.5** `[OPEN]` Pre-synthesised filler must go through the normal interrupt path, and the
test is that a barge-in over "one moment" is honoured. If it is not, you have created audio the
user cannot stop.

**E6.7.6** `[OPEN]` Dead-air instrumentation should report the distribution of silence between
`t_eou` and `ttfa` plus gaps within agent speech. Set $D$ at 1000–1500 ms and expect the
violations to cluster on tool-calling turns.

**E6.7.7** `[OPEN]` Drill 2 (slow, not down) is the one that usually reveals no alert fires at
all, because error-rate monitors stay green during a brownout. That is the finding.

**E6.7.8** `[OPEN]` The SLO document should budget in call-minutes weighted by session position,
and list truncation correctness and no-dead-air as *invariants* rather than SLOs.

### 06-realtime-systems/08-deployment.md

**E6.8.1** `[OPEN]` Expect three co-located full-stack regions to beat eight media-only edges
with central inference on both p95 and the share over 800 ms. Optimise the share over your
threshold rather than the mean, because the mean hides the badly-served population.

**E6.8.2** The triangle inequality gives $d(\text{user}, \text{edge}) +
d(\text{edge}, \text{model}) \ge d(\text{user}, \text{model})$, with equality when the edge lies
on the geodesic. Routing can make it *appear* false when the direct internet path is worse than
the path via a well-peered edge — real routes are not great circles, and a provider's private
backbone can beat the public internet. That is the honest exception, and it is an argument about
peering rather than geometry.

**E6.8.3** `[OPEN]` Models in two regions with media in eight lands between the extremes and
costs you pooling efficiency in both model regions. Three full stacks is usually the better
shape.

**E6.8.4** `[OPEN]` Choose the drain deadline from the killed-percentage column at your session
distribution; anything that kills more than a fraction of a percent is choosing to drop calls.
The capacity overhead at long deadlines is small (1.01–1.04×).

**E6.8.5** Permanently mid-rollover occurs when the deploy interval is shorter than the drain
time: at a 1200 s drain, more than three deploys an hour means two versions always live. The fix
is batching changes, or accepting dual-version operation and instrumenting for it.

**E6.8.6** `[OPEN]` The largest cold-start term is almost always weight loading if you download
at start, and image pull if you do not. Most teams expect process init and are wrong.

**E6.8.7** `[OPEN]` The browser checklist as assertions: AEC/NS/AGC on, `AudioWorklet` not
`ScriptProcessorNode`, no client-side resampling, output gated on a user gesture. Most existing
clients fail the autoplay assertion.

**E6.8.8** `[OPEN]` With `terminationGracePeriodSeconds` below the drain deadline, sessions are
killed at the grace period regardless of your drain logic — the count should be large. Fixing
it to exceed the drain deadline should give zero.

---

## 07-livekit (48)

### 07-livekit/01-architecture.md

**E7.1.1** `[OPEN]` Rooms hold participants; participants publish and subscribe tracks. The
agent is a participant, which is the design decision that makes one topology serve one-to-one
calls, supervisor monitoring and recording without special cases.

**E7.1.2** JWT grants: HS256, `iss` = API key, `sub` = identity, `defaultValidDuration = 6h`.
The trap is that `VideoGrant.canPublish`, `canSubscribe` and `canPublishData` are `*bool` — so
**absent means granted**. Omitting a field to be safe grants it.

**E7.1.3** `[OPEN]` Redis carries room-to-node routing for multi-node deployments; without it
each server is an island. `roomPreset` is Cloud-only, which is the sort of detail that decides
whether a config is portable.

**E7.1.4** `[OPEN]` DataChannel is the right transport for non-audio session messages —
transcripts, state, UI updates — because it shares the same connection and the same congestion
control as the media.

**E7.1.5** `[OPEN]` `SIPGrant{admin, call}` and `AgentGrant{admin, simulationAdmin,
databaseAdmin}` exist so telephony and agent control can be granted independently of media
rights. Least privilege applies.

**E7.1.6** `[OPEN]` Egress and ingress are separate services because recording and streaming
have different scaling and failure characteristics from live media.

**E7.1.7** `[OPEN]` The Cloud-versus-OSS boundary is worth mapping explicitly before you design
against a feature, since several are Cloud-only.

**E7.1.8** `[OPEN]` Token minting must be server-side and short-lived; a long-lived key in a
browser bundle is the classic mistake.

### 07-livekit/02-agents-framework.md

**E7.2.1** In 1.7.0 `WorkerOptions = ServerOptions` and `WorkerType = ServerType` are aliases,
and the class is `AgentServer`. Read the **published wheel**, not `main`, because `main` is
routinely ahead of the release and a constant you quote may not exist in the version you run.

**E7.2.2** The dispatch constants: `ASSIGNMENT_TIMEOUT = 7.5`, `UPDATE_LOAD_INTERVAL = 0.5`,
`DRAIN_TIMEOUT = 3600`, load as a 5-sample moving average of `cpu_percent(interval=0.5)`,
`load_threshold` `inf` in dev and **0.7** in production, `num_idle_processes` 0 in dev and
`min(ceil(cpu_count), 4)` in production, `job_memory_warn_mb = 1000`,
`job_memory_limit_mb = 0`, `shutdown_process_timeout = 10.0`, `session_end_timeout = 300.0`,
`initialize_process_timeout = 10.0`, `max_retry = 16`, `port` 0 in dev and 8081 in production.

**E7.2.3** `num_idle_processes = 0` puts a **2.74 s** cold start on every call; idle = 2 removes
it. That is the single most consequential default in the framework for perceived latency, and it
differs between dev and production precisely because dev optimises for restart speed.

**E7.2.4** The turn defaults: endpointing `{mode: "fixed", min_delay: 0.5, max_delay: 3.0,
alpha: 0.9}` with a streaming-detector variant `{min_delay: 0.3, max_delay: 2.5}`; interruption
`{enabled: True, discard_audio_if_uninterruptible: True, min_duration: 0.5, min_words: 0,
resume_false_interruption: True, false_interruption_timeout: 2.0, backchannel_boundary:
(1.0, 1.0)}`; preemptive `{enabled: True, preemptive_tts: False, max_speech_duration: 10.0,
max_retries: 3}`. `TurnDetectionMode` auto-selects realtime_llm → vad → stt → manual.

**E7.2.5** `[OPEN]` `min_delay = 0.5` is the floor on endpointing latency, so it is 500 ms of
your budget before anything adaptive happens. Lowering it raises the cut-off rate; the frontier
in [`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md) is how you pick.

**E7.2.6** `[OPEN]` `Agent` node overrides are the extension points — `stt_node`, `llm_node`,
`tts_node` and the turn hooks — and they are how you insert a clause-level guardrail without
forking the graph.

**E7.2.7** `[OPEN]` `DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` exists
because prompting alone does not stop a model emitting markdown. Belt and braces.

**E7.2.8** `[OPEN]` `_DEFAULT_AEC_WARMUP_DURATION = 3.0` means the echo canceller needs three
seconds to converge — so the first few seconds of a call are the most likely to self-interrupt,
which is worth knowing when you read a bug report about greetings.

### 07-livekit/03-writing-plugins.md

**E7.3.1** `STTCapabilities{streaming, interim_results, diarization, aligned_transcript,
offline_recognize, keyterms, chat_context}` is the contract, and `SpeechEventType` includes
**`PREFLIGHT_TRANSCRIPT`** — an early, low-confidence transcript intended for speculative work,
which is exactly the hook speculative retrieval needs.

**E7.3.2** `RecognizeStream` exposes `push_frame` / `flush` / `end_input` / `aclose`. The
distinction that matters: `flush` requests a final for what has been pushed, `end_input` says no
more audio is coming, `aclose` tears down. Conflating flush and end_input is why some plugins
cannot handle a second utterance.

**E7.3.3** `StreamAdapter(stt=, vad=)` makes a batch model streaming by using the VAD to
segment, and reports `interim_results = False` because it genuinely has none. That honesty in
the capability flags is what lets `AgentSession` adapt its behaviour.

**E7.3.4** `TTSCapabilities{streaming, aligned_transcript}` and
`SynthesizedAudio{frame, request_id, is_final, segment_id, delta_text}`.
`AudioEmitter.initialize(..., frame_size_ms=200)` sets emission granularity — smaller means
lower `ttfb_tts` and more overhead.

**E7.3.5** `VADEvent.frames` contains the **complete utterance** on `END_OF_SPEECH`, which is
what lets a batch STT work at all — and is also a memory consideration for long turns.

**E7.3.6** `APIConnectOptions(max_retry=3, retry_interval=2.0, timeout=10.0)` is the plugin
default. A 10 s timeout is far beyond a conversational deadline, so tighten it: the framework's
default optimises for eventual success, and you need bounded failure.

**E7.3.7** `[OPEN]` A local faster-whisper STT plugin needs `StreamAdapter` (since CTranslate2
is batch), and a Kokoro TTS plugin needs `streaming = False` with chunked emission. Both are
~100 lines, and writing them is how you stop paying vendors.

**E7.3.8** `ChatChunk.has_response()` distinguishes a chunk carrying content from one carrying
only metadata, which matters when you are measuring `ttft_llm` — counting the wrong chunk gives
you a flatteringly small number.

### 07-livekit/04-self-hosting-and-scale.md

**E7.4.1** `[OPEN]` `livekit-server` needs keys, Redis for multi-node, and a TURN configuration;
the non-obvious requirement is that media ports must be directly reachable, which rules out an
HTTP load balancer in front.

**E7.4.2** Media cannot sit behind a layer-7 load balancer because such a balancer terminates
TCP and inspects HTTP, and knows nothing about UDP ports, ICE candidates or session affinity.
Media needs node-addressability plus a shared routing store.

**E7.4.3** `load_threshold = 0.7` rejected 10% of calls under a surge where `inf` spent **38 s**
above load 1.0. That is the tradeoff stated precisely: threshold-based admission converts
queueing into rejection, and rejection is the better failure for held sessions.

**E7.4.4** `[OPEN]` Autoscaling should key on concurrent sessions or arrival rate, not CPU,
because CPU lags by the holding time. Scale up on arrivals, down on session count.

**E7.4.5** `[OPEN]` `DRAIN_TIMEOUT = 3600` is what makes the killed-session count zero for a
realistic session distribution; a 300 s drain kills 22.2%.

**E7.4.6** The self-host crossovers: agents from about **290k call-minutes/month**, media only
from about **3.5 M**. Media is later because the managed media plane is genuinely cheap per
participant-minute ($0.0004) and expensive to operate yourself.

**E7.4.7** `[OPEN]` Prometheus metrics on the worker port (8081 in production) give you load and
job counts; what you must add is the turn-level spans and `heard_ms`.

**E7.4.8** `[OPEN]` A defensible self-host decision states the crossover volume, the operational
headcount it assumes, and the failure modes you are taking on — TURN, Redis and media
addressability.

### 07-livekit/05-telephony-sip.md

**E7.5.1** `[OPEN]` INVITE establishes, REFER transfers, BYE ends. The detail that bites is that
REFER hands control to the carrier, so your agent loses visibility at exactly the moment a
customer is being transferred.

**E7.5.2** In-band DTMF puts loud dual tones directly into the audio your ASR is transcribing,
which produces garbage transcripts and can trigger the VAD. The carrier chooses the transport,
not you, so you must detect and suppress.

**E7.5.3** The 8 kHz WER tax is real and concentrated: everything above 4 kHz is gone by
Nyquist, and that is where /s/, /f/ and /θ/ are distinguished — so the errors are systematic on
sibilants, plosive bursts and spelled letters, which is exactly the content phone agents need.

**E7.5.4** `[OPEN]` AMD failure modes: classifying a human as a machine (you hang up on a
customer) and a machine as a human (you talk to an answering machine). The costs are asymmetric
and the threshold should reflect that.

**E7.5.5** `[OPEN]` Trunk channel limits are a hard capacity constraint separate from your
worker pool, sized by Erlang B — and the trunking gain means one large trunk group beats
several small ones.

**E7.5.6** `[OPEN]` Third-party SIP at $0.003–0.004/min against US local inbound at $0.01/min
is a meaningful saving at volume, traded against control and support.

**E7.5.7** `[OPEN]` The PSTN failure modes nobody warns about: one-way audio from asymmetric
NAT/SBC configuration, silent call drops, DTMF arriving by an unexpected transport, and codec
renegotiation mid-call.

**E7.5.8** `[OPEN]` A defensible telephony design keeps a second carrier configured and tested,
because a trunk outage has no in-band workaround.

### 07-livekit/06-alternatives.md

**E7.6.1** The platform crossovers: **Vapi below ~15.5k** call-minutes/month, **LiveKit Cloud to
~133k**, **Cloud with your own agents to ~2.04 M**, fully self-hosted beyond. The shape is the
usual one — managed wins small, self-host wins large — and the interesting part is how *late*
the last crossover is.

**E7.6.2** The LLM is **0.6%** of the model layer ($0.00009 of $0.0157 per call-minute), which
means optimising the LLM for cost is misdirected while optimising it for latency is not. This is
the single most useful number to carry into a vendor conversation.

**E7.6.3** `[OPEN]` Vapi at $0.05/min plus $10/line/month with 14-day history, HIPAA at
$2k/month and ZDR at $1k/month; Retell at $0.07–0.31/min plus $0.055/min infrastructure and 20
concurrent. The compliance add-ons are the line items that decide regulated deployments.

**E7.6.4** `[OPEN]` Pipecat versus LiveKit is a graph-control-versus-tuned-defaults choice, not
a quality one. Pick Pipecat for non-standard topologies, LiveKit for standard agents.

**E7.6.5** `[OPEN]` Amazon Connect and Azure Voice Live bundle telephony and contact-centre
features; they win when you need the surrounding product, not when you need the best agent.

**E7.6.6** `[OPEN]` Riva is CUDA-only and on-prem-capable, which makes it the answer for
air-gapped deployments and irrelevant otherwise.

**E7.6.7** Keeping business logic portable means it imports neither framework: tools, state
machine, prompts and persona in your own module, with thin adapters. Then the platform choice is
reversible, which is worth more than picking correctly the first time.

**E7.6.8** `[OPEN]` A defensible decision flowchart branches first on telephony versus browser,
then on volume against the crossovers, then on compliance — in that order, because each can
disqualify the branches below it.

---

## 08-eval-safety (24)

### 08-eval-safety/01-testing.md

**E8.1.1** `[OPEN]` Sweeping the budget from 20 to 35 ms should show the real-clock flake rate
falling from ~100% to ~0%, with the 50% point somewhere in the low-to-mid 20s on an idle
machine — and moving between runs. No budget gives both a reliable pass and a tight bound,
because the true bound is 5.00 ms and the real clock reports 16.48 ms p50: any budget tight
enough to be meaningful fails, and any budget loose enough to pass asserts nothing.

**E8.1.2** Reducing the yield count from 60 to 1 reintroduces the race the clock exists to
remove: time can advance while a task is still runnable, so a stage may not have consumed its
input before the clock moves past its deadline. Expect nonzero and non-reproducible failures —
the virtual clock becomes as bad as the real one.

**E8.1.3** `[OPEN]` The truncation invariant is that the logged assistant turn is a *prefix* of
the synthesised text, cut at the playback position. Removing the truncation makes the test fail
with a logged turn longer than what was heard — which is the production bug the assertion
exists to catch.

**E8.1.4** `[OPEN]` The gate is the 99th percentile of your p50's resampled distribution.
Whether it is useful depends on corpus size: at 1000 utterances expect roughly ±10 ms of noise
and a ~22 ms minimum detectable regression, which is useful; at 50 it is ~124 ms, which is not.

**E8.1.5** The p50 gate is more sensitive because it is estimated from the whole sample while
p95 uses the top 5%. The regression shape the p95 catches and the p50 misses is a **tail-only**
one — a new failure mode affecting a small fraction of turns, such as a timeout on tool-heavy
calls. That is why you gate on p50 and monitor p95: they detect different things.

**E8.1.6** `[OPEN]` A 1-frame (20 ms) shift is 320× the 1-sample shift and should clearly exceed
the 0.10 dB gate, because at that scale the STFT frames genuinely misalign. The threshold you
*want* sits above sub-sample jitter and below anything audible — which is roughly where 0.10 dB
lands.

**E8.1.7** `[OPEN]` The ASR round-trip gate's run-to-run WER variance is the number that sets
the threshold; expect it to be small for a deterministic ASR on fixed audio, which is what makes
the gate viable for a sampling TTS.

**E8.1.8** `[OPEN]` The artefact most teams are missing is the **decision inputs** — prompt,
model version, tool schema, retrieved context — without which a replay exercises different logic
than the incident did.

### 08-eval-safety/02-simulation-and-load.md

**E8.2.1** `[OPEN]` Expect the corrected rate to differ from your dashboard by several points,
and the *sign* to depend on whether your judge is lenient or harsh. A lenient judge (high TPR,
low TNR) overstates; a harsh one understates by more.

**E8.2.2** Rogan–Gladen is exact because the observed positive rate is an exact linear function
of the true prevalence: $p_{\text{obs}} = p\,\text{TPR} + (1-p)(1-\text{TNR})$, which inverts
uniquely whenever the slope $\text{TPR} - (1-\text{TNR})$ is nonzero. It becomes unusable as
that slope approaches zero — which means $\text{TPR} + \text{TNR} \to 1$, i.e. the judge is no
better than chance. A useless judge cannot be corrected into a useful one.

**E8.2.3** `[OPEN]` With 203 labels per class the standard errors on TPR and TNR are about
±3%, and propagating them gives a corrected-rate interval of roughly ±4–6 points depending on
the operating point — wider near the chance boundary. Reporting the interval is what stops a
corrected number being over-trusted.

**E8.2.4** At a 98% base rate a judge that always says "success" achieves 98% raw agreement and
κ = 0. Reporting the 98% would be indefensible because it measures the base rate, not the
judge — and it is exactly the number a dashboard will show you by default.

**E8.2.5** `[OPEN]` The knee moves earlier for small pools: a 10-worker pool knees around
ρ ≈ 0.4, a 400-worker pool closer to 0.9. That is the same safe-utilisation curve from
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)
seen through latency rather than wait probability.

**E8.2.6** `[OPEN]` The concurrency at which p95 doubles is the number to publish. Whether the
system rejected cleanly or degraded uniformly is the more important observation — clean
rejection at 105% load is a far better outcome than everyone getting 15-second latency.

**E8.2.7** `[OPEN]` Task count and file descriptors are often *more* sensitive leak detectors
than RSS, because they are integers with no allocator noise — a leaked task is a few kilobytes
of memory and an unmistakable +1.

**E8.2.8** `[OPEN]` Expect per-persona success to vary enormously — the interrupter and the
corrector usually score worst. Fix the one whose traffic-weighted contribution is largest, not
the one with the lowest score.

### 08-eval-safety/03-safety-and-privacy.md

**E8.3.1** `[OPEN]` A 400 ms classifier at clause granularity adds ~240 ms (at the 0.6 ratio),
which starts to be visible. Clause gating stops being worth it roughly when the per-clause check
approaches the clause duration itself — at which point you are serialising synthesis and should
consider a smaller classifier rather than a different placement.

**E8.3.2** `[OPEN]` A prefix-inspecting guardrail lands between parallel and clause-gated: it
can catch a violation partway through rather than at the end, so the leak is bounded by the
inspection interval. It costs more classifier calls than serial and fewer than per-clause.

**E8.3.3** `[OPEN]` Handling number-words ("eleven", "nineteen ninety") requires a full spoken-
number grammar, and the remaining failures are ambiguous forms where the same words are a date,
a quantity or an identifier depending on context. It is unbounded because natural language
number expression is unbounded — which is the same reason ITN is never finished.

**E8.3.4** `[OPEN]` Tier 3's false positives come from carrier words in innocent contexts: "my
account is fine", "the card game", "pin it to the board" followed by any short digit run.
Expect precision to fall from 100% on a realistic corpus, and choose the threshold from the
cost ratio — a false positive redacts something harmless, a false negative leaks PII.

**E8.3.5** `[OPEN]` A compliant greeting names the company, states plainly that this is an
automated assistant (Art. 50(1)), states that the call is recorded and why, and offers a human.
Expect roughly three seconds — and it sits at the front of the call, before any latency budget
applies, which is why it is the one place not to optimise.

**E8.3.6** `[OPEN]` The processor inventory should list every vendor receiving audio or
transcripts with its retention default, its training-on-data default and whether a BAA or ZDR
tier exists. The weakest link is usually a vendor added for one feature and never reviewed.

**E8.3.7** `[OPEN]` Present the FAR at the FRR product would accept, and the expected attempts
to break in. At a 2% EER and a 1% FRR that is 4% and 25 attempts — which is the sentence that
ends the "let's use voice authentication" conversation.

**E8.3.8** `[OPEN]` Spoken injections succeed more often than people expect, and the useful
finding is whether your *tool-boundary* limits bounded the damage. If a successful injection
could move money, the guardrail was never the control.

---

## 09-mastery (8)

### 09-mastery/01-design-interviews.md

**E9.1.1** With a fixed 700 ms endpointer, scenario 1's allocation becomes 780 − 330 + 700 =
1150 ms against an 800 ms target — **infeasible by 350 ms**. What you tell the product owner is
that the requirement and the endpointing policy are in direct conflict, that an adaptive
endpointer resolves it at a *lower* cut-off rate (2.78% versus 3.04%), and that if they want the
fixed timeout they must relax the target to 1200 ms.

**E9.1.2** `ceil(concurrent / 0.7)` gives 72 for 50 E (against 69), 715 for 500 E (against 556),
1143 for 800 E (against 870), and **14 286 for 10 000 E (against 10 257)** — a 39%
over-provision at the largest scale. At managed agent-minute pricing that is roughly $1.7 M/year
of workers that were never needed, which is the figure to put in front of finance.

**E9.1.3** `[OPEN]` A good seventh scenario states its target, concurrency, mean session and
tool-call rate, then reports slack, pool, trunks and cost — and names the dominant term in each,
which for most real designs will be endpointing and telephony.

**E9.1.4** `[OPEN]` Sweeping `cache_hit` from 0 to 0.95 moves the LLM term by 3.2× at the
extremes. Prompt restructuring for cache stability becomes the highest-value cost work when your
hit rate is below roughly 0.5 *and* the LLM is a material share — which for most cascaded agents
it is not, so the honest answer is usually "do it for latency, not for cost".

**E9.1.5** `[OPEN]` Splitting scenario 2 into three regional pools costs channels (three pools
of ~3333 E need more than one of 10 000 E) and workers (three smaller pools have lower safe ρ).
Present the total as the price of residency, because that is what it buys.

**E9.1.6** `[OPEN]` Modelling S2S replaces five latency terms with a frame plus a forward pass
and adds audio-token cost at 100–212 tokens/s. It improves scenario 6 (the interpreter, no tool
calls) and worsens scenarios 1, 3 and 5 (tool-heavy), which is the tool-call-rate crossover made
concrete.

**E9.1.7** `[OPEN]` The BAA shortlist is usually much shorter than the vendor list, and the
exercise's value is discovering that your preferred ASR or TTS is not on it.

**E9.1.8** `[OPEN]` Session segmentation for the interpreter: segment roughly every 2 minutes,
carry a text summary and the current speaker state across the boundary, and ensure the seam
falls in a silence. The user should notice nothing; if they do, the boundary is in the wrong
place.

---

## Where these answers came from

Every number quoted here is a measurement from the chapter it belongs to, and each chapter's
`## Sources` states what was measured, on what, and what was modelled. Three answers correct
claims that were wrong in earlier drafts and are worth knowing as failure modes rather than
trivia:

- **E6.8.2** — the triangle-inequality result contradicted the conventional "edge media,
  central models" advice, which two earlier chapters had asserted before it was measured. Both
  were corrected.
- **E8.1.6** — the golden-audio metric was originally a per-bin log-spectral distance, which
  ranked a benign TTS re-run as *more* changed than a real formant regression. The mel-band
  formulation replaced it.
- **E0.1.6** — the reason this curriculum pins Python 3.12 is `audioop`'s removal in 3.13, not
  kokoro's declared `<3.13` bound, which `uv run --with` does not enforce.

If you find a fourth, the chapter is wrong and should be fixed rather than the answer.
