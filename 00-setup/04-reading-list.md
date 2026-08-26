# Reading list

Books worth owning, 40 papers in the order they make sense, and 15 repositories to read as
literature — with the specific files, because "read the source" is useless advice without a
path.

Every arXiv identifier here was resolved against the arXiv API on 2026-08-26 and the titles
below are the ones arXiv returns. If a title looks unfamiliar, that is because the paper is
better known by its model's name.

---

## 1. Books

Eight books cover this field. You do not need all of them, and you should not read any of
them cover to cover.

| Book | Read for | How much |
|---|---|---|
| **Jurafsky & Martin**, *Speech and Language Processing* (3rd ed. draft, free online) | The single best reference for ASR, language modelling and dialogue. Chapters on HMMs, WFSTs and dialogue systems | Chapters as needed; the free draft is the current one |
| **Rabiner & Juang**, *Fundamentals of Speech Recognition* (1993) | Why classical ASR was built the way it was. HMMs, Viterbi, and the vocabulary everyone still uses | Chapters 2, 6, 8. Dated and clarifying |
| **Taylor**, *Text-to-Speech Synthesis* (2009) | The only rigorous book on TTS as a whole system: text analysis, prosody, unit selection | Chapters 1–5 and 7. Pre-neural and still the best on the front end |
| **Oppenheim & Schafer**, *Discrete-Time Signal Processing* | The reference for sampling, the DFT, filters and multirate processing. When you need to be certain | Chapters 2–4, 7, 10. A reference, not a read |
| **Smith**, *The Scientist and Engineer's Guide to DSP* (free online) | The same material with intuition first. Read this *before* Oppenheim | Chapters 8–12 for the DFT and convolution |
| **Kleppmann**, *Designing Data-Intensive Applications* | Distributed systems reasoning: replication, consistency, stream processing. The systems half of this curriculum assumes it | Chapters 1, 5, 8, 9, 11 |
| **Nygard**, *Release It!* (2nd ed.) | Stability patterns and antipatterns — circuit breakers, bulkheads, cascading failure. Directly behind [`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md) | Part I in full. Short and load-bearing |
| **Beyer et al.**, *Site Reliability Engineering* (free online) | SLIs, SLOs, error budgets, alerting on symptoms | Chapters 3–6. Skip the Google-specific parts |

If you buy two: **Jurafsky & Martin** for the models and **Nygard** for the systems. If you
buy one: Jurafsky & Martin, and read Nygard's Part I from a library.

---

## 2. Forty papers, in reading order

Ordered so that each paper's prerequisites come before it. Read the abstract, the figures and
the numbers; read the method section only when you intend to implement it.

### Foundations of end-to-end speech (1–6)

| # | Paper | Why |
|---|---|---|
| 1 | Graves, Fernández, Gomez & Schmidhuber, "Connectionist Temporal Classification", ICML 2006 | The loss that made end-to-end ASR possible. Not on arXiv; the ICML paper is the source. Derived in [`../02-asr/02-ctc-from-scratch.md`](../02-asr/02-ctc-from-scratch.md) |
| 2 | Graves, "Sequence Transduction with Recurrent Neural Networks", arXiv:1211.3711 (2012) | RNN-T. The streaming-native alternative to CTC |
| 3 | Chan, Jaitly, Le & Vinyals, "Listen, Attend and Spell", arXiv:1508.01211 (2015) | The first credible attention-based ASR; the ancestor of Whisper |
| 4 | Vaswani et al., "Attention Is All You Need", arXiv:1706.03762 (2017) | You cannot skip it and you have probably read it |
| 5 | Park et al., "SpecAugment", arXiv:1904.08779 (2019) | The augmentation that made large-scale ASR training work. One idea, huge effect |
| 6 | Baevski, Zhou, Mohamed & Auli, "wav2vec 2.0", arXiv:2006.11477 (2020) | Self-supervised speech representation; the reason labelled data stopped being the bottleneck |

### Modern ASR (7–14)

| # | Paper | Why |
|---|---|---|
| 7 | Hsu et al., "HuBERT", arXiv:2106.07447 (2021) | The other self-supervised lineage, and the source of "semantic tokens" |
| 8 | Gulati et al., "Conformer", arXiv:2005.08100 (2020) | The encoder architecture almost everything streaming uses |
| 9 | Shi et al., "Emformer", arXiv:2010.10759 (2020) | Streaming with bounded memory; how lookahead becomes a knob |
| 10 | Yao et al., "Zipformer", arXiv:2310.11230 (2023) | The current efficient streaming encoder; read alongside icefall |
| 11 | Rekesh et al., "Fast Conformer with Linearly Scalable Attention", arXiv:2305.05084 (2023) | NVIDIA's efficiency line; what Parakeet is built on |
| 12 | Kuang et al., "Pruned RNN-T for fast, memory-efficient ASR training", arXiv:2206.13236 (2022) | The practical fix for RNN-T's memory blow-up |
| 13 | Radford et al., "Robust Speech Recognition via Large-Scale Weak Supervision", arXiv:2212.04356 (2022) | Whisper. Read it as a paper about *data*, then read its decoding heuristics as bug workarounds |
| 14 | Gandhi, von Platen & Rush, "Distil-Whisper", arXiv:2311.00430 (2023) | Distillation done properly, and the model you will actually deploy |

### Alignment, diarization, evaluation (15–18)

| # | Paper | Why |
|---|---|---|
| 15 | Bain, Huh, Han & Zisserman, "WhisperX", arXiv:2303.00747 (2023) | Accurate word timestamps from an inaccurate-timestamp model |
| 16 | Desplanques, Thienpondt & Demuynck, "ECAPA-TDNN", arXiv:2005.07143 (2020) | The speaker embedding everyone uses |
| 17 | Bredin & Laurent, "End-to-end speaker segmentation for overlap-aware resegmentation", arXiv:2104.04045 (2021) | pyannote's segmentation; overlapped speech is the hard part |
| 18 | Snyder, Garcia-Romero, Sell, Povey & Khudanpur, "X-vectors", ICASSP 2018 | The predecessor worth knowing for context. Not on arXiv |

### TTS, in lineage order (19–27)

| # | Paper | Why |
|---|---|---|
| 19 | van den Oord et al., "WaveNet", arXiv:1609.03499 (2016) | The paper that ended concatenative synthesis |
| 20 | Wang et al., "Tacotron: Towards End-to-End Speech Synthesis", arXiv:1703.10135 (2017) | Sequence-to-sequence TTS, and its attention failure modes |
| 21 | Shen et al., "Natural TTS Synthesis by Conditioning WaveNet on Mel Spectrogram Predictions", arXiv:1712.05884 (2017) | Tacotron 2. The mel-spectrogram-plus-vocoder split that defined a decade |
| 22 | Ren et al., "FastSpeech", arXiv:1905.09263 (2019) | Non-autoregressive TTS; why attention failures stopped mattering |
| 23 | Ren et al., "FastSpeech 2", arXiv:2006.04558 (2020) | Explicit duration, pitch and energy — the controllability story |
| 24 | Kong, Kim & Bae, "HiFi-GAN", arXiv:2010.05646 (2020) | The vocoder that made real-time neural TTS practical |
| 25 | Kim, Kong & Son, "Conditional Variational Autoencoder with Adversarial Learning for End-to-End Text-to-Speech", arXiv:2106.06103 (2021) | VITS. What Piper is |
| 26 | Le et al., "Voicebox", arXiv:2306.15687 (2023) | Flow-matching TTS; the current quality frontier |
| 27 | Chen et al., "F5-TTS", arXiv:2410.06885 (2024) | Flow matching made simple and reproducible |

### Neural codecs and audio LMs (28–33)

| # | Paper | Why |
|---|---|---|
| 28 | Zeghidour, Luebs, Omran, Skoglund & Tagliasacchi, "SoundStream", arXiv:2107.03312 (2021) | RVQ neural codecs. Read this before any audio LM paper |
| 29 | Défossez, Copet, Synnaeve & Adi, "High Fidelity Neural Audio Compression", arXiv:2210.13438 (2022) | EnCodec. The codec most tooling defaults to, and 6× Mimi's token rate |
| 30 | Borsos et al., "AudioLM", arXiv:2209.03143 (2022) | Semantic versus acoustic tokens — the distinction the whole field rests on |
| 31 | Zhang et al., "SpeechTokenizer", arXiv:2308.16692 (2023) | Unifying the two token types by distillation; the trick Mimi uses |
| 32 | Wang et al., "Neural Codec Language Models are Zero-Shot Text to Speech Synthesizers", arXiv:2301.02111 (2023) | VALL-E. Zero-shot cloning, and the moment the ethics conversation became urgent |
| 33 | Défossez et al., "Moshi: a speech-text foundation model for real-time dialogue", arXiv:2410.00037 (2024) | The only open full-duplex system. Read it with the repo open |

### Serving and systems (34–40)

| # | Paper | Why |
|---|---|---|
| 34 | Dao, Fu, Ermon, Rudra & Ré, "FlashAttention", arXiv:2205.14135 (2022) | IO-awareness as the dominant consideration. Changes how you read every later serving paper |
| 35 | Kwon et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention", arXiv:2309.06180 (2023) | vLLM. The KV-cache-as-virtual-memory idea behind modern serving |
| 36 | Leviathan, Kalman & Matias, "Fast Inference from Transformers via Speculative Decoding", arXiv:2211.17192 (2022) | The method, and the acceptance-rate arithmetic that decides whether it helps you |
| 37 | Chen et al., "Accelerating Large Language Model Decoding with Speculative Sampling", arXiv:2302.01318 (2023) | The same idea, independently, with a cleaner proof of distribution preservation |
| 38 | Cai et al., "Medusa", arXiv:2401.10774 (2024) | Speculation without a draft model; the practical variant |
| 39 | Dean & Barroso, "The Tail at Scale", *CACM* 56(2), 2013 | Tail latency in series systems, and hedged requests. Not on arXiv. Behind [`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md) |
| 40 | Erlang, "Solution of some Problems in the Theory of Probabilities of Significance in Automatic Telephone Exchanges", 1917 | A century old and still the correct way to size a voice fleet. Behind [`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md) |

### Suggested paths

**If you have one week:** 1, 2, 13, 28, 30, 33, 35, 39. That is enough to hold a serious
conversation about any modern voice stack.

**If you are implementing ASR:** 1, 2, 8, 9, 10, 12, 13, 14.

**If you are implementing TTS:** 19, 21, 24, 25, then 28, 29, 32, and 26–27 for the frontier.

**If you are building the platform:** 34, 35, 36, 39, 40, plus Nygard and the SRE book.

---

## 3. Fifteen repositories, with the files that matter

Read source the way you read papers: with a specific question. Each entry names the file that
answers one.

### Speech recognition

**1. `openai/whisper`** — the reference implementation, small enough to read fully.
- `whisper/audio.py` — every constant of the input contract: `SAMPLE_RATE = 16000`,
  `N_FFT = 400`, `HOP_LENGTH = 160`, `CHUNK_LENGTH = 30`, `N_FRAMES = 3000`. Also the
  `stft[..., :-1]` truncation that everyone reimplements wrongly.
- `whisper/decoding.py` — the decoding heuristics as a list of defences.
- `whisper/normalizers/english.py` — `EnglishTextNormalizer`, including the filler-word
  deletion `\b(hmm|mm|mhm|mmm|uh|um)\b` that quietly changes your WER.

**2. `SYSTRAN/faster-whisper`** — what you deploy.
- `faster_whisper/transcribe.py` — the VAD-gated chunking and the parameters that map onto
  Whisper's heuristics.

**3. `ggml-org/whisper.cpp`** — the Metal path and the GGUF quantisation story.
- `src/whisper.cpp` — the state machine of a streaming transcription in one file.

**4. `k2-fsa/icefall`** — the modern RNN-T reference, and readable.
- `egs/librispeech/ASR/pruned_transducer_stateless7/` — the whole training recipe.
- `egs/librispeech/ASR/zipformer/` — Zipformer as actually configured.

**5. `k2-fsa/sherpa-onnx`** — deployment without Python.
- `sherpa-onnx/csrc/online-recognizer.cc` — the streaming API contract, partials and finals.

**6. `NVIDIA/NeMo`** — big, and worth grepping.
- `nemo/collections/asr/parts/submodules/rnnt_greedy_decoding.py` — streaming RNN-T decoding
  written out plainly.

### Turn-taking

**7. `snakers4/silero-vad`** — the VAD everyone uses.
- `src/silero_vad/utils_vad.py` — `VADIterator` and the defaults quoted throughout this
  curriculum: window `512 if sr == 16000 else 256`, `threshold = 0.5`,
  `min_speech_duration_ms = 250`, `min_silence_duration_ms = 100`, `speech_pad_ms = 30`.

**8. `pipecat-ai/smart-turn`** — an open audio-native end-of-turn detector.
- the training and inference scripts; note it runs *only during VAD silence*, which is the
  design insight.

### Synthesis

**9. `rhasspy/piper`** — VITS in ONNX, production-shaped.
- `src/python_run/piper/voice.py` — phonemisation to audio, including the espeak-ng call.

**10. `hexgrad/kokoro`** — 82 M parameters, Apache weights.
- `kokoro/model.py` — how small a usable TTS model can be.

**11. `kyutai-labs/moshi`** — full duplex, and the best-documented codec in the field.
- `moshi/moshi/models/loaders.py` — `SAMPLE_RATE = 24000`, `FRAME_RATE = 12.5`, quantiser
  `bins = 2048`, and the LM config `n_q = 16`, `dep_q = 8`, `card = 2048`. Every number in
  [`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)
  comes from here.
- `moshi/moshi/modules/transformer.py` — the RQ-Transformer's temporal/depth split.

### Real-time systems

**12. `webrtc-mirror/webrtc`** — the reference media stack. Read exactly two directories.
- `modules/audio_coding/neteq/delay_manager.{h,cc}` — `quantile = 0.95`,
  `forget_factor = 0.983`, `reorder_forget_factor = 0.9993`, and
  **`ms_per_loss_percent = 20`**, an explicit exchange rate between latency and loss.
- `api/neteq/neteq.h` — `NetEq::Config` (`max_packets_in_buffer = 200`) and the
  `Operation` enum: `kAccelerate`, `kPreemptiveExpand`, `kExpand`, `kMerge`. Proof that a
  jitter buffer is a playback-rate controller.

**13. `pion/webrtc`** — the clearest ICE and RTP code in any language.
- `pkg/rtp` and the ICE internals. Read when a spec sentence stops making sense.

**14. `pipecat-ai/pipecat`** — the frame-graph model, explicit.
- `src/pipecat/frames/frames.py` — ~2400 lines defining `SystemFrame` / `DataFrame` /
  `ControlFrame` / `UninterruptibleFrame`, `InterruptionFrame`, and the `*UrgentFrame`
  escalation tier. The taxonomy derived in
  [`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md).

**15. `livekit/agents`** — the platform this curriculum ships on.
- `livekit/agents/worker.py` — `ASSIGNMENT_TIMEOUT = 7.5`, `UPDATE_LOAD_INTERVAL = 0.5`,
  `DRAIN_TIMEOUT = 3600`, `load_threshold` 0.7 in production, `num_idle_processes`
  `min(ceil(cpu_count), 4)`. A capacity policy in one file.
- `livekit/agents/voice/turn.py` — the interruption and endpointing defaults:
  `min_delay = 0.5`, `max_delay = 3.0`, `min_duration = 0.5`,
  `resume_false_interruption = True`, `false_interruption_timeout = 2.0`.
- `livekit/agents/stt/stt.py` and `tts/tts.py` — the ABCs you implement in
  [`../07-livekit/03-writing-plugins.md`](../07-livekit/03-writing-plugins.md), including
  `SpeechEventType.PREFLIGHT_TRANSCRIPT`.

### How to read a repository

**Read the published release, not `main`.** LiveKit's `main` is routinely ahead of the
released wheel, and a constant you quote from `main` may not exist in the version you run.
`pip download`, unzip, read.

**Grep for constants first.** A file full of magic numbers is a file full of decisions, and
`ms_per_loss_percent = 20` teaches more in one line than a page of documentation.

**Find the state machine.** Every real-time system has one. In NetEQ it is the `Operation`
enum; in Pipecat it is the frame taxonomy; in LiveKit it is the worker's job lifecycle.

**Read the tests when the code confuses you.** They state the intended contract more directly
than the implementation does.

---

## 4. Specifications worth reading directly

RFCs are shorter and more precise than the blog posts about them.

| Spec | Read for |
|---|---|
| **RFC 6716** (Opus) | §2.1.4 frame sizes, §2.1.7 in-band FEC, §2.1.9 DTX. The origin of the 20 ms contract |
| **RFC 7587** (Opus RTP) | The 48 kHz clock rule, and `useinbandfec` defaulting to **0** |
| **RFC 3550** (RTP) | The 12-byte header and the jitter estimator, §6.4.1 |
| **RFC 8445** (ICE) | §5.1.2.1 candidate priority; §6.1.2.3 pair priority |
| **RFC 8656** (TURN) | ChannelData's 4-byte header against 36 for indications |
| **RFC 5764** (DTLS-SRTP) | Why signalling integrity decides media confidentiality |
| **RFC 8866** (SDP) | The attribute set you will read in logs for years |
| **Regulation (EU) 2024/1689**, Art. 50 | Disclosure, synthetic-audio marking, emotion-recognition notice. In force 2 August 2026 |
| **OTel GenAI semantic conventions** | `gen_ai.*` attributes and metrics — and note the bucket recommendation this curriculum measures as 17.8% wrong for voice |

---

## 5. What to skip

Said plainly, because reading lists usually will not.

**Most "voice AI" blog posts.** The architecture diagrams are all the same diagram, and the
numbers are unsourced. The exceptions are vendor engineering blogs that publish measurements.

**Papers on TTS quality you cannot listen to.** MOS numbers without audio samples are not
evidence you can act on.

**Benchmark leaderboards for ASR.** WER on read speech predicts almost nothing about your
telephony traffic. Measure on your own audio
([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)).

**Anything about prompt engineering that is not about *your* model and *your* task.**
Especially for voice, where the constraints — spoken output, length, ASR errors — are
domain-specific ([`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md)).

**The classical DSP textbooks, front to back.** Use them as references. Smith first for
intuition, Oppenheim when you need to be sure.

---

## Sources

- All 40 arXiv identifiers in §2 were resolved against the arXiv API (`export.arxiv.org/api/query`) on 2026-08-26; 36 of the 40 entries are arXiv preprints and all 36 resolved, with the titles reproduced above exactly as arXiv returns them. The four non-arXiv items are named with their venue: Graves et al. (ICML 2006), Snyder et al. (ICASSP 2018), Dean & Barroso (*CACM* 56(2), 2013), and Erlang (1917).
- Repository constants in §3 were read from source during the writing of this curriculum and are cited in the chapters that use them: `whisper/audio.py` and `normalizers/english.py`; `silero-vad` `utils_vad.py`; `moshi/models/loaders.py`; `webrtc` `neteq/delay_manager.{h,cc}` and `api/neteq/neteq.h`; `pipecat` `frames/frames.py`; `livekit/agents` `worker.py`, `voice/turn.py`, `stt/stt.py`, `tts/tts.py`. Versions are stated in the chapters that quote them — notably `livekit-agents` 1.7.0 and `pipecat-ai` 1.7.0.
- Book editions: Jurafsky & Martin 3rd edition draft (free, updated continuously); Rabiner & Juang 1993; Taylor 2009; Oppenheim & Schafer 3rd edition; Smith, *The Scientist and Engineer's Guide to DSP* (free at `dspguide.com`); Kleppmann 2017; Nygard 2nd edition 2018; Beyer et al. 2016 (free at `sre.google/books`).
- `[MEASURED]`: nothing in this chapter is a measurement. The arXiv identifiers and titles are **verified** against the arXiv API on the date given; the repository file paths and constants are verified by reading those files; the book recommendations and the reading-order judgements are `[INFERENCE]` — they are opinions, formed while writing the rest of this curriculum, and the "what to skip" section especially so.
