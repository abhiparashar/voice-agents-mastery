# Continuation prompt

Paste everything below the line into a new chat to resume.

---

I am continuing work on a voice-AI curriculum at `~/Desktop/voice-agents-mastery/`.
**Read `README.md` and `00-setup/05-bootcamp-coverage.md` first** — README is the
authoritative map and file list, and every chapter must match its description.

## What this is

Book-length **teaching material only** — no projects, no app code, no scaffolding. It takes a
strong software engineer who is new to speech from zero to top-1% mastery, at both model level
and systems level. I ship on **LiveKit** at work, so LiveKit gets a deep source-grounded
module, but every alternative (Pipecat, raw WebSocket, Twilio, native speech-to-speech, Riva,
Amazon Connect) must be taught well enough that I can choose rather than inherit.

## Progress: 39 files, ~172k words. All verified.

| Module | Status |
|---|---|
| `README.md` | done |
| `00-setup/` | 2 of 5 — has `03-canonical-formats.md`, `05-bootcamp-coverage.md` |
| `01-foundations/` | **complete** (5) |
| `02-asr/` | **complete** (9) |
| `03-turn-taking/` | **complete** (5) |
| `04-tts/` | **complete** (5) |
| `05-llm-layer/` | **complete** (5) |
| `06-realtime-systems/` | 1 of 8 — has `01-transports.md` |
| `07-livekit/` | **complete** (6) |
| `08-eval-safety/` | 0 of 3 |
| `09-mastery/` | 0 of 4 |

## Remaining, in this order (15 files)

1. `06-realtime-systems/`: `02-webrtc-internals.md`, `03-pipeline-architecture.md`, `04-speech-to-speech.md`, `05-scale-and-orchestration.md`, `06-observability.md`, `07-reliability.md`, `08-deployment.md`
2. `08-eval-safety/`: `01-testing.md`, `02-simulation-and-load.md`, `03-safety-and-privacy.md`
3. `09-mastery/`: `01-design-interviews.md`, `02-mastery-checklist.md`, `04-glossary.md`, then `03-answers.md` **last** (it answers every chapter's exercises, so it needs them all to exist)
4. `00-setup/`: `01-environment.md`, `02-hardware-and-cost.md`, `04-reading-list.md`, `bootstrap.sh`

Work already done for `06-realtime-systems/02-webrtc-internals.md`: an adaptive-jitter-buffer
plus RTP-parser listing exists at `/tmp/vam/jitter.py` (measured: fixed 20/60/120/250 ms buffers
vs adaptive — adaptive reaches 97.8% usable at 67.1 ms mean delay where a fixed buffer needs
280 ms to reach 99.0%); RFC numbers verified: ICE 8445, STUN 8489, TURN 8656, DTLS-SRTP 5764,
SRTP 3711, SDP 8866, Opus RTP payload 7587, RTCP feedback 4585, RTP 3550.

## Non-negotiable process (this is what made the existing chapters good)

- **Write one file at a time, yourself. Do NOT spawn subagents.** I hit rate limits and 429s
  when 8–16 parallel agents each burned their own context; a 16-agent batch died mid-run and
  lost everything. Sequential single-threaded authoring is required.
- **Measure before writing.** For each chapter, first write a throwaway script in `/tmp`, run
  it, and use the real numbers. Then write the chapter around them.
- **Verify every published listing after writing.** Extract the ```python block from the
  finished markdown, run it, and confirm the output matches the documented block *exactly*.
  I caught several fabricated-number and arithmetic errors this way — including a cost model
  whose conclusion was the opposite of what I had written. If they differ, fix the doc, not
  the memory of it.
- **Verify API facts from primary source** (raw GitHub files, PyPI JSON) before asserting.
  Budget 3–6 targeted fetches per chapter, not exhaustive crawling.

## Chapter format (exact)

H1 title, then a 2–4 line "**What you'll be able to do after this:**" block, then these H2s in
order: `## 1. Intuition`, `## 2. Rigour`, `## 3. From scratch`, `## 4. How production does it`,
`## 5. At scale`, `## 6. Exercises`, `## 7. Interview drill`, `## Sources`.

- 1800–4500 words. Dense; every paragraph carries a fact, derivation, number or decision. No
  filler, no marketing, no emoji, no exclamation marks.
- Tables for tradeoffs. ```mermaid``` only for genuine architecture/state-machine/sequence
  diagrams. LaTeX (`$...$`, `$$...$$`) for maths.
- `## 3. From scratch` = one standalone, runnable, copy-pasteable listing (numpy / PyTorch /
  stdlib only; no shared helper library). Comment only the non-obvious lines, and explicitly
  call out the two or three load-bearing details that are easy to get wrong.
- Exercises: 4–8, numbered `E<module>.<chapter>.<n>` (e.g. `E6.3.1` for
  `06-realtime-systems/03-...`). Falsifiable, answerable from the chapter. Do not write answers.
- Interview drill: a realistic staff-level question with a full model answer in prose (not
  bullets), including what distinguishes a senior answer and what premise to question.
- `## Sources`: papers with authors+year+arXiv id, OSS as `repo path:symbol`, APIs with the
  version checked, and a final line stating which values are `[MEASURED]` and on what.
- Tag claims: `[MEASURED]` = actually run, `[INFERENCE]` = reasoned/unverified,
  `[UNVERIFIED PRICE]` = price I could not confirm. Never invent a number.
- Cross-link with relative paths using README's exact filenames. Mastery module is `09-mastery/`.

## Environment (verified)

Apple M5, 16 GiB, macOS 26.5.2, MPS/MLX, **no CUDA**. `uv` 0.11.19; system python is 3.9.6 so
always run `uv run --python 3.12 ... `. `numpy` 2.5.2, `torch` 2.13.0, `torchaudio` 2.11.0,
`scipy`, `soxr` all available via `--with`. Local-first stack: faster-whisper, silero-vad,
kokoro/piper, ollama/llama.cpp, sounddevice. No paid API keys.

## Contracts used throughout

- Audio: internal **16 kHz mono s16le**, frame **20 ms = 320 samples = 640 bytes**; `bytes` on
  the wire, `np.int16` in transport, `np.float32` in [-1,1) for models (scale 32768). WebRTC
  edge 48 kHz Opus; telephony edge 8 kHz G.711 µ-law. Resample only at edges.
- Metric names, exactly: `speech_start`, `speech_end`, `t_eou`, `stt_final`, `ttft_llm`,
  `first_clause`, `ttfb_tts`, `ttfa`, `eou_to_ttfa`, `wer`, `endpoint_f1`,
  `interruption_rate`, `barge_in_latency`.

## Verified facts already established (reuse, don't re-derive)

- `livekit-agents==1.7.0`, Python `>=3.10,<3.15`. **Read the published wheel, not `main`** —
  `main` is ahead of the release. In 1.7.0 `WorkerOptions = ServerOptions` and
  `WorkerType = ServerType` are aliases; the class is `AgentServer`.
- `worker.py` 1.7.0: `ASSIGNMENT_TIMEOUT = 7.5`, `UPDATE_LOAD_INTERVAL = 0.5`,
  `DRAIN_TIMEOUT = 3600`, load = 5-sample moving average of `cpu_percent(interval=0.5)`,
  `load_threshold` dev `inf` / prod **0.7**, `num_idle_processes` dev 0 / prod
  `min(ceil(cpu_count), 4)`, `job_memory_warn_mb=1000`, `job_memory_limit_mb=0`,
  `shutdown_process_timeout=10.0`, `session_end_timeout=300.0`,
  `initialize_process_timeout=10.0`, `max_retry=16`, `port` dev 0 / prod 8081.
- `voice/turn.py` 1.7.0 defaults (these DO exist — quote them): endpointing
  `{mode:"fixed", min_delay:0.5, max_delay:3.0, alpha:0.9}`, streaming-detector variant
  `{min_delay:0.3, max_delay:2.5}`; interruption `{enabled:True,
  discard_audio_if_uninterruptible:True, min_duration:0.5, min_words:0,
  resume_false_interruption:True, false_interruption_timeout:2.0,
  backchannel_boundary:(1.0,1.0)}`; preemptive `{enabled:True, preemptive_tts:False,
  max_speech_duration:10.0, max_retries:3}`; user_turn_limit both `None`.
  `TurnDetectionMode` auto-selects realtime_llm → vad → stt → manual.
- Also in `agent_session.py`: `DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown","filter_emoji"]`,
  `DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)`,
  `_DEFAULT_AEC_WARMUP_DURATION = 3.0`, `SpeechSteeringOptions{disfluencies,
  nonverbal_sounds, pace}`, `NonverbalOptions{laughing, breathing, sighing, crying,
  vocalizing, mouth_sounds}`, `Instructions(common, audio=, text=)` + `render(modality=)`.
- Plugin ABCs (1.7.0): `STTCapabilities{streaming, interim_results, diarization,
  aligned_transcript, offline_recognize, keyterms, chat_context}`; `SpeechEventType` includes
  **`PREFLIGHT_TRANSCRIPT`**; `RecognizeStream.push_frame/flush/end_input/aclose`;
  `StreamAdapter(stt=, vad=)` makes a batch model streaming with `interim_results=False`;
  `TTSCapabilities{streaming, aligned_transcript}`, `SynthesizedAudio{frame, request_id,
  is_final, segment_id, delta_text}`, `AudioEmitter.initialize(..., frame_size_ms=200)`;
  `VADEvent.frames` = complete utterance on END_OF_SPEECH; `APIConnectOptions(max_retry=3,
  retry_interval=2.0, timeout=10.0)`; `ChatChunk.has_response()`.
- Auth (`livekit/protocol`): HS256, `iss`=API key, `sub`=identity, `defaultValidDuration =
  6h`; `VideoGrant.canPublish/canSubscribe/canPublishData` are `*bool` — **absent means
  granted**; `roomPreset` is Cloud-only; `SIPGrant{admin,call}`;
  `AgentGrant{admin,simulationAdmin,databaseAdmin}`.
- Published prices (retrieved 2026-08-22): LiveKit Cloud Scale $500/mo, agent minutes
  $0.01/min, WebRTC participant minutes $0.0004/min (self-hosted agents count), data
  $0.10/GB, US local inbound $0.01/min, third-party SIP $0.003–0.004/min, Nova-3
  $0.0048/min, Aura-2 $30/M chars, Gemini 2.5 Flash-Lite $0.10/$0.01/$0.40 per M tokens.
  Vapi $0.05/min + $10/line/mo, 14-day history, HIPAA $2k/mo, ZDR $1k/mo. Retell
  $0.07–0.31/min, infra $0.055/min, 20 concurrent.
- `livekit-plugins-turn-detector` is **deprecated**; replacement is
  `livekit.agents.inference.TurnDetector` shipped in `livekit-agents` — a unified **audio**
  end-of-turn detector replacing the old English/Multilingual text models. Needs
  `python -m livekit.agents download-files`; <500 MB RAM; code Apache-2.0 but **weights under
  the LiveKit Model License**.
- Smart Turn v3.2 (`pipecat-ai/smart-turn`): BSD 2-clause, open datasets+training+weights, 23
  languages, audio-native on PCM, 10 ms on some CPUs / <100 ms on most cloud instances, 8 MB
  int8 CPU and 32 MB fp32 GPU builds, runs only during VAD silence.
- Whisper (`openai/whisper`): `SAMPLE_RATE=16000`, `N_FFT=400`, `HOP_LENGTH=160`,
  `CHUNK_LENGTH=30`, `N_SAMPLES=480000`, `N_FRAMES=3000`, `TOKENS_PER_SECOND=50`;
  `temperature=(0.0,0.2,0.4,0.6,0.8,1.0)`, `compression_ratio_threshold=2.4`,
  `logprob_threshold=-1.0`, `no_speech_threshold=0.6`, `condition_on_previous_text=True`;
  timestamp tokens `<|{i*0.02:.2f}|>` for `i in range(1501)`; `stft[..., :-1]` truncation.
  `EnglishTextNormalizer` deletes fillers via `\b(hmm|mm|mhm|mmm|uh|um)\b`.
- Silero VAD: window `512 if sr==16000 else 256`; `threshold=0.5`,
  `min_speech_duration_ms=250`, `min_silence_duration_ms=100`, `speech_pad_ms=30`,
  `max_speech_duration_s=inf`, plus `neg_threshold`.
- `piper-tts` 1.7.0 (VITS/ONNX, espeak-ng, `>=3.9`); `kokoro` 0.9.4 = Kokoro-82M, **82 M
  params, Apache weights**, `<3.13,>=3.10` — this is why the curriculum pins Python 3.12.

## Headline measured results to stay consistent with

Batch vs streaming 3851 ms vs 744 ms (5.2×) · queue p95 141 ms at ρ=0.70 → 675 ms at ρ=0.90 ·
CTC matches PyTorch to 1e-15 · RNN-T matches torchaudio to 3e-7, anti-diagonal identity 1.8e-15 ·
Whisper log-mel reproduced exactly as `(80, 3000)` · VAD best frame-F1 shreds 33 utterances into
265 segments; hangover (not hysteresis) fixes it → F1 0.962 at 34 segments · fixed endpoint
timeout 700 ms → 3.04% cut-off, vs adaptive 2.78% at 330 ms · turn detector at AUC 0.510 is
*worse* than a fixed timeout · barge-in: 14 words generated, 14 synthesised, **5 heard** ·
AEC without double-talk detection attenuates the near-end speaker by −10 dB vs +30.6 dB with it ·
Griffin-Lim spectral convergence 0.66→0.013 while waveform SNR stays −3 dB (true phase: +36.8 dB) ·
RVQ 17.29 dB from 6 small codebooks vs flat VQ ~1.4 dB/bit · local TTS breakeven ~56k audio-min/month
vs local ASR ~1.2M.

New (this session): tiktoken o200k_base — spoken 5.02 chars/token (1.04 tok/word), prose 3.35,
tool JSON 3.99, so the "4 chars/token" heuristic over-counts speech ~25% · GPT-2 on M5 MPS:
prefill ~0.09 ms/token vs decode 6.37 ms/token = **69x**, decode peak throughput at batch 16
(942 tok/s), KV-cache hit saves 85.1% (1024+128) / 94.0% (2048+64) · speculative decoding with
DistilGPT-2 draft: alpha 0.44 at k=2 but c_draft/c_target = 0.56, so predicted AND measured
speedup < 1 (needs r < 0.32) · context policies over 40 items: full history 62 recomputed
tokens/turn vs sliding-window-12 213 (window is 32% smaller context, 3.4x more prefill);
RAG prepended 609 vs appended 184 · tool turn Monte Carlo: filler cuts ttfa p50 1815→551 ms and
changes answer time not at all; speculative read 1539→540; hedging p95 3288→2351 at 1.2 wasted
calls; deadline p99 4956→2961 at 3.1% degraded · persona: chatty vs terse = +324% agent speech,
2x call length, TTS $6.93→$29.40 per 1000 calls · transports: TCP at 5% loss / 200 ms RTT leaves
66.1% of frames usable vs RTP 95.1% and RTP+FEC 99.8%; Twilio JSON+base64 = 2.86x the audio
bytes on the wire (182.8 kbit/s for 64 kbit/s of audio) · LLM serving: static batching ttft p50
489 ms vs continuous 15 ms; chunked prefill only pays on cold cache (tpot p95 41.3→33.7 ms) ·
dispatch: idle=0 puts 2.74 s cold start on every call, idle=2 removes it; thr=0.7 rejects 10%
under surge where thr=inf spends 38 s above load 1.0 · LiveKit crossovers: self-host agents from
~290k call-min/mo, self-host media only from ~3.5M · platform crossovers: Vapi <15.5k, LiveKit
Cloud to 133k, Cloud+own agents to 2.04M, then fully self-hosted; the LLM is **0.6%** of the
model layer ($0.00009 of $0.0157 per call-minute).

Start with `06-realtime-systems/02-webrtc-internals.md`. Work sequentially, verify each listing, and
tell me the file count after each one.
