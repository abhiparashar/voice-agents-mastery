# Glossary

237 terms with precise definitions and units. Where this curriculum measured
something, the number is here too — a definition you cannot attach a magnitude to is not much
use in a design review.

---

## The confusions that matter

These twelve pairs account for most of the miscommunication in voice-AI teams. If you fix
nothing else, fix these.

| Not the same | Distinction |
|---|---|
| **VAD** ≠ **endpointing** | VAD answers "is there speech in this 20 ms frame?" — a per-frame classification. Endpointing answers "has the user finished their turn?" — a policy decision with an asymmetric cost. A perfect VAD does not give you an endpointer, and tuning a VAD for frame-level F1 makes endpointing *worse*: best frame-F1 shredded 33 utterances into 265 segments. |
| **TTFB** ≠ **TTFA** | `ttfb_tts` is when the first audio *byte* leaves the TTS engine. `ttfa` is when the first audio *reaches the user's ear*. Between them sit the network, the jitter buffer and the client's playout. You control the first and are judged on the second. |
| **jitter** ≠ **latency** | Latency is the mean delay. Jitter is the *variation* in delay. A jitter buffer converts jitter into latency, at a price: absorbing a 200 ms spike costs 200 ms of buffer for every frame. |
| **loss** ≠ **lateness** | A frame that arrives after its playout deadline is discarded exactly like one that never arrived. Reporting delivery rate instead of *usable* frames is how a TCP transport passes a network test and fails a call. |
| **WER** ≠ **quality** | WER weights "the" and "four-one-five" equally. Entity WER, latency-to-final and task success predict agent quality; overall WER predicts it weakly. |
| **agreement** ≠ **κ** | A judge can show 90% raw agreement with humans and κ = 0.11 when the base rate is 90%. Agreement measures the base rate; κ measures the signal. |
| **`ttfa`** ≠ **answer time** | "Sub-second" is almost always achievable for *starting to speak* and almost never for *delivering a tool-backed answer*. Conflating them is how teams commit to the impossible. |
| **availability per request** ≠ **per call** | Five stages at 99.5–99.995% give 98.899% per turn and **80.14%** clean 20-turn calls. Per-request SLOs do not compose into a promise about conversations. |
| **utilisation** ≠ **safe utilisation** | The utilisation you can run at is a function of pool size: 25% at 5 workers, 92.5% at 1000. "Never above 70%" is a statement about a pool of about fifty. |
| **interruption** ≠ **backchannel** | "Mm-hm" while the agent speaks is agreement, not a request to stop. Treating every overlap as an interruption produces an agent that cannot finish a sentence. |
| **serial guardrail** ≠ **safe guardrail** | A whole-response guardrail in series costs +986 ms because it must wait for generation. In parallel it costs nothing and leaks 830 ms of unsafe audio. Only clause gating gets both (+104 ms, zero leak). |
| **speech-to-speech** ≠ **one thing** | Audio-in/text-out (Ultravox), half-duplex audio-out (OpenAI Realtime, Gemini Live) and full-duplex (Moshi) are three different architectures with different latency, tooling and context costs. |

---

## A

**A-law** — European companding counterpart to µ-law in G.711.

**AEC** — Acoustic Echo Cancellation. Removes the agent's own played audio from the captured
microphone signal. Must run on the client, where both signals exist. Without double-talk
detection it attenuates the near-end speaker by **−10 dB**; with it, +30.6 dB of suppression.

**AGC** — Automatic Gain Control. Normalises input level. One of three `getUserMedia`
constraints, with `echoCancellation` and `noiseSuppression`.

**Aliasing** — Frequency content above the Nyquist limit folding down into the audible band.
Audible, irreversible, prevented only by filtering *before* sampling.

**AMD** — Answering Machine Detection. Deciding whether an outbound call reached a human or a
voicemail greeting.

**AMR / AMR-WB** — Adaptive Multi-Rate codecs used in mobile telephony.

**Anti-alias filter** — Low-pass filter applied before sampling or downsampling.

**APM** — Audio Processing Module. libwebrtc's AEC, noise suppression and gain control.
Free in any browser using WebRTC; unavailable to a raw WebSocket client.

**ASR** — Automatic Speech Recognition. Audio → text.

**Attention-based encoder-decoder (AED)** — Sequence-to-sequence ASR with cross-attention;
Whisper's family. Not inherently streaming.

**Audio token** — A discrete code from a neural audio codec. Cost is frame rate × codebooks:
Mimi at 12.5 Hz × 8 = **100 tokens/s**; Moshi's dual stream plus text = **212.5 tokens/s**,
82× the token rate of the same speech as a transcript.

**AudioWorklet** — The Web Audio node that runs on the audio thread in 128-frame quanta. The
correct choice; `ScriptProcessorNode` is deprecated and runs on the main thread, so a UI
re-render becomes an audio glitch.

**Autoplay policy** — Browser rule requiring a user gesture before audio output. Without one
the agent speaks into a muted context while your metrics look perfect.

## B

**Backchannel** — A short listener vocalisation ("mm-hm", "right") signalling attention
rather than a bid for the turn.

**Backpressure** — Blocking a producer when a downstream queue is full, so overload
propagates upstream to where a decision can be made rather than accumulating as latency.

**Bandwidth estimate** — The congestion controller's view of available capacity. Audio-only
sessions are mostly immune, but the estimate still gates FEC and redundancy.

**Barge-in** — The user speaking while the agent speaks, and the machinery for handling it.
Requires a priority interrupt path *and* an ordered playback report.

**`barge_in_latency`** — Time from user speech onset to the agent's audio stopping at the
user's ear. Units: ms.

**Beam search** — Decoding that keeps the top-$k$ hypotheses; combined in ASR with shallow LM
fusion and contextual biasing.

**Bit depth** — Bits per sample. 16-bit gives an SNR of $6.02 \times 16 + 1.76 = 98.1$ dB.

**Blue/green** — Deploying a parallel fleet and shifting traffic. For held sessions the old
colour must *drain*, not stop.

**Bounded queue** — A queue with a maximum depth, so overload becomes backpressure or loss
rather than unbounded latency. Measured: unbounded gives p50 476 ms and max 920 ms where a
2-frame bound is flat at 84 ms.

**BUNDLE** — SDP mechanism putting all media on one ICE transport, so a session needs one UDP
port rather than four.

## C

**Canary** — Routing a fraction of *new calls* to a new version. Splitting by request rather
than by call splits one conversation across two versions.

**Cancellation** — In asyncio, `Task.cancel()` schedules a `CancelledError` at the task's next
suspension point. It is not synchronous, and a task with no `await` in its hot loop cannot be
cancelled at all.

**CELT** — The MDCT layer of Opus, used at higher bandwidths. 2.5 ms of look-ahead.

**Chunked prefill** — Splitting a long prefill across scheduler steps to protect decode
latency. Measured to pay only on a cold cache (tpot p95 41.3 → 33.7 ms).

**Circuit breaker** — Failing fast after repeated errors to protect a sick dependency. Fed
post-retry outcomes it **never opens**; fed attempt outcomes it cut provider load 87% while
raising user-visible failures from 86 to 1152 — so it is only correct paired with a fallback.

**Clause aggregator** — The component turning an LLM token stream into speakable clauses for
streaming TTS. Also the correct place for an output guardrail.

**Clock drift** — Divergence between capture and playback clocks, measured in ppm. 100 ppm is
360 ms over an hour.

**Codebook** — One quantiser stage in RVQ. Mimi uses 8 codebooks of 2048 entries (11 bits),
giving 1.1 kbit/s at 12.5 Hz.

**Coarticulation** — Neighbouring phones influencing each other's realisation; why
context-dependent units existed.

**Cohen's κ** — Agreement corrected for chance. Essential when class balance is skewed.

**Cold start** — Time from "capacity requested" to "capacity serving". Measured effect: idle=0
put a **2.74 s** cold start on every call; idle=2 removed it. Decomposes into node
provisioning, image pull, weight load, process init and first-inference JIT.

**Concatenative synthesis** — TTS by splicing recorded units. Superseded.

**Conformer** — Convolution-augmented transformer encoder, common in streaming ASR.

**Congestion control** — Rate adaptation from delay and loss signals; GCC in WebRTC.

**Consent** — The lawful basis for recording. Must be captured *before* the first recorded
frame, which makes it a state machine rather than a flag.

**Containment** — Fraction of calls resolved without escalation to a human.

**Context window** — The model's maximum token span. Audio-native sessions exhaust it fast:
Moshi's dual stream fills 32k in **2.6 minutes** where a transcript takes 210.

**Continuous batching** — Serving that admits and retires sequences per step. Measured `ttft`
p50 **15 ms** against 489 ms for static batching.

**Contextual biasing** — Boosting specific phrases during decoding so ASR hears your product
and place names.

**CTC** — Connectionist Temporal Classification. Frame-synchronous ASR loss with a blank
symbol; alignment-free, cannot model output dependencies.

**Cut-off rate** — Fraction of turns where the endpointer fired while the user was still
speaking. The cost on the other side of dead air.

## D

**Data frame** — In a frame graph, an in-band ordered payload frame, cancelled by
interruptions.

**dBA** — A-weighted sound pressure level, approximating human loudness perception. An
*acoustic* measure.

**dBFS** — Decibels relative to full scale; 0 dBFS is the loudest representable sample. A
*digital* measure. Not comparable to dBA.

**Dead air** — Unexplained silence during a call. The invariant is that it never exceeds
~1–1.5 s, above which users say "hello?" and talk over the recovery.

**Deadline** — A time budget propagated down the call chain. A reliability mechanism, not a
performance one: it is the only defence against a provider brownout.

**Decode** — Autoregressive token generation, one token per forward pass. Measured
6.37 ms/token against 0.09 ms/token for prefill — a 69× gap.

**Deepfake** — Synthetic media presented as real. AI Act Art. 50(4) requires disclosure.

**DER** — Diarization Error Rate. Missed speech + false alarm + speaker confusion.

**DET curve** — Detection Error Tradeoff: false-reject against false-accept.

**Diarization** — Determining who spoke when.

**DID** — Direct Inward Dialling number; a phone number you can receive calls on.

**Dither** — Small noise added before quantisation to decorrelate quantisation error;
prevents buzzy tonal distortion at low levels.

**Drain** — Marking a worker ineligible for new sessions and letting existing ones end
naturally. LiveKit's `DRAIN_TIMEOUT = 3600`. A 300 s drain still kills 22.2% of live calls.

**DTLS-SRTP** — RFC 5764. Establishes SRTP keys via a DTLS handshake over the ICE-selected
5-tuple, verified against the SDP fingerprint — so media confidentiality depends on
signalling integrity.

**DTMF** — Dual-Tone Multi-Frequency keypad tones. Three possible transports; in-band DTMF
puts loud tones into the audio your ASR is listening to.

**DTX** — Discontinuous Transmission. Opus sends "only one frame every 400 milliseconds"
during silence, removing roughly half the packets in a conversation.

**Double-talk** — Both parties speaking at once. The condition an echo canceller must detect
before adapting.

## E

**Egress** — Outbound data transfer, and its cost. ~0.6 MB per call-minute at $0.10/GB.

**Emformer** — Efficient memory transformer for streaming ASR.

**EnCodec** — RVQ neural codec at a 75 Hz frame rate; 8 codebooks give 600 tokens/s, 6× Mimi.

**Endpointing** — Deciding the user's turn has ended. A *policy* with an asymmetric cost.
Measured frontier: fixed 700 ms → 3.04% cut-off; adaptive → **2.78% at 330 ms**.

**`endpoint_f1`** — F1 of endpoint decisions against labelled turn boundaries.

**Entity WER** — WER over entities only (names, numbers, IDs). Predicts task success far
better than overall WER.

**Ephemeral token** — A short-lived credential minted server-side for a browser client.
Never ship a long-lived API key in a bundle.

**`eou_to_ttfa`** — End-of-utterance to first audio at the user's ear. The single most
important user-perceived latency metric. Units: ms.

**EER** — Equal Error Rate, where false accept equals false reject. **Not** an access-control
policy: a 2% EER model at 1% FRR admits impostors at 4%, so 25 attempts.

**Erlang** — Unit of offered load: $A = \lambda h$. 20 calls/min at 3 min each = 60 E.

**Erlang B** — Blocking probability for lost-calls-cleared systems; sizes SIP trunks.
Exhibits the trunking gain: 1 E needs 5 channels (20%), 500 E needs 527 (94.9%).

**Erlang C** — Delay model where blocked calls wait; sizes worker pools.

**Escalation** — Handing the call to a human. A successful outcome, not a failure.

**Exemplar** — A trace ID attached to a histogram bucket, letting a dashboard jump from an
aggregate to a representative call.

## F

**Fake clock** — A virtual time source for tests. Advances only when every task is blocked,
which is what makes timing assertions exact: the real clock reported 16.48 ms where the true
bound was **5.00 ms**.

**Fallback ladder** — The ordered recovery path for a failed stage: cached audio → secondary
provider → degraded answer → human handoff. Took total dead air across six failure modes
from ~51 s to ~7.5 s.

**FAR / FRR** — False Accept Rate / False Reject Rate in verification.

**FEC** — Forward Error Correction. Opus in-band FEC re-encodes important frames onto a
*subsequent* packet, costing one frame of delay rather than a round trip. Lifted usable frames
from 95.1% to **99.8%** at 5% loss. **Defaults to off** (`useinbandfec=0`, RFC 7587).

**Filler speech** — A short acknowledgement spoken while a tool call completes. Measured to
cut `ttfa` p50 from 1815 ms to **551 ms** with no change in answer time.

**Fingerprint** — The `a=fingerprint` SDP attribute carrying a hash of the DTLS certificate.

**`first_clause`** — Time from first LLM token to a complete speakable clause. Units: ms.

**Flake rate** — Fraction of runs on which a test fails without a code change. Not
reproducible for real-clock timing tests, which is why they cannot be triaged.

**Formant** — A vocal-tract resonance appearing as a spectral peak. F1–F3 carry vowel
identity.

**Frame** — 20 ms of audio in this curriculum: 320 samples at 16 kHz, 640 bytes as s16le.

**Frame graph** — A pipeline modelled as nodes passing typed frames over bounded queues.

**Frame rate (codec)** — Discrete frames per second emitted by a neural codec. The
first-order design decision for an audio LM: 12.5 Hz (Mimi) against 75 Hz (EnCodec).

**Full duplex** — A model consuming and emitting audio simultaneously and continuously, with
no turn decision. Measured `eou_to_ttfa` p50 **343 ms** against 1370 ms cascaded.

## G

**G.711** — 8 kHz PCM with µ-law or A-law companding, 64 kbit/s. The PSTN wire format.

**GCC** — Google Congestion Control: delay-based plus loss-based estimation over
transport-wide feedback.

**GDPR** — Regulation (EU) 2016/679. Art. 9 makes biometric data special-category *when used
for unique identification*, which is the trigger a voiceprint pulls.

**Gilbert–Elliott** — A two-state bursty loss model. More realistic than independent loss,
and it makes FEC look better.

**Golden audio** — A reference recording used as a regression test. Requires a perceptual
tolerance: an inaudible 62 µs shift scores worse on RMS (0.05298) than a real formant
regression (0.04586).

**G2P** — Grapheme-to-phoneme conversion.

**Greeting** — The opening utterance. Where AI-disclosure and recording consent both live, so
it is the one place not to optimise for brevity.

**Griffin-Lim** — Iterative phase reconstruction from a magnitude spectrogram. Spectral
convergence improves 0.66 → 0.013 while waveform SNR stays at −3 dB.

**Guardrail** — A classifier gating input or output. Placement decides everything: serial
+986 ms, parallel leaks 830 ms, clause-gated +104 ms and zero leak.

## H

**Hallucination** — ASR or LLM output unsupported by the input. In Whisper, mitigated by the
temperature fallback, compression-ratio and log-prob thresholds.

**Hangover** — Continuing to treat frames as speech for a fixed period after the VAD drops.
The fix that took segmentation from 265 segments to 34 at F1 0.962 — **not** hysteresis.

**HCLG** — The composed WFST (HMM, context, lexicon, grammar) of classical ASR decoding.

**Head-of-line blocking** — TCP's in-order delivery stalling frames that already arrived.
Damage per loss ≈ RTT / frame duration, so one loss at 200 ms RTT ruins ten frames.

**`heard_ms`** — How much of the agent's reply the user actually heard, from playout rather
than synthesis. Required for correct transcript truncation.

**Hedging** — Issuing a duplicate request to cut tail latency. Measured: p95 3288 → 2351 ms
at 1.2 wasted calls per turn.

**HIPAA** — US health-privacy rules. Every processor in the audio path needs a BAA, which is
what actually shortens your vendor list.

**Histogram bucket** — A latency counter boundary. Choice decides your reported p95: the OTel
GenAI recommended boundaries read a true 1820 ms p95 as **2144 ms**, 17.8% high.

**Hop length** — STFT frame advance. Whisper uses 160 samples (10 ms) at 16 kHz.

**Hysteresis** — Separate on/off thresholds. Useful, but not what fixes VAD segmentation.

## I

**ICE** — Interactive Connectivity Establishment, RFC 8445. Priority
$= 2^{24}\cdot\text{type} + 2^{8}\cdot\text{local} + (256-\text{component})$, with type
preferences 126 host / 110 prflx / 100 srflx / 0 relay.

**ICE restart** — Re-gathering and re-checking without tearing down the session; how a client
survives a network change.

**Idempotency key** — A caller-supplied identifier making a retried mutation safe.

**Idle process** — A prewarmed worker process. `num_idle_processes = min(ceil(cpu_count), 4)`
in production, 0 in dev.

**Ingress** — Inbound media into a platform; the mirror of egress.

**Inner monologue** — Moshi's prediction of text tokens for its own speech alongside audio,
improving accuracy.

**Interim result** — A non-final ASR hypothesis, subject to revision.

**`interruption_rate`** — Interruptions per agent turn.

**Intent** — The user's goal for a turn, as classified or inferred.

**ITN** — Inverse Text Normalisation: spoken forms to written ones ("four one five" → "415").
Unbounded work; the reason spoken-PII detection tops out at 86% recall.

**IVR** — Interactive Voice Response. Menu-driven telephony; a voice agent's ancestor.

## J

**Jitter** — Variation in packet inter-arrival time. RFC 3550 estimates it as
$J(i) = J(i-1) + (|D(i-1,i)| - J(i-1))/16$.

**Jitter buffer** — Receiver-side buffer converting jitter into fixed latency. Not a delay
line: NetEQ is a **playback-rate controller** that time-stretches via `kAccelerate` and
`kPreemptiveExpand`.

**Judge** — An LLM scoring conversations. A noisy classifier whose raw score is biased: a
harsh judge reported **72.3%** for a true 90%.

**JWT** — The signed token carrying room grants. HS256, `iss` = API key, `sub` = identity,
default validity 6 h. `VideoGrant` booleans are pointers — **absent means granted**.

## K

**KV cache** — Cached attention keys and values, avoiding prefill recomputation. Measured
savings 85.1% (1024+128) and 94.0% (2048+64). Grows monotonically through a session.

**Knee** — The load at which p95 turns up. On a 60-worker pool: flat to ρ = 0.77, then
**3.37× at ρ = 0.80**. Not where CPU saturates.

**Kokoro** — An 82 M-parameter TTS model with Apache-licensed weights; `<3.13,>=3.10`, which
is why this curriculum pins Python 3.12.

## L

**Latency budget** — The allocation of a mouth-to-ear target across pipeline stages. In six
worked designs, endpointing was **33–44%** of it — the largest single term in all six.

**Leak** — Monotonically growing resource use per session. A 1-hour soak can only detect
leaks above ~46 KB/session; a 24-hour soak reaches 0.39.

**Lexicon** — Pronunciation dictionary mapping words to phone sequences.

**Little's law** — $L = \lambda W$. Applied per edge, it gives the stability condition
$\lambda < \mu$; no queue depth fixes $\mu < \lambda$.

**Load threshold** — The utilisation above which a worker refuses new jobs. **0.7** in
LiveKit production, `inf` in dev.

**LocalAgreement** — Stabilisation that emits text only once successive hypotheses agree.

**Log-mel** — Log-scaled mel filterbank energies; the standard ASR input. Whisper's is exactly
`(80, 3000)` for a 30 s chunk.

**Lookahead** — Future context a streaming model may consult. A tunable knob trading latency
against WER.

## M

**MCU** — Multipoint Control Unit. Decodes, mixes and re-encodes; adds a full codec round trip
(40–100 ms). Necessary at telephony gateways, redundant for a two-party agent call.

**Mel scale** — Perceptual frequency warping, $2595\log_{10}(1 + f/700)$ in HTK form.

**Mimi** — Moshi's neural codec: 24 kHz audio at a 12.5 Hz frame rate, 1.1 kbit/s, 80 ms
frame, fully streaming.

**MOS** — Mean Opinion Score, 1–5, from human listeners. The only real measure of TTS
quality, and too slow for CI.

**µ-law** — Logarithmic companding in North American telephony; 8 bits carrying ~14 bits of
dynamic range.

**Multi-tenant** — Serving several customers from shared infrastructure. Per-tenant isolation
costs the trunking gain: two pools of 50 E need 128 channels where one of 100 E needs 117.

## N

**NACK** — Negative acknowledgement requesting retransmission. Usually wrong for voice: a
retransmission costs a round trip and arrives after the deadline.

**NetEQ** — libwebrtc's jitter buffer and playout controller.
`max_packets_in_buffer = 200` (4 s), `DelayManager` targeting the **0.95 quantile** with
`forget_factor = 0.983` and an explicit **20 ms of delay per 1% of loss avoided**.

**NLMS** — Normalised Least Mean Squares, the adaptive filter behind simple AEC.

**Noise suppression** — Attenuating stationary background noise. The second `getUserMedia`
constraint.

**Nyquist limit** — Half the sampling rate; the highest representable frequency.

## O

**Offered load** — See erlang.

**Opus** — RFC 6716. 6–510 kbit/s, 2.5–60 ms frames, hybrid SILK/CELT. 20 ms frames are "a
good choice for most applications". RTP timestamps always advance at **48 kHz regardless of
the audio's sample rate** (RFC 7587).

**OTel** — OpenTelemetry. Its GenAI conventions now live in a separate repository and define
`gen_ai.conversation.id`, `gen_ai.usage.*` and `time_to_first_chunk` — but nothing for
endpointing, barge-in or audio heard.

**Overrun** — Input buffer filling faster than it is drained; audio is dropped.

## P

**PCI DSS** — Payment card rules. A recording containing card data is in scope, which is why
the fix is architectural: never capture it.

**Persona** — The agent's designed personality as an engineering artefact. Measured: chatty
versus terse gave +324% agent speech, 2× call length, and TTS cost $6.93 → $29.40 per 1000
calls.

**PII** — Personally Identifiable Information. Spoken aloud, a digits-only regex catches
**14%**; spoken-aware 57%; with carrier phrases 86%.

**PLC** — Packet Loss Concealment. Extrapolates a missing frame; works for one, degrades
audibly across consecutive losses.

**Playout** — The moment audio is rendered to the user. The reference point for `ttfa` and
`heard_ms`.

**Poisson arrivals** — The memoryless arrival assumption behind Erlang. Broken by outbound
campaigns, advertisements and retry storms — which is when the tables understate the peak.

**Prefill** — The parallel forward pass over the prompt. Measured at **0.09 ms/token**.

**Prefix cache** — Reusing KV state for a shared prompt prefix. Moves the LLM cost term by
**3.2×**; the difference between the LLM being 0.63% and 2% of a call's cost.

**Prewarm** — Initialising a process before it is needed. See cold start.

**Prompt injection** — Instructions smuggled into data. Through speech the payload is
acoustic and therefore fuzzy, which degrades both recall and precision of string-matching
defences.

**Prosody** — Pitch, timing, loudness and voice quality: the information ASR discards and
audio-native models keep.

**PSTN** — Public Switched Telephone Network.

**`ptime`** — The SDP attribute for preferred packet duration; 20 ms for voice.

## Q

**Quantile** — A distributional summary. Latency must be reported as quantiles, never means:
a 900 ms mean is consistent with two very different products.

**Quantisation** — Mapping continuous amplitudes to discrete levels. SNR $= 6.02b + 1.76$ dB.
Separately, reducing model weight precision to save memory and time.

## R

**Rate limit** — A cap on requests or calls. For voice, apply per caller *identity*, because
denial-of-wallet and injection probing both look like a few callers making many calls.

**Redaction** — Removing sensitive data from transcripts, logs and recordings. Defence in
depth at 86% recall, not a certifiable control.

**Region** — A deployment locality. With central inference, media edges **cannot** reduce
mouth-to-ear latency (triangle inequality) and with sparse edges make it worse: 756 ms
against 730 ms for a single central region.

**Replay** — Re-running a recorded call through the pipeline. Needs unmixed audio, the event
log and the decision inputs. Also: an attack that defeats speaker verification outright.

**Resampling** — Changing sample rate. Belongs only at the edges of the pipeline; Opus always
decodes at 48 kHz, so a resample to 16 kHz is mandatory.

**Retention** — How long an artefact is kept. Differs per artefact: metrics for a year, traces
for days, audio for as short as legally possible.

**Retry budget** — Capping retries as a *fraction of traffic* rather than per request.
Prevents the 1.64× amplification measured during a provider brownout.

**Ring buffer** — Fixed-size circular buffer, the standard structure between an audio
callback and the rest of the program.

**RNN-T** — Recurrent Neural Network Transducer. Joint network over a $T \times U$ lattice;
natively streaming; memory-hungry, mitigated by pruned loss and stateless predictors.

**Rogan–Gladen** — The estimator inverting a noisy classifier's confusion matrix:
$\hat{p} = (p_{\text{obs}} - (1-\text{TNR})) / (\text{TPR} - (1-\text{TNR}))$.

**RTCP** — RTP Control Protocol. Bandwidth-limited to a RECOMMENDED 1.25% senders / 3.75%
receivers, so its reporting is coarse by design.

**RTP** — RFC 3550. 12-byte header: sequence number, timestamp in *codec clock units*, SSRC.
The 16-bit sequence wraps every 65536 packets — 21.8 minutes at 50 packets/s.

**RTT** — Round-trip time. Bounded by physics: 0.0137 ms/km through fibre with routed-path
inflation, so Sydney to Virginia is ~218 ms and no engineering removes it.

**RVQ** — Residual Vector Quantisation. Successive codebooks quantise the previous residual:
17.29 dB from six small codebooks against ~1.4 dB/bit for flat VQ.

## S

**Safe utilisation** — The highest ρ at which queueing stays acceptable. A function of pool
size: 25% at 5 workers, 69.5% at 50, 92.5% at 1000.

**Sampling (trace)** — Choosing which traces to keep. Head sampling is unbiased; tail
sampling is deliberately biased and made the observed p99 **26.7–38.9% too high**.

**Sampling rate** — Samples per second. 16 kHz internally, 48 kHz at the WebRTC edge, 8 kHz
at the telephony edge.

**SDP** — Session Description Protocol, RFC 8866. The offer/answer text carrying codecs, ICE
credentials, the DTLS fingerprint and direction.

**Semantic turn detection** — Predicting turn completion from linguistic content rather than
silence. Measured at AUC 0.510 in one case — *worse* than a fixed timeout.

**Session affinity** — Routing a session consistently to the node holding its media.
Mandatory, not an optimisation.

**SFU** — Selective Forwarding Unit. Forwards packets without decoding; ~1–5 ms added. The
right topology for a voice agent, because the agent is just another participant.

**Sidetone** — Deliberate feedback of a talker's own voice into their earpiece.

**Silero VAD** — A small DNN VAD. Window 512 at 16 kHz, threshold 0.5, min speech 250 ms, min
silence 100 ms, pad 30 ms.

**SILK** — The linear-prediction layer of Opus. 5 ms look-ahead plus up to 1.5 ms resampling,
so a 20 ms Opus frame costs 22.5–26.5 ms before a byte leaves the encoder.

**SIP** — Session Initiation Protocol. Telephony signalling: INVITE, REFER, BYE.

**SLI / SLO** — Service Level Indicator / Objective. For voice they must be defined per
*call*, not per request.

**Smart Turn** — An open audio-native end-of-turn detector (BSD 2-clause), 23 languages, 8 MB
int8 build, running only during VAD silence.

**Soak test** — A long-running load test for leaks. Minimum detectable leak scales with
window length: 46 KB/session at 1 h, 0.39 at 24 h.

**Speaker verification** — Confirming a claimed identity from voice. An identity *claim* and a
convenience factor, never the authenticator of record.

**Spectrogram** — Time–frequency magnitude representation from the STFT.

**`speech_start` / `speech_end`** — VAD-detected speech boundaries. Units: ms.

**Speculative decoding** — Drafting with a small model and verifying with a large one.
Measured to *fail* here: acceptance 0.44 at k=2 with cost ratio 0.56, needing r < 0.32.

**Speculative execution** — Starting a tool call before the turn ends, on the predicted
intent. Measured to cut a read from 1539 ms to 540 ms.

**SRTP** — RFC 3711. Encrypts and authenticates RTP; 10-byte default tag. A per-packet cost,
which is why packet rate is the media plane's scaling variable.

**SSRC** — RTP synchronisation source identifier. Changes on renegotiation, a classic cause
of "audio stopped".

**Step-up authentication** — Requiring an additional factor before a consequential action.
The correct use of a voice match.

**STFT** — Short-Time Fourier Transform.

**Streaming** — Emitting output incrementally. Measured end to end: 744 ms streaming against
3851 ms batch, a 5.2× difference.

**`stt_final`** — Time from end-of-utterance to the final ASR transcript. Units: ms.

**STUN** — RFC 8489. One UDP round trip returning `XOR-MAPPED-ADDRESS`, your server-reflexive
candidate.

**Summarisation** — Compressing conversation history. Belongs off the critical path.

**System frame** — In a frame graph, an out-of-band priority frame that jumps the queue and
survives interruptions.

## T

**`t_eou`** — Timestamp of the end-of-utterance decision; the moment the endpointer commits.

**Task success** — Whether the user's goal was achieved. The outcome metric everything else
proxies for.

**TCPA** — US rules on automated outbound calling; consent per number with a working opt-out.

**Time-stretching** — WSOLA-style insertion or removal of audio to grow or shrink a jitter
buffer. Means client-side duration measurements are unreliable.

**Tool call** — A function invocation by the model. The term that inverts the S2S argument:
audio-native plus a tool call measured 1499 ms against cascaded 1370 ms.

**Truecasing** — Restoring capitalisation to ASR output.

**Trunking gain** — The non-linear efficiency of larger pools. Splitting one pool of 100 E
into two of 50 E costs ~9% more channels.

**TTS** — Text-to-Speech.

**`ttfa`** — Time to first audio at the user's ear.

**`ttfb_tts`** — Time to first byte out of the TTS engine.

**`ttft_llm`** — Time to first LLM token. OTel: `gen_ai.client.operation.time_to_first_chunk`.

**TURN** — RFC 8656. A media relay for when ICE fails. ChannelData headers are **4 bytes**
against 36 for Send/Data indications. Relayed sessions consume both directions in your
infrastructure.

**Turn** — One participant's contiguous contribution. The unit product complaints map onto,
and the span level most teams forget to instrument.

**TWCC** — Transport-Wide Congestion Control feedback, superseding REMB.

**Two-party consent** — Jurisdictions requiring all parties to consent to recording. Makes
consent a routing decision.

## U

**Underrun** — Output buffer emptying before the next frame arrives; a click or dropout.

**Uninterruptible frame** — A mixin marking frames that are ordered normally but survive an
interruption — tool-call results, summaries.

**Utterance** — A contiguous stretch of speech bounded by silence. Not the same as a turn: a
turn may contain several.

## V

**VAD** — Voice Activity Detection. Per-frame speech/non-speech classification.

**VITS** — End-to-end TTS with a variational autoencoder and adversarial training; what Piper
is.

**Vocoder** — Converts an acoustic representation to a waveform. Griffin-Lim, WaveNet,
HiFi-GAN.

**Voiceprint** — A speaker embedding. Biometric data under GDPR Art. 9 when used for unique
identification.

## W

**Watermarking** — Embedding a machine-detectable marker in synthetic audio. AI Act
Art. 50(2) requires outputs "marked in a machine-readable format".

**WebRTC** — The stack (ICE, DTLS-SRTP, RTP, NetEQ, GCC) for real-time media. Mandatory for
browsers, and the only way to get the browser's AEC.

**WER** — Word Error Rate: (substitutions + insertions + deletions) / reference words.

**WFST** — Weighted Finite-State Transducer, the composition machinery of classical ASR.

**Whisper** — OpenAI's AED ASR family. `SAMPLE_RATE` 16000, `N_FFT` 400, `HOP_LENGTH` 160,
`CHUNK_LENGTH` 30, `N_FRAMES` 3000, 50 tokens/s.

**Window function** — A taper applied before the DFT to control leakage; Hann is the default
choice.

**WSOLA** — Waveform Similarity Overlap-Add, the time-stretching method behind NetEQ's
accelerate and expand.

## Z

**ZCR** — Zero-Crossing Rate. A cheap spectral proxy used in the simplest VADs.

**ZDR** — Zero Data Retention. A vendor tier guaranteeing audio and transcripts are not
stored; a compliance line item rather than a code change.

**Zipformer** — An efficient streaming ASR encoder from the icefall/k2 line.

---

## Units, quickly

| Quantity | Unit | Typical value here |
|---|---|---|
| Frame duration | ms | 20 |
| Samples per frame | samples | 320 at 16 kHz |
| Bytes per frame | bytes | 640 (s16le mono) |
| Packet rate | packets/s | 50 per direction |
| Opus wire bitrate | kbit/s | ~40 including headers |
| `eou_to_ttfa` | ms | 343 (full-duplex) to 1370 (cascaded) |
| Jitter buffer target | ms | 20–200 adaptive |
| Offered load | erlang (E) | concurrent calls |
| Blocking | % | 1% typical trunk target |
| Audio token rate | tokens/s | 100 (Mimi) to 600 (EnCodec 6 kbit/s) |
| Text token rate of speech | tokens/s | 2.60 at 150 wpm |
| Fibre RTT | ms/km | 0.0137 |
| Cost | $/1000 call-min | ~$10 self-hosted to ~$32 fully managed |
