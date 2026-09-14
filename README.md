# Voice Agents: Zero → Top 1%

A self-contained, book-length **teaching curriculum** for real-time voice AI systems.
No projects, no app scaffolding — this is the material you read and work through to
*understand* voice agents at the level of someone who can design the platform, not
just call the API.

> **Building, rather than reading?** `PROJECTS.md` is the companion ladder — 27 projects
> in four tiers, from single-file drills to a flagship platform, each mapped to the
> chapters it draws on and specified by acceptance criteria. This file teaches; that
> file is what you ship.

Written for a strong software engineer who is **new to speech and audio**, and who
will be **shipping on LiveKit** — so LiveKit gets a deep, source-grounded module,
while every alternative (Pipecat, raw WebSocket, Twilio, native speech-to-speech
APIs, NVIDIA Riva, Amazon Connect) is taught well enough that you *choose* rather
than inherit.

> **Thesis.** A voice agent is not "ASR + LLM + TTS". It is a **soft-real-time
> distributed system with a human in the loop and a ~300 ms deadline**. Barge-in,
> endpointing, echo, jitter, cold starts, cost — almost every hard problem is a
> *systems* problem wearing an ML costume. So we learn both layers, and we learn
> exactly where the boundary between them is.

---

## 0. How to use this

**Two tracks, read interleaved** in the order given in §3.

| Track | What it makes you able to do | Modules |
|---|---|---|
| **ML / signals track** | Debug *models*: why WER explodes on your accent, why streaming ASR flip-flops, why TTS clips mid-word, why a codec-LM voice costs you 300 ms | `01-foundations`, `02-asr`, `04-tts` |
| **Systems track** | Design *platforms*: latency budgets, WebRTC, endpointing policy, autoscaling GPU fleets, SLOs, $/minute | `03-turn-taking`, `05-llm-layer`, `06-realtime-systems`, `07-livekit`, `08-eval-safety` |

**Every chapter has the same seven-part shape:**

1. **Intuition** — the mental model, no math.
2. **Rigour** — the actual math or protocol, derived, not asserted.
3. **From scratch** — code you can read end to end (numpy / PyTorch / stdlib only, fully standalone, no framework magic).
4. **How production does it** — the corresponding code path in a real OSS project, cited by repo + file + symbol (LiveKit Agents, Pipecat, faster-whisper, whisper.cpp, NeMo, icefall, sherpa-onnx, Silero, Kokoro, Piper, Moshi, vLLM, WebRTC).
5. **At scale** — what breaks at 1 → 100 → 10,000 concurrent conversations, with the arithmetic.
6. **Exercises** — 4–8 short drills, all 377 have worked answers in `09-mastery/03-answers.md`.
7. **Interview drill** — the question a staff-level interviewer would actually ask.

**Claim discipline.** `[MEASURED]` = actually run on this machine. `[INFERENCE]` =
reasoned, unverified. `[UNVERIFIED PRICE]` = vendor price I could not confirm.
API snippets state the version they were checked against.

---

## 1. Prerequisites

You need: comfortable Python, basic async/concurrency, comfort reading unfamiliar
source code, and high-school trigonometry. You do **not** need DSP, ML, or telephony
background — that is what `01-foundations` is for. Complex numbers and the FFT are
introduced from zero.

---

## 2. The map (55 chapters, plus a mini-projects list)

### `00-setup/` — the bench, and the cost of everything
| File | Contents |
|---|---|
| `01-environment.md` | uv + Python 3.12, PortAudio, ffmpeg, macOS microphone permissions (TCC), the dependency graph behind every audio package, why not conda, and the 10 first-run errors with fixes |
| `02-hardware-and-cost.md` | What runs on an M5 Mac (MPS/MLX/CoreML/CTranslate2/GGUF-Metal) vs what needs CUDA; per-model RAM tables; rented-GPU $/hr; total curriculum cost arithmetic |
| `03-canonical-formats.md` | The format contract used by every chapter: 16 kHz mono s16le, 20 ms / 320 samples / 640 bytes. Why 16 k, why 20 ms, int16 vs float32, WAV/RIFF layout, every conversion in the book |
| `04-reading-list.md` | The books (Jurafsky & Martin, Rabiner & Juang, Taylor, Oppenheim & Schafer, Smith's DSP, Kleppmann, Nygard, Google SRE), ~40 papers in reading order, and 15 OSS repos to read as literature with the exact files worth reading |
| `05-bootcamp-coverage.md` | Line-by-line mapping of the Vizuara 8-day syllabus onto these chapters, so you can prove nothing is missing |
| `bootstrap.sh` | Idempotent bench setup |

### `01-foundations/` — what sound is, and where time goes
| File | Contents |
|---|---|
| `00-what-is-a-voice-agent.md` | Voice agent vs chatbot vs IVR vs conversational AI vs speech-to-speech. The canonical architecture, batch vs streaming, the four hard problems (latency, turn-taking, interruption, error compounding), and a map of the 2026 ecosystem |
| `01-sound-and-sampling.md` | Pressure waves → PCM. Speech spectrum, formants, Nyquist derived, aliasing you can hear, quantisation noise ($6.02b + 1.76$ dB), dBFS vs dBA, µ-law, why telephony is 8 kHz |
| `02-time-frequency.md` | DFT/FFT, leakage, windows, STFT, the time–frequency uncertainty tradeoff, mel filterbanks built in numpy, log-mel vs MFCC and why MFCC died, reading a real spectrogram |
| `03-audio-io-and-buffering.md` | The real-time audio contract, callback vs blocking I/O, lock-free ring buffers, underrun/overrun symptoms, clock drift in ppm, resampler quality vs latency, and the full buffering ladder mic → model |
| `04-latency-budget.md` | **The most important chapter.** Mouth-to-ear budget decomposed term by term for three regimes; why endpointing is a *policy* cost not a compute cost; human turn-gap literature; Little's law and why >70% utilisation destroys p95 |

### `02-asr/` — speech recognition, HMMs → streaming transducers
| File | Contents |
|---|---|
| `01-from-hmm-to-e2e.md` | GMM-HMM, lexicon, n-gram LM, WFST/HCLG, Viterbi worked numerically, forced alignment, DNN-HMM, what end-to-end removed and what it silently kept |
| `02-ctc-from-scratch.md` | CTC derived and implemented: forward–backward in numpy verified against PyTorch, the blank symbol, alignment collapse, prefix beam search, peaky posteriors, why CTC can't model output dependencies |
| `03-rnnt-transducer.md` | RNN-T: joint network, the $T \times U$ lattice, loss implemented, the memory blow-up and its real mitigations (pruned loss, stateless predictor), streaming decoding |
| `04-attention-and-whisper.md` | LAS → Transformer AED → Whisper's actual design and every decoding heuristic as a bug-workaround; hallucination and repetition failure modes; faster-whisper, whisper.cpp, Distil-Whisper, WhisperX, MLX |
| `05-streaming-asr.md` | Chunked vs truly streaming, lookahead as a knob, Conformer/Zipformer/Emformer, LocalAgreement stabilisation, partial-vs-final semantics as an API contract, emission-latency vs WER |
| `06-decoding-and-biasing.md` | Beam search, shallow LM fusion, and contextual biasing — how to make ASR hear *your* product and place names. ITN, punctuation, truecasing |
| `07-evaluation.md` | WER done correctly (alignment, the normalisation trap), plus the metrics that actually predict agent quality: entity WER, latency-to-final, endpoint F1, task success; bootstrap confidence intervals |
| `08-serving-asr.md` | Runtimes (ONNX/CTranslate2/TensorRT/ggml), quantisation caveats, batching a streaming model, GPU concurrency math, cold starts, self-host vs vendor at 10k/100k/1M min/mo |
| `09-diarization-and-speaker-id.md` | Who spoke, and when: VAD → segmentation → embeddings (x-vector/ECAPA) → clustering, overlapped speech, streaming vs offline diarization, DER measured correctly, and speaker verification as an auth anti-pattern |

### `03-turn-taking/` — the module that separates experts from demo-builders
| File | Contents |
|---|---|
| `01-vad.md` | Energy/ZCR and a six-subband WebRTC-style GMM likelihood-ratio detector, both implemented from scratch; Silero DNN integrated via source-verified defaults; ROC curves; hysteresis; why the threshold is a product decision |
| `02-endpointing.md` | Turn-end detection as decision theory: the asymmetric cost of cutting off vs dead air, fixed vs adaptive vs prosodic vs semantic, and the measured cut-off/latency frontier |
| `03-semantic-turn-detection.md` | Transformer turn detectors (LiveKit's plugin, Smart Turn v2): architecture, training, calibration, and how to fuse them with a VAD timer |
| `04-barge-in.md` | Full-duplex mechanics: which of four interrupt signals to act on, the TTS-flush race, truncating the transcript to what the user actually *heard*, backchannels, async cancellation and the zombie-TTS bug |
| `05-echo-and-aec.md` | Why an agent interrupts itself. NLMS derived and implemented, double-talk, WebRTC APM, browser `getUserMedia` constraints, why AEC must live on the client, and the telephony echo cases |

### `04-tts/` — speech synthesis
| File | Contents |
|---|---|
| `01-tts-architectures.md` | G2P/phonemisation → acoustic model → vocoder. Concatenative → parametric → Tacotron → FastSpeech → VITS; Griffin-Lim, WaveNet, HiFi-GAN; what Piper and Kokoro actually are |
| `02-codec-lm-tts.md` | Neural audio codecs (RVQ, SoundStream/EnCodec/DAC), semantic vs acoustic tokens, VALL-E-lineage LM TTS, zero-shot cloning, flow-matching TTS, and the latency you pay for it |
| `03-streaming-tts.md` | `ttfb_tts` is the metric. The LLM-token → speakable-clause aggregator (with the adversarial cases), prosody damage from bad splits, streaming protocols, mid-utterance flush, phrase caching |
| `04-prosody-and-voice.md` | Pronunciation control, lexicons, SSML's decline, number/date/currency verbalisation (en-US vs en-IN), emotion and style control, cloning ethics, watermarking, EU AI Act Art. 50 |
| `05-engine-selection.md` | Local vs hosted TTS: quality/latency/cost/licensing decision tables, per-engine $/1000 min, offline and on-prem constraints, and how to run a fair A/B |

### `05-llm-layer/` — the brain, under a deadline
| File | Contents |
|---|---|
| `01-prompting-for-speech.md` | Why text-tuned LLMs produce unspeakable output, with a full annotated production voice system prompt, length policy, ASR-error robustness, and confirmation strategies |
| `02-context-and-memory.md` | The conversation as a state machine, transcript curation, off-critical-path summarisation, memory tiers with real schemas, and RAG that must retrieve *speculatively* during the user's turn |
| `03-tools-and-agentic.md` | What makes a voice system an actual agent: function calling under a deadline, filler speech, optimistic execution, idempotency, spoken error recovery, constrained state machines vs pure LLM agency, handoff and human escalation |
| `04-serving-llms-fast.md` | TTFT engineering: prefill vs decode, prefix/KV caching and cache-key discipline, continuous batching, speculative decoding, model size vs quality for voice, structured output without a latency tax, local Apple-Silicon serving |
| `05-persona-design.md` | Designing a voice agent's personality as an engineering artifact: register, pace, verbosity, disfluency, error and refusal behaviour, brand constraints, consistency across providers, and how persona changes measurable metrics |

### `06-realtime-systems/` — the systems core
| File | Contents |
|---|---|
| `01-transports.md` | WebSocket vs WebRTC vs SIP/RTP vs gRPC. Why TCP head-of-line blocking ruins audio, Opus PLC/FEC/DTX, when WS is fine, a concrete audio-over-WS subprotocol design, and Twilio Media Streams' actual payload |
| `02-webrtc-internals.md` | SDP, ICE/STUN/TURN, DTLS-SRTP, RTP/RTCP, Opus settings for voice agents, jitter buffers and NetEQ, PLC, congestion control, SFU vs MCU, and how server code gets PCM out of a track |
| `03-pipeline-architecture.md` | Frame graphs from first principles: frame taxonomy, in-band control frames, bounded queues and per-edge backpressure, asyncio cancellation, interrupt propagation. Pipecat's model vs LiveKit `AgentSession`, compared honestly |
| `04-speech-to-speech.md` | Audio-native models: token schemes, full-duplex designs (Moshi), audio-in/text-out (Ultravox), OpenAI Realtime and Gemini Live wire protocols, and the real tradeoff table vs cascaded |
| `05-scale-and-orchestration.md` | 1 → 10,000 sessions: per-session resource model, worker pools, session affinity, draining during deploys, autoscaling signals that work, GPU packing, Erlang for trunks, full $/1000-min model |
| `06-observability.md` | OTel span model for a conversation, the metric set that matters, histogram buckets, recording + deterministic replay, sampling, cost attribution, and alerts that catch real regressions |
| `07-reliability.md` | Failure taxonomy and drills: provider 5xx, TTS death mid-utterance, LLM timeout, GPU OOM, ICE restart, SIP trunk loss. Hedging, circuit breakers, the never-dead-air invariant, chaos injection, SLOs for a *call* |
| `08-deployment.md` | Shipping it: local, browser (WebAudio/AudioWorklet + WebRTC), and cloud. Containers, GPU nodes, regions, edge vs central, CI/CD for real-time services, config and secrets, and blue/green with live calls |

### `07-livekit/` — your production platform, mastered
| File | Contents |
|---|---|
| `01-architecture.md` | Rooms/participants/tracks, the Go SFU, signalling, DataChannel, JWT grants, Redis multi-node routing, egress/ingress — a read-the-source tour, with Cloud-only vs OSS marked |
| `02-agents-framework.md` | v1.7.0 deep dive: `WorkerOptions`, job dispatch, `JobContext`, prewarm and process isolation, `AgentSession` and every interruption/endpointing knob, `Agent` node overrides, `function_tool`, session events, metrics |
| `03-writing-plugins.md` | The real `STT`/`TTS`/`LLM`/`VAD` ABCs and streaming contracts, and how to implement local faster-whisper STT and local Kokoro TTS plugins — how to stop paying vendors |
| `04-self-hosting-and-scale.md` | `livekit-server` config, Redis, TURN, why media can't sit behind an HTTP LB, worker containers, autoscaling and drain, Prometheus, and the honest Cloud-vs-self-host crossover |
| `05-telephony-sip.md` | SIP for software engineers: INVITE/REFER, trunks, DIDs, G.711, DTMF and why in-band breaks ASR, transfer, AMD, the 8 kHz WER tax, and the PSTN failure modes nobody warns you about |
| `06-alternatives.md` | LiveKit vs Pipecat vs Vapi/Retell vs raw WS vs Amazon Connect vs Azure Voice Live vs Riva vs direct S2S — same axes, decision flowchart, and how to keep business logic portable |
| `00-beginner-lab/` | **On-ramp, added 2026-09-14.** Nine files for someone starting from zero on LiveKit: the mental model in plain words; a verified local lab (dev server, tokens, a PCM meter, a full `AgentSession` with **no API keys**); eight small projects; one large project in eight milestones; a debug playbook with real error strings and the 1.7.0→1.8.1 deltas; a build guide for **self-hosted LiveKit + Azure Speech (`centralindia`) + Gemini 2.5 Flash (`asia-south1`)** with vendor region tables parsed rather than recalled; the full provider landscape (cascade vs speech-to-speech, all 75 official plugins, open-source alternatives, who hosts where); and production latency + observability (the twelve levers, Prometheus, **OTel traces into Langfuse** with the span tree captured off the wire, and the PII switch measured). Not chapters — no eight-section format, no exercises |

### `08-eval-safety/`
| File | Contents |
|---|---|
| `01-testing.md` | Testing async audio without flakiness: fake clocks, WAV-driven pipelines, stubbed engines, cancellation tests, golden audio, and latency-regression gates whose thresholds come from distributions |
| `02-simulation-and-load.md` | Simulated callers (script- and LLM-driven), adversarial personas, the quality dashboard, LLM-as-judge done responsibly with calibration, load testing to the knee, soak tests for leaks |
| `03-safety-and-privacy.md` | Prompt injection *via speech*, PII and voiceprint law, redaction, consent and recording law (GDPR, EU AI Act Art. 50, two-party consent, HIPAA, PCI), guardrails placed in parallel not serial, threat model table |

### `09-mastery/`
| File | Contents |
|---|---|
| `01-design-interviews.md` | Six staff/principal design questions with full model answers, arithmetic included — starting with the bootcamp's own "sub-second tool-calling barge-in agent" |
| `02-mastery-checklist.md` | ~120 falsifiable capability statements, each pointing at the chapter that teaches it, with a scoring rubric |
| `03-answers.md` | Worked answers to every chapter exercise |
| `04-glossary.md` | ~200 terms with precise definitions, units, and the confusions that matter (VAD ≠ endpointing, TTFB ≠ TTFA, jitter ≠ latency) |
| `05-mini-projects.md` | A list of small, single-concept projects (30 min – 2 hr each) mapped to specific chapters, distinct from the multi-week capstones in `00-setup/05-bootcamp-coverage.md` §12 |

---

## 3. Study plan — basics to advanced, in order

The dependency order matters: each week's material is *used* by the next.

| Week | Read | You can then |
|---|---|---|
| **1. Ground truth** | `00-setup/*` → `01-foundations/00,01,02,03` | Reason about samples, frames, spectra, and buffering from first principles |
| **2. The deadline** | `01-foundations/04` → `02-asr/01,02` | Build a latency budget on a whiteboard; derive CTC |
| **3. Recognition** | `02-asr/03,04,05` | Explain why streaming ASR is architecturally different, and pick one |
| **4. Recognition quality** | `02-asr/06,07,08` | Make ASR hear your domain, and measure it honestly |
| **5. Turn-taking** | `03-turn-taking/01..05` | Defend an endpointing and barge-in policy with numbers. **The differentiator week** |
| **6. Output + brain** | `04-tts/01..05` → `05-llm-layer/01..05` | Design the response path: speakable text, fast tokens, streaming audio |
| **7. Systems** | `06-realtime-systems/01..08` | Design the platform: transport, frame graph, scale, reliability, deployment |
| **8. Platform + rigour** | `07-livekit/01..06` → `08-eval-safety/*` → `09-mastery/*` | Own the LiveKit stack, evaluate it against alternatives, and pass the interview |

Total reading: 55 chapters plus the `09-mastery/05-mini-projects.md` list. At 2 chapters/day this is ~4 weeks; at 1/day, 8 weeks.
The exercises are where the learning actually happens — do them.

---

## 4. Relationship to the Vizuara bootcamp syllabus

Every bullet of the 8-day syllabus at `voice-agents.vizuara.ai` is mapped to a
chapter in `00-setup/05-bootcamp-coverage.md`, with the gaps that syllabus leaves
called out explicitly. Summary:

| Bootcamp day | Covered by | Depth here |
|---|---|---|
| 1. Voice agents & architecture | `01-foundations/00`, `06-realtime-systems/03` | Adds frame-graph design, batch-vs-streaming tradeoffs, ecosystem map |
| 2. ASR foundations | `02-asr/01..08`, `01-foundations/01,02` | Adds CTC/RNN-T from scratch, decoding, biasing, evaluation, serving |
| 3. TTS & voice output | `04-tts/01..05` | Adds codec-LM TTS, vocoders, streaming aggregation, ethics/law |
| 4. LLM as the brain | `05-llm-layer/01,02,05` | Adds TTFT engineering and persona-as-engineering |
| 5. Tools, memory, agentic | `05-llm-layer/02,03` | Adds idempotency, speculative execution, constrained state machines |
| 6. Real-time streaming | `03-turn-taking/*`, `06-realtime-systems/01,02` | Adds WebRTC internals, AEC, semantic turn detection, jitter buffers |
| 7. Production architecture | `06-realtime-systems/05..08`, `08-eval-safety/*` | Adds SLOs, capacity math, chaos drills, cost models, compliance |
| 8. End-to-end / deployment | `07-livekit/*`, `06-realtime-systems/08` | Adds self-hosting, SIP telephony, plugin authoring, alternatives analysis |

## 5. Ground rules

- **No hand-waving.** If a chapter says "the jitter buffer adapts", it shows the algorithm.
- **Everything runs on an M5 Mac** unless marked `[NEEDS GPU]`.
- **Sources are pointers, not vibes.** OSS references name repo, path, and version.
- **Cost is a first-class metric.** Every architecture chapter ends with $/1000 minutes.
- **Code in chapters is standalone.** Copy a block into a file and it runs.
