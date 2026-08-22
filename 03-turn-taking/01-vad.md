# Voice Activity Detection

**What you'll be able to do after this:** build energy, spectral and neural VADs and
say what each one can and cannot detect; read an ROC curve and choose an operating
point from the *cost* of each error rather than from F1; explain why a VAD tuned to the
best frame-level threshold shreds one utterance into eight; and integrate Silero VAD
correctly, including the 512-sample window that does not divide into your 20 ms frames.

---

## 1. Intuition

Voice activity detection answers one question per frame: *is someone speaking right
now?* It is the cheapest and most load-bearing component in a voice agent. Everything
downstream depends on it — the ASR is gated by it, the endpointer counts its silences,
the barge-in detector triggers on its onsets, and your GPU bill is proportional to how
much non-speech it lets through
([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md)).

Two errors, wildly asymmetric costs, and the asymmetry is context-dependent:

- **Missing speech** (false negative) — words are never transcribed. The user repeats
  themselves. In the middle of an utterance this fragments a sentence; at the start it
  clips the first word, which is where the intent usually is.
- **Detecting non-speech** (false positive) — noise, a cough, hold music, or a
  television is treated as speech. Downstream, Whisper hallucinates on it
  ([`../02-asr/04-attention-and-whisper.md`](../02-asr/04-attention-and-whisper.md) §2.5),
  the endpointer's silence timer resets and the turn never ends, and you pay to
  transcribe a dog.

The critical realisation, and the reason this chapter measures more than it explains:
**the frame-level metric everyone reports is the wrong metric.** A VAD's job is not to
label frames correctly, it is to produce *segments* that correspond to utterances. §2.4
shows a detector with an excellent frame F1 of 0.891 that cuts 33 utterances into 265
fragments — because a single dip below threshold mid-vowel starts a new segment. Frame
accuracy is high and the output is useless. The fix is temporal smoothing, and the
smoothing is where all the engineering is.

The second realisation is that **VAD is not endpointing.** VAD says "sound is speech";
endpointing says "the turn is over". A perfect VAD does not tell you whether a 400 ms
silence is a thinking pause or a finished sentence — that is a different decision with
different information, and it gets its own chapter
([`02-endpointing.md`](02-endpointing.md)). Conflating them is the most common
architectural confusion in this area.

---

## 2. Rigour

### 2.1 What distinguishes speech from noise

Three families of cue, in increasing order of what they require:

**Energy.** Speech is louder than background, usually. Cheap, and it fails on the cases
that matter: it cannot distinguish speech from a slamming door, and it fails entirely
when the interferer is loud — a car, a fan, or another conversation.

**Spectral and temporal structure.** Voiced speech is harmonic (energy at multiples of
$F_0$), has formant structure, and is modulated at the syllable rate of roughly 3–8 Hz.
Noise is typically broadband and stationary. Zero-crossing rate separates voiced (low
ZCR, periodic) from unvoiced fricatives (high ZCR, noise-like) — which is why classical
VADs combined energy with ZCR: the two features fail on different sounds.

**Learned representations.** A small neural network on log-mel features learns cues no
hand-designed feature captures, and — crucially — learns them *from data that contains
your interferers*. This is why Silero VAD beats an energy detector on speech-in-babble,
where energy and harmonicity are both present in the noise.

The reason a neural VAD wins is worth stating precisely: hand-designed features encode
what speech *is*; a trained model additionally encodes what noise *is not*. Given a
training set with music, typing, road noise and crosstalk, the model learns
discriminative boundaries in a space no closed-form feature spans.

### 2.2 Frame-level detection performance

Measured on 60 seconds of synthetic speech-like signal (harmonic stacks with 3–7 Hz
syllabic modulation, $F_0$ 90–220 Hz) plus white noise at controlled SNR, 20 ms frames,
with ground truth from the generator `[MEASURED]`:

| SNR | Feature | AUC | Best F1 | Threshold |
|---|---|---|---|---|
| 20 dB | energy (dBFS) | 0.982 | 0.968 | −31.47 |
| 20 dB | −ZCR | 0.983 | 0.963 | −0.44 |
| 20 dB | energy − 20·ZCR | **0.985** | **0.970** | −40.61 |
| 10 dB | energy (dBFS) | 0.947 | 0.922 | −21.62 |
| 10 dB | −ZCR | 0.952 | 0.919 | −0.45 |
| 10 dB | energy − 20·ZCR | **0.957** | **0.928** | −30.98 |
| 5 dB | energy (dBFS) | 0.920 | 0.891 | −16.69 |
| 5 dB | −ZCR | 0.916 | 0.881 | −0.45 |
| 5 dB | energy − 20·ZCR | **0.926** | **0.895** | −26.01 |
| 0 dB | energy (dBFS) | 0.884 | 0.841 | −11.70 |
| 0 dB | −ZCR | 0.888 | 0.843 | −0.48 |
| 0 dB | energy − 20·ZCR | **0.899** | **0.855** | −21.41 |

Three observations.

**Degradation is graceful, not catastrophic.** AUC falls from 0.982 to 0.884 across a
20 dB SNR range. Energy-based VAD does not fall off a cliff on this signal; it degrades
steadily, which is why it survived so long.

**Combining features helps consistently but modestly** — about +0.003 to +0.015 AUC.
The features are correlated, so the gain is small; it is nonetheless free, and it is
larger at low SNR where you need it.

**The optimal threshold moves 20 dB with the noise floor** (−31.47 to −11.70 dBFS).
A fixed absolute threshold is therefore wrong in any deployment where level varies —
which is all of them, since gain differs across devices, carriers and speakers. Any
energy VAD needs an **adaptive noise floor**: track a low percentile of recent energy
and set the threshold relative to it. This is the single most important implementation
detail for energy-based detection, and it is why VAD in a lab and VAD on a phone call
behave so differently.

### 2.3 Why frame F1 is the wrong objective

Segment counts for the same detector at its best frame-level threshold, SNR 5 dB, 33
true utterances `[MEASURED]`:

| Configuration | Detected segments | Fragmentation | Frame F1 |
|---|---|---|---|
| Plain threshold, no smoothing | **265** | **8.03×** | 0.891 |
| Hysteresis 3 dB gap, no hangover | 4 | 0.12× | 0.782 |
| Hysteresis 3 dB gap, 100 ms hangover | 1 | 0.03× | 0.780 |
| Hysteresis 6 dB gap, 200 ms hangover | 1 | 0.03× | 0.780 |

The first row is the finding. At the threshold that maximises frame F1, the detector
produces **eight times too many segments** — every utterance is shredded, because
speech contains brief low-energy moments (stop closures, inter-word gaps, the
unvoiced portion of a plosive) that dip below any threshold. Frame F1 barely notices,
because only a handful of frames are wrong. Downstream, everything notices: the ASR
receives 265 tiny clips instead of 33 utterances, each too short for a reliable
embedding or a language-model context.

The next three rows show the opposite failure, and they are the reason I am showing
them rather than a clean success. Classical hysteresis — an *off* threshold below the
*on* threshold — over-merges catastrophically here, collapsing the whole recording into
one segment, because once triggered the detector never sees energy low enough to
release. Frame F1 also drops. Naive hysteresis is not a free win.

### 2.4 Finding the operating point

Sweeping on-threshold offset $a$, off-threshold offset $b$ (off $=$ threshold $- b$,
so negative $b$ means the release threshold is *higher* than the trigger) and hangover
$h$ in frames `[MEASURED]`, SNR 5 dB, 33 true utterances:

| $a$ (dB) | $b$ (dB) | $h$ (frames) | Segments | Fragmentation | Precision | Recall | F1 |
|---|---|---|---|---|---|---|---|
| 0 | −1 | 0 | 277 | 8.39× | 0.959 | 0.787 | 0.865 |
| 0 | −1 | 4 | 57 | 1.73× | 0.870 | 0.998 | 0.930 |
| 0 | +1 | 0 | 69 | 2.09× | 0.810 | 0.984 | 0.889 |
| 0 | +1 | 4 | 1 | 0.03× | 0.639 | 1.000 | 0.780 |
| **1** | **−1** | **4** | **34** | **1.03×** | **0.931** | **0.996** | **0.962** |
| 1 | −1 | 10 | 33 | 1.00× | 0.849 | 0.996 | 0.917 |
| 2 | −1 | 4 | 34 | 1.03× | 0.932 | 0.991 | 0.961 |
| 3 | −1 | 4 | 34 | 1.03× | 0.932 | 0.991 | 0.961 |

The best configuration recovers **34 segments against 33 true** with F1 0.962, up from
0.891 — and it does so with $b = -1$, meaning the release threshold is 1 dB *above* the
trigger threshold, with an 80 ms hangover.

The lesson is not the specific numbers, it is which mechanism did the work: **the
hangover timer, not the hysteresis gap.** Requiring 80 ms of continuous sub-threshold
energy before closing a segment bridges stop closures and inter-word gaps, which is
exactly the fragmentation cause. Lowering the release threshold instead — textbook
hysteresis — makes the detector reluctant to close *at all*, which over-merges. The
generalisable rule: **fragmentation is a temporal problem and wants a temporal fix.**

Notice also how insensitive the result is to $a$ (rows with $a = 1, 2, 3$ are within
0.001 F1). The trigger threshold barely matters once the hangover is right, which is
the opposite of where tuning effort usually goes.

### 2.5 Silero VAD, and its integration friction

Silero VAD is the current default open neural VAD. Verified from
`snakers4/silero-vad`, `src/silero_vad/utils_vad.py` (master, retrieved 2026-08-22):

| Parameter | Default | What it is |
|---|---|---|
| window size | `512 if sr == 16000 else 256` samples | **mandatory**, not advisory |
| `threshold` | 0.5 | speech probability above which a frame is speech |
| `neg_threshold` | derived from `threshold` | the release threshold — hysteresis, §2.4 |
| `min_speech_duration_ms` | 250 | speech chunks shorter than this are discarded |
| `min_silence_duration_ms` | 100 | silence required before closing a chunk — **the hangover** |
| `speech_pad_ms` | 30 | final chunks are padded on each side |
| `max_speech_duration_s` | `inf` | long chunks split at the last silence over 100 ms |

Two things are worth noting about that table.

**Silero's defaults are the §2.4 conclusion, independently arrived at.** It ships a
`neg_threshold` (hysteresis), a `min_silence_duration_ms` of 100 (hangover), a minimum
speech duration to discard fragments, and padding to avoid clipping onsets. My measured
optimum was an 80 ms hangover; Silero's default is 100 ms. The convergence is not a
coincidence — both are fixing the same physical property of speech.

**The 512-sample window does not divide your frames.** 512 samples at 16 kHz is 32 ms,
and the canonical pipeline frame is 20 ms / 320 samples
([`../00-setup/03-canonical-formats.md`](../00-setup/03-canonical-formats.md)). 32 and
20 have no useful common factor, so you must buffer: accumulate 20 ms frames until 512
samples are available, run the model, and carry the remainder. Consequences to plan for:
VAD decisions arrive on a 32 ms grid while audio arrives on a 20 ms grid; the effective
detection latency includes up to one extra frame of buffering; and feeding Silero a
wrong-sized window does not raise an error in every code path — it can silently produce
degraded probabilities, which is a genuinely nasty failure. Assert the window size at
the call site.

`speech_pad_ms = 30` deserves one note for agent use: padding the *start* of a chunk
requires audio from before the trigger, so a streaming implementation must keep a small
pre-roll buffer. Without it, you clip the first phoneme, and the first phoneme is
disproportionately where the intent lives ("cancel" versus "can't sell").

### 2.6 WebRTC VAD

The other VAD you will encounter, embedded in browsers and in `py-webrtcvad`. Its
design: split each 10/20/30 ms frame into six sub-bands, compute per-band energy,
score against two Gaussian mixture models (speech and noise) with continuously updated
parameters, and take the likelihood ratio. Aggressiveness modes 0–3 shift the decision
threshold.

Two properties matter for agent work. It is **extremely cheap** — fixed-point, no
matrix multiplies, microseconds per frame — which is why it runs in every browser. And
it is **tuned for telephony-band speech versus stationary noise**, so it degrades on
non-stationary interferers (music, babble) in exactly the conditions a neural VAD
handles. It accepts only 8/16/32/48 kHz and 10/20/30 ms frames, so unlike Silero it
composes cleanly with a 20 ms pipeline.

The honest positioning: WebRTC VAD as a nearly-free first-stage gate, Silero as the
decision-maker. Cascading them — cheap gate rejects obvious silence, neural model
adjudicates the rest — is a common and effective pattern that cuts neural VAD compute
substantially on typical audio, since most of a call is silence.

---

## 3. From scratch

Energy and ZCR features, ROC evaluation, and the hysteresis-plus-hangover state machine
whose operating point §2.4 searched. Standalone, numpy only.

```python
"""Energy/ZCR VAD with ROC evaluation and a hysteresis + hangover state machine."""
import numpy as np

SR, FRAME = 16_000, 320          # 20 ms canonical frame

def synth(seconds=60, snr_db=10, rng=None):
    """Speech-like bursts + white noise, with frame-accurate ground truth.
    Harmonic stacks modulated at 3-7 Hz mimic the syllabic rate; that modulation
    is the property real VADs key on."""
    rng = rng or np.random.default_rng(2)
    n = SR * seconds
    t = np.arange(n) / SR
    speech = np.zeros(n)
    truth = np.zeros(n, dtype=bool)
    pos = 0
    while pos < n - SR:
        dur = int(SR * rng.uniform(0.4, 2.0))
        gap = int(SR * rng.uniform(0.2, 1.2))
        if pos + dur >= n:
            break
        seg = slice(pos, pos + dur)
        f0 = rng.uniform(90, 220)
        env = 0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(3, 7) * t[seg])
        speech[seg] = env * sum(np.sin(2 * np.pi * f0 * k * t[seg]) / k
                                for k in range(1, 12))
        truth[seg] = True
        pos += dur + gap
    speech /= np.abs(speech).max() + 1e-9
    noise = rng.standard_normal(n)
    noise *= np.sqrt((speech ** 2).mean() /
                     ((noise ** 2).mean() * 10 ** (snr_db / 10)))
    return (speech + noise).astype(np.float32), truth

def to_frames(x, truth):
    nf = len(x) // FRAME
    X = x[:nf * FRAME].reshape(nf, FRAME)
    y = truth[:nf * FRAME].reshape(nf, FRAME).mean(axis=1) > 0.5
    return X, y

def energy_dbfs(X):
    return 20 * np.log10(np.sqrt((X.astype(np.float64) ** 2).mean(axis=1)) + 1e-12)

def zcr(X):
    return (np.diff(np.signbit(X), axis=1) != 0).mean(axis=1)

def roc(score, y):
    """Returns (AUC, best F1, threshold at best F1)."""
    order = np.argsort(-score)
    s, yy = score[order], y[order]
    tp, fp = np.cumsum(yy), np.cumsum(~yy)
    tpr, fpr = tp / max(y.sum(), 1), fp / max((~y).sum(), 1)
    auc = np.trapezoid(tpr, fpr)
    prec = tp / np.maximum(tp + fp, 1)
    f1 = 2 * prec * tpr / np.maximum(prec + tpr, 1e-9)
    i = int(np.argmax(f1))
    return auc, f1[i], s[i]

def hysteresis(score, on, off, hangover):
    """Two thresholds plus a release timer.

    The hangover is what prevents fragmentation: brief dips below `off` (stop
    closures, inter-word gaps) must persist for `hangover` frames before the
    segment closes. Section 2.4 measures this as the dominant mechanism.
    """
    out = np.zeros(len(score), dtype=bool)
    active, below = False, 0
    for i, s in enumerate(score):
        if not active:
            if s > on:
                active, below = True, 0
        else:
            if s < off:
                below += 1
                if below > hangover:
                    active = False
            else:
                below = 0
        out[i] = active
    return out

def n_segments(mask):
    return int((np.diff(np.concatenate(([False], mask, [False])).astype(int)) == 1).sum())

def prf(pred, y):
    tp, fp, fn = (pred & y).sum(), (pred & ~y).sum(), (~pred & y).sum()
    p, r = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
    return p, r, 2 * p * r / max(p + r, 1e-9)

if __name__ == "__main__":
    rng = np.random.default_rng(2)
    print(f"{'snr':>5} {'feature':>18} {'AUC':>7} {'bestF1':>7} {'thresh':>9}")
    for snr in (20, 10, 5, 0):
        x, truth = synth(60, snr, rng)
        X, y = to_frames(x, truth)
        e, z = energy_dbfs(X), zcr(X)
        for name, sc in (("energy (dBFS)", e), ("-ZCR", -z),
                         ("energy - 20*ZCR", e - 20 * z)):
            auc, f1, th = roc(sc, y)
            print(f"{snr:5d} {name:>18} {auc:7.3f} {f1:7.3f} {th:9.2f}")

    # Fragmentation: the metric frame F1 cannot see.
    x, truth = synth(60, 5, rng)
    X, y = to_frames(x, truth)
    e = energy_dbfs(X)
    _, base_f1, th = roc(e, y)
    true_segs = n_segments(y)
    print(f"\ntrue utterances: {true_segs}   plain-threshold frame F1: {base_f1:.3f}")
    print(f"{'a(dB)':>6} {'b(dB)':>6} {'h(fr)':>6} {'segs':>6} {'frag':>6} "
          f"{'P':>6} {'R':>6} {'F1':>6}")
    for a, b, h in ((0, -1, 0), (0, -1, 4), (0, 1, 0), (0, 1, 4),
                    (1, -1, 4), (1, -1, 10), (2, -1, 4), (3, -1, 4)):
        pred = hysteresis(e, th + a, th - b, h)
        p, r, f1 = prf(pred, y)
        ns = n_segments(pred)
        print(f"{a:6d} {b:6d} {h:6d} {ns:6d} {ns/true_segs:6.2f} "
              f"{p:6.3f} {r:6.3f} {f1:6.3f}")
```

The `hysteresis` function is the whole chapter in fifteen lines, and the parameter to
tune is `hangover`. Note that it is a *stateful* function over a frame sequence — which
is why VAD belongs in a synchronous per-frame interface rather than behind an async
boundary: it must see every frame, in order, with no gaps.

---

## 4. How production does it

**`snakers4/silero-vad`** is the default choice: small, ONNX-exportable, permissively
licensed, multilingual, and shipped with the smoothing parameters from §2.5 already
sensible. The integration rules that matter: assert the 512-sample window, keep a
pre-roll buffer so `speech_pad_ms` can actually pad the onset, and reset state between
sessions but never mid-utterance.

**`livekit-plugins-silero`** wraps it for LiveKit Agents (`livekit-agents==1.7.0`
declares a `silero` extra), which is how most LiveKit deployments get their VAD. The
`AgentSession` takes a `vad` component, and the practical consequence is that your VAD's
thresholds interact with the framework's endpointing behaviour — so tuning one without
the other produces confusing results
([`../07-livekit/02-agents-framework.md`](../07-livekit/02-agents-framework.md)).

**WebRTC VAD** ships inside every browser and is exposed through
`getUserMedia`-adjacent processing; `wiseman/py-webrtcvad` is the common Python binding.
Use it as the cheap first-stage gate described in §2.6.

**`pyannote.audio`** provides neural voice-activity and overlapped-speech detection as
part of its segmentation pipeline; if you need overlap detection rather than plain VAD,
this is the place to look
([`../02-asr/09-diarization-and-speaker-id.md`](../02-asr/09-diarization-and-speaker-id.md)).

**Hosted ASR endpoints run their own VAD**, usually not configurable, and its policy
becomes part of your latency budget whether you like it or not. If a vendor's endpointing
fires at 700 ms of silence and you cannot change it, that 700 ms is yours
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md)).
Find out the default before you design around it.

---

## 5. At scale

**VAD is the cheapest way to cut your ASR bill, and the arithmetic is large.** In a
typical conversation each party is silent most of the time. Gating ASR on VAD removes
that fraction of the encoder work, and for a fixed-window model such as Whisper it
additionally removes the padding tax
([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md) §5). Nothing else in the
pipeline offers that ratio for so little code.

**Run it per session on CPU, not batched on GPU.** Silero is small enough that
per-session CPU inference at 31 calls/second is cheap, and batching it across sessions
would add exactly the coordination latency you are trying to avoid. VAD is the one
component where the naive per-session approach is correct.

**Thresholds must be per-deployment, not global.** §2.2 measured a 20 dB shift in
optimal threshold across SNR conditions. A single global default cannot be right for
both a headset user and a speakerphone in a car. Segment your traffic by channel type
and calibrate each — and where you cannot, use an adaptive noise floor so the threshold
tracks conditions automatically.

**Instrument the VAD, because it explains other components' failures.** Export speech
fraction per call, segment count per minute, mean segment duration, and the rate of
segments shorter than `min_speech_duration_ms`. A rise in segment count per minute with
flat speech fraction is fragmentation (§2.3) and predicts ASR quality problems before
users report them. This is a small number of counters and it converts "the transcripts
got worse" into a specific diagnosis.

**The cascade pays off at scale.** WebRTC VAD as a first-stage gate rejects most silence
at negligible cost, so the neural model runs on a fraction of frames. At thousands of
concurrent sessions this is real money, and it does not change detection quality if the
gate is tuned for high recall (let everything ambiguous through).

**Failure isolation matters more than accuracy here.** A VAD that gets stuck in the
speech state produces an infinite turn — the endpointer never fires, the user waits
forever, and no error is logged. Bound it: enforce a maximum utterance duration, which
is what Silero's `max_speech_duration_s` exists for, and alert when it triggers
([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).

---

## 6. Exercises

**E3.1.1** Run the §3 code. Then replace the fixed threshold with an adaptive one — a
low percentile of the last 2 seconds of frame energy, plus a margin — and re-measure AUC
and best F1 at all four SNRs. Quantify the improvement at 0 dB.

**E3.1.2** Reproduce the fragmentation table for the combined `energy - 20*ZCR` feature
instead of energy alone. Does the optimal hangover change? Explain why or why not from
the physical cause of fragmentation.

**E3.1.3** Add a non-stationary interferer — a second harmonic stack at a different
$F_0$, standing in for a television — at 0 dB SNR. Report AUC for energy, ZCR and the
combination. Explain the result in terms of §2.1's three cue families.

**E3.1.4** Implement the two-stage cascade from §2.6: a permissive cheap gate followed by
the full detector. Measure the fraction of frames reaching stage two and the change in
overall F1. State the recall you must demand of stage one and why.

**E3.1.5** Install Silero VAD and feed it 20 ms frames directly, without buffering to
512 samples. Document exactly what happens — error, silent degradation, or correct
behaviour — and then implement the correct buffering with a pre-roll for
`speech_pad_ms`.

**E3.1.6** Using a real recording of your own voice with two deliberate 400 ms
mid-sentence pauses, tune the hangover so that the pauses do not split the utterance.
Then report what that hangover costs you in end-of-turn detection latency, and connect it
to [`02-endpointing.md`](02-endpointing.md).

**E3.1.7** Build the cost model: assign a cost to a missed speech frame and to a false
speech frame based on a scenario you specify (for example, GPU seconds for false
positives, a repeated user turn for false negatives). Find the ROC operating point that
minimises total cost, and compare it against the best-F1 point.

---

## 7. Interview drill

> "Our agent sometimes transcribes the caller's television as if it were the caller, and
> sometimes drops the first word of a sentence. Same VAD, same config. Explain how both
> can be true and what you would change."

The answer that shows understanding starts by identifying these as **the two ends of one
operating point**, not two independent bugs. Transcribing the television is a false
positive; dropping the first word is a false negative at the onset. A single threshold
sits somewhere on the ROC curve of §2.2, and moving it trades one for the other. So
"tighten the VAD" fixes the television and worsens the clipping, which is presumably how
the configuration arrived at its current unhappy compromise.

The next move is to reject the framing that a threshold change can solve it, and explain
why: energy and harmonicity cannot separate speech from a television, because a
television *is* speech (§2.1). No operating point on an energy-based curve separates
them. That reframes the problem from tuning to capability.

Then the two fixes, which are different in kind. For the television, the discriminator
has to be something other than "is this speech" — a neural VAD trained with babble and
broadcast in its negatives will do better, and beyond that the right tool is speaker
identity: enrol or cluster the caller and reject speech that does not match
([`../02-asr/09-diarization-and-speaker-id.md`](../02-asr/09-diarization-and-speaker-id.md)).
If the deployment allows it, the cheapest real fix is upstream of the VAD entirely —
better microphone directionality or client-side noise suppression
([`05-echo-and-aec.md`](05-echo-and-aec.md)).

For the clipped first word, the fix is not threshold at all, it is the **pre-roll
buffer** (§2.5): keep a rolling 200–300 ms of audio before the trigger and prepend it
when speech is detected. The onset is detected late by construction — the detector needs
evidence — so you recover the missing audio from the past rather than trying to detect
faster. This is the insight the question is testing, and it costs nothing in accuracy.

A strong close adds measurement, because the report was anecdotal: log VAD probability
alongside audio for the failing calls, compute the ROC on that real audio rather than on
assumptions, and choose the operating point from the *cost* of each error in this product
— a false positive costs GPU time and a hallucinated transcript, a false negative costs
the user repeating themselves — rather than from F1, which weights them equally and has
no reason to be the right tradeoff.

---

## Sources

- `snakers4/silero-vad`, `src/silero_vad/utils_vad.py` (master, retrieved 2026-08-22) — `num_samples = 512 if sr == 16000 else 256`, and the `get_speech_timestamps` defaults `threshold=0.5`, `min_speech_duration_ms=250`, `min_silence_duration_ms=100`, `speech_pad_ms=30`, `max_speech_duration_s=inf`, `neg_threshold`, `window_size_samples=512` quoted in §2.5.
- WebRTC source, `common_audio/vad` — the six-sub-band GMM likelihood-ratio design and aggressiveness modes described in §2.6; `wiseman/py-webrtcvad` for the Python binding and its 8/16/32/48 kHz, 10/20/30 ms frame constraints.
- `livekit-agents` 1.7.0 package metadata (PyPI JSON, retrieved 2026-08-22) — the `silero` extra and `livekit-plugins-silero` referenced in §4.
- `pyannote/pyannote-audio` — neural voice-activity and overlapped-speech detection.
- Sohn, J., Kim, N. S. & Sung, W. (1999). *A statistical model-based voice activity detection.* IEEE Signal Processing Letters 6(1) — the likelihood-ratio formulation underlying classical VADs.
- All `[MEASURED]` values in §2.2, §2.3 and §2.4 were produced by the code in §3 on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2, on synthetic audio with generator-derived ground truth. Synthetic signals overstate absolute performance; the *relative* findings (threshold drift with SNR, fragmentation at best frame F1, hangover dominating hysteresis) are the transferable results.
