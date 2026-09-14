# Status: complete

The curriculum described in `README.md` is finished. All **57 files** in the README manifest
exist — 55 chapters, one mini-projects list, plus `00-setup/bootstrap.sh` — totalling roughly
**271,000 words**, with **377 exercises** and a worked answer for every one.

There is no remaining work queued. This file is now a record of what was built and how, for
whoever picks it up next.

---

## What exists

| Module | Files | State |
|---|---|---|
| `README.md` | 1 | authoritative map; chapter count and answer count verified against the tree |
| `00-setup/` | 5 + `bootstrap.sh` | complete |
| `01-foundations/` | 5 | complete |
| `02-asr/` | 9 | complete |
| `03-turn-taking/` | 5 | complete |
| `04-tts/` | 5 | complete |
| `05-llm-layer/` | 5 | complete |
| `06-realtime-systems/` | 8 | complete |
| `07-livekit/` | 6 | complete |
| `08-eval-safety/` | 3 | complete |
| `09-mastery/` | 5 | complete |

Verified mechanically at the end of the final session: every file in the README manifest
exists; **zero broken relative links** across all 58 markdown files; every `## 3. From scratch`
listing runs; and the 377 exercise IDs in the chapters match the 377 answer IDs in
`09-mastery/03-answers.md` exactly, with no gaps and no orphans.

---

## The process that produced it

Worth preserving, because it is what made the material trustworthy.

- **One file at a time, written directly, no subagents.** Parallel authoring lost work and hit
  rate limits; sequential single-threaded writing did not.
- **Measure before writing.** Each chapter began as a throwaway script in `/tmp/vam`, run to
  produce real numbers, and the prose was written around those numbers rather than the reverse.
- **Verify every published listing after writing.** Extract the ```python block from the
  finished markdown, run it, diff against the documented output. This caught real errors,
  including a misaligned output column and two wrong conclusions.
- **Verify API and spec facts from primary source** — raw GitHub files, PyPI JSON, RFC text,
  the arXiv API — before asserting them.

### Four corrections the process forced

These are recorded because each was a plausible, widely-repeated claim that measurement
falsified. They are listed in `09-mastery/03-answers.md` too.

1. **"Terminate media at the edge, run models centrally" is wrong.** With central inference the
   media edge lies on the geodesic to the model region, so by the triangle inequality it cannot
   reduce mouth-to-ear latency, and with sparse edges it *increases* it — 756 ms mean against
   730 ms for a single central region. This had been asserted in two earlier chapters
   (`06-realtime-systems/02` §5 and `06-realtime-systems/05` §5) before being measured in
   `06-realtime-systems/08`; both were corrected.
2. **Golden audio cannot be gated on a waveform or per-bin spectral metric.** The first version
   of that measurement ranked a benign TTS re-run as *more* changed than a real formant
   regression. The mel-band formulation replaced it, and an inaudible 62 µs shift is now shown
   scoring worse on RMS (0.05298) than a genuine 2% formant shift (0.04586).
3. **Python 3.12 is pinned because of `audioop`, not kokoro.** Kokoro 0.9.4 declares
   `Requires-Python: <3.13`, and `uv run --with` installs and imports it on 3.13.13 anyway — the
   declared bound does not protect you. What actually breaks is `audioop`, removed in 3.13 under
   PEP 594.
4. **`sounddevice` bundles PortAudio.** Verified `PortAudio V19.7.0-devel` from the wheel, so
   `brew install portaudio` is unnecessary despite near-universal advice to the contrary.

### One deliberate deviation from the original spec

Five files are reference artefacts rather than chapters and do not carry the seven-part
format: `00-setup/05-bootcamp-coverage.md` (a syllabus mapping table, pre-existing),
`00-setup/04-reading-list.md` (books, 40 papers, 15 repositories),
`09-mastery/02-mastery-checklist.md` (138 scored capability statements),
`09-mastery/04-glossary.md` (237 terms), and `09-mastery/05-mini-projects.md` (added
2026-09-13: 33 single-concept, 30 min–2 hr projects mapped to specific chapters, distinct
from the five multi-week capstones in `00-setup/05-bootcamp-coverage.md` §12).
`09-mastery/03-answers.md` is likewise exempt from the
1800–4500 word guidance, since it answers 377 exercises. Several chapters also run above 4500
words; density was preferred over the cap where the extra words were verified facts, tables or
source citations.

---

## Environment the measurements were taken on

Apple M5, 10 cores (4P + 6E), 16 GiB unified memory, macOS 26.5.2 (build 25F84), `arm64`,
MPS available and **no CUDA**. `uv` 0.11.19; system Python is 3.9.6 so every listing runs under
`uv run --python 3.12 ...`. CPython 3.12.13, `numpy` 2.5.2, `torch` 2.13.0, `torchaudio` 2.11.0,
`scipy` 1.18.1, `soxr` 1.1.0, PortAudio V19.7.0-devel via `sounddevice` 0.5.6. No paid API keys
were used for any measurement.

Reproduce the bench with `00-setup/bootstrap.sh`, which extracts the doctor script from
`00-setup/01-environment.md` so there is exactly one copy of it.

---

## If you extend it

- **Keep the contracts.** Audio is 16 kHz mono s16le, 20 ms = 320 samples = 640 bytes; metric
  names are fixed (`t_eou`, `stt_final`, `ttft_llm`, `first_clause`, `ttfb_tts`, `ttfa`,
  `eou_to_ttfa`, `wer`, `endpoint_f1`, `interruption_rate`, `barge_in_latency`). Both are
  asserted by the doctor and used by every chapter.
- **Exercise IDs are `E<module>.<chapter>.<n>`.** Two chapters violated this and were
  normalised (`00-setup/03` used `E0.n`, `02-asr/02` had trailing periods). Any new exercise
  needs an answer in `09-mastery/03-answers.md`; the one-to-one check is a three-line script and
  worth keeping in CI.
- **Prices are stamped.** Everything published was retrieved 2026-08-22 and is marked
  `[UNVERIFIED PRICE]` where it could not be re-confirmed. Re-date them before quoting.
- **Version-pinned facts will drift.** `livekit-agents` 1.7.0, `pipecat-ai` 1.7.0,
  `moshi` 0.2.13 and the OTel GenAI conventions (which moved repositories mid-project and are
  still marked Development) are the most likely to move. Read the published wheel, never `main`.

---

## Addendum, 2026-09-14: `07-livekit/00-beginner-lab/`

Nine files added as an on-ramp for a beginner shipping on LiveKit — mental model, a local lab,
eight small projects, one large project, a debug playbook. Registered in the `README.md`
`07-livekit/` table and explicitly **not** chapters: no eight-section format, no exercises, so
the 55-chapter / 377-exercise invariants are untouched.

Everything in it was run rather than recalled, on `livekit-server` **1.13.7** (Homebrew),
`lk` **2.18.6**, `livekit-agents` **1.8.1**, `livekit` (Python realtime SDK) **1.1.18**,
CPython 3.12.13, and **no API keys**. Scratch work in `/tmp/vam/lk`.

Five facts the run established that the 1.7.0-era chapters do not have:

1. **`AgentSession` now defaults to a local Silero VAD** (`inference.VAD(model="silero")` via
   `livekit-local-inference`), 32 inferences/s at ~4.4 ms CPU per second of audio.
2. **Adaptive interruption is on by default in dev mode and calls LiveKit Cloud**
   (`wss://agent-gateway.livekit.cloud/v1/bargein`). Against a self-hosted server it 401s three
   times over ~4.5 s, then falls back to VAD. `turn_handling={"interruption": {"mode": "vad"}}`
   suppresses it.
3. **`conversation_item_added` can carry an `AgentHandoff`**, so `ev.item.role` raises
   `AttributeError`. Every published handler needs an `isinstance(ev.item, ChatMessage)` guard.
4. **`AudioStream`'s default frame size is 10 ms**, not 20: `sample_rate=16000` alone yields 160
   samples / 320 bytes; `frame_size_ms=20` yields the curriculum's 320 samples / 640 bytes.
   `AudioFrame.data` is already an int16 `memoryview` — re-casting it raises `TypeError`.
5. **A token grant for another room joins that room.** `room.connect()` takes no room name, so a
   token endpoint that trusts a client-supplied room name is an authorisation bug; reproduced in
   11 ms.

A full `AgentSession` — streaming STT, streaming LLM, chunked TTS, turn-taking, metrics — can be
run with **zero vendor accounts** by implementing the three ABCs as ~150 lines of energy
detector, echo and beep generator. That listing is in `02-run-it-locally.md` §6 and is the
recommended first exercise for anyone who has never seen the framework.

### Second pass, same day: `06-your-stack-india.md`

Written for a self-hosted deployment with Azure Speech + Gemini and Indian data residency.
Region availability was parsed out of the vendors' own published tables rather than recalled
(the Google table marks availability with `aria-label="Supported"` on empty `<td>`s, so a plain
text scrape reads as blank — parse the HTML attributes):

- **`gemini-2.5-flash` is available in Mumbai `asia-south1`**; `gemini-2.5-pro` is **not** (Tokyo
  is the only Asian region for it), and Google's own Chirp STT/TTS reach only `asia-southeast1`.
- **Azure Speech supports `centralindia`** and explicitly **does not support `southindia`** for
  speech processing. So Azure-for-speech + Vertex-for-brain is the correct India pairing, not a
  compromise.
- The LiveKit Google plugin **defaults to `us-central1`** when `location` is unset — a silent
  residency violation with no error. Flagged as the stack's headline trap.
- `livekit-plugins-sarvam` **1.8.1** exists (Saaras STT, Bulbul TTS, India-hosted inference) and
  is the recommended second STT/TTS for Indic and code-mixed audio.

Verified by running: all three providers construct offline with dummy credentials
(`azure.STT` streaming + interim, `azure.TTS` **non-streaming**, `google.LLM` with
`vertexai=True, location="asia-south1"`); a hand-written `livekit.yaml` with keys from
`livekit-server generate-keys` booted, carried a call, and exposed 270 `livekit_*` metrics on
`prometheus_port`; and the published agent listing registered, was dispatched and started a
session against that server. Wrong-credential failure modes were produced deliberately and are
quoted verbatim in §8 — Azure STT `CancellationErrorCode.AuthenticationFailure` looping through
"STT stream ended on an unrecoverable error, recreating", Azure TTS
`APIStatusError('Unauthorized', 401, retryable=False)`, and 1.8.1's Cloud **turn detector** also
401ing and falling back to a local mini model on self-hosted keys.

### Third pass, same day: `07-provider-landscape.md`, `08-production-and-observability.md`

The landscape file is spined on fact rather than memory: the **75 provider directories** in
`livekit/agents` `main` (GitHub contents API, retrieved 2026-09-14) are quoted verbatim, and
everything about quality/price is marked `[INFERENCE]`. Region facts reused from the same parsed
vendor tables; notably `gemini-live-2.5-flash-native-audio` has **no Asian region** at all, and
Microsoft's own docs say the Azure **voice live** API uses Sweden Central for generative-AI load
balancing — so neither major S2S option is India-resident today, which is why the India stack is
necessarily cascaded.

The observability file rests on a measurement worth keeping: **`livekit-agents` 1.8.1 is fully
OpenTelemetry-instrumented** (`telemetry/traces.py` imports the OTLP HTTP exporters for traces,
logs *and* metrics; LiveKit Cloud is just another OTLP sink at
`…/observability/{traces,logs,metrics}/otlp/v0`). A 35-line `http.server` OTLP receiver was run
against a real call and captured the span tree verbatim `[MEASURED]`:
`agent_session` (`gen_ai.operation.name=invoke_workflow`) → `start_agent_activity`
(`create_agent`) → `on_enter` → `agent_turn` (`invoke_agent`) → `user_turn` → `llm_request`
(`chat`, with `gen_ai.usage.*`, `gen_ai.response.finish_reasons`,
`gen_ai.response.time_to_first_chunk`) → `llm_node` (`lk.response.ttft`) →
`tts_request`/`tts_stream_adapter`/`tts_node` (`lk.response.ttfb`) → `on_exit` →
`drain_agent_activity`. Both published listings (the receiver and the 15-line `setup_tracing()`)
were then run verbatim together and reproduced it.

**`set_tracer_provider(..., allow_pii=False)` was verified to strip content in-process**:
`gen_ai.system_instructions`, `gen_ai.input.messages` and `gen_ai.output.messages` disappear
while timings, model names, token counts and finish reasons remain. That is the switch to
recommend by default, since Langfuse (self-hostable, OTLP HTTP at `/api/public/otel`, Basic auth
from base64 `pk:sk`) otherwise receives the whole transcript.
