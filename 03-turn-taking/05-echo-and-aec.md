# Echo, and Why Your Agent Interrupts Itself

**What you'll be able to do after this:** derive and implement NLMS adaptive echo
cancellation and read its convergence curve; explain why double-talk destroys a naive
canceller and *why the destruction takes the form of cancelling the user*; state where AEC
must live and why server-side cancellation is close to hopeless; and diagnose
self-interruption in production with a test that costs nothing.

---

## 1. Intuition

Your agent speaks through a speaker. The microphone, sitting a few centimetres away,
hears it. That signal goes to your VAD, which correctly reports "speech detected", and
your barge-in logic — also correctly, given its inputs — concludes that the user is
interrupting. The agent stops talking, hears nothing, and starts again. Then it
interrupts itself again.

This is the single most common cause of a voice agent that "randomly stops mid-sentence",
and the reason it is so frequently missed in development is brutal: **it does not happen
on headphones.** The entire team tests on headphones, ships, and the first speakerphone
user finds it immediately.

The fix has a name and it is old: acoustic echo cancellation. The idea is that you have
information no other component has — **you know exactly what you played**. If you can
model the acoustic path from your speaker to your microphone, you can predict the echo
and subtract it, leaving only the sound that did not come from you.

Two things make that hard.

**The acoustic path is unknown and non-stationary.** It depends on room geometry,
speaker and microphone placement, volume, the position of the user's head, whether a
laptop lid moves. So the filter must be *learned online* and continuously re-learned.
That is what makes AEC an adaptive-filtering problem rather than a subtraction.

**Both parties sometimes speak at once.** This is *double-talk*, and it is where naive
cancellers do not merely degrade — they invert. The adaptive filter's job is to minimise
the microphone signal's residual energy. When the user speaks, the largest available
source of residual energy is *the user*, so the filter dutifully adapts to cancel them.
Measured in §2.4: without double-talk protection, the near-end speaker is attenuated by
10 dB, while with protection they are preserved. **An unprotected AEC actively removes the
voice you are trying to hear**, which is a far more insidious failure than leaving echo in.

---

## 2. Rigour

### 2.1 The signal model

Let $x(n)$ be the **far-end** signal — what you sent to the speaker, which you know
exactly. Let $h$ be the impulse response of the acoustic echo path. The microphone
observes

$$d(n) = \underbrace{(h * x)(n)}_{\text{echo}} + \underbrace{s(n)}_{\text{near-end speech}} + \underbrace{v(n)}_{\text{noise}}$$

The goal is to estimate $\hat{h}$, form $\hat{y}(n) = (\hat{h} * x)(n)$, and output the
residual

$$e(n) = d(n) - \hat{y}(n) \approx s(n) + v(n)$$

The quality metric is **echo return loss enhancement**:

$$\mathrm{ERLE} = 10\log_{10}\frac{\mathbb{E}[d^2(n)]}{\mathbb{E}[e^2(n)]}\ \text{dB}$$

ERLE is only meaningful during **single-talk** — when $s(n) = 0$ and everything in $d$ is
echo. During double-talk a *low* ERLE is correct, because you want $s(n)$ to survive.
§2.4 shows this inversion explicitly, and it is a trap in real measurement work: a
dashboard that alerts on low ERLE will fire every time the user speaks.

Two structural facts about $h$ that determine your design. Its **length** is set by room
reverberation — a small office tail of 100–200 ms at 16 kHz is 1600–3200 taps, which is
why real AEC works in the frequency domain in subbands rather than as one long
time-domain filter. And it has a **bulk delay** from the playout and capture path
(hardware buffers, driver latency), often tens of milliseconds, which the filter must
either span or have removed by an explicit delay estimator. Getting the delay estimate
wrong is the most common reason a correctly-implemented AEC achieves nothing at all.

### 2.2 NLMS

Least mean squares adapts the filter by gradient descent on the instantaneous squared
error. With $\mathbf{x}(n)$ the vector of the last $L$ far-end samples:

$$\mathbf{w}(n+1) = \mathbf{w}(n) + \mu\, e(n)\, \mathbf{x}(n)$$

Plain LMS has a fatal practical flaw: the effective step size scales with input power, so
a filter tuned on quiet speech diverges on loud speech. **Normalised** LMS divides by the
input energy:

$$\mathbf{w}(n+1) = \mathbf{w}(n) + \frac{\mu\, e(n)\, \mathbf{x}(n)}{\|\mathbf{x}(n)\|^2 + \epsilon}$$

which makes $\mu$ dimensionless and stable for $0 < \mu < 2$. The $\epsilon$ prevents
division by zero during silence — and note that during silence the update is meaningless
anyway, which is a hint that gating adaptation on far-end activity is worthwhile.

The step size trades convergence speed against steady-state accuracy. Measured on a
synthetic four-tap echo path (delays 30/55/90/140 samples, gains 0.6/−0.3/0.15/−0.07),
$L = 256$, ERLE per 0.5 s window `[MEASURED]`:

| $\mu$ | 0.5 s | 1.0 s | 1.5 s | 2.0 s | 2.5 s | 3.0 s | 3.5 s |
|---|---|---|---|---|---|---|---|
| 0.05 | 21.1 | 25.5 | 27.4 | 29.2 | 31.0 | 33.0 | 34.8 |
| 0.20 | 23.8 | 32.0 | 38.7 | 42.6 | 44.5 | **44.8** | **44.8** |
| 0.50 | 24.8 | 40.4 | **43.5** | 43.5 | 43.8 | 43.7 | 43.6 |
| 1.00 | 24.1 | 40.8 | 41.0 | 41.0 | 41.5 | 41.3 | 41.1 |

Three readings.

**Convergence takes seconds, not milliseconds.** Even at $\mu = 0.5$, reaching 40 dB
takes about a second. This is why LiveKit Agents defines
`_DEFAULT_AEC_WARMUP_DURATION = 3.0` (verified from source, §4): for the first few
seconds of a session the canceller's output cannot be trusted, and any barge-in logic
keyed on it will misfire. If your agent interrupts itself specifically at the start of
calls, this is why.

**Large $\mu$ converges fast and settles worse.** $\mu = 1.0$ reaches 40.8 dB by 1 second
but plateaus at 41 dB, while $\mu = 0.2$ is slower and reaches 44.8 dB. This is the
classic adaptive-filter tradeoff, and it motivates **variable step size**: adapt
aggressively when far from convergence, gently once converged.

**Steady-state ERLE is finite and modest.** 40–45 dB here, on a *synthetic linear*
echo path with a filter long enough to span it. Real paths are longer than your filter,
and real speakers are non-linear, so 20–30 dB is a more realistic expectation — which is
why a residual echo suppressor is a mandatory second stage (§2.5).

### 2.3 Double-talk destroys the filter

Introduce near-end speech at $t = 2.0$ s and adapt continuously, with no protection
`[MEASURED]`:

| Window | 0.5 s | 1.0 s | 1.5 s | 2.0 s | **2.5 s** | **3.0 s** | **3.5 s** |
|---|---|---|---|---|---|---|---|
| ERLE (dB), no DTD | 24.8 | 40.4 | 43.5 | 43.5 | **14.5** | **10.9** | **14.8** |

The filter had converged to 43.5 dB. Within half a second of the user speaking it has
fallen to 10.9 dB — a 30 dB regression. The filter did not "get confused"; it did exactly
what it was told, minimising residual energy, and the residual energy is now the user's
voice.

The mechanism is worth stating precisely because it explains the *shape* of the
production symptom. The adaptation is driven by $e(n)\mathbf{x}(n)$, which correlates the
residual with the far-end. When near-end speech is present, the residual contains a large
component uncorrelated with $\mathbf{x}$, so the gradient estimate is dominated by noise
and the weights random-walk away from the true $h$. The filter is being *actively
corrupted* while the user talks, so the echo returns afterwards too — the agent starts
hearing itself again after every user turn.

### 2.4 Double-talk detection, and the metric that inverts

The standard defence is to detect double-talk and **freeze adaptation** — keep the
converged filter, keep subtracting, stop learning. Detectors include Geigel (compare
microphone level against recent far-end maximum), normalised cross-correlation, and
coherence-based tests. A practical one uses the smoothed power ratio $P_e / P_d$: once
converged this ratio is small, so a sudden rise means energy the filter cannot explain.

Measured with that detector `[MEASURED]`:

| Configuration | 0.5 s | 1.0 s | 1.5 s | 2.0 s | 2.5 s | 3.0 s | 3.5 s |
|---|---|---|---|---|---|---|---|
| no DTD | 24.8 | 40.4 | 43.5 | 43.5 | 14.5 | 10.9 | 14.8 |
| DTD, ratio 0.15 (froze 44.9%) | 24.8 | 40.4 | 43.5 | 43.5 | −15.0 | −19.1 | −18.0 |
| DTD, ratio 0.30 (froze 38.9%) | 24.8 | 40.4 | 43.5 | 43.5 | −8.1 | −29.0 | −27.9 |
| DTD, ratio 0.50 (froze 38.6%) | 24.8 | 40.4 | 43.5 | 43.5 | −10.0 | −30.8 | −29.7 |

The negative ERLE looks alarming and is **the correct result**. During double-talk the
output $e$ contains the near-end speaker, which is *louder* than the echo-only $d$ would
have been, so the ratio $P_d/P_e$ drops below one and its logarithm goes negative. ERLE is
simply the wrong metric during double-talk. This is exactly the trap flagged in §2.1, and
it is why production AEC monitoring must gate ERLE on a single-talk condition.

The metric that actually answers the question is how much of the near-end speaker
survives. Measured over the double-talk interval, relative to the original near-end
signal `[MEASURED]`:

| Configuration | Near-end preserved |
|---|---|
| no DTD | **−10.0 dB** |
| DTD, ratio 0.30 | **+30.6 dB** |

This is the finding of the chapter. Without double-talk detection the user's voice is
attenuated by 10 dB — **the AEC is cancelling the person you are trying to hear.** With
detection it passes through with 30 dB of headroom. And now the production symptom is
fully explained: an agent with a naive AEC does not merely echo, it becomes *deaf* while
speaking, so barge-in stops working, users repeat themselves louder, and the agent talks
over them. Every one of those complaints traces back to a missing double-talk detector.

Note the cost: the detector froze adaptation for roughly 39% of samples. That is the
tradeoff — you stop tracking a changing room while the user speaks. If the acoustic path
changes during a long double-talk stretch, the frozen filter becomes stale and echo
returns when the user stops. Hence real systems keep a second, slowly-adapting "shadow"
filter and swap it in when it outperforms the active one.

### 2.5 The full client-side chain

AEC alone is insufficient. The standard chain, in order:

| Stage | Purpose | Why it is needed |
|---|---|---|
| **Delay estimation** | align far-end reference with microphone | wrong delay makes AEC useless (§2.1) |
| **Linear AEC** | subtract the modelled echo | the 20–45 dB from §2.2 |
| **Non-linear / residual echo suppression** | attenuate what linear AEC cannot model | speakers clip and distort; the echo is not a linear function of $x$ |
| **Noise suppression** | steady-state noise | improves ASR and VAD |
| **Automatic gain control** | normalise level | ASR expects a consistent level |
| **High-pass filter** | remove DC and rumble | wasted bits and VAD false triggers |

The **non-linear** stage is the one engineers underestimate. A small laptop or phone
speaker driven near its limit clips, and clipping generates harmonics that are not in $x$
at all — so no linear filter can predict them. Residual suppression is usually
spectral: estimate the residual echo's magnitude per frequency band and apply a
suppression gain. It is effectively a smart mute, and pushed too hard it becomes
half-duplex — which is what "the agent can't hear me while it's talking" means in a
system with aggressive suppression rather than a missing detector.

### 2.6 Where AEC must live

**On the client, always.** The reason is definitional rather than practical: AEC needs the
far-end reference *as it was actually played*, time-aligned with the microphone capture.
Only the device that played it has that.

Server-side cancellation faces obstacles that are individually hard and jointly fatal.
The reference must be transported back or reconstructed, and its alignment with the
microphone stream is unknown to within the network jitter — which varies per packet. The
microphone signal has already been through the client's own AGC and noise suppression,
which are non-linear and time-varying, so the echo is no longer a linear function of your
reference. And it has been Opus-coded, which is lossy and non-linear. Each of these
breaks an assumption in §2.1.

The practical consequences:

- **Browser:** you get WebRTC's AEC3 for free through `getUserMedia` constraints
  (`echoCancellation`, `noiseSuppression`, `autoGainControl`). Leave them on. Disabling
  `echoCancellation` for "better audio quality" is a recurring self-inflicted wound.
- **Native app:** use the platform APIs (Apple's Voice-Processing I/O, Android's
  `VOICE_COMMUNICATION` mode) or embed WebRTC's APM. Do not write your own.
- **Telephony:** echo control lives in the network and the endpoint; you get what the
  carrier and handset provide, and it is governed by the ITU-T G.168 echo-canceller
  standard.
- **Server-side Python agent reading raw microphone audio:** you have no AEC. This is the
  configuration in most local development scripts, and it is why the first thing to check
  when an agent interrupts itself is whether AEC exists at all
  ([`../01-foundations/03-audio-io-and-buffering.md`](../01-foundations/03-audio-io-and-buffering.md)).

### 2.7 Diagnosing self-interruption

An ordered checklist, cheapest first. Each step eliminates a hypothesis.

1. **Headphones test.** Same scenario on headphones. If the problem disappears, it is
   acoustic echo. This is the single highest-information test in this chapter and it
   costs nothing.
2. **Correlate interruptions with agent speech.** If interruption events cluster inside
   intervals when the agent was speaking, it is hearing itself. If they are uniformly
   distributed, look at VAD thresholds or endpointing instead
   ([`02-endpointing.md`](02-endpointing.md)).
3. **Check that AEC is enabled** and that the reference is actually reaching it. A
   correctly-implemented AEC with no far-end reference is an expensive pass-through.
4. **Check the warm-up window.** Interruptions concentrated in the first seconds of a
   call point at unconverged adaptation (§2.2) — the reason a warm-up constant exists.
5. **Look for double-talk collapse.** If self-interruption starts *after* the first user
   turn rather than immediately, the filter is being corrupted during double-talk
   (§2.3) — a missing or mistuned detector.
6. **Check volume and clipping.** High speaker volume drives non-linearity that linear
   AEC cannot touch (§2.5). Reducing output level is a legitimate fix.
7. **Only then** raise the barge-in threshold. Doing this first masks the symptom and
   makes genuine interruption worse
   ([`04-barge-in.md`](04-barge-in.md)).

---

## 3. From scratch

NLMS with a power-ratio double-talk detector, and the ERLE and near-end-preservation
measurements. Standalone, numpy only.

```python
"""NLMS acoustic echo cancellation, with and without double-talk protection."""
import numpy as np

SR = 16_000

def make_scene(seconds=4, near_start_s=2.0, seed=3):
    """far-end (what we played), mic signal, and the near-end speech we must keep."""
    rng = np.random.default_rng(seed)
    n = SR * seconds
    t = np.arange(n) / SR
    # Far-end: harmonic 'speech' with a 4 Hz syllabic envelope.
    far = (np.sin(2*np.pi*180*t)*0.5 + np.sin(2*np.pi*540*t)*0.3) \
          * (0.5 + 0.5*np.sin(2*np.pi*4*t)) + 0.02*rng.standard_normal(n)
    # Echo path: bulk delay plus a few decaying reflections.
    h = np.zeros(200); h[30], h[55], h[90], h[140] = 0.6, -0.3, 0.15, -0.07
    echo = np.convolve(far, h)[:n]
    near = np.zeros(n)
    k = int(SR * near_start_s)
    near[k:] = np.sin(2*np.pi*220*t[k:]) * 0.4 * (0.5 + 0.5*np.sin(2*np.pi*3*t[k:]))
    mic = echo + near + 0.001*rng.standard_normal(n)
    return far, mic, near

def nlms(x, d, L=256, mu=0.5, eps=1e-6, dtd=False,
         warmup=SR//2, ratio_thresh=0.30, smooth=0.995, hold=1600):
    """Normalised LMS. Optional double-talk detector freezes adaptation.

    Detector: once converged, smoothed P_e/P_d is small. A rise means energy the
    filter cannot explain -- i.e. near-end speech. Freeze (do not reset) so the
    converged filter keeps subtracting while it stops learning.
    """
    w = np.zeros(L)
    e = np.zeros(len(d))
    xbuf = np.zeros(L)
    Pe = Pd = 1e-9
    frozen = hold_ctr = 0
    for n in range(len(d)):
        xbuf[1:] = xbuf[:-1]; xbuf[0] = x[n]
        e[n] = d[n] - w @ xbuf
        Pe = smooth*Pe + (1-smooth)*e[n]**2
        Pd = smooth*Pd + (1-smooth)*d[n]**2
        if dtd and n > warmup:
            if Pe / max(Pd, 1e-12) > ratio_thresh:
                hold_ctr = hold
            if hold_ctr > 0:
                hold_ctr -= 1
                frozen += 1
                continue                      # subtract, but do not adapt
        # Normalisation makes mu dimensionless; eps guards silence.
        w += mu * e[n] * xbuf / (xbuf @ xbuf + eps)
    return e, frozen

def erle(d, e, win=SR//2):
    """Echo return loss enhancement, per window. ONLY meaningful in single-talk."""
    return np.array([10*np.log10((d[i:i+win]**2).mean()
                                 / max((e[i:i+win]**2).mean(), 1e-20))
                     for i in range(0, len(d)-win, win)])

if __name__ == "__main__":
    far, mic, near = make_scene()
    echo_only = mic - near                     # single-talk reference

    print("A. single-talk convergence, ERLE per 0.5 s window")
    for mu in (0.05, 0.20, 0.50, 1.00):
        e, _ = nlms(far, echo_only, mu=mu)
        print(f"  mu={mu:4.2f}: " + " ".join(f"{v:5.1f}" for v in erle(echo_only, e)))

    print("\nB. double-talk from t=2.0 s")
    e_no, _ = nlms(far, mic, mu=0.5)
    print("  no DTD      : " + " ".join(f"{v:5.1f}" for v in erle(mic, e_no)))
    for rt in (0.15, 0.30, 0.50):
        e_d, fr = nlms(far, mic, mu=0.5, dtd=True, ratio_thresh=rt)
        print(f"  DTD rt={rt:.2f} (frozen {100*fr/len(mic):4.1f}%): "
              + " ".join(f"{v:5.1f}" for v in erle(mic, e_d)))

    print("\nC. near-end preservation over the double-talk interval")
    print("   (the metric that matters: we must NOT cancel the user)")
    seg = slice(SR*2, SR*4)
    for label, e in (("no DTD", e_no),
                     ("DTD rt=0.30", nlms(far, mic, mu=0.5, dtd=True)[0])):
        db = 10*np.log10((e[seg]**2).mean() / max((near[seg]**2).mean(), 1e-20))
        print(f"  {label:12s}: {db:+5.1f} dB relative to the original near-end")
```

The `continue` inside the detector branch is the entire mechanism, and its placement is
deliberate: the residual $e[n]$ has already been computed, so the converged filter keeps
*subtracting* echo while it stops *learning*. Freezing adaptation is not the same as
bypassing the canceller, and implementations that disable the whole filter during
double-talk reintroduce full echo exactly when the user is speaking.

---

## 4. How production does it

**WebRTC's audio processing module** (`modules/audio_processing` in the WebRTC source) is
the reference implementation and what runs in every browser: AEC3 with delay estimation,
subband adaptive filtering, residual echo suppression, noise suppression, AGC and a
high-pass filter, operating on 10 ms frames. If you are building a browser client you
already have all of §2.5, and the correct action is to leave the `getUserMedia`
constraints `echoCancellation`, `noiseSuppression` and `autoGainControl` enabled.

**LiveKit Agents** acknowledges convergence explicitly:
`_DEFAULT_AEC_WARMUP_DURATION = 3.0` (verified in
`livekit-agents/livekit/agents/voice/agent_session.py`, main branch, retrieved
2026-08-22). That constant exists because of §2.2 — output before convergence cannot be
trusted, so interruption logic must not act on it. It pairs with the interruption
parameters in [`04-barge-in.md`](04-barge-in.md) §4, and for a WebRTC deployment the
cancellation itself happens in the browser or native SDK, not in the agent process.

**Speexdsp and `webrtc-audio-processing`** are the standalone libraries for embedding AEC
outside a browser; on Apple platforms the Voice-Processing I/O audio unit provides the
platform chain, and Android's `VOICE_COMMUNICATION` capture preset does the same. The
consistent advice across all of them: use the platform implementation, because AEC has
twenty years of accumulated edge cases and none of them are in a paper.

**Telephony** is governed by ITU-T G.168 for network echo cancellers, and the failure
modes are different — hybrid echo from analogue conversion, and long-delay echo from
satellite or poorly-configured VoIP legs
([`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)).

**Hosted speech-to-speech APIs** assume the client has done this. Their server-side turn
detection operates on the audio you send, so if you send echo, they will detect it as
speech. AEC is your responsibility regardless of how much of the stack you outsource.

---

## 5. At scale

**AEC is client-side, so it is not on your server bill — and it is not under your
control either.** Your fleet's echo behaviour is a function of your users' devices,
browsers and platform versions. Treat it as a property of the traffic to be measured, not
a component to be tuned: segment interruption rate by client type, and expect
speakerphone and kiosk deployments to behave differently from headset users.

**Instrument self-interruption as a first-class metric.** The proxy is cheap: count
interruption events whose onset falls inside an interval when the agent was speaking, and
divide by agent-speaking time. Compare it against the same rate outside agent speech. A
significant excess is echo, not users, and it is the one metric that distinguishes them
without listening to audio.

**Gate ERLE monitoring on single-talk.** §2.4 showed ERLE goes negative during
double-talk *by design*. An alert on low ERLE will fire constantly on healthy systems.
Compute ERLE only over intervals where the near-end is quiet, or you will train your team
to ignore the alert.

**Kiosks and speakerphones need different treatment, and it is mostly hardware.**
Loud output, close microphone coupling and non-linear speakers push echo beyond what
linear AEC handles (§2.5). The effective levers are physical — directional microphone,
lower output level, physical separation, and hardware with a dedicated echo-cancelling
DSP — plus, if necessary, accepting half-duplex behaviour for that deployment class. This
is a case where the right engineering answer is not software.

**Beware AGC fighting your VAD.** Automatic gain control normalises level, which means the
absolute energy threshold your VAD was calibrated against is being actively rescaled by
another component ([`01-vad.md`](01-vad.md) §2.2). This is a further argument for adaptive
noise-floor tracking rather than fixed thresholds, and for keeping the whole client chain
consistent across your fleet.

**Do not disable AEC to "improve" audio for ASR.** It is a recurring and expensive
mistake: cancellation does colour the signal slightly, and a cleaner-sounding stream that
contains your own output is far worse for a voice agent than a slightly processed one that
does not. If ASR quality is the concern, measure WER with AEC on and off
([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)) rather than reasoning from
how it sounds.

---

## 6. Exercises

**E3.5.1** Run the §3 code. Then lengthen the echo path beyond the filter length — put a
reflection at tap 300 with $L = 256$ — and report steady-state ERLE. Explain the ceiling
in terms of what the filter can represent.

**E3.5.2** Add a bulk delay of 500 samples to the echo path without lengthening the
filter. Report ERLE, then implement a delay estimator (cross-correlate far-end with
microphone) and show the recovery. Quantify how wrong the delay estimate can be before
AEC stops working.

**E3.5.3** Implement a variable step size: large $\mu$ while $P_e/P_d$ is high, small once
converged. Compare its convergence curve against the fixed-$\mu$ rows in §2.2 and report
whether it achieves both fast convergence and high steady-state ERLE.

**E3.5.4** Introduce non-linearity by clipping the played signal at $\pm 0.6$ before it
enters the echo path, leaving the reference un-clipped. Measure the ERLE ceiling and
explain why no linear filter can exceed it.

**E3.5.5** Simulate the acoustic path *changing* mid-call (swap $h$ at $t = 2.5$ s) during
frozen adaptation. Measure how much echo returns, then implement a slowly-adapting shadow
filter and show it recovering.

**E3.5.6** Sweep the DTD ratio threshold and plot near-end preservation against
single-talk ERLE. Identify the operating point and state which error each end of the range
produces in a real conversation.

**E3.5.7** Build the §2.7 diagnostic as an automated check: given a recording of a call
with agent-speaking intervals labelled, compute the excess interruption rate during agent
speech and output a verdict. State the threshold you would alert on.

---

## 7. Interview drill

> "Our voice agent works perfectly in the office and fails for one customer whose staff
> use desk speakerphones. It interrupts itself constantly, and when their staff talk over
> it, it goes deaf and never responds. Same code, same config."

The two symptoms are one root cause and the answer should link them, because doing so
demonstrates you understand the mechanism rather than the checklist. Speakerphones couple
the speaker to the microphone acoustically, which the office headsets did not, so the
agent now hears itself — that is the self-interruption. And the "goes deaf when they talk
over it" is §2.4: with echo present and adaptation running unprotected, the filter adapts
toward cancelling whatever dominates the residual, which during double-talk is the human.
The measured attenuation was 10 dB. So the agent is not ignoring them, it is *subtracting*
them.

The first diagnostic is free and should be stated as such: have one of their staff use
headphones for a single call. If both symptoms vanish, the acoustic path is confirmed and
no further investigation of your code is warranted. That test replaces a day of
speculation.

Then locate the missing piece. Because AEC must be client-side (§2.6), the question is
what their client is: a browser gets AEC3 through `getUserMedia` and should be fine unless
someone disabled `echoCancellation`; a native or embedded client may have no AEC at all;
and a server-side process reading raw audio certainly does not. Establishing which of
these it is determines the fix, and it is a configuration question rather than a modelling
one.

The remedies in order of leverage: ensure platform AEC is enabled with the far-end
reference actually wired to it; add or fix double-talk detection so adaptation freezes
rather than corrupting the filter; reduce speaker output level, since non-linear echo from
a clipping speaker is beyond any linear canceller (§2.5); and only then consider raising
the barge-in threshold — noting explicitly that doing it first would mask self-interruption
at the cost of making genuine interruption worse
([`04-barge-in.md`](04-barge-in.md)).

The senior close is to admit the limit honestly. For a desk speakerphone in a hard-walled
room at high volume, software may not be sufficient, and the credible options are hardware
with a dedicated echo-cancelling DSP, a headset policy for that customer, or accepting
half-duplex behaviour where the agent does not listen while speaking. Knowing when the
answer is procurement rather than code is part of the engineering.

---

## Sources

- WebRTC source, `modules/audio_processing` — AEC3, delay estimation, residual echo suppression, noise suppression, AGC and high-pass filtering on 10 ms frames, as described in §2.5 and §4.
- W3C Media Capture and Streams specification — the `echoCancellation`, `noiseSuppression` and `autoGainControl` constraints referenced in §2.6.
- ITU-T Recommendation G.168, *Digital network echo cancellers* — the telephony standard referenced in §2.6 and §4.
- Haykin, S. *Adaptive Filter Theory* — LMS and NLMS derivation, convergence and step-size analysis underlying §2.2.
- Benesty, J., Gänsler, T., Morgan, D. R., Sondhi, M. M. & Gay, S. L. *Advances in Network and Acoustic Echo Cancellation* — double-talk detection methods including Geigel and normalised cross-correlation, §2.4.
- `livekit/agents`, `livekit-agents/livekit/agents/voice/agent_session.py` (main branch, retrieved 2026-08-22) — `_DEFAULT_AEC_WARMUP_DURATION = 3.0`, quoted in §2.2 and §4.
- `speexdsp` and `webrtc-audio-processing`; Apple Voice-Processing I/O audio unit; Android `VOICE_COMMUNICATION` capture preset — the platform implementations recommended in §4.
- All `[MEASURED]` values in §2.2, §2.3 and §2.4 were produced by the code in §3 on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2. The echo path is a synthetic 4-tap linear model, so absolute ERLE figures are optimistic relative to a real room; the transferable results are the convergence-versus-step-size tradeoff, the collapse under unprotected double-talk, and the sign of the near-end preservation figures.
