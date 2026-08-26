# Mastery checklist

138 falsifiable capability statements. Each one is a claim you can test on yourself in a few
minutes, and each points at the chapter that teaches it.

This is not a reading log. A statement you have *read about* scores 1. The bar for the top
score is that you could produce the thing from scratch, on a whiteboard or in an empty file,
without looking it up.

---

## How to score

| Score | Meaning | Test |
|---|---|---|
| **0** | Never encountered it | You do not recognise the terms |
| **1** | Recognise | You could follow a colleague's explanation and ask a sensible question |
| **2** | Explain | You could teach it correctly to an engineer new to speech, including *why* |
| **3** | Derive or build | You could derive the maths, or write the code, from an empty file — and you know the numbers |

Score every statement, then total. Maximum is **414** (138 × 3).

| Total | Band | What it means |
|---|---|---|
| 0–100 | **Novice** | You can use a voice framework. You cannot yet debug it. |
| 101–190 | **Practitioner** | You ship features and diagnose the common failures. Gaps are in the maths and at scale. |
| 191–278 | **Senior** | You own a subsystem, design against numbers, and know where your knowledge ends. |
| 279–356 | **Staff** | You design the platform, arbitrate cross-team tradeoffs, and can defend every number. |
| 357–414 | **Top 1%** | You could have written this curriculum. Go build the thing instead. |

Two honest calibrations. **Anything below a 2 on a `03-turn-taking` statement caps you at
Practitioner**, whatever your total — turn-taking is the module that separates people who
have shipped a voice agent from people who have shipped a demo. And **a 3 on every
`06-realtime-systems` statement with 1s in `02-asr` makes you a systems engineer who ships
voice, which is a real and valuable thing** — the bands assume breadth, but the job may not.

---

## 00-setup — the bench (6)

| # | I can… | Chapter |
|---|---|---|
| 1 | State the internal audio contract from memory — 16 kHz mono s16le, 20 ms, 320 samples, 640 bytes — and justify every one of those four numbers | [`00-setup/03-canonical-formats.md`](../00-setup/03-canonical-formats.md) |
| 2 | Convert between `bytes`, `np.int16` and `np.float32` in [−1, 1) without a scaling bug, and say why 32768 rather than 32767 | [`00-setup/03`](../00-setup/03-canonical-formats.md) |
| 3 | Write a WAV/RIFF header by hand and explain why a header in a Twilio `media.payload` breaks playback | [`00-setup/03`](../00-setup/03-canonical-formats.md) |
| 4 | Set up the bench from scratch — uv, Python 3.12, PortAudio, ffmpeg, macOS microphone permissions — and fix the first ten errors without searching | [`00-setup/01-environment.md`](../00-setup/01-environment.md) |
| 5 | Say which models run on Apple Silicon via MPS/MLX/CoreML/CTranslate2/GGUF-Metal and which genuinely need CUDA, with RAM figures | [`00-setup/02-hardware-and-cost.md`](../00-setup/02-hardware-and-cost.md) |
| 6 | Name the ten OSS repositories worth reading as literature, and the specific files in each | [`00-setup/04-reading-list.md`](../00-setup/04-reading-list.md) |

## 01-foundations — sound, and where time goes (14)

| # | I can… | Chapter |
|---|---|---|
| 7 | Distinguish voice agent, chatbot, IVR, conversational AI and speech-to-speech precisely enough to correct a product manager | [`01-foundations/00`](../01-foundations/00-what-is-a-voice-agent.md) |
| 8 | Name the four hard problems (latency, turn-taking, interruption, error compounding) and say which is a systems problem wearing an ML costume | [`01-foundations/00`](../01-foundations/00-what-is-a-voice-agent.md) |
| 9 | Derive the Nyquist limit and demonstrate aliasing audibly | [`01-foundations/01`](../01-foundations/01-sound-and-sampling.md) |
| 10 | Derive the quantisation SNR $6.02b + 1.76$ dB and say what it means for 16-bit audio | [`01-foundations/01`](../01-foundations/01-sound-and-sampling.md) |
| 11 | Explain formants, F0 and the speech spectrum well enough to predict which sounds an 8 kHz channel destroys | [`01-foundations/01`](../01-foundations/01-sound-and-sampling.md) |
| 12 | Distinguish dBFS from dBA and read a level meter without confusing them | [`01-foundations/01`](../01-foundations/01-sound-and-sampling.md) |
| 13 | Explain µ-law companding and why telephony is 8 kHz | [`01-foundations/01`](../01-foundations/01-sound-and-sampling.md) |
| 14 | Implement the DFT, explain spectral leakage, and choose a window with a reason | [`01-foundations/02`](../01-foundations/02-time-frequency.md) |
| 15 | State the time–frequency uncertainty tradeoff and pick a frame length for a stated purpose | [`01-foundations/02`](../01-foundations/02-time-frequency.md) |
| 16 | Build a mel filterbank in numpy and reproduce Whisper's log-mel as `(80, 3000)` exactly | [`01-foundations/02`](../01-foundations/02-time-frequency.md) |
| 17 | Say why MFCCs died, and what replaced them | [`01-foundations/02`](../01-foundations/02-time-frequency.md) |
| 18 | Implement a lock-free ring buffer and name the symptoms of underrun versus overrun by ear | [`01-foundations/03`](../01-foundations/03-audio-io-and-buffering.md) |
| 19 | Compute clock drift in ppm and say what it does to a two-hour call | [`01-foundations/03`](../01-foundations/03-audio-io-and-buffering.md) |
| 20 | Decompose a mouth-to-ear latency budget term by term for three regimes, and explain why endpointing is a *policy* cost rather than a compute cost | [`01-foundations/04`](../01-foundations/04-latency-budget.md) |

## 02-asr — recognition (20)

| # | I can… | Chapter |
|---|---|---|
| 21 | Work a Viterbi decode numerically by hand on a small HMM | [`02-asr/01`](../02-asr/01-from-hmm-to-e2e.md) |
| 22 | Explain what WFST/HCLG composition buys and what end-to-end silently kept | [`02-asr/01`](../02-asr/01-from-hmm-to-e2e.md) |
| 23 | Explain forced alignment and name three things it is still used for | [`02-asr/01`](../02-asr/01-from-hmm-to-e2e.md) |
| 24 | Derive the CTC forward–backward recursion and implement it in numpy, matching PyTorch to ~1e-15 | [`02-asr/02`](../02-asr/02-ctc-from-scratch.md) |
| 25 | Explain the blank symbol, alignment collapse, and why CTC cannot model output dependencies | [`02-asr/02`](../02-asr/02-ctc-from-scratch.md) |
| 26 | Implement prefix beam search and explain peaky posteriors | [`02-asr/02`](../02-asr/02-ctc-from-scratch.md) |
| 27 | Derive the RNN-T loss over the $T \times U$ lattice and implement it, matching torchaudio to ~3e-7 | [`02-asr/03`](../02-asr/03-rnnt-transducer.md) |
| 28 | Quantify RNN-T's memory blow-up and name the real mitigations (pruned loss, stateless predictor) | [`02-asr/03`](../02-asr/03-rnnt-transducer.md) |
| 29 | Explain every Whisper decoding heuristic as the bug it works around, with the threshold values | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) |
| 30 | Reproduce Whisper's constants from memory: 16 kHz, `N_FFT` 400, hop 160, 30 s chunk, 3000 frames, 50 tokens/s | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) |
| 31 | Diagnose Whisper hallucination and repetition from a transcript alone | [`02-asr/04`](../02-asr/04-attention-and-whisper.md) |
| 32 | Choose between faster-whisper, whisper.cpp, Distil-Whisper, WhisperX and MLX with reasons | [`02-asr/04`](../02-asr/04-attention-and-whisper.md), [`02-asr/08`](../02-asr/08-serving-asr.md) |
| 33 | Distinguish chunked from truly streaming ASR, and treat lookahead as a tunable knob | [`02-asr/05`](../02-asr/05-streaming-asr.md) |
| 34 | Implement LocalAgreement stabilisation and explain partial-versus-final as an API contract | [`02-asr/05`](../02-asr/05-streaming-asr.md) |
| 35 | Explain the emission-latency versus WER frontier and pick an operating point | [`02-asr/05`](../02-asr/05-streaming-asr.md) |
| 36 | Implement shallow LM fusion and contextual biasing so ASR hears my product names | [`02-asr/06`](../02-asr/06-decoding-and-biasing.md) |
| 37 | Explain ITN, punctuation and truecasing as separate problems with separate failure modes | [`02-asr/06`](../02-asr/06-decoding-and-biasing.md) |
| 38 | Compute WER correctly, including the normalisation trap, with bootstrap confidence intervals | [`02-asr/07`](../02-asr/07-evaluation.md) |
| 39 | Name the metrics that predict agent quality better than WER — entity WER, latency-to-final, endpoint F1, task success | [`02-asr/07`](../02-asr/07-evaluation.md) |
| 40 | Do the GPU concurrency arithmetic for batching a streaming model, and the self-host-versus-vendor crossover at 10k/100k/1M min/mo | [`02-asr/08`](../02-asr/08-serving-asr.md) |

## 03-turn-taking — the differentiator (14)

| # | I can… | Chapter |
|---|---|---|
| 41 | Implement energy/ZCR, WebRTC-GMM-style and Silero VAD, and explain what each gains | [`03-turn-taking/01`](../03-turn-taking/01-vad.md) |
| 42 | Read an ROC/DET curve and choose a VAD threshold as a *product* decision | [`03-turn-taking/01`](../03-turn-taking/01-vad.md) |
| 43 | Explain why best frame-level F1 shredded 33 utterances into 265 segments, and why hangover — not hysteresis — fixed it (F1 0.962 at 34 segments) | [`03-turn-taking/01`](../03-turn-taking/01-vad.md) |
| 44 | Quote Silero's defaults: window 512 at 16 kHz, threshold 0.5, min speech 250 ms, min silence 100 ms, pad 30 ms | [`03-turn-taking/01`](../03-turn-taking/01-vad.md) |
| 45 | Frame endpointing as decision theory with an asymmetric cost, and defend a policy with numbers | [`03-turn-taking/02`](../03-turn-taking/02-endpointing.md) |
| 46 | Reproduce the cut-off/latency frontier: fixed 700 ms → 3.04% cut-off, adaptive → 2.78% at 330 ms | [`03-turn-taking/02`](../03-turn-taking/02-endpointing.md) |
| 47 | Explain why a semantic turn detector at AUC 0.510 is *worse* than a fixed timeout, and what that implies about buying one | [`03-turn-taking/03`](../03-turn-taking/03-semantic-turn-detection.md) |
| 48 | Fuse a transformer turn detector with a VAD timer, including calibration | [`03-turn-taking/03`](../03-turn-taking/03-semantic-turn-detection.md) |
| 49 | Name the four interrupt signals and say which to act on | [`03-turn-taking/04`](../03-turn-taking/04-barge-in.md) |
| 50 | Explain the TTS-flush race and the zombie-TTS bug, and fix both | [`03-turn-taking/04`](../03-turn-taking/04-barge-in.md) |
| 51 | Truncate a transcript to what the user actually *heard*, and say why the alternative corrupts the next turn — 14 words generated, 14 synthesised, 5 heard | [`03-turn-taking/04`](../03-turn-taking/04-barge-in.md) |
| 52 | Distinguish a backchannel from an interruption, and tune `min_duration` / `min_words` / false-interruption resume | [`03-turn-taking/04`](../03-turn-taking/04-barge-in.md) |
| 53 | Derive NLMS and implement an echo canceller | [`03-turn-taking/05`](../03-turn-taking/05-echo-and-aec.md) |
| 54 | Explain why AEC without double-talk detection attenuates the near-end speaker by −10 dB where correct DTD gives +30.6 dB, and why AEC must live on the client | [`03-turn-taking/05`](../03-turn-taking/05-echo-and-aec.md) |

## 04-tts — synthesis (12)

| # | I can… | Chapter |
|---|---|---|
| 55 | Trace G2P → acoustic model → vocoder and say what each stage can break | [`04-tts/01`](../04-tts/01-tts-architectures.md) |
| 56 | Explain the concatenative → parametric → Tacotron → FastSpeech → VITS lineage and what each fixed | [`04-tts/01`](../04-tts/01-tts-architectures.md) |
| 57 | Implement Griffin-Lim and explain why spectral convergence 0.66 → 0.013 while waveform SNR stays −3 dB (true phase: +36.8 dB) | [`04-tts/01`](../04-tts/01-tts-architectures.md) |
| 58 | Say what Piper and Kokoro actually are, including Kokoro-82M's 82 M parameters and Apache weights | [`04-tts/01`](../04-tts/01-tts-architectures.md) |
| 59 | Implement residual vector quantisation and explain 17.29 dB from six small codebooks versus ~1.4 dB/bit for flat VQ | [`04-tts/02`](../04-tts/02-codec-lm-tts.md) |
| 60 | Distinguish semantic from acoustic tokens and explain the VALL-E lineage | [`04-tts/02`](../04-tts/02-codec-lm-tts.md) |
| 61 | Price the latency of zero-shot cloning and flow-matching TTS against a cascade | [`04-tts/02`](../04-tts/02-codec-lm-tts.md) |
| 62 | Build the LLM-token → speakable-clause aggregator and name its adversarial cases | [`04-tts/03`](../04-tts/03-streaming-tts.md) |
| 63 | Explain prosody damage from bad clause splits, and implement mid-utterance flush | [`04-tts/03`](../04-tts/03-streaming-tts.md) |
| 64 | Verbalise numbers, dates and currency correctly for en-US *and* en-IN | [`04-tts/04`](../04-tts/04-prosody-and-voice.md) |
| 65 | State the cloning-consent and watermarking obligations, including AI Act Art. 50(2)'s machine-readable marking | [`04-tts/04`](../04-tts/04-prosody-and-voice.md), [`08-eval-safety/03`](../08-eval-safety/03-safety-and-privacy.md) |
| 66 | Compute the local-versus-hosted TTS breakeven (~56k audio-min/month) and run a fair A/B | [`04-tts/05`](../04-tts/05-engine-selection.md) |

## 05-llm-layer — the brain under a deadline (14)

| # | I can… | Chapter |
|---|---|---|
| 67 | Write a production voice system prompt and explain every clause, including length policy and ASR-error robustness | [`05-llm-layer/01`](../05-llm-layer/01-prompting-for-speech.md) |
| 68 | Say why text-tuned LLMs produce unspeakable output, with concrete examples | [`05-llm-layer/01`](../05-llm-layer/01-prompting-for-speech.md) |
| 69 | Design a confirmation strategy that survives ASR errors on entities | [`05-llm-layer/01`](../05-llm-layer/01-prompting-for-speech.md) |
| 70 | Model the conversation as a state machine and curate the transcript deliberately | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) |
| 71 | Compare context policies with real numbers: full history 62 recomputed tokens/turn versus sliding-window-12 at 213 | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) |
| 72 | Explain why RAG must retrieve *speculatively* during the user's turn, and why prepended (609) versus appended (184) matters for cache | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) |
| 73 | Design memory tiers with real schemas and off-critical-path summarisation | [`05-llm-layer/02`](../05-llm-layer/02-context-and-memory.md) |
| 74 | Implement function calling under a deadline with filler speech, and quote the effect: `ttfa` p50 1815 → 551 ms with no change in answer time | [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) |
| 75 | Implement optimistic execution and idempotency keys, and say what happens on a retried mutation | [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) |
| 76 | Choose between a constrained state machine and pure LLM agency, and justify it | [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) |
| 77 | Quantify hedging and deadlines: p95 3288 → 2351 ms at 1.2 wasted calls; p99 4956 → 2961 ms at 3.1% degraded | [`05-llm-layer/03`](../05-llm-layer/03-tools-and-agentic.md) |
| 78 | Explain prefill versus decode with the measured 69× gap (0.09 ms/token versus 6.37 ms/token) and what it implies for TTFT | [`05-llm-layer/04`](../05-llm-layer/04-serving-llms-fast.md) |
| 79 | Explain prefix-cache discipline and its measured savings (85.1% at 1024+128, 94.0% at 2048+64), and why static batching gives ttft p50 489 ms versus 15 ms continuous | [`05-llm-layer/04`](../05-llm-layer/04-serving-llms-fast.md) |
| 80 | Show why speculative decoding failed here — alpha 0.44 at k=2 but c_draft/c_target 0.56, needing r < 0.32 | [`05-llm-layer/04`](../05-llm-layer/04-serving-llms-fast.md) |

## 06-realtime-systems — the systems core (22)

| # | I can… | Chapter |
|---|---|---|
| 81 | Derive TCP head-of-line blocking and quantify it: 5% loss / 200 ms RTT leaves 66.1% of frames usable versus 95.1% RTP and 99.8% RTP+FEC | [`06-realtime-systems/01`](../06-realtime-systems/01-transports.md) |
| 82 | Say when a WebSocket is genuinely fine, and design a binary audio-over-WS subprotocol that is not a mistake | [`06-realtime-systems/01`](../06-realtime-systems/01-transports.md) |
| 83 | Price Twilio's JSON+base64 envelope at 2.86× the audio bytes, and explain `clear` and `mark` | [`06-realtime-systems/01`](../06-realtime-systems/01-transports.md) |
| 84 | Read an SDP audio section and say what was negotiated, including why `opus/48000/2` is not a stereo request | [`06-realtime-systems/02`](../06-realtime-systems/02-webrtc-internals.md) |
| 85 | State that `useinbandfec` defaults to **0** in RFC 7587, and what that costs | [`06-realtime-systems/02`](../06-realtime-systems/02-webrtc-internals.md) |
| 86 | Compute ICE candidate priority from RFC 8445 and show no relay pair can outrank a host pair | [`06-realtime-systems/02`](../06-realtime-systems/02-webrtc-internals.md) |
| 87 | Implement an adaptive jitter buffer and reproduce the frontier: adaptive 97.8% usable at 67.1 ms mean versus a fixed buffer needing 280 ms for 99.0% | [`06-realtime-systems/02`](../06-realtime-systems/02-webrtc-internals.md) |
| 88 | Quote NetEQ's policy — `quantile` 0.95, `forget_factor` 0.983, `ms_per_loss_percent` 20 — and explain that a jitter buffer is a playback-rate controller | [`06-realtime-systems/02`](../06-realtime-systems/02-webrtc-internals.md) |
| 89 | Trace one 20 ms frame from SRTP bytes to `np.int16`, naming what breaks at each stage | [`06-realtime-systems/02`](../06-realtime-systems/02-webrtc-internals.md) |
| 90 | Derive the frame taxonomy (data / control / system / uninterruptible) from the ordering-versus-immediacy tension | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) |
| 91 | Explain why an unbounded queue gives p50 476 ms and max 920 ms where a 2-frame bounded queue is flat at 84 ms | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) |
| 92 | Show that a flag and an in-band FIFO interrupt both leak 1220 ms, a priority path leaks 20 ms, and `Task.cancel()` leaks nothing but loses the cut point | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) |
| 93 | State asyncio cancellation semantics precisely, including why a CPU-bound stage cannot be cancelled | [`06-realtime-systems/03`](../06-realtime-systems/03-pipeline-architecture.md) |
| 94 | Compute audio token rates from codec configs (Mimi 12.5 Hz × 8 = 100 tok/s; Moshi dual-stream 212.5) and the context tax (32k full in 2.6 min) | [`06-realtime-systems/04`](../06-realtime-systems/04-speech-to-speech.md) |
| 95 | Show that full-duplex's win is the *endpointer*: cascaded 1370 ms, half-duplex 814 ms, full-duplex 343 ms — and that S2S + tool call is 1499 ms, worse than cascaded | [`06-realtime-systems/04`](../06-realtime-systems/04-speech-to-speech.md) |
| 96 | Integrate OpenAI Realtime and Gemini Live from their wire protocols, including 16 kHz in / 24 kHz out | [`06-realtime-systems/04`](../06-realtime-systems/04-speech-to-speech.md) |
| 97 | Compute Erlang B for trunks and show the trunking gain: 1 E needs 5 channels at 20%, 500 E needs 527 at 94.9% | [`06-realtime-systems/05`](../06-realtime-systems/05-scale-and-orchestration.md) |
| 98 | Show that safe utilisation is a function of pool size — 25% at 5 workers, 92.5% at 1000 — and that "never above 70%" describes a pool of about fifty | [`06-realtime-systems/05`](../06-realtime-systems/05-scale-and-orchestration.md) |
| 99 | Show that naive GPU packing from the mean gives a 31.85% OOM probability, and that three fewer sessions per GPU buys a 47× reduction | [`06-realtime-systems/05`](../06-realtime-systems/05-scale-and-orchestration.md) |
| 100 | Choose histogram buckets that do not misreport my own SLO — the OTel GenAI recommended boundaries are 17.8% high on a bimodal voice p95 | [`06-realtime-systems/06`](../06-realtime-systems/06-observability.md) |
| 101 | Show that a static threshold cannot detect a 75 ms p95 regression at any setting, and that head sampling is unbiased where tail sampling is 26.7–38.9% wrong | [`06-realtime-systems/06`](../06-realtime-systems/06-observability.md) |
| 102 | Compute call-level reliability as a series system — five stages at 99.5–99.995% give 80.14% clean 20-turn calls — and show hedging two stages lifts it to 94.01% | [`06-realtime-systems/07`](../06-realtime-systems/07-reliability.md) |

## 06-realtime-systems — reliability and deployment (5)

| # | I can… | Chapter |
|---|---|---|
| 103 | Explain why a circuit breaker fed post-retry outcomes never opens, and why a working one raised user failures from 86 to 1152 while cutting provider load 87% | [`06-realtime-systems/07`](../06-realtime-systems/07-reliability.md) |
| 104 | State the never-dead-air invariant, build the four-rung fallback ladder, and show detection latency dominates the LLM-timeout row | [`06-realtime-systems/07`](../06-realtime-systems/07-reliability.md) |
| 105 | Run the six reliability drills and say which real bug each has found | [`06-realtime-systems/07`](../06-realtime-systems/07-reliability.md) |
| 106 | Prove that with central inference, media edges cannot reduce mouth-to-ear latency (triangle inequality) and with sparse edges make it worse — 756 ms versus 730 ms | [`06-realtime-systems/08`](../06-realtime-systems/08-deployment.md) |
| 107 | Size a drain deadline from a session-duration distribution (300 s kills 22.2%; 1200 s kills 0.6%) and show reactive autoscaling cannot answer a surge | [`06-realtime-systems/08`](../06-realtime-systems/08-deployment.md) |

## 07-livekit — the platform (12)

| # | I can… | Chapter |
|---|---|---|
| 108 | Explain rooms, participants and tracks, and trace the signalling and DataChannel paths in the Go SFU | [`07-livekit/01`](../07-livekit/01-architecture.md) |
| 109 | Mint a JWT with the right grants, and know that `VideoGrant.canPublish/canSubscribe/canPublishData` are `*bool` where **absent means granted** | [`07-livekit/01`](../07-livekit/01-architecture.md) |
| 110 | Explain Redis multi-node routing, and egress/ingress, and mark what is Cloud-only | [`07-livekit/01`](../07-livekit/01-architecture.md) |
| 111 | Configure `AgentServer` in 1.7.0 and know `WorkerOptions = ServerOptions` is an alias | [`07-livekit/02`](../07-livekit/02-agents-framework.md) |
| 112 | Quote `worker.py` 1.7.0 from memory: `ASSIGNMENT_TIMEOUT` 7.5, `UPDATE_LOAD_INTERVAL` 0.5, `DRAIN_TIMEOUT` 3600, `load_threshold` 0.7 prod, `num_idle_processes` `min(ceil(cpu_count), 4)` | [`07-livekit/02`](../07-livekit/02-agents-framework.md) |
| 113 | Quote `voice/turn.py` interruption defaults — `min_duration` 0.5, `min_words` 0, `resume_false_interruption` True, `false_interruption_timeout` 2.0 — and say what each changes | [`07-livekit/02`](../07-livekit/02-agents-framework.md) |
| 114 | Explain prewarm and process isolation, and quantify it: idle=0 puts 2.74 s of cold start on every call, idle=2 removes it | [`07-livekit/02`](../07-livekit/02-agents-framework.md) |
| 115 | Implement the `STT`/`TTS`/`LLM`/`VAD` ABCs, including `PREFLIGHT_TRANSCRIPT` and `StreamAdapter(stt=, vad=)` | [`07-livekit/03`](../07-livekit/03-writing-plugins.md) |
| 116 | Write local faster-whisper STT and local Kokoro TTS plugins that work in a real session | [`07-livekit/03`](../07-livekit/03-writing-plugins.md) |
| 117 | Configure `livekit-server`, Redis and TURN for self-hosting, and say why media cannot sit behind an HTTP load balancer | [`07-livekit/04`](../07-livekit/04-self-hosting-and-scale.md) |
| 118 | State the SIP failure modes nobody warns about: in-band DTMF breaking ASR, the 8 kHz WER tax, transfer, AMD | [`07-livekit/05`](../07-livekit/05-telephony-sip.md) |
| 119 | Place a deployment on the crossover ladder — Vapi under ~15.5k min/mo, LiveKit Cloud to ~133k, Cloud with own agents to ~2.04M, then self-hosted | [`07-livekit/06`](../07-livekit/06-alternatives.md) |

## 08-eval-safety — rigour (10)

| # | I can… | Chapter |
|---|---|---|
| 120 | Build a virtual clock and explain why a real-clock timing test reports 16.48 ms where the true bound is 5.00 ms, making the correct assertion fail 100% of the time | [`08-eval-safety/01`](../08-eval-safety/01-testing.md) |
| 121 | Calibrate a CI latency gate from the sampling distribution of its own statistic, and say why p50 detects a 22 ms shift where p95 needs 151 ms | [`08-eval-safety/01`](../08-eval-safety/01-testing.md) |
| 122 | Gate golden audio with a mel-band tolerance, and explain why an inaudible 62 µs shift scores worse on RMS (0.05298) than a real formant regression (0.04586) | [`08-eval-safety/01`](../08-eval-safety/01-testing.md) |
| 123 | Name the case where golden audio cannot work at all, and what replaces it | [`08-eval-safety/01`](../08-eval-safety/01-testing.md) |
| 124 | Correct an LLM judge with Rogan–Gladen, and show a harsh judge understates a true 90% as 72.3% | [`08-eval-safety/02`](../08-eval-safety/02-simulation-and-load.md) |
| 125 | Explain why 90% raw agreement can mean κ = 0.11, and why a weak judge compresses a true 5-point gap to 1.2 points | [`08-eval-safety/02`](../08-eval-safety/02-simulation-and-load.md) |
| 126 | Find the load knee rather than the saturation point — flat to ρ = 0.77, then 3.37× at ρ = 0.80 | [`08-eval-safety/02`](../08-eval-safety/02-simulation-and-load.md) |
| 127 | Size a soak test from the smallest leak it can detect (1 h → 46 KB/session; 24 h → 0.39) and explain why an end-versus-start check is a coin flip at 1 h | [`08-eval-safety/02`](../08-eval-safety/02-simulation-and-load.md) |
| 128 | Place a guardrail so it costs +104 ms and leaks nothing, and show serial costs +986 ms while parallel leaks 830 ms | [`08-eval-safety/03`](../08-eval-safety/03-safety-and-privacy.md) |
| 129 | Detect PII spoken aloud (digits-only 14% recall → spoken-aware 57% → with carrier phrases 86%) and say why the real fix is architectural | [`08-eval-safety/03`](../08-eval-safety/03-safety-and-privacy.md) |

## 09-mastery — synthesis (9)

| # | I can… | Chapter |
|---|---|---|
| 130 | State what AI Act Art. 50(1) and 50(5) require of a voice agent and when it applies (2 August 2026) | [`08-eval-safety/03`](../08-eval-safety/03-safety-and-privacy.md) |
| 131 | Explain why a 2% EER is not an access-control policy — FRR 1% implies FAR 4%, so 25 attempts — and refuse to make voice the authenticator | [`08-eval-safety/03`](../08-eval-safety/03-safety-and-privacy.md) |
| 132 | Allocate a latency budget for a stated target and report the slack, naming the dominant term before designing | [`09-mastery/01`](01-design-interviews.md) |
| 133 | Size pools and trunks from offered load without the naive `ceil(n/0.7)` error, which over-provisions 10 000 E by 39% | [`09-mastery/01`](01-design-interviews.md) |
| 134 | Build a $/1000-call-minute model, decomposed, and know the LLM is 0.63% of it — 3.2× larger without prefix caching | [`09-mastery/01`](01-design-interviews.md) |
| 135 | Answer six staff-level design questions with arithmetic, and identify which requirement is infeasible as stated | [`09-mastery/01`](01-design-interviews.md) |
| 136 | Define every metric in the contract without hesitation: `t_eou`, `stt_final`, `ttft_llm`, `first_clause`, `ttfb_tts`, `ttfa`, `eou_to_ttfa`, `endpoint_f1`, `barge_in_latency` | [`09-mastery/04`](04-glossary.md) |
| 137 | Distinguish the confusions that matter: VAD ≠ endpointing, TTFB ≠ TTFA, jitter ≠ latency, WER ≠ quality | [`09-mastery/04`](04-glossary.md) |
| 138 | Work every exercise in this curriculum and check my reasoning against the answers | [`09-mastery/03`](03-answers.md) |

---

## Using this honestly

**Score cold.** Read the statement, decide, move on. Looking anything up converts a 1 into a
false 3 and wastes the exercise.

**Re-score after each module, not at the end.** The point is to find the gap while you can
still act on it.

**A statement you score 3 on should survive a hostile question.** If you claim you can derive
the CTC forward–backward, someone should be able to ask why the recursion has two cases and
get a clean answer.

**Numbers are part of the claim.** Many statements name a measured figure on purpose. Knowing
that an unbounded queue is bad is a 2; knowing it produced a 476 ms p50 and a 920 ms maximum
against a flat 84 ms, and being able to say why, is a 3. The numbers are what make an
argument in a design review land.

**The lowest scores are the curriculum's fault as much as yours.** If a statement reads as
unfalsifiable, or the chapter it points at does not actually teach it, that is a defect worth
fixing — in the chapter.
