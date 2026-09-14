# Voice Agents: The Project Ladder

The companion to `README.md`. That file is the **teaching curriculum** — deliberately
"no projects, no app scaffolding". This file is the other half: **what to build** to turn
270,000 words of reading into an artifact you can put in front of a hiring committee.

**27 projects in four tiers**, in dependency order. Every project names the chapters it draws
on and the acceptance criteria that decide whether it is done. §7 audits the mapping in the
other direction: all 55 chapters, and the project that exercises each.

Start with `01-foundations/00-what-is-a-voice-agent.md` for orientation if you have not read it.

> **Thesis.** A voice-agent portfolio is not judged on whether the demo talks. It is judged
> on whether you can *defend a policy with numbers*. Every project below is therefore
> specified around a measurement, not a feature.

---

## 0. The showcase bar

Stated once here; assumed by every project. A reviewer at a large company discounts
"I built a voice bot" — the API makes that a weekend. What survives scrutiny:

| Dimension | Minimum bar |
|---|---|
| **Measurement** | Every README claim carries a number produced by a script *in the repo*. No number, no claim. |
| **Metric names** | Reuse the curriculum's fixed set. Do not invent synonyms. |
| **Audio contract** | 16 kHz mono s16le; 20 ms = 320 samples = 640 bytes. Asserted at every process and module boundary. |
| **Determinism** | Async audio tested with fake clocks and WAV-driven pipelines. A `sleep()`-based test is a failed test. |
| **Failure** | Named failure modes with drills. A happy path only is a demo, not a system. |
| **Cost** | $/1000 minutes arithmetic in the README, with the inputs shown. |
| **Honesty** | `[MEASURED]` / `[INFERENCE]` / `[UNVERIFIED PRICE]` labels, exactly as the chapters use them. |

### The fixed metric set

`t_eou`, `stt_final`, `ttft_llm`, `first_clause`, `ttfb_tts`, `ttfa`, `eou_to_ttfa`,
`wer`, `endpoint_f1`, `interruption_rate`, `barge_in_latency`

Defined in `01-foundations/04-latency-budget.md` and `09-mastery/04-glossary.md`.
The glossary distinctions reviewers probe: VAD is not endpointing, TTFB is not TTFA,
jitter is not latency.

### Local-first, by construction

This bench has **no vendor API keys**, no `ffmpeg`, and no Ollama. That is a constraint worth
keeping rather than fixing: every project must run end to end on local models, with vendor
adapters as an *optional* code path behind the same interface. The result argues architecture
instead of API-key plumbing, and it costs nothing to run during an interview.

Verified bench: Apple M5, `uv` 0.11.19, CPython 3.12.13 (pinned — `audioop` was removed in
3.13 under PEP 594), Docker 29.5.3, Node v20.20.2. See `00-setup/01-environment.md` and
`00-setup/02-hardware-and-cost.md`.

Two prerequisites you will hit at Tier 1: install `ffmpeg`, and pick a local LLM runtime —
`llama.cpp` or MLX, per `05-llm-layer/04-serving-llms-fast.md`, since neither Ollama nor any
hosted key is present.

### Numbering

IDs are **tier-local**: `D` drills, `C` components, `S` systems, `F` flagship. Cross-references
use the full ID (`C2`, `S4`). Adding a project never renumbers an existing one.

---

## 1. Tier 0 — Drills

Single file, 2–6 h each, `numpy`/`torch`/stdlib only. Individually these are not portfolio
pieces. A `drills/` directory where every drill commits its **measured output** is, because it
demonstrates the habit the rest of the ladder depends on.

### D1. `frame-clock`
20 ms frame pacer plus a lock-free ring buffer, with clock-drift correction in ppm.

- **Chapters** — `01-foundations/03-audio-io-and-buffering.md`, `00-setup/03-canonical-formats.md`
- **Accept** — Runs 10 min without an underrun at 20 ms; injected ±100 ppm drift is corrected without a glitch; underruns and overruns are *counted and reported*, not merely avoided; asserts 640 bytes per frame at the buffer boundary.

### D2. `melspec-cli`
Mel filterbank built from scratch in numpy; spectrogram rendered in the terminal.

- **Chapters** — `01-foundations/02-time-frequency.md`, `01-foundations/01-sound-and-sampling.md`
- **Accept** — Output matches `torchaudio.transforms.MelSpectrogram` within a stated tolerance, with the diff printed; three window functions compared for leakage; the time–frequency tradeoff shown by varying hop against a chirp.

### D3. `vad-bakeoff`
Energy/ZCR, WebRTC GMM, and Silero on the same labeled audio.

- **Chapters** — `03-turn-taking/01-vad.md`
- **Accept** — ROC and DET curves for all three from one command; hysteresis effect quantified; the README states which threshold you would ship **and the product reason**, not the best F1.

### D4. `ctc-lab`
CTC forward–backward and prefix beam search in numpy, then the RNN-T lattice.

- **Chapters** — `02-asr/02-ctc-from-scratch.md`, `02-asr/01-from-hmm-to-e2e.md`, `02-asr/03-rnnt-transducer.md`
- **Accept** — Loss agrees with `torch.nn.functional.ctc_loss` to float tolerance; gradient checked numerically; prefix beam search beats greedy on a crafted case where output dependence matters; peaky posteriors demonstrated; the RNN-T extension implements the $T \times U$ lattice loss and *measures* the memory blow-up against CTC, showing what a stateless predictor recovers.

### D5. `wer-lab`
WER done correctly, plus the metrics that actually predict agent quality.

- **Chapters** — `02-asr/07-evaluation.md`, `02-asr/04-attention-and-whisper.md`
- **Accept** — Levenshtein alignment with substitution/insertion/deletion breakdown; a worked demonstration of the normalisation trap where two defensible normalisers move WER by a material margin; entity WER reported separately; bootstrap 95% CI on every number; includes at least one Whisper hallucination and one repetition-loop case, with the WER those failures produce versus how bad they *sound*.

### D6. `clause-aggregator`
LLM token stream to speakable clauses. **Highest signal per line in Tier 0.**

- **Chapters** — `04-tts/03-streaming-tts.md`
- **Accept** — Adversarial suite passes: `3.14`, `Dr. Smith`, `$1,200.50`, `e.g.`, `U.S.A.`, `10:30 a.m.`, an ellipsis, and a URL; `first_clause` latency measured against a no-aggregation baseline; a documented case where an aggressive split audibly damages prosody, with the audio committed.

### D7. `aec-nlms`
NLMS echo canceller with a double-talk detector.

- **Chapters** — `03-turn-taking/05-echo-and-aec.md`
- **Accept** — ERLE curve over time on a synthetic echo path; divergence during double-talk demonstrated *and then* prevented by the detector; step-size / convergence-rate tradeoff plotted; README states why AEC belongs on the client.

### D8. `budget-sim`
Discrete-event simulation of the mouth-to-ear budget.

- **Chapters** — `01-foundations/04-latency-budget.md`
- **Accept** — Reproduces the chapter's three regimes term by term; p95 plotted against utilisation, showing the knee past roughly 70%; Little's law verified against the simulation rather than quoted; identifies which single term dominates in each regime.

### D9. `vocoder-lab`
What actually turns features into a waveform, and what a neural codec costs you.

- **Chapters** — `04-tts/01-tts-architectures.md`, `04-tts/02-codec-lm-tts.md`
- **Accept** — Griffin-Lim implemented and compared against a pretrained HiFi-GAN on identical mels, with both audio files committed and the phase-reconstruction artefacts named; an RVQ codec round-trip at three bitrates with the quality/bitrate curve; the added latency of a codec-LM path measured, not assumed.

### D10. `jitter-buffer`
Adaptive jitter buffer with packet-loss concealment.

- **Chapters** — `06-realtime-systems/02-webrtc-internals.md`
- **Accept** — Replays a real jitter trace and plots concealment rate against added buffer latency, marking the operating point; PLC audibly beats zero-fill, with both committed; adapts to a mid-stream jitter step within a stated bound; README distinguishes jitter from latency with the data on screen.

An underrated drill: it is the concrete answer to "why does the audio sound fine on wifi and
terrible on a train".

### D11. `verbalizer`
Text normalisation for speech: numbers, dates, currency, addresses.

- **Chapters** — `04-tts/04-prosody-and-voice.md`
- **Accept** — Correct en-US *and* en-IN output for a shared test set including `1,20,000`, `₹1,200.50`, `2026-08-28`, `+91 98765 43210`, and an ordinal; a pronunciation lexicon overrides at least one product name; each locale divergence is a test case, not a branch comment.

Small, unglamorous, and the source of a large share of real voice-agent embarrassment.

---

## 2. Tier 1 — Components

Days each. Each is a standalone repository with tests, CI, and a measured README. These make
the flagship possible, and several stand alone as interview material.

### C1. `streaming-asr-service`
WebSocket ASR server with partial/final semantics treated as a public API contract.

- **Chapters** — `02-asr/05-streaming-asr.md`, `02-asr/08-serving-asr.md`, `02-asr/04-attention-and-whisper.md`, `06-realtime-systems/01-transports.md`
- **Build** — faster-whisper behind a runtime-agnostic interface; LocalAgreement stabilisation; bounded queues with per-edge backpressure; a versioned wire protocol document.
- **Accept** — Partial transcripts never retract a token already marked stable, enforced by a property test; `stt_final` and emission latency reported as distributions, not means; the WER-versus-lookahead frontier plotted; behaviour under a slow consumer is *specified* (drop or block) and tested; $/1000 min self-hosted against one vendor.

### C2. `endpointer`
VAD timer fused with a semantic turn detector, calibrated. **The single most differentiating component on this ladder.**

- **Chapters** — `03-turn-taking/02-endpointing.md`, `03-turn-taking/03-semantic-turn-detection.md`, `09-mastery/01-design-interviews.md`
- **Build** — fixed, adaptive, and semantic policies behind one interface; a fusion rule; a tuning CLI.
- **Accept** — Plots the cut-off-rate ↔ `eou_to_ttfa` frontier and marks the operating point you would ship; `endpoint_f1` per policy on a held-out set; detector calibration shown with a reliability diagram, not just accuracy; documents the asymmetric cost of cutting a user off versus dead air, and shows the chosen threshold following from it.

Most candidates cannot defend an endpointing policy at all. This is the answer to the opening
question in `09-mastery/01-design-interviews.md`.

### C3. `tts-gateway`
Streaming TTS service built around `ttfb_tts`.

- **Chapters** — `04-tts/03-streaming-tts.md`, `04-tts/05-engine-selection.md`, `04-tts/01-tts-architectures.md`
- **Build** — Kokoro and Piper behind one interface; mid-utterance flush; phrase cache; consumes D6 and D11.
- **Accept** — `ttfb_tts` and `ttfa` distributions per engine on identical text; flush cancels audio within a stated bound with no trailing samples emitted afterwards, proven by a test; cache hit-rate against latency saved; a fair A/B protocol per the chapter, and a licensing column in the engine table.

### C4. `livekit-local-plugins`
Real `STT` / `TTS` / `VAD` / `LLM` plugin implementations for LiveKit Agents, backed by local models.

- **Chapters** — `07-livekit/03-writing-plugins.md`, `07-livekit/02-agents-framework.md`, `07-livekit/01-architecture.md`
- **Accept** — Implements the actual ABCs and streaming contracts against a pinned `livekit-agents` version, stated in the README; drop-in swappable with a vendor plugin in one line of config; cancellation and cleanup verified — no task leak across 100 sessions; the vendor spend eliminated is quantified.

The project that proves you can *extend* the platform rather than configure it.

### C5. `barge-in-harness`
Full-duplex interrupt correctness, tested deterministically.

- **Chapters** — `03-turn-taking/04-barge-in.md`, `08-eval-safety/01-testing.md`
- **Build** — the four interrupt signals with an explicit choice of which to act on; the TTS-flush race; transcript truncation to what the user *actually heard*.
- **Accept** — `barge_in_latency` measured end to end; the zombie-TTS bug reproduced by a regression test that fails on the naive implementation; transcript after interruption reflects only played audio, asserted against a sample-accurate playback cursor; every test uses a fake clock and completes in under a second.

### C6. `voice-otel`
OpenTelemetry instrumentation library and dashboard for the fixed metric set.

- **Chapters** — `06-realtime-systems/06-observability.md`
- **Accept** — One span tree per conversation with turn-level children; histogram buckets chosen from observed distributions and justified in writing; cost attributed per session and per tenant; deterministic replay of a recorded session reproduces the same metric values; at least one alert that fires on a *seeded* regression and stays silent across a benign re-run.

Operability reads as seniority faster than almost anything else in a portfolio.

### C7. `contextual-biasing`
Make ASR hear *your* product, place, and person names.

- **Chapters** — `02-asr/06-decoding-and-biasing.md`
- **Build** — shallow LM fusion and a contextual biasing list; ITN, punctuation, truecasing as a post-chain.
- **Accept** — Entity WER on a domain vocabulary improves by a stated margin with general WER not regressing beyond a stated bound — both with bootstrap CIs; the over-biasing failure shown, where a strong bias hallucinates entities into audio that never contained them; biasing cost in added decode latency measured; the list is injected per session, not baked at build time.

Directly commercial: it is the fix every enterprise pilot asks for in week two.

### C8. `diarization-service`
Who spoke, and when.

- **Chapters** — `02-asr/09-diarization-and-speaker-id.md`
- **Build** — VAD to segmentation to ECAPA embeddings to clustering; streaming and offline modes.
- **Accept** — DER computed correctly, with overlapped speech and collar handling stated explicitly; streaming DER reported against offline as the cost of causality; behaviour with an unknown speaker count; README argues why speaker verification is an authentication **anti-pattern**, per the chapter.

---

## 3. Tier 2 — Systems

One to two weeks each. Deployable, with runbooks.

### S1. `cascaded-agent`
The full local pipeline agent, composed from Tier 1.

- **Chapters** — `05-llm-layer/01-prompting-for-speech.md`, `05-llm-layer/02-context-and-memory.md`, `05-llm-layer/03-tools-and-agentic.md`, `05-llm-layer/05-persona-design.md`, `07-livekit/02-agents-framework.md`, `06-realtime-systems/03-pipeline-architecture.md`
- **Build** — barge-in, tool calling under a deadline, filler speech, memory tiers with real schemas, speculative RAG during the user's turn, persona as a written artifact, health and drain endpoints, Docker Compose.
- **Accept** — `eou_to_ttfa` p50 and p95 against a stated budget over at least 100 turns; tools are idempotent and a retry is proven not to double-charge; spoken error recovery on a forced tool failure; `SIGTERM` drains in-flight calls without cutting audio; runs with zero API keys.

Deliberately sequenced **after** C2 and C5. Building the agent first is the common mistake that
produces an impressive demo nobody can test or debug.

### S2. `voice-eval-lab`
Simulated callers and quality gates.

- **Chapters** — `08-eval-safety/02-simulation-and-load.md`, `08-eval-safety/01-testing.md`, `08-eval-safety/03-safety-and-privacy.md`
- **Build** — scripted and LLM-driven callers, adversarial personas, LLM-as-judge with calibration, CI regression gates.
- **Accept** — Judge agreement with human labels reported on a calibration set, with disagreement cases shown; gate thresholds derived from distributions rather than picked; a seeded quality regression is caught and a benign change is not; adversarial personas include interruption, accent, background noise, and speech-borne prompt injection; PII redaction verified on transcripts.

Very few portfolios contain anything like this. It is the difference between "I built it" and
"I know whether it works".

### S3. `loadgen`
Synthetic concurrent callers, to the knee.

- **Chapters** — `06-realtime-systems/05-scale-and-orchestration.md`, `08-eval-safety/02-simulation-and-load.md`
- **Accept** — Finds and reports the knee, p95 against concurrency; emits a per-session resource model (CPU, RAM, GPU) fitted to measurement; $/1000 min at three concurrency levels; a soak run long enough to expose a leak, with the memory curve committed; the observed knee compared against D8's prediction and any discrepancy explained.

### S4. `chaos-drills`
Fault injection with an invariant.

- **Chapters** — `06-realtime-systems/07-reliability.md`
- **Accept** — Injects provider 5xx, TTS death mid-utterance, LLM timeout, ICE restart, and OOM; asserts the **never-dead-air** invariant with a measured maximum silence per drill; hedging and circuit breakers shown to help *with* the cost they add; SLOs defined for a call rather than for a request; every drill is a CI job.

### S5. `s2s-vs-cascaded`
The same task built both ways, compared honestly.

- **Chapters** — `06-realtime-systems/04-speech-to-speech.md`, `07-livekit/06-alternatives.md`
- **Accept** — Identical task, identical eval harness from S2; `eou_to_ttfa`, interruption behaviour, task success, and $/1000 min side by side; states which axes each approach wins and the conditions that flip the decision; names what the cascaded pipeline can do that the S2S model cannot, and the reverse.

Produces a defensible tradeoff table instead of a hype take. Reviewers notice.

### S6. `telephony-bridge`
SIP ingress and the 8 kHz reality.

- **Chapters** — `07-livekit/05-telephony-sip.md`, `06-realtime-systems/01-transports.md`
- **Accept** — INVITE and REFER handled; G.711 both directions; DTMF detected, with in-band's effect on ASR measured; the 8 kHz WER tax quantified against the same audio at 16 kHz; blind and attended transfer; answering-machine detection with its false-positive rate stated.

Telephony is where enterprise voice budgets live, and almost nobody demos it.

---

## 4. Tier 3 — Flagship

Pick **one**. Three to six weeks. This is the artifact you lead with.

### F1. `voice-platform`
A multi-tenant voice-agent platform composing Tiers 1–2.

- **Chapters** — `06-realtime-systems/05-scale-and-orchestration.md`, `06-realtime-systems/07-reliability.md`, `06-realtime-systems/08-deployment.md`, `07-livekit/04-self-hosting-and-scale.md`, `07-livekit/01-architecture.md`
- **Build** — worker pools, session affinity, autoscaling on a signal that actually leads load, draining during deploy, blue/green with live calls, per-tenant config and cost attribution, an admin console, runbooks.
- **Accept** — A deploy completes with live calls in progress and **zero dropped calls**, shown in a recorded trace; autoscaling reacts to a load step within a stated bound; per-tenant SLOs and their error budgets published; a runbook for every drill in S4; the honest self-host versus Cloud crossover computed from your own numbers.

### F2. `agent-runtime` + provider conformance suite
A frame-graph runtime with pluggable providers, plus the test suite that *defines* what a
correct provider adapter is.

- **Chapters** — `06-realtime-systems/03-pipeline-architecture.md`, `07-livekit/06-alternatives.md`, `08-eval-safety/01-testing.md`
- **Build** — frame taxonomy, in-band control frames, bounded queues with per-edge backpressure, asyncio cancellation and interrupt propagation; adapters for at least two ASR, two TTS, and two LLM providers, including local ones; a conformance suite every adapter must pass.
- **Accept** — The suite fails a deliberately broken adapter for each of at least six distinct contract violations (late cancellation, unbounded buffering, retraction of a stable token, silent truncation, missing flush acknowledgement, clock assumption); swapping any provider requires no change outside its adapter; business logic proven portable by running the same agent over two different transports.

**Recommendation: build F2 as the core of F1.** One repository, two stories — portable
architecture and an operated platform. F2 alone is the rarer signal, because a test suite that
defines correctness is a principal-engineer artifact rather than an application.

---

## 5. Order, and the time-boxed cut

```
D1, D2  →  D3, D6  →  D4, D5  →  D7, D8  →  D9, D10, D11
        →  C1, C3  →  C2, C5   →  C4, C6  →  C7, C8
        →  S1      →  S2, S3, S4  →  S5, S6
        →  F2 inside F1
```

D3 and D6 come early despite mid-list difficulty: highest differentiation per hour, almost no
dependencies. D9–D11 are placed late only because nothing depends on them; D10 is worth pulling
forward if you are targeting a WebRTC-heavy role.

**If time-boxed**, this subset already makes the argument:

| Keep | Because |
|---|---|
| D3, D5, D6 | You measure before you claim |
| C2, C5 | You can defend turn-taking policy with data — the expert/demo-builder line |
| C6 | You can operate what you build |
| S2 | You know whether it works |

That set argues *measures, defends, operates* without a flagship. It is a stronger portfolio
than S1 alone, which is the project most people build first and the one reviewers have seen
most often.

Add **C7** if you are interviewing at a company selling voice agents to enterprises, and **S6**
if the role touches contact centres.

---

## 6. Conventions for every repository here

Inherited from the curriculum, per `CONTINUE-HERE.md`:

- Audio is 16 kHz mono s16le; 20 ms = 320 samples = 640 bytes.
- Metric names come from the fixed set in §0. Do not rename them per project.
- Python 3.12 via `uv run --python 3.12`. The pin exists because of `audioop`, not because of
  any model's declared bound.
- `sounddevice` bundles PortAudio V19.7.0-devel. `brew install portaudio` is unnecessary.
- Version-pinned facts drift. Read the published wheel, never `main`, and state the version
  every API snippet was checked against.
- Prices are stamped with a retrieval date, or marked `[UNVERIFIED PRICE]`.
- Every README opens with the measurement that justifies the project, not a feature list.

---

## 7. Coverage audit — all 55 chapters

The inverse mapping. Kept honest for the same reason the curriculum verifies its own links:
a project ladder with silent gaps teaches the gaps.

| Chapter | Project |
|---|---|
| `00-setup/01-environment.md` | bench, all |
| `00-setup/02-hardware-and-cost.md` | bench, all |
| `00-setup/03-canonical-formats.md` | D1 |
| `00-setup/04-reading-list.md` | reference artifact |
| `00-setup/05-bootcamp-coverage.md` | reference artifact |
| `01-foundations/00-what-is-a-voice-agent.md` | orientation, all |
| `01-foundations/01-sound-and-sampling.md` | D2 |
| `01-foundations/02-time-frequency.md` | D2 |
| `01-foundations/03-audio-io-and-buffering.md` | D1 |
| `01-foundations/04-latency-budget.md` | D8, S3 |
| `02-asr/01-from-hmm-to-e2e.md` | D4 |
| `02-asr/02-ctc-from-scratch.md` | D4 |
| `02-asr/03-rnnt-transducer.md` | D4 |
| `02-asr/04-attention-and-whisper.md` | D5, C1 |
| `02-asr/05-streaming-asr.md` | C1 |
| `02-asr/06-decoding-and-biasing.md` | C7 |
| `02-asr/07-evaluation.md` | D5 |
| `02-asr/08-serving-asr.md` | C1 |
| `02-asr/09-diarization-and-speaker-id.md` | C8 |
| `03-turn-taking/01-vad.md` | D3 |
| `03-turn-taking/02-endpointing.md` | C2 |
| `03-turn-taking/03-semantic-turn-detection.md` | C2 |
| `03-turn-taking/04-barge-in.md` | C5 |
| `03-turn-taking/05-echo-and-aec.md` | D7 |
| `04-tts/01-tts-architectures.md` | D9, C3 |
| `04-tts/02-codec-lm-tts.md` | D9 |
| `04-tts/03-streaming-tts.md` | D6, C3 |
| `04-tts/04-prosody-and-voice.md` | D11 |
| `04-tts/05-engine-selection.md` | C3 |
| `05-llm-layer/01-prompting-for-speech.md` | S1 |
| `05-llm-layer/02-context-and-memory.md` | S1 |
| `05-llm-layer/03-tools-and-agentic.md` | S1 |
| `05-llm-layer/04-serving-llms-fast.md` | bench prerequisite, S1 |
| `05-llm-layer/05-persona-design.md` | S1 |
| `06-realtime-systems/01-transports.md` | C1, S6 |
| `06-realtime-systems/02-webrtc-internals.md` | D10 |
| `06-realtime-systems/03-pipeline-architecture.md` | S1, F2 |
| `06-realtime-systems/04-speech-to-speech.md` | S5 |
| `06-realtime-systems/05-scale-and-orchestration.md` | S3, F1 |
| `06-realtime-systems/06-observability.md` | C6 |
| `06-realtime-systems/07-reliability.md` | S4, F1 |
| `06-realtime-systems/08-deployment.md` | F1 |
| `07-livekit/01-architecture.md` | C4, F1 |
| `07-livekit/02-agents-framework.md` | C4, S1 |
| `07-livekit/03-writing-plugins.md` | C4 |
| `07-livekit/04-self-hosting-and-scale.md` | F1 |
| `07-livekit/05-telephony-sip.md` | S6 |
| `07-livekit/06-alternatives.md` | S5, F2 |
| `08-eval-safety/01-testing.md` | C5, S2, F2 |
| `08-eval-safety/02-simulation-and-load.md` | S2, S3 |
| `08-eval-safety/03-safety-and-privacy.md` | S2 |
| `09-mastery/01-design-interviews.md` | C2, all |
| `09-mastery/02-mastery-checklist.md` | reference artifact |
| `09-mastery/03-answers.md` | reference artifact |
| `09-mastery/04-glossary.md` | reference artifact |

Five files are reference artifacts with no build attached, consistent with the deviation already
recorded in `CONTINUE-HERE.md`. Every other chapter is exercised by at least one project.
