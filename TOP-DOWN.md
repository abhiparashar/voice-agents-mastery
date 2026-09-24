# Top-Down Path: production code first, theory on demand

`README.md` teaches bottom-up (sound → ASR → turn-taking → TTS → systems), and `PROJECTS.md`
builds bottom-up (drills → components → systems → flagship). Both are correct orders for
*mastery*, and both are wrong for someone who wants to see the whole machine working first.

This file reverses the order. It uses the same chapters and projects, re-sequenced:

1. **Run** a production-grade voice agent end to end on your laptop.
2. **Read** the production source that ran it: one turn, one interruption, one fleet.
3. **Operate** it: real providers, measured latency, dispatch, cold start, drain, traces.
4. **Peel**: replace one production component at a time with your own. Each replacement is a
   project from `PROJECTS.md`, and each one pulls in the chapters that explain it.
5. **Foundations last**: DSP and signal chapters only when a symptom sends you there.

> **The one rule.** Never open a chapter without a question that the code or a log gave you.
> Every row in the code tour below ends in that question and the chapter that answers it.

Everything here runs with **zero API keys** until Stage 3, same as the beginner lab.

---

## Stage 1 — See the whole machine (days 1–3)

| Do | File | Exit test |
|---|---|---|
| Read the mental model | [`07-livekit/00-beginner-lab/01-livekit-in-plain-words.md`](07-livekit/00-beginner-lab/01-livekit-in-plain-words.md) | Draw the four processes and the call trace from memory |
| Run the lab, Steps 1–6 | [`07-livekit/00-beginner-lab/02-run-it-locally.md`](07-livekit/00-beginner-lab/02-run-it-locally.md) | A full `AgentSession` answers you with no vendor account |
| Read the worker log line by line | same file, "Read the worker log line by line" | You can say which log line is dispatch, which is job start, which is a turn |
| Skim the latency picture | [`07-livekit/00-beginner-lab/08-production-and-observability.md`](07-livekit/00-beginner-lab/08-production-and-observability.md) §1 | You can name every term between "user stops" and "user hears" |

Stop here and do not read theory yet. You now have a running system and a log; Stage 2 explains
it from the inside.

---

## Stage 2 — Read the production source (week 1)

The system you just ran is `livekit-agents`, the open-source worker used in production
LiveKit deployments. Read the **published wheel**, not GitHub `main` (it moves weekly):

```bash
mkdir -p ~/src/voice && cd ~/src/voice
uv venv --python 3.12 .venv
uv pip install --python .venv 'livekit-agents==1.8.1' 'pipecat-ai==1.11.0'
cd .venv/lib/python3.12/site-packages     # livekit/agents/ and pipecat/ live here
```

Line numbers below are from exactly those versions, checked on 2026-09-24. `livekit/agents`
is ~70,000 lines; you need about 15 functions of it. Paths are relative to
`site-packages/livekit/agents/`.

### Tour A — One turn, mic to speaker

Follow a single user utterance. Open each location, read ~50 lines, answer the question.

| # | Location | What happens there | Question to hold | Dig deeper |
|---|---|---|---|---|
| A1 | `voice/agent_session.py:879` `AgentSession.start` | Wires room I/O, VAD, STT, LLM, TTS into one session | What does a session own, and what does the job own? | [`07-livekit/02-agents-framework.md`](07-livekit/02-agents-framework.md) |
| A2 | `voice/agent_activity.py:1506` `push_audio` | Every inbound frame lands here; while the agent speaks during AEC warm-up, STT gets **silence** but VAD still gets the real frame | Why feed VAD real audio but STT silence? | [`03-turn-taking/05-echo-and-aec.md`](03-turn-taking/05-echo-and-aec.md) |
| A3 | `voice/audio_recognition.py:239` `AudioRecognition` | Fans audio into VAD and the STT stream; collects interim and final transcripts | Why are interim and final transcripts different events? | [`02-asr/05-streaming-asr.md`](02-asr/05-streaming-asr.md) |
| A4 | `stt/stt.py:359` `RecognizeStream`, `:465` `_main_task` | Provider-agnostic streaming STT with reconnect and retry | What must a streaming STT promise its caller? | [`07-livekit/03-writing-plugins.md`](07-livekit/03-writing-plugins.md), [`02-asr/08-serving-asr.md`](02-asr/08-serving-asr.md) |
| A5 | `voice/audio_recognition.py:1480` `_run_eou_detection`, `:1507` `_bounce_eou_task` | **Endpointing.** Waits `min_delay`; if the turn-detector model says the user is probably not done (`probability < unlikely_threshold`, line 1572), waits `max_delay` instead | Why two delays? What does a wrong choice cost in each direction? | [`03-turn-taking/02-endpointing.md`](03-turn-taking/02-endpointing.md), [`03-turn-taking/03-semantic-turn-detection.md`](03-turn-taking/03-semantic-turn-detection.md) |
| A6 | `voice/agent_activity.py:2474` `on_end_of_turn` | Turn committed; drops turns under `min_words` while the agent is speaking; spawns the reply task | Why is this method deliberately synchronous? (comment at 2475) | [`06-realtime-systems/03-pipeline-architecture.md`](06-realtime-systems/03-pipeline-architecture.md) |
| A7 | `voice/agent_activity.py:2551` `_user_turn_completed_task` | Runs your `on_user_turn_completed` hook (RAG, context edits), then schedules a reply | Where would you inject retrieval so it costs no latency? | [`05-llm-layer/02-context-and-memory.md`](05-llm-layer/02-context-and-memory.md) |
| A8 | `voice/agent_activity.py:3203` `_pipeline_reply_task` | The reply: starts the LLM at `:3338`, starts TTS on the token stream at `:3386`, **before** the LLM finishes | Why start TTS before the LLM is done, and what breaks if you split text badly? | [`04-tts/03-streaming-tts.md`](04-tts/03-streaming-tts.md) |
| A9 | `voice/generation.py:149` `perform_llm_inference`, `:431` `perform_tts_inference` | Token stream in, audio frames out, with tool calls separated from speakable text | Where is `ttft_llm` measured, and where is `ttfb_tts`? | [`01-foundations/04-latency-budget.md`](01-foundations/04-latency-budget.md) |
| A10 | `tts/stream_adapter.py:25` `StreamAdapter` + `tokenize/basic.py:34` `SentenceTokenizer` | Makes a non-streaming TTS streamable by cutting the LLM text into sentences | What does it do with `Dr. Smith` or `3.14`? | [`04-tts/03-streaming-tts.md`](04-tts/03-streaming-tts.md), project **D6** |
| A11 | `voice/generation.py:589` `perform_audio_forwarding` | Pushes TTS frames to the room's audio output | What is the unit of audio here, and who paces it? | [`01-foundations/03-audio-io-and-buffering.md`](01-foundations/03-audio-io-and-buffering.md) |
| A12 | `voice/io.py:227` `AudioOutput.on_playback_finished` | Reports `playback_position`, `interrupted`, `synchronized_transcript` | Why does the framework need to know how much audio the user *actually heard*? | [`03-turn-taking/04-barge-in.md`](03-turn-taking/04-barge-in.md) |
| A13 | `voice/transcription/synchronizer.py:479` `TranscriptSynchronizer` | Releases transcript text in step with audio playback | What goes wrong in the chat history if text runs ahead of audio? | [`03-turn-taking/04-barge-in.md`](03-turn-taking/04-barge-in.md) |
| A14 | `telemetry/traces.py` | The OpenTelemetry span tree for everything above | Which span would you page on? | [`06-realtime-systems/06-observability.md`](06-realtime-systems/06-observability.md) |

### Tour B — The user interrupts

| # | Location | What happens there | Question to hold | Dig deeper |
|---|---|---|---|---|
| B1 | `voice/agent_activity.py:2159` `_interrupt_by_audio_activity` | VAD saw speech while the agent talks. Honours `min_words`; either **pauses** output (false-interruption recovery) or calls `interrupt()` | Why pause first instead of stopping? What is a false interruption? | [`03-turn-taking/04-barge-in.md`](03-turn-taking/04-barge-in.md) |
| B2 | `voice/agent_activity.py:1742` `interrupt` | Cancels current and queued speech, except speech marked non-interruptible | Which utterances should be uninterruptible, and why is that a product decision? | [`05-llm-layer/05-persona-design.md`](05-llm-layer/05-persona-design.md) |
| B3 | `voice/agent_activity.py:1857` `_scheduling_task` | A priority queue of `SpeechHandle`s; only one plays at a time | Why is agent speech a queue and not a function call? | [`06-realtime-systems/03-pipeline-architecture.md`](06-realtime-systems/03-pipeline-architecture.md) |
| B4 | `voice/agent_activity.py:3470` `wait_if_not_interrupted` | Every await in the reply races the interruption | What leaks if one await forgets to race? (the "zombie TTS" bug) | project **C5** |

### Tour C — The fleet: how this runs at scale

This is the part that is "at scale": thousands of calls are just many copies of Tour A, placed
by a scheduler.

| # | Location | What happens there | Question to hold | Dig deeper |
|---|---|---|---|---|
| C1 | `worker.py:297` `AgentServer`, `:536` `run` | One worker process registers with the LiveKit server over a WebSocket and waits for jobs | Who decides which worker gets a call? | [`07-livekit/01-architecture.md`](07-livekit/01-architecture.md) |
| C2 | `worker.py:1351` `_answer_availability` | The server offers a job; the worker accepts or rejects (your `request_fnc`) | What should make a worker refuse a call? | [`07-livekit/02-agents-framework.md`](07-livekit/02-agents-framework.md) |
| C3 | `worker.py:1491` `_update_worker_status` | Reports load; marks itself `WS_FULL` when `effective_load >= load_threshold` or while draining | Why 0.7 and not 1.0? What happens to p95 near 100%? | [`06-realtime-systems/05-scale-and-orchestration.md`](06-realtime-systems/05-scale-and-orchestration.md), project **D8** |
| C4 | `ipc/proc_pool.py:280` `ProcPool._main_task` | Keeps N **pre-warmed** processes; one call = one process | What does a cold start cost the caller, and what does a warm process cost you? | beginner lab **L6** |
| C5 | `worker.py:930` `drain` | On deploy: stop accepting, let live calls finish | How do you ship code without hanging up on anyone? | [`06-realtime-systems/08-deployment.md`](06-realtime-systems/08-deployment.md), beginner lab **L7** |
| C6 | `job.py:581` `add_shutdown_callback` | Post-call work that survives the caller hanging up | Why not put post-call code after `session.start()`? | beginner lab **L7** |
| C7 | `tts/fallback_adapter.py:53` `FallbackAdapter`, `types.py:124` `APIConnectOptions` | Provider failover and retry budgets | Default is 3 retries — is that sane inside a live call? | [`06-realtime-systems/07-reliability.md`](06-realtime-systems/07-reliability.md) |

The media side of scale (SFU nodes, Redis, TURN, regions) is not in this Python package; it is
the `livekit-server` process you started in Stage 1. Read
[`07-livekit/04-self-hosting-and-scale.md`](07-livekit/04-self-hosting-and-scale.md) once Tour C
makes sense.

### Tour D — The same problem, a different architecture (Pipecat)

Reading a second framework shows which parts are design choices and which are forced by the
problem. Pipecat models the agent as a **graph of frame processors**. Paths are relative to
`site-packages/pipecat/`.

| # | Location | What it shows | Compare with |
|---|---|---|---|
| D1 | `frames/frames.py:105` `SystemFrame`, `:116` `DataFrame`, `:128` `ControlFrame` | Three frame classes. System frames skip the queue and survive interruptions; data and control frames are cancelled by them | LiveKit's `SpeechHandle` queue (B3) |
| D2 | `frames/frames.py:1204` `InterruptionFrame` | Barge-in is a frame that flows through the graph | LiveKit's `interrupt()` method call (B2) |
| D3 | `processors/frame_processor.py:195` `FrameProcessor`, routing at `:1304`–`:1307` | Two queues per processor: system frames processed immediately, everything else queued | Why does interruption need a priority lane? |
| D4 | `processors/frame_processor.py:1130` `_start_interruption` | Interruption = cancel the processing task and drop the queued frames | LiveKit's `wait_if_not_interrupted` (B4) |
| D5 | `pipeline/pipeline.py:91` `Pipeline`, `pipeline/worker.py:207` `PipelineWorker` | Linear chain plus its runner (`PipelineTask` is a deprecated alias) | `AgentSession` (A1) |
| D6 | `transports/base_input.py:36`, `transports/base_output.py:60` | VAD and output pacing live in the transport | LiveKit's `AudioRecognition` (A3) and `AudioOutput` (A12) |
| D7 | `turns/user_turn_controller.py:36` `UserTurnController` | Turn start/stop strategies | `_bounce_eou_task` (A5) |
| D8 | `processors/aggregators/sentence.py:24` `SentenceAggregator` | LLM text to sentences | `SentenceTokenizer` (A10) |

Dig deeper: [`06-realtime-systems/03-pipeline-architecture.md`](06-realtime-systems/03-pipeline-architecture.md)
and [`07-livekit/06-alternatives.md`](07-livekit/06-alternatives.md).

**Stage 2 exit test.** Without the tables, draw one turn from mic frame to speaker frame and
name the function at each arrow. Then explain how a barge-in cancels it in both frameworks.

---

## Stage 3 — Operate it (weeks 2–3)

Now make the system real and measure it. All projects are in
[`07-livekit/00-beginner-lab/03-small-projects.md`](07-livekit/00-beginner-lab/03-small-projects.md)
and [`08-production-and-observability.md`](07-livekit/00-beginner-lab/08-production-and-observability.md).

| Order | Do | Code from Stage 2 it exercises |
|---|---|---|
| 1 | **L3** two provider stacks, p50/p95 per layer from `metrics_collected` | A4, A8–A9, C7 |
| 2 | Wire traces (08 §3.2) and find your slowest span | A14 |
| 3 | **L5** dispatch lab | C1–C2 |
| 4 | **L6** cold-start measurement | C4 |
| 5 | **L7** drain drill | C5–C6 |
| 6 | **L4** transcript sidecar | A12–A13 |
| 7 | Large project **M3**: tune endpointing on your own recorded calls | A5, B1 |

Then read [`07-livekit/04-self-hosting-and-scale.md`](07-livekit/04-self-hosting-and-scale.md)
and do the large project's **M4** (self-host for real) and **M7** (deploy without dropping calls)
from [`04-large-project.md`](07-livekit/00-beginner-lab/04-large-project.md). This is where
"at scale" becomes something you have run instead of something you read.

---

## Stage 4 — Peel: replace production parts with your own (week 4 onward)

This is where the theory comes in. Pick a component you just used as a black box, replace it with
your own implementation behind the same interface, and measure against the original. The
replacement forces the chapter; the original gives you a baseline to beat.

Order follows what hurts in Stage 3, not the chapter order.

| Replace (from the tour) | With your own | Project | Chapters it forces |
|---|---|---|---|
| Sentence cutting (A10) | Clause aggregator with an adversarial suite | **D6** | `04-tts/03-streaming-tts.md` |
| Endpointing policy (A5) | VAD timer + semantic detector, calibrated | **C2** | `03-turn-taking/01`–`03` |
| Barge-in logic (B1–B4) | Deterministic interrupt harness | **C5** | `03-turn-taking/04-barge-in.md`, `08-eval-safety/01-testing.md` |
| Silero VAD | Three VADs on labelled audio | **D3** | `03-turn-taking/01-vad.md` |
| STT plugin (A4) | Local streaming ASR service | **C1**, then **C4** | `02-asr/04`, `05`, `08`; `07-livekit/03-writing-plugins.md` |
| TTS plugin (A9) | Local TTS gateway | **C3**, then **C4** | `04-tts/01`, `03`, `05` |
| Built-in tracing (A14) | Your own metric library | **C6** | `06-realtime-systems/06-observability.md` |
| Load reporting (C3) | Load generator to the knee | **S3** (+ **D8**) | `06-realtime-systems/05`, `01-foundations/04` |
| Failover (C7) | Fault-injection drills | **S4** | `06-realtime-systems/07-reliability.md` |
| The whole pipeline | Frame-graph runtime + conformance suite | **F2** | `06-realtime-systems/03`, `07-livekit/06` |

Each row is fully specified, with acceptance criteria, in [`PROJECTS.md`](PROJECTS.md). Build it
to that spec; the showcase bar in `PROJECTS.md` §0 still applies.

When a replacement works, go one level lower **only if the component needs it**. Examples:
C1 misrecognises names, so do **C7** and read `02-asr/06`. You want to know why Whisper
hallucinates on silence, so do **D5** and read `02-asr/04`. You want to understand CTC because
your streaming ASR emits peaky timestamps, so do **D4** and read `02-asr/01`–`03`.

---

## Stage 5 — Foundations, pulled in by symptoms

Do not start here. Come here when one of these happens:

| Symptom you hit | Drill | Chapter |
|---|---|---|
| Choppy or robotic audio; frame-size assertion fires | **D1** frame clock | `01-foundations/03-audio-io-and-buffering.md`, `00-setup/03-canonical-formats.md` |
| Resampling artefacts; "what is 16 kHz actually buying me?" | **D2** mel spectrogram | `01-foundations/01`, `02` |
| Agent hears itself | **D7** NLMS echo canceller | `03-turn-taking/05-echo-and-aec.md` |
| Fine on wifi, terrible on a train | **D10** jitter buffer | `06-realtime-systems/02-webrtc-internals.md` |
| TTS reads "₹1,20,000" wrongly | **D11** verbaliser | `04-tts/04-prosody-and-voice.md` |
| Curious what a vocoder does | **D9** | `04-tts/01`, `02` |
| Phone calls sound worse than web | **S6** telephony | `07-livekit/05-telephony-sip.md` |

---

## A calendar, if you want one

| Week | Stage | Outcome |
|---|---|---|
| 1 | 1 + Tours A–B | Keyless agent running; one turn traced through the source |
| 2 | Tours C–D + L3, traces | Fleet mechanics understood; first real latency table |
| 3 | L4–L7, M3 | Dispatch, cold start, drain, endpointing tuned on real calls |
| 4 | M4, M7 + `07-livekit/04` | Self-hosted cluster; deploy without dropping calls |
| 5–6 | D6, C2 | First two replacements, each measured against the production default |
| 7–8 | C5, C6 | Interrupt correctness and your own observability |
| 9+ | C1/C3 → C4, S3, S4, then F2 | Local providers plugged in, load and chaos, then your own runtime |

At any point, [`09-mastery/02-mastery-checklist.md`](09-mastery/02-mastery-checklist.md) shows
what you can already defend and [`09-mastery/01-design-interviews.md`](09-mastery/01-design-interviews.md)
tests whether you can explain it.
