# Mini-projects: one concept, one sitting

This is a list, not a curriculum. The five capstones in
[`../00-setup/05-bootcamp-coverage.md`](../00-setup/05-bootcamp-coverage.md) §12 are
multi-week builds that assemble several modules. These are the opposite: one concept,
30 minutes to 2 hours, runnable the same sitting you read the chapter. Each one takes
an exercise or a `[MEASURED]` claim from its chapter and makes you reproduce, break, or
extend it on your own audio or your own numbers instead of the book's synthetic data.

No starter code here by design — the from-scratch listing in each chapter's §3 is the
starter code. Pick a project, open the chapter, adapt the listing.

---

## `00-setup/`

- **Break the doctor on purpose.** Run the bench-doctor from
  [`01-environment.md`](../00-setup/01-environment.md), then uninstall or rename one
  dependency (ffmpeg, a Python package) and read the failure it produces. Does it name
  the actual missing thing, or does it fail somewhere confusing downstream? *(30 min)*
- **Size your own fleet.** Using the RAM table in
  [`02-hardware-and-cost.md`](../00-setup/02-hardware-and-cost.md), work out whether
  Whisper-medium + Kokoro + a 7B LLM fit concurrently on your machine, then check
  against a real run. *(30 min)*
- **Round-trip and measure the loss.** Record 5 seconds of your own voice, convert
  int16 → float32 → int16, and measure the SQNR against
  [`03-canonical-formats.md`](../00-setup/03-canonical-formats.md)'s derivation. *(1 hr)*

## `01-foundations/`

- **Hear an alias.** Generate a sine sweep that crosses Nyquist at an 8 kHz sample
  rate and listen to the folded frequency; check it against the alias formula in
  [`01-sound-and-sampling.md`](../01-foundations/01-sound-and-sampling.md). *(30 min)*
- **Read your own spectrogram.** Record yourself saying five vowels, plot log-mel
  spectrograms with the code in
  [`02-time-frequency.md`](../01-foundations/02-time-frequency.md), and label the
  formants by eye. *(1 hr)*
- **Starve your own ring buffer.** Implement the lock-free buffer from
  [`03-audio-io-and-buffering.md`](../01-foundations/03-audio-io-and-buffering.md),
  then deliberately slow the reader until an underrun happens and identify it in the
  symptom, not the log line. *(1–2 hr)*
- **Compute your own latency floor.** Ping a real cloud region from your network and
  plug the RTT into the term-by-term budget in
  [`04-latency-budget.md`](../01-foundations/04-latency-budget.md) to get your personal
  mouth-to-ear minimum. *(30 min)*

## `02-asr/`

- **Align three letters by hand.** Take the forward-backward code in
  [`02-ctc-from-scratch.md`](../02-asr/02-ctc-from-scratch.md), align a 3-symbol
  sequence on paper, then confirm the code agrees. *(1 hr)*
- **Make WER move without changing the model.** Transcribe 10 of your own sentences,
  score WER with and without text normalization per
  [`07-evaluation.md`](../02-asr/07-evaluation.md), and see how much of the "error" was
  formatting. *(1 hr)*
- **Bias it toward your own names.** Give faster-whisper a contextual biasing list of
  your product or place names per
  [`06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md) and measure the
  WER delta on names alone. *(1–2 hr)*
- **Diarize a real two-person clip.** Run VAD → embeddings → clustering from
  [`09-diarization-and-speaker-id.md`](../02-asr/09-diarization-and-speaker-id.md) on a
  real recording and find where it merges or splits speakers wrongly. *(1–2 hr)*

## `03-turn-taking/`

- **Find your own SNR knee.** Run the energy/ZCR and 6-band GMM-LLR code from
  [`01-vad.md`](../03-turn-taking/01-vad.md) on a noisy recording of your own and find
  the SNR where the "optimal" threshold moves. *(30 min)*
- **Set your own timeout.** Plug your own guess at cutoff-vs-dead-air costs into the
  decision-theoretic model in
  [`02-endpointing.md`](../03-turn-taking/02-endpointing.md) and find the timeout it
  implies. *(30 min)*
- **Reproduce the zombie-TTS bug.** Break the cancellation ordering in
  [`04-barge-in.md`](../03-turn-taking/04-barge-in.md)'s asyncio pipeline on purpose,
  watch it happen, then fix it. *(1 hr)*
- **Hear AEC do its job.** Play TTS output through a laptop speaker into its own mic
  with and without the NLMS filter from
  [`05-echo-and-aec.md`](../03-turn-taking/05-echo-and-aec.md), and listen to the
  difference. *(1 hr)*

## `04-tts/`

- **Lose the phase, keep the magnitude.** Reconstruct a waveform from magnitude only
  with Griffin-Lim, per
  [`01-tts-architectures.md`](../04-tts/01-tts-architectures.md), and measure the SNR
  loss against the original. *(1 hr)*
- **Walk the RVQ ladder.** Run the from-scratch RVQ code in
  [`02-codec-lm-tts.md`](../04-tts/02-codec-lm-tts.md) at 1, 2, 4 and 8 codebook stages
  and measure reconstruction SNR at each. *(1 hr)*
- **Break the clause aggregator, then fix it.** Feed the aggregator in
  [`03-streaming-tts.md`](../04-tts/03-streaming-tts.md) an adversarial case it isn't
  built to survive (pick one not in the chapter's table) and patch the rule that's
  missing. *(30–60 min)*
- **Extend the verbalizer to a locale it doesn't cover.** Add a new locale to the
  number/currency verbalizer in
  [`04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md) and test it on 20 real
  numbers. *(1–2 hr)*

## `05-llm-layer/`

- **Lint your own system prompt.** Run the speakability detector from
  [`01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md) against a
  real system prompt (yours or a public one) and fix what it flags. *(30 min)*
- **Price your own prefix cache.** Run the cache simulator from
  [`02-context-and-memory.md`](../05-llm-layer/02-context-and-memory.md) with your own
  conversation shape and compute the $ saved. *(30 min)*
- **A/B filler speech.** Implement the filler-during-tool-call pattern from
  [`03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md) and time
  perceived latency with and without it on a genuinely slow API call. *(1 hr)*
- **Find your own prefill/decode crossover.** Measure a local model's prefill vs
  decode time per token per
  [`04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md) and find the
  context length where prefill starts to dominate. *(1 hr)*

## `06-realtime-systems/`

- **Feel head-of-line blocking.** Simulate 2% packet loss over TCP vs UDP for the same
  audio stream per [`01-transports.md`](../06-realtime-systems/01-transports.md) and
  measure the added latency. *(1 hr)*
- **Tune a jitter buffer against a real trace.** Run the fixed vs adaptive jitter
  buffer from [`02-webrtc-internals.md`](../06-realtime-systems/02-webrtc-internals.md)
  against a bursty-loss trace you generate yourself. *(1 hr)*
- **Cut a queue and watch backpressure propagate — or not.** Slow one consumer in the
  frame graph from
  [`03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)
  and see whether the bounded queues actually protect upstream stages. *(1 hr)*
- **Reproduce the breaker that never opens.** Rebuild the circuit-breaker-keyed-on-the-
  wrong-outcome bug from
  [`07-reliability.md`](../06-realtime-systems/07-reliability.md), then fix the outcome
  classification. *(1 hr)*

## `07-livekit/`

- **Hand-roll a token.** Build and verify a LiveKit access token with the from-scratch
  HS256 code in [`01-architecture.md`](../07-livekit/01-architecture.md), no SDK
  involved. *(1 hr)*
- **Wire in a local STT plugin.** Connect the faster-whisper plugin from
  [`03-writing-plugins.md`](../07-livekit/03-writing-plugins.md) to a minimal
  `AgentSession` and talk to it. *(1–2 hr)*
- **Decode real DTMF.** Feed the Goertzel tone detector from
  [`05-telephony-sip.md`](../07-livekit/05-telephony-sip.md) a real touch-tone
  recording and decode the digits. *(30 min)*

## `08-eval-safety/`

- **Reproduce the golden-audio false alarm.** Show, on your own two TTS re-runs, that a
  raw RMS gate scores a benign re-synthesis as more "changed" than the mel-band metric
  in [`01-testing.md`](../08-eval-safety/01-testing.md) does. *(1 hr)*
- **Write one adversarial caller.** Pick one persona from the table in
  [`02-simulation-and-load.md`](../08-eval-safety/02-simulation-and-load.md) and script
  it against your own agent. *(1–2 hr)*
- **Measure your own redaction recall.** Run the PII redaction pass from
  [`03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md) on a
  transcript containing a phone number, a card number, and an address, and report
  recall per field type. *(1 hr)*

---

## Sources

This file is a project list, not a research artefact — it cites no external sources.
Every entry points at a chapter whose own Sources section carries the citations for
the code and claims being exercised.
