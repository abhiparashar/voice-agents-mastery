# Coverage map: the Vizuara 8-day syllabus vs this curriculum

**What you'll be able to do after this:** confirm that every item in the
`voice-agents.vizuara.ai` syllabus is taught here and know exactly which file
teaches it; see where this curriculum goes materially deeper; and see the topics
that syllabus omits which you nonetheless need to be top 1%.

This is a bookkeeping chapter. Read it once, then use it as an index.

---

## 1. How to read the mapping

Each syllabus bullet is quoted verbatim, then mapped to the file(s) that teach it.
The **Depth** column says what this curriculum adds beyond what an 8-day live
bootcamp can fit:

- `=` — equivalent coverage.
- `+` — same topic, taught from first principles with derivations and source-verified production references.
- `++` — the syllabus mentions it; here it is a full chapter or module with its own math, measurements, and scale analysis.

A syllabus bullet that says "build X" is mapped to the chapter that teaches the
*understanding* required, since this curriculum is teaching material by design —
projects come later.

---

## 2. Day 1 — Voice Agents & System Architecture

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| What is a voice agent vs chatbot vs conversational AI | [`01-foundations/00-what-is-a-voice-agent.md`](../01-foundations/00-what-is-a-voice-agent.md) §1–2 | `++` adds IVR, rule-based voicebot, cascaded vs native S2S, and "agent" defined by tool use + state |
| Core architecture: Audio → ASR → LLM → TTS → Audio | [`01-foundations/00`](../01-foundations/00-what-is-a-voice-agent.md) §2; [`06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md) | `++` adds frame taxonomy, in-band control frames, backpressure per edge |
| Batch vs streaming pipeline design | [`01-foundations/00`](../01-foundations/00-what-is-a-voice-agent.md) §2; [`01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md) | `++` adds the arithmetic showing why batch is 2–4× worse, and the three independent streaming levels |
| Key challenges: latency, interruptions, turn-taking | [`01-foundations/04`](../01-foundations/04-latency-budget.md); all of [`03-turn-taking/`](../03-turn-taking/) | `++` an entire five-chapter module on turn-taking alone |
| Overview of the voice agent ecosystem and frameworks | [`01-foundations/00`](../01-foundations/00-what-is-a-voice-agent.md) §4; [`07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md) | `++` adds a decision matrix on control, ops burden, lock-in, and cost at 10k/100k/1M min/mo |
| Build a simple end-to-end voice interaction loop | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) §3 (a complete runnable frame runtime) | `+` |

## 3. Day 2 — Speech-to-Text (ASR) Foundations

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| How automatic speech recognition works | [`02-asr/01-from-hmm-to-e2e.md`](../02-asr/01-from-hmm-to-e2e.md), [`02`](../02-asr/02-ctc-from-scratch.md), [`03`](../02-asr/03-rnnt-transducer.md), [`04`](../02-asr/04-attention-and-whisper.md) | `++` four chapters: GMM-HMM/WFST/Viterbi, CTC derived and implemented, RNN-T, attention |
| Audio preprocessing, feature extraction, decoding | [`01-foundations/01`](../01-foundations/01-sound-and-sampling.md), [`02`](../01-foundations/02-time-frequency.md); [`02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md) | `++` Nyquist and quantisation derived; mel filterbank built in numpy; beam search, LM fusion, contextual biasing |
| Whisper, faster-whisper, Distil-Whisper deep dive | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) | `++` every decoding threshold read from source and explained as the failure it prevents; adds whisper.cpp, WhisperX, MLX |
| Implement local transcription pipeline in Python | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) §3–4; [`02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md) | `+` adds runtime/quantisation choice and the WER re-measurement rule |
| Microphone recording and live transcription | [`01-foundations/03-audio-io-and-buffering.md`](../01-foundations/03-audio-io-and-buffering.md); [`02-asr/05-streaming-asr.md`](../02-asr/05-streaming-asr.md) | `++` adds the real-time callback contract, ring buffers, clock drift, LocalAgreement stabilisation |
| Voice Activity Detection (VAD) for speech pipelines | [`03-turn-taking/01-vad.md`](../03-turn-taking/01-vad.md) | `++` energy and GMM VADs implemented from scratch, Silero integrated correctly, with ROC curves and operating-point selection |

## 4. Day 3 — Text-to-Speech & Voice Output

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| How modern TTS systems work | [`04-tts/01-tts-architectures.md`](../04-tts/01-tts-architectures.md), [`02-codec-lm-tts.md`](../04-tts/02-codec-lm-tts.md) | `++` G2P through vocoders; RVQ codecs and VALL-E-lineage LM TTS, which the syllabus omits entirely |
| Trade-offs: latency, quality, controllability, cost | [`04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md) | `++` per-engine $/1000 min and licensing, plus how to run a fair A/B |
| Piper, Coqui TTS, ElevenLabs comparison | [`04-tts/01`](../04-tts/01-tts-architectures.md) §4, [`05`](../04-tts/05-engine-selection.md) | `+` adds Kokoro and what each engine architecturally *is* |
| Build a TTS pipeline in Python | [`04-tts/01`](../04-tts/01-tts-architectures.md) §3, [`03-streaming-tts.md`](../04-tts/03-streaming-tts.md) §3 | `+` |
| Real-time speech playback | [`01-foundations/03`](../01-foundations/03-audio-io-and-buffering.md); [`04-tts/03`](../04-tts/03-streaming-tts.md) | `++` adds playout buffering, underruns, and mid-utterance flush semantics |
| Local vs API-based TTS systems | [`04-tts/05`](../04-tts/05-engine-selection.md) | `++` |

## 5. Day 4 — LLMs as the Brain

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| Why ASR + TTS alone is not enough | [`01-foundations/00`](../01-foundations/00-what-is-a-voice-agent.md) §1 | `=` |
| LLMs as the reasoning and decision-making layer | [`05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md) | `+` |
| Prompting for voice: concise, spoken-style responses | [`05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md) | `++` full annotated production system prompt, each line justified by the failure it prevents |
| Transcript → LLM → spoken response loop | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md); [`04-tts/03`](../04-tts/03-streaming-tts.md) | `++` adds the token→clause aggregator, the part that actually determines perceived latency |
| Conversation history and context management | [`05-llm-layer/02-context-and-memory.md`](../05-llm-layer/02-context-and-memory.md) | `++` adds memory tiers with schemas, and truncating interrupted turns to what was heard |
| Designing voice agent personalities | [`05-llm-layer/05-persona-design.md`](../05-llm-layer/05-persona-design.md) | `++` persona as an engineering artifact with measurable effects on latency and task success |

## 6. Day 5 — Tool Use, Memory & Agentic Workflows

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| What makes a voice system an actual agent | [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) §1 | `=` |
| Tool calling: calculator, web search, scheduling, APIs | [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) | `++` adds filler speech during tool latency, timeouts, idempotency, spoken error recovery |
| Short-term vs long-term memory | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) | `++` four tiers, not two, with storage schemas and retrieval budgets |
| Context engineering: keep, compress, control latency | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md), [`04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md) | `++` ties context length to prefill cost and prefix-cache key discipline |
| Build a tool-using voice agent pipeline | [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) §3 | `+` |
| Example: voice assistant that searches and takes actions | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) (speculative retrieval), [`03`](../05-llm-layer/03-tools-and-agentic.md) | `+` |

## 7. Day 6 — Real-Time Streaming Voice Agents

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| Turn-based vs real-time voice systems | [`01-foundations/00`](../01-foundations/00-what-is-a-voice-agent.md) §2; [`06-realtime-systems/01-transports.md`](../06-realtime-systems/01-transports.md) | `+` |
| WebSockets, incremental ASR, partial transcripts | [`06-realtime-systems/01`](../06-realtime-systems/01-transports.md); [`02-asr/05`](../02-asr/05-streaming-asr.md) | `++` adds why TCP head-of-line blocking ruins audio, and a concrete audio-over-WS subprotocol |
| Streaming TTS, endpointing, turn detection | [`04-tts/03`](../04-tts/03-streaming-tts.md); [`03-turn-taking/02`](../03-turn-taking/02-endpointing.md), [`03`](../03-turn-taking/03-semantic-turn-detection.md) | `++` endpointing as decision theory; transformer turn detectors and VAD fusion |
| Barge-in and user interruption handling | [`03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md), [`05-echo-and-aec.md`](../03-turn-taking/05-echo-and-aec.md) | `++` the flush race, transcript truncation, backchannels, and AEC — the reason agents interrupt themselves |
| Build a real-time streaming voice loop | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) §3 | `+` |
| Understanding production latency sources | [`01-foundations/04`](../01-foundations/04-latency-budget.md) | `++` term-by-term budget for three regimes plus queueing theory |

## 8. Day 7 — Production-Grade Architecture

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| Designing a robust, modular voice agent system | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md), [`07-reliability.md`](../06-realtime-systems/07-reliability.md) | `++` |
| Frontend, backend, ASR/LLM/TTS services, memory layer | [`06-realtime-systems/08-deployment.md`](../06-realtime-systems/08-deployment.md); [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) | `++` adds browser AudioWorklet client, containers, regions, blue/green with live calls |
| Fallbacks, retries, and failure handling | [`06-realtime-systems/07`](../06-realtime-systems/07-reliability.md) | `++` full failure taxonomy, hedging, circuit breakers, chaos injection, never-dead-air invariant |
| Cost optimization and model selection | [`02-asr/08`](../02-asr/08-serving-asr.md), [`04-tts/05`](../04-tts/05-engine-selection.md), [`05-llm-layer/04`](../05-llm-layer/04-serving-llms-fast.md), [`06-realtime-systems/05`](../06-realtime-systems/05-scale-and-orchestration.md) | `++` $/1000-min models per layer with the formulas |
| Safety, filtering, and guardrails | [`08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md) | `++` adds prompt injection *via speech*, PII/voiceprint law, parallel-not-serial guardrails |
| Frameworks comparison: Python+WS vs Pipecat/LiveKit | [`07-livekit/06`](../07-livekit/06-alternatives.md); [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) §4 | `++` |

## 9. Day 8 — End-to-End and Deployment

| Syllabus bullet | Taught in | Depth |
|---|---|---|
| Build a complete voice agent from scratch | Whole curriculum; assembly guide in [`09-mastery/01-design-interviews.md`](../09-mastery/01-design-interviews.md) Q1 | `+` |
| Full pipeline: mic → VAD → ASR → LLM → tools → TTS | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) | `+` |
| Choose: receptionist, meeting, research, desktop assistant | §12 below maps each to its prerequisite chapters | deferred by design |
| Testing, debugging, and improving your system | [`08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md), [`02-simulation-and-load.md`](../08-eval-safety/02-simulation-and-load.md) | `++` deterministic async audio tests, simulated adversarial callers, latency-regression gates |
| Deployment: local, browser-based, and cloud setups | [`06-realtime-systems/08`](../06-realtime-systems/08-deployment.md); [`07-livekit/04-self-hosting-and-scale.md`](../07-livekit/04-self-hosting-and-scale.md) | `++` |
| Extending into real-world products | [`07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md), [`06`](../07-livekit/06-alternatives.md) | `++` real PSTN failure modes and build-vs-buy |

## 10. Tools and models list

| Syllabus tool | Where it is taught in depth |
|---|---|
| Whisper | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) |
| faster-whisper | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) §4, [`08`](../02-asr/08-serving-asr.md) |
| Distil-Whisper | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) §4 |
| Piper TTS | [`04-tts/01`](../04-tts/01-tts-architectures.md) §4, [`05`](../04-tts/05-engine-selection.md) |
| Coqui TTS | [`04-tts/01`](../04-tts/01-tts-architectures.md) §4, [`05`](../04-tts/05-engine-selection.md) |
| Silero VAD | [`03-turn-taking/01`](../03-turn-taking/01-vad.md) |
| Claude / GPT | [`05-llm-layer/01`](../05-llm-layer/01-prompting-for-speech.md), [`04`](../05-llm-layer/04-serving-llms-fast.md) |
| WebSockets | [`06-realtime-systems/01`](../06-realtime-systems/01-transports.md) |
| Python (asyncio) | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) |

## 11. What that syllabus does not cover, and why you need it

An 8-day bootcamp has to stop somewhere. These are the omissions that separate
"can build a demo" from "can own the platform", and each is a chapter here.

| Omitted topic | Why it matters | Chapter |
|---|---|---|
| **WebRTC internals** | Every production voice agent that is not a phone call runs on WebRTC. Not knowing jitter buffers or Opus DTX means you cannot debug choppy audio | [`06-realtime-systems/02`](../06-realtime-systems/02-webrtc-internals.md) |
| **Acoustic echo cancellation** | The single most common cause of an agent interrupting itself. Invisible with headphones, fatal on speakerphone | [`03-turn-taking/05`](../03-turn-taking/05-echo-and-aec.md) |
| **Semantic turn detection** | Fixed silence timeouts are why agents feel robotic. Transformer turn detectors are the current state of the art | [`03-turn-taking/03`](../03-turn-taking/03-semantic-turn-detection.md) |
| **Telephony / SIP** | Most commercial voice agents are phone-based. 8 kHz narrowband, DTMF, and transfer are their own discipline | [`07-livekit/05`](../07-livekit/05-telephony-sip.md) |
| **Speaker diarization and identification** | "Who spoke?" is required for meeting assistants and multi-party calls, and it is a different problem from ASR | [`02-asr/09`](../02-asr/09-diarization-and-speaker-id.md) |
| **Codec-LM TTS and neural audio codecs** | The paradigm behind every zero-shot voice clone since 2023, and the reason those voices cost you latency | [`04-tts/02`](../04-tts/02-codec-lm-tts.md) |
| **Native speech-to-speech models** | The architecture that may replace the cascade. You need to be able to argue both sides | [`06-realtime-systems/04`](../06-realtime-systems/04-speech-to-speech.md) |
| **Scale and orchestration** | Worker pools, session affinity, draining during deploys, GPU packing, capacity math | [`06-realtime-systems/05`](../06-realtime-systems/05-scale-and-orchestration.md) |
| **Observability for conversations** | You cannot improve latency you do not trace per turn | [`06-realtime-systems/06`](../06-realtime-systems/06-observability.md) |
| **Evaluation methodology** | WER normalisation traps, endpoint F1, bootstrap confidence intervals, simulated callers | [`02-asr/07`](../02-asr/07-evaluation.md), [`08-eval-safety/02`](../08-eval-safety/02-simulation-and-load.md) |
| **Plugin authoring against a real framework** | How you stop paying vendors and run local models inside LiveKit | [`07-livekit/03`](../07-livekit/03-writing-plugins.md) |
| **Compliance and consent law** | Recording consent, EU AI Act disclosure, PCI, HIPAA. These are launch blockers, not footnotes | [`08-eval-safety/03`](../08-eval-safety/03-safety-and-privacy.md) |

## 12. The five capstone ideas, and what each requires

Projects are deliberately out of scope here — build them after the reading. This
table tells you which chapters are the actual prerequisites for each, so the
build is assembly rather than discovery. If a multi-week capstone is too much
commitment before you know a chapter is worth it,
[`09-mastery/05-mini-projects.md`](../09-mastery/05-mini-projects.md) lists 33
single-concept projects (30 min – 2 hr each) instead.

| Capstone | Hard part | Required chapters |
|---|---|---|
| **AI receptionist** (inbound phone) | Telephony + endpointing under 8 kHz noise + transfer | [`07-livekit/05`](../07-livekit/05-telephony-sip.md), [`03-turn-taking/02`](../03-turn-taking/02-endpointing.md)–[`04`](../03-turn-taking/04-barge-in.md), [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md), [`06-realtime-systems/07`](../06-realtime-systems/07-reliability.md) |
| **Meeting assistant** | Diarization + long-context summarisation + no barge-in at all | [`02-asr/09`](../02-asr/09-diarization-and-speaker-id.md), [`02-asr/05`](../02-asr/05-streaming-asr.md), [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) |
| **Research assistant** | Speculative retrieval during the user's turn, spoken citations | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md), [`03`](../05-llm-layer/03-tools-and-agentic.md), [`04-tts/04`](../04-tts/04-prosody-and-voice.md) |
| **Desktop assistant** | Wake word, always-on VAD, AEC on speakers, OS side effects | [`03-turn-taking/01`](../03-turn-taking/01-vad.md), [`05`](../03-turn-taking/05-echo-and-aec.md), [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) |
| **Scheduling agent** | Slot-filling from noisy speech, dates/times, idempotent writes | [`04-tts/04`](../04-tts/04-prosody-and-voice.md), [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md), [`02-asr/06`](../02-asr/06-decoding-and-biasing.md) |

## 13. The research-track topics

The bootcamp's research add-on lists example topics. Each maps to the chapter
that gives you enough background to read the literature critically:

| Research topic | Background chapter |
|---|---|
| Low-latency streaming ASR with Conformer encoders | [`02-asr/03`](../02-asr/03-rnnt-transducer.md), [`05`](../02-asr/05-streaming-asr.md) |
| Expressive neural TTS with emotion and prosody control | [`04-tts/02`](../04-tts/02-codec-lm-tts.md), [`04`](../04-tts/04-prosody-and-voice.md) |
| End-to-end speech-to-speech translation, small models | [`06-realtime-systems/04`](../06-realtime-systems/04-speech-to-speech.md) |
| Real-time VAD and barge-in for conversational agents | [`03-turn-taking/01`](../03-turn-taking/01-vad.md)–[`04`](../03-turn-taking/04-barge-in.md) |
| Knowledge distillation of Whisper for on-device ASR | [`02-asr/04`](../02-asr/04-attention-and-whisper.md), [`08`](../02-asr/08-serving-asr.md) |
| Voice cloning ethics and watermarking | [`04-tts/04`](../04-tts/04-prosody-and-voice.md), [`08-eval-safety/03`](../08-eval-safety/03-safety-and-privacy.md) |
| Speaker diarization for multi-party assistants | [`02-asr/09`](../02-asr/09-diarization-and-speaker-id.md) |
| Retrieval-augmented voice agents | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) |

---

## Sources

- Vizuara Voice Agent Engineering Bootcamp syllabus, `https://voice-agents.vizuara.ai/`, retrieved 2026-08-22. All syllabus bullets in §2–§10 are quoted from that page.
