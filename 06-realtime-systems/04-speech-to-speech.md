# Speech-to-speech

**What you'll be able to do after this:** say precisely where an audio-native model's
latency advantage comes from — and show that most of it is not where people think; price
audio as tokens and predict when a session outgrows its context window; read the OpenAI
Realtime and Gemini Live wire protocols well enough to integrate either in a day; and
decide cascaded versus speech-to-speech from your own requirements instead of a demo.

---

## 1. Intuition

The cascaded pipeline throws away almost everything about the audio. ASR emits words, so
the LLM never learns that the user was hesitant, annoyed, whispering, or a child; TTS
invents prosody from scratch, so the reply's intonation is unrelated to the question's.
Audio-native models keep that information because they never leave the audio domain.

That is the quality argument, and it is real. But the argument people actually make is
about latency, and it is usually wrong in an interesting way. The intuition is "removing
ASR and TTS removes their latency". Measured below, that is the smaller half. A
speech-to-speech model that still uses a VAD to decide the user has finished talking lands
at **814 ms p50** to first audio, against **1370 ms** for a cascaded pipeline. Remove the
turn decision entirely — a genuinely full-duplex model that is always listening and always
generating — and it drops to **343 ms**. **The endpointing decision, not the model chain,
is the dominant term**, which is exactly the conclusion the turn-taking module reached from
the other direction ([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)).

And there is a bill. Audio, tokenised, is enormously more expensive per second than text:
Mimi at 12.5 Hz with 8 codebooks is 100 tokens/s, and Moshi's dual-stream-plus-text
scheme is **212.5 tokens/s** against **2.6 tokens/s** for the same speech as a transcript —
82×. A 32k context holds **2.6 minutes** of that conversation. It holds 210 minutes of the
transcript. Every architectural property of audio-native systems — short sessions,
aggressive summarisation, sliding windows, hybrid text memory — follows from that one
ratio.

---

## 2. Rigour

### 2.1 What an audio token is

A neural codec encodes audio into a sequence of discrete codes at a low frame rate, with
several codebooks per frame from residual vector quantisation
([`../04-tts/02-codec-lm-tts.md`](../04-tts/02-codec-lm-tts.md)). Two numbers define the
cost: the **frame rate** and the **codebooks per frame**. The token rate is their product.

Mimi, the codec inside Moshi, is the instructive case because its published config is
internally checkable: `sample_rate 24000`, `frame_rate 12.5`, quantiser `bins 2048`
(11 bits per code). Eight codebooks gives $8 \times 11 \times 12.5 = 1100$ bit/s — exactly
the 1.1 kbit/s the authors claim. And the design intent is stated plainly: 12.5 Hz "allows
Mimi to get closer to the average frame rate of text tokens (~3-4 Hz), and limit the number
of autoregressive steps in Moshi." Frame rate *is* the architecture.

`[MEASURED]` from §3 — token rates computed from published configs, against a text baseline
of 150 wpm at the measured 1.04 tokens/word:

| Scheme | tok/s | kbit/s | vs text | 10-min call |
|---|---|---|---|---|
| Mimi (Moshi), 1 stream | 100.0 | 1.10 | 38× | 60 000 |
| Mimi, Moshi dual stream + text | 212.5 | 2.20 | **82×** | 127 500 |
| EnCodec 24 kHz @ 6 kbit/s | 600.0 | 6.00 | **231×** | 360 000 |
| EnCodec 24 kHz @ 1.5 kbit/s | 150.0 | 1.50 | 58× | 90 000 |
| SoundStream-class 50 Hz | 400.0 | 4.00 | 154× | 240 000 |

Text speech is 2.60 tok/s. Note that the 75 Hz codecs — the previous generation, and still
the default in much tooling — are 3–6× worse than Mimi at the same job, which is why "use a
low-frame-rate codec" is the first-order design decision for any audio LM.

### 2.2 The context tax

Token rate times session length is context consumption, and audio does not pause for
silence: a codec emits frames whether anyone is speaking or not, so **the cost is wall-clock
time, not words spoken**. `[MEASURED]`, minutes of conversation until the window is full:

| Scheme | 8k | 32k | 128k |
|---|---|---|---|
| text transcript only | 53 | 210 | 840 |
| Mimi, 1 stream | 1.4 | 5.5 | 21.8 |
| Mimi, Moshi dual stream + text | 0.6 | **2.6** | 10.3 |
| EnCodec 24 kHz @ 6 kbit/s | 0.2 | 0.9 | 3.6 |
| SoundStream-class 50 Hz | 0.3 | 1.4 | 5.5 |

Read the second row as a design constraint, not a curiosity. A dual-stream full-duplex
model in a 32k window has **two and a half minutes** before it must forget something. Three
consequences follow, and you can see all three in shipped products: audio-native sessions
are short and are expected to be short; long sessions keep a *text* summary alongside the
audio and re-inject it (a hybrid, not a pure S2S system); and attention cost scales on the
audio token count, so the compute per conversational turn grows far faster than in a
cascaded system whose context is a transcript
([`../05-llm-layer/02-context-and-memory.md`](../05-llm-layer/02-context-and-memory.md)).

Cascaded pipelines are, from this angle, an aggressive compression scheme: they throw away
99% of the tokens and keep the words.

### 2.3 Three architectures, not one

"Speech-to-speech" is used for three genuinely different designs, and conflating them is
the source of most confusion:

| | Audio-in / text-out | Half-duplex audio-in/audio-out | Full-duplex |
|---|---|---|---|
| Example | Ultravox | OpenAI Realtime, Gemini Live | Moshi |
| Input | audio embeddings via projector | audio tokens | audio tokens, continuous |
| Output | **text** (then your TTS) | audio tokens + transcript | audio tokens, continuous |
| Turn decision | yours (VAD/endpointer) | server-side VAD or client commit | none — always generating |
| Prosody understood | yes | yes | yes |
| Prosody produced | no — your TTS invents it | yes | yes |
| Voice choice | any TTS you like | vendor's voices | the model's voice |
| Tools | native (it is an LLM) | supported, with a text detour | research-grade |
| Context cost | audio in only | audio both ways | audio both ways, always |

**Ultravox** is the least glamorous and most immediately useful: "a multimodal projector
that converts audio directly into the high-dimensional space used by LLM", trained by
freezing both the LLM and the audio encoder and training only the adapter — v0.4 took
"2-3 hours on 8xH100 GPUs for 14K training steps". It removes the ASR stage and its error
compounding while leaving you full control of the output path, including voice selection
and your existing TTS contracts. It emits "streaming text", so §2.5's TTS term stays in
your budget.

**Half-duplex audio-out** is what the big vendor APIs are. The model produces audio, but a
turn must still be delimited, and that is where §2.5's cost hides.

**Full-duplex** is architecturally different: the model consumes and emits simultaneously
and forever, so there is no "turn" to detect. It is the only design that removes the
endpointing term rather than relocating it.

### 2.4 Moshi, specifically

Worth reading closely because it is open and its design choices are legible. The published
architecture: a **7B-parameter Temporal Transformer** over time steps, plus "a small Depth
Transformer [that] models inter-codebook dependencies for a given time step" — so the model
factorises the joint distribution over 8 codebooks at each 80 ms step instead of flattening
them into 8× more sequence positions. The LM config confirms the shape: `dim 4096`,
`num_layers 32`, `num_heads 32`, `text_card 32000`, `n_q 16`, `dep_q 8`, `card 2048`.

`n_q = 16` is the interesting number. Moshi models **two** audio streams — "one corresponds
to Moshi, and the other one to the user" — which is what makes full duplex possible: the
model is always predicting both sides, so overlapping speech, backchannels and
interruptions are in-distribution rather than special cases. On top of that it "predicts
text tokens corresponding to its own speech for improved accuracy" (the Inner Monologue),
giving 16 audio + 1 text = **17 tokens per 80 ms step**, hence the 212.5 tok/s in §2.1.

The latency claim is stated precisely and is a good example of how to reason about a floor:
"a theoretical latency of 160ms (80ms for the frame size of Mimi + 80ms of acoustic delay),
with a practical overall latency as low as 200ms on an L4 GPU." Neither term is tunable
without retraining — the frame size is the codec and the acoustic delay is the training
scheme — which is what "floor" means.

### 2.5 The latency floor, measured

`[MEASURED]` from §3 — 20 000 Monte Carlo trials per architecture over per-stage
distributions, reporting `eou_to_ttfa` in ms:

| Architecture | p50 | p90 | p95 | p99 | >800 ms |
|---|---|---|---|---|---|
| cascaded | 1370 | 1726 | 1829 | 2009 | 99.8% |
| S2S half-duplex | 814 | 1068 | 1132 | 1235 | 53.0% |
| S2S full-duplex | **343** | 462 | 491 | 528 | **0.0%** |
| S2S + text tool call | **1499** | 1945 | 2072 | 2291 | 100.0% |

Three findings, and the third is the one worth arguing about in a design review.

**The endpointer is the dominant term.** Half-duplex S2S removes ASR finalisation, LLM
prefill and TTS first-byte — three stages — and improves p50 by 556 ms. Removing the *turn
decision alone* improves it by a further 471 ms. Nearly half of the total gain comes from
one policy term that has nothing to do with model architecture, which means a cascaded
pipeline with an excellent endpointer beats a half-duplex S2S model with a lazy one.

**Full duplex changes the shape, not just the level.** Its p99 (528 ms) is below the
cascaded p50, and 0% of turns exceed 800 ms against 99.8% cascaded. That is because the
removed terms were the variable ones; what remains is a frame and a forward pass.

**A tool call inverts the ranking.** S2S plus a text tool call is 1499 ms p50 — *worse than
cascaded*. The audio-native model must suspend generation, emit a structured call, wait,
and re-enter audio generation, and it pays its own base latency twice around a tool that
the cascaded system was already built to hide behind filler speech
([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)). If
your agent's job is looking things up and taking actions — which is what most commercial
voice agents do — the latency argument for S2S weakens sharply, and may reverse.

### 2.6 The wire protocols, concretely

**OpenAI Realtime**, GA interface (retrieved 2026-08-26). Sessions are opened on
`/v1/realtime`, with `POST /v1/realtime/client_secrets` minting ephemeral credentials for
browser and mobile clients and `/v1/realtime/calls` used when establishing WebRTC. Three
transports, and the split matches [`01-transports.md`](01-transports.md) exactly: **WebRTC**
for browser and mobile clients that touch audio hardware, **WebSocket** when your server
already has raw audio from a media pipeline, and **SIP** for telephony. The current
voice-agent model is `gpt-realtime-2.1`; there are separate models for translation
(`gpt-realtime-translate`, on `/v1/realtime/translations`) and streaming transcription
(`gpt-live-transcribe`). Migration details that bite: drop the `OpenAI-Beta:
realtime=v1` header, set `session.type`, move output audio config under
`session.audio.output`, and use the current event names —
`response.output_text.delta`, `response.output_audio.delta`,
`response.output_audio_transcript.delta`. Reasoning is now exposed on the speech path, and
the guidance is to "start with `reasoning.effort` set to `low` for most production voice
agents" — which is the latency budget speaking.

**Gemini Live** is a "stateful WebSocket connection (WSS)" with a specification that is
refreshingly exact: input is "raw 16-bit PCM audio, 16kHz, little-endian" plus images
(JPEG ≤ 1 FPS) and text; output is "raw 16-bit PCM audio, 24kHz, little-endian". Note the
asymmetry — **16 kHz in, 24 kHz out** — so this curriculum's internal contract is exactly
its input format and a resample is mandatory on the return path
([`../00-setup/03-canonical-formats.md`](../00-setup/03-canonical-formats.md)). It supports
70 languages, barge-in, tool use, transcriptions of *both* input and output audio,
proactive audio (controlling when the model responds), and affective dialog. Both
server-to-server and client-to-server (with ephemeral tokens) topologies are documented.

Two protocol-level observations that apply to both. **Transcriptions of the model's own
audio are not optional in practice** — you need them for logging, evaluation, and the
transcript you show the user, and a vendor that does not emit them makes your agent
unobservable ([`06-observability.md`](06-observability.md)). And **barge-in is a server-side
policy you configure rather than implement**, which is convenient until you need behaviour
their knobs do not express, at which point you cannot reach the mechanism at all.

### 2.7 The honest comparison

| Axis | Cascaded | Audio-native |
|---|---|---|
| `eou_to_ttfa` p50 | 1370 ms | 814 ms half-duplex, 343 ms full-duplex |
| With a tool call | 1499 ms hidden behind filler | 1499 ms, harder to hide |
| Prosody, emotion, speaker traits | discarded at ASR | preserved |
| Non-speech (laughter, sighs, hesitation) | lost | modelled |
| Context cost per minute | ~156 text tokens | 6 000–12 750 audio tokens |
| Session length before forgetting | hours | minutes |
| Voice control | any TTS, any voice, cloning | vendor's voices |
| Swap one component | yes — per-stage vendors | no — it is one model |
| Debuggability | every boundary is inspectable text | opaque; you see audio in, audio out |
| Determinism / testability | replay transcripts | replay audio, non-deterministic |
| Domain adaptation | biasing, lexicons, prompt, fine-tune per stage | prompt, maybe fine-tune the whole thing |
| Compliance / redaction | redact the transcript | PII is in the audio tokens |
| Cost model | per-stage, optimisable | per-audio-token, dominated by input |
| Self-hosting | mature, many options | Moshi, and courage |

The decision rule that survives contact with production: **use audio-native where the
conversation itself is the product** — companionship, tutoring, interviewing, translation,
anything where hesitation and tone carry meaning. **Use cascaded where the conversation is
an interface to a system** — booking, support, verification, anything dominated by tool
calls, entity accuracy, auditability and per-stage cost control. And note that the second
category is where most of the money is, which is why cascaded is not going away.

---

## 3. From scratch

Audio token economics from published codec configs, then a Monte Carlo of the latency
floor. Standalone, stdlib only, deterministic.

```python
"""Speech-to-speech versus cascaded: token economics, then the latency floor.

Part A prices audio as tokens. Text is ~1 token per spoken word; audio is a
codec's frame rate times its codebook count, every second, whether anyone is
talking or not. The ratio decides how long a session can last inside a fixed
context window, and it is the single most under-appreciated constraint on
audio-native models.

Part B is the latency floor. A cascaded pipeline pays endpointing + ASR final +
LLM TTFT + TTS TTFB in series; an audio-native model pays one frame plus one
forward pass. A half-duplex audio model still pays endpointing, because
something must decide the user stopped. Monte Carlo over the per-stage
distributions this curriculum has already measured.

All codec parameters are read from published configs, not invented; sources are
listed in the chapter. Deterministic: fixed seed.
"""

import random

SEED = 11
N_TRIALS = 20_000

# --------------------------------------------------------------- Part A
# (name, frame rate Hz, codebooks per stream, streams, bits per code)
CODECS = [
    ("Mimi (Moshi), 1 stream",      12.5,  8, 1, 11),
    ("Mimi, Moshi dual stream+text", 12.5, 16, 1, 11),   # n_q=16, +1 text below
    ("EnCodec 24 kHz @ 6 kbps",     75.0,  8, 1, 10),
    ("EnCodec 24 kHz @ 1.5 kbps",   75.0,  2, 1, 10),
    ("SoundStream-class 50 Hz",     50.0,  8, 1, 10),
]

WORDS_PER_MIN = 150            # conversational speech
TOK_PER_WORD = 1.04            # measured earlier: tiktoken o200k_base on speech
CONTEXTS = [8_192, 32_768, 131_072]


def part_a():
    text_tok_s = WORDS_PER_MIN / 60 * TOK_PER_WORD
    print(f"text baseline: {WORDS_PER_MIN} wpm x {TOK_PER_WORD} tok/word = "
          f"{text_tok_s:.2f} tok/s of speech\n")
    print(f"{'scheme':30s} {'tok/s':>7} {'kbit/s':>7} {'vs text':>8} "
          f"{'10-min call':>12}")
    rows = []
    for name, fr, cb, streams, bits in CODECS:
        extra_text = 1 if "text" in name else 0
        tok_s = fr * (cb * streams + extra_text)
        kbps = fr * cb * streams * bits / 1000
        rows.append((name, tok_s))
        print(f"{name:30s} {tok_s:7.1f} {kbps:7.2f} {tok_s/text_tok_s:7.0f}x "
              f"{tok_s*600:11.0f}")
    print(f"\n{'scheme':30s} " + " ".join(f"{c//1024:>6}k" for c in CONTEXTS)
          + "   <- minutes of conversation until the context is full")
    print(f"{'text transcript only':30s} "
          + " ".join(f"{c/text_tok_s/60:6.0f}" for c in CONTEXTS))
    for name, tok_s in rows:
        print(f"{name:30s} " + " ".join(f"{c/tok_s/60:6.1f}" for c in CONTEXTS))


# --------------------------------------------------------------- Part B
def tri(rng, lo, mode, hi):
    return rng.triangular(lo, hi, mode)


def cascaded(rng):
    """Endpoint decision -> ASR final -> LLM first token -> TTS first byte."""
    endpoint = tri(rng, 200, 330, 900)      # adaptive endpointer, measured
    stt_final = tri(rng, 40, 90, 260)       # streaming ASR finalisation
    ttft_llm = tri(rng, 120, 260, 900)      # first token, warm prefix cache
    first_clause = tri(rng, 40, 110, 300)   # tokens -> speakable clause
    ttfb_tts = tri(rng, 60, 130, 420)       # TTS first audio byte
    return endpoint + stt_final + ttft_llm + first_clause + ttfb_tts


def s2s_half_duplex(rng):
    """Audio in, audio out, but a VAD still decides the turn ended."""
    endpoint = tri(rng, 200, 330, 900)      # same policy cost -- unavoidable
    frame = 80.0                            # Mimi frame size, published
    forward = tri(rng, 60, 120, 400)        # first audio token out
    acoustic_delay = 80.0                   # published Moshi acoustic delay
    return endpoint + frame + forward + acoustic_delay


def s2s_full_duplex(rng):
    """The model consumes and emits continuously; no turn decision at all."""
    frame = 80.0
    forward = tri(rng, 60, 120, 400)
    acoustic_delay = 80.0
    return frame + forward + acoustic_delay


def s2s_with_text_tool(rng):
    """Audio-native, but the answer needs a tool call: back to text and out."""
    base = s2s_half_duplex(rng)
    tool = tri(rng, 80, 220, 1200)          # the API call itself
    resume = tri(rng, 60, 120, 400)         # re-enter audio generation
    return base + tool + resume


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def part_b():
    rng = random.Random(SEED)
    archs = [("cascaded", cascaded),
             ("S2S half-duplex", s2s_half_duplex),
             ("S2S full-duplex", s2s_full_duplex),
             ("S2S + text tool call", s2s_with_text_tool)]
    print(f"{'architecture':22s} {'p50':>7} {'p90':>7} {'p95':>7} {'p99':>7} "
          f"{'>800ms':>8}")
    for name, fn in archs:
        xs = [fn(rng) for _ in range(N_TRIALS)]
        over = sum(1 for x in xs if x > 800) / len(xs)
        print(f"{name:22s} {pct(xs,.50):7.0f} {pct(xs,.90):7.0f} "
              f"{pct(xs,.95):7.0f} {pct(xs,.99):7.0f} {over:7.1%}")


if __name__ == "__main__":
    print("PART A -- audio as tokens\n")
    part_a()
    print("\n\nPART B -- eou_to_ttfa, ms, 20000 trials per architecture\n")
    part_b()
```

Output `[MEASURED]`:

```
PART A -- audio as tokens

text baseline: 150 wpm x 1.04 tok/word = 2.60 tok/s of speech

scheme                           tok/s  kbit/s  vs text  10-min call
Mimi (Moshi), 1 stream           100.0    1.10      38x       60000
Mimi, Moshi dual stream+text     212.5    2.20      82x      127500
EnCodec 24 kHz @ 6 kbps          600.0    6.00     231x      360000
EnCodec 24 kHz @ 1.5 kbps        150.0    1.50      58x       90000
SoundStream-class 50 Hz          400.0    4.00     154x      240000

scheme                              8k     32k    128k   <- minutes of conversation until the context is full
text transcript only               53    210    840
Mimi (Moshi), 1 stream            1.4    5.5   21.8
Mimi, Moshi dual stream+text      0.6    2.6   10.3
EnCodec 24 kHz @ 6 kbps           0.2    0.9    3.6
EnCodec 24 kHz @ 1.5 kbps         0.9    3.6   14.6
SoundStream-class 50 Hz           0.3    1.4    5.5


PART B -- eou_to_ttfa, ms, 20000 trials per architecture

architecture               p50     p90     p95     p99   >800ms
cascaded                  1370    1726    1829    2009   99.8%
S2S half-duplex            814    1068    1132    1235   53.0%
S2S full-duplex            343     462     491     528    0.0%
S2S + text tool call      1499    1945    2072    2291  100.0%
```

Three load-bearing details. **The `kbit/s` column is a self-check, not decoration**: Mimi's
computed 1.10 kbit/s reproduces the published 1.1 kbit/s exactly, which is how you know the
frame rate and codebook count were read correctly rather than guessed. **Part A's `10-min
call` column is wall-clock, not speech time** — a codec emits frames during silence too, so
unlike a transcript the cost does not fall when the user stops talking. And **the two
`s2s_*` functions differ by exactly one term**, `endpoint`; keeping them otherwise
identical is what isolates the endpointing cost as the dominant contributor rather than
burying it in a bundle of optimistic assumptions.

---

## 4. How production does it

**Moshi** (`kyutai-labs/moshi`, PyPI `moshi` 0.2.13, Python `>=3.10,<3.15`) is the only
full-duplex system you can run yourself, and the codebase is the reference for §2.4. Read
`moshi/models/loaders.py` for the config constants, and note that Mimi ships with a Rust
implementation exposed as `rustymimi` — a hint about where the per-frame budget goes.

**Ultravox** (`fixie-ai/ultravox`, 0.7 as of 2025-12) is the pragmatic middle path, and its
training recipe is the most reusable idea in this chapter: freeze the LLM and the audio
encoder, train only the projector. That is an afternoon of GPU time rather than a
pretraining run, which makes "audio-in" a feature you can add to a model you already trust
rather than a model you must adopt wholesale.

**OpenAI Realtime and Gemini Live** are where nearly all production S2S traffic actually
runs, and both are integrated as plugins rather than as architectures: LiveKit and Pipecat
each expose them as a realtime model behind the same session abstraction as a cascaded
stack ([`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md)). This is the
right way to adopt S2S — behind an interface that lets you A/B it against your cascade on
the same traffic, because §2.5 says the answer depends on your tool-call rate.

**Nobody ships pure S2S for transactional agents.** The pattern that works is hybrid:
audio-native for the conversational surface, a text path for tools and business logic, and
a text transcript as the durable record. The vendors' transcription features exist because
every serious integration needs that record.

---

## 5. At scale

**Audio tokens dominate the bill and the GPU.** At 212.5 tok/s a ten-minute call is
127 500 input-equivalent tokens before the model says anything — two orders of magnitude
more than a transcript. Price S2S per audio-minute against your cascade's per-stage costs;
the LLM was 0.6% of a cascaded model layer, and in S2S it is nearly all of it
([`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md)).

**Context management is a capacity problem, not a quality problem.** With 2.6 minutes per
32k window, session length caps your concurrency per GPU through KV-cache footprint. Plan
truncation, summarisation and session handoff up front
([`../05-llm-layer/04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md)).

**You cannot swap a component under load.** In a cascade, a failing TTS vendor is a
failover to another TTS vendor. In S2S, the model *is* the pipeline, so the only failover is
to an entirely different architecture — which means your cascade has to keep working as a
fallback path, and therefore keep being tested
([`07-reliability.md`](07-reliability.md)).

**Observability must be designed in.** Every span boundary a cascade gives you for free —
`stt_final`, `ttft_llm`, `ttfb_tts` — does not exist. You get `eou_to_ttfa` and the
vendor's transcripts, so instrument those deliberately and expect coarser diagnosis
([`06-observability.md`](06-observability.md)).

**Compliance moves into the audio.** PII redaction on a transcript is a solved problem;
redaction of audio tokens is not, and a voiceprint is biometric data under several regimes.
An S2S vendor that retains audio changes your legal posture, not just your architecture
([`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)).

---

## 6. Exercises

**E6.4.1** Run the §3 listing. Add a codec at 25 Hz with 4 codebooks and compute where it
lands in both tables. State the frame-rate/codebook tradeoff you would pick for a 10-minute
support call in a 32k window, and why.

**E6.4.2** Verify Mimi's published bitrate yourself from `frame_rate`, `bins` and codebook
count, and explain what a mismatch would have told you about your reading of the config.

**E6.4.3** Change Part B so the cascaded pipeline uses a perfect oracle endpointer (0 ms).
Report the new p50 and state how much of S2S half-duplex's advantage survives.

**E6.4.4** Add a fifth architecture: cascaded with filler speech masking the tool call
(`ttfa` decided by the filler, not the answer). Compare it to `S2S + text tool call` and
state which architecture you would choose for a booking agent.

**E6.4.5** Measure your own tool-call rate — fraction of turns that require an external
call — and compute the blended p50 for cascaded versus S2S at that rate. Find the crossover
tool-call rate.

**E6.4.6** Integrate one vendor S2S API behind the same interface as your cascade. Report
`eou_to_ttfa` on identical audio for both, and the delta in transcript WER on entities
(names, numbers, IDs).

**E6.4.7** For Gemini Live's 16 kHz-in / 24 kHz-out asymmetry, write the resampling path
and state where it belongs in your pipeline and what it costs.

**E6.4.8** Take a real 10-minute call recording and compute, from §2.1's rates, the audio
token count for each codec scheme. Then decide the session-length limit you would enforce
in production and what happens when a user exceeds it.

---

## 7. Interview drill

> "Leadership saw a speech-to-speech demo and wants us to replace our cascaded pipeline
> next quarter. We run a customer-support agent that looks up orders and issues refunds.
> What do you tell them?"

I would start by agreeing with the part that is true: the demo was probably genuinely
better, because audio-native models keep prosody and non-speech cues that our ASR throws
away, and they can respond without waiting for a turn to be declared over. Then I would
separate the latency claim into its parts, because that is where the decision actually
lives. In the modelling I would bring, a cascaded pipeline sits around 1370 ms p50 to first
audio and a half-duplex audio model around 814 ms — but nearly half the remaining gap to a
full-duplex model's 343 ms is the endpointing decision, not the model chain. So the first
question is which kind of S2S the demo was. If it was OpenAI Realtime or Gemini Live, it is
half-duplex, and a meaningful share of the improvement is available to us by fixing our
endpointer — which is a two-week project, not a re-platform.

The second thing I would put in front of them is our tool-call rate, because our agent is
not a conversation, it is an interface to an order system. An audio-native model that has to
suspend generation, emit a structured call, wait on our API and re-enter audio generation
came out at 1499 ms p50 in the same model — *worse* than the cascade, which can hide the
lookup behind filler speech because we control the output path. For a support agent where
most turns touch a tool, the latency argument does not merely weaken, it reverses. I would
want the real number from our logs before either of us asserts anything.

Then the constraints that do not appear in a demo. Audio tokenised at Mimi's dual-stream
rate is about 82× the token rate of the transcript, which puts roughly 2.6 minutes of
conversation in a 32k context — our calls are longer than that, so we would be building
summarisation and session handoff immediately. We lose per-stage failover, so our cascade
has to stay alive and tested as the fallback anyway. We lose the inspectable text
boundaries that our latency dashboards and regression tests are built on. And refunds mean
PII and audit: redacting a transcript is solved, redacting audio tokens is not, and a
retained voiceprint is biometric data in several jurisdictions, which is a legal
conversation rather than an engineering one.

What distinguishes a senior answer is proposing the version that gets the win without the
bet. Put the S2S model behind the same interface as the cascade, run it on a slice of real
traffic, and measure three things: `eou_to_ttfa`, entity WER on order numbers and names,
and task completion. That is a two-week experiment that answers the question with our data.
My prior is that we adopt audio-native for the greeting and the small talk — where prosody
and interruption matter and no tool is called — and keep the cascade for the transactional
core, which is a hybrid rather than a replacement.

The premise to question is "replace". S2S is not a faster cascade, it is a different
product with different failure modes; and if what leadership actually liked in the demo was
that the agent did not talk over the user and did not leave dead air, that is turn-taking
and barge-in policy, and we can deliver most of it on the stack we already have.

---

## Sources

- Défossez, Mazaré, Orsini, Royer, Pérez, Jégou, Grave & Zeghidour, "Moshi: a speech-text foundation model for real-time dialogue", 2024, arXiv:2410.00037 — the architecture described in §2.4.
- `kyutai-labs/moshi` (README and `moshi/models/loaders.py`, `main`, retrieved 2026-08-26; PyPI `moshi` 0.2.13, `requires_python <3.15,>=3.10`) — Mimi processes "24 kHz audio, down to a 12.5 Hz representation with a bandwidth of 1.1 kbps, in a fully streaming manner (latency of 80ms, the frame size)"; the 12.5 Hz choice "allows Mimi to get closer to the average frame rate of text tokens (~3-4 Hz), and limit the number of autoregressive steps in Moshi"; "a small Depth Transformer models inter-codebook dependencies for a given time step, while a large, 7B-parameter Temporal Transformer models the temporal dependencies"; "a theoretical latency of 160ms (80ms for the frame size of Mimi + 80ms of acoustic delay), with a practical overall latency as low as 200ms on an L4 GPU"; the dual audio streams ("one corresponds to Moshi, and the other one to the user") plus text prediction for its own speech. Config constants from `loaders.py`: `SAMPLE_RATE = 24000`, `FRAME_RATE = 12.5`, quantiser `bins = 2048`, `n_q = 32` available, SEANet `ratios [8, 6, 5, 4]`; LM `dim 4096`, `num_layers 32`, `num_heads 32`, `text_card 32000`, `n_q 16`, `dep_q 8`, `card 2048`; default `num_codebooks = 8`.
- `fixie-ai/ultravox` (README, `main`, retrieved 2026-08-26; Ultravox 0.7 released 2025-12) — "a multimodal LLM that can understand text as well as human speech, without the need for a separate Audio Speech Recognition (ASR) stage", extending "any open-weight LLM with a multimodal projector that converts audio directly into the high-dimensional space used by LLM"; "currently takes in audio and emits streaming text"; default built on Llama 3.3 70B with an 8B variant; "we keep both the LLM and the audio encoder frozen and only train the adapter/projector. Training Ultravox v0.4 took 2-3 hours on 8xH100 GPUs for 14K training steps."
- OpenAI, "Realtime and audio" guide, `developers.openai.com/api/docs/guides/realtime`, retrieved 2026-08-26 — `/v1/realtime`, `/v1/realtime/translations`, `/v1/realtime/calls`, `POST /v1/realtime/client_secrets`; the WebRTC / WebSocket / SIP transport split and its stated use cases; models `gpt-realtime-2.1`, `gpt-realtime-translate`, `gpt-live-transcribe`; the beta-to-GA changes (drop `OpenAI-Beta: realtime=v1`, set `session.type`, `session.audio.output`, `response.output_text.delta`, `response.output_audio.delta`, `response.output_audio_transcript.delta`); "start with `reasoning.effort` set to `low` for most production voice agents"; the `OpenAI-Safety-Identifier` header.
- Google, "Gemini Live API overview", `ai.google.dev/gemini-api/docs/live-api`, page dated 2026-06-12, retrieved 2026-08-26 — input "Audio (raw 16-bit PCM audio, 16kHz, little-endian), images (JPEG <= 1FPS), text"; output "Audio (raw 16-bit PCM audio, 24kHz, little-endian)"; protocol "Stateful WebSocket connection (WSS)"; 70 supported languages, barge-in, tool use, audio transcription of input and output, proactive audio, affective dialog; server-to-server and client-to-server topologies.
- Zeghidour, Luebs, Omran, Skoglund & Tagliasacchi, "SoundStream: An End-to-End Neural Audio Codec", 2021, arXiv:2107.03312, and Défossez, Copet, Synnaeve & Adi, "High Fidelity Neural Audio Compression" (EnCodec), 2022, arXiv:2210.13438 — the RVQ codecs whose frame rates are used in §2.1; the codec mechanics are derived in [`../04-tts/02-codec-lm-tts.md`](../04-tts/02-codec-lm-tts.md).
- `[MEASURED]`: both tables are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only, `SEED = 11`. Part A is exact arithmetic over the published codec parameters cited above plus the previously measured 1.04 tokens/word for spoken text (tiktoken `o200k_base`); its 1.10 kbit/s for Mimi reproduces the published 1.1 kbit/s, which validates the frame-rate and codebook figures. Part B is a Monte Carlo whose Mimi frame size (80 ms) and acoustic delay (80 ms) are published values, but whose per-stage endpointing, ASR, LLM, TTS and tool distributions are `[INFERENCE]` triangular priors informed by this curriculum's earlier measurements, not measured end to end on one system — the ranking and the isolation of the endpointing term are the robust results, not the absolute milliseconds.
