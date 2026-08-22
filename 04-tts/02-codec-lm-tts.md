# Neural Audio Codecs and Codec-LM TTS

**What you'll be able to do after this:** explain residual vector quantisation and
demonstrate why it beats a flat codebook by a large factor in memory; distinguish
semantic from acoustic tokens and say what each is for; describe the VALL-E paradigm and
why it enables zero-shot voice cloning; and state precisely what that capability costs
you in latency, determinism and observability.

---

## 1. Intuition

The previous chapter ended on a problem: a mel spectrogram does not determine a waveform,
so a vocoder must *generate* plausible detail. Codec-based TTS takes that observation to
its conclusion. If speech has to be generated rather than reconstructed, then represent it
as a sequence of **discrete tokens** and generate them the way language models generate
text.

Two things fall out of that reframing, and they are the reason the field moved.

**Text and audio become the same kind of object.** Once audio is a token sequence, every
technique developed for language modelling applies: transformers, in-context learning,
scaling laws, prompting. A TTS model becomes "a language model over audio tokens", and
that is not an analogy — it is the same architecture with a different vocabulary.

**Voice cloning becomes prompting.** This is the part that changed the industry. If the
model is an autoregressive predictor over audio tokens, then giving it three seconds of a
target speaker as a *prefix* and asking it to continue produces speech in that speaker's
voice — for a speaker it never saw during training. No fine-tuning, no enrolment, no
studio session. Zero-shot cloning is in-context learning, and it emerged from the
architecture rather than being designed in.

The cost is equally structural, and it is the reason this branch has not simply replaced
the previous one. An autoregressive model over audio tokens must emit tokens sequentially,
at a rate set by the codec's frame rate multiplied by the number of quantiser stages. That
puts a floor under time-to-first-byte that a parallel VITS-style model does not have. So the
choice between this chapter and the previous one is, in practice, a choice between cloning
plus expressivity and latency plus determinism
([`05-engine-selection.md`](05-engine-selection.md)).

The enabling component is the codec, and the trick inside the codec is residual vector
quantisation. §2.2 measures why it works.

---

## 2. Rigour

### 2.1 Why discretise audio at all

An autoencoder compresses audio to a continuous latent. To model it with a language model
you need a *discrete* sequence, so you quantise the latent against a learned codebook —
vector quantisation. The naive version has a fatal problem.

Speech at 16 kHz through an encoder with 320× downsampling gives 50 latent vectors per
second. To represent each with reasonable fidelity you might need 20 bits, which is a
codebook of $2^{20} \approx 10^6$ entries. That codebook is too large to train (most
entries never get used), too large to store, and produces a vocabulary no language model
can handle.

### 2.2 Residual vector quantisation

RVQ quantises in **stages**. Quantise the vector with codebook 1, compute the residual,
quantise the residual with codebook 2, and repeat. The reconstruction is the sum of the
stage outputs, and $n$ stages of $K$ entries give $K^n$ effective combinations from $nK$
stored vectors.

Measured on 64-dimensional vectors with realistic structure (a rank-8 subspace plus noise,
which is roughly how audio latents behave), 20 000 vectors, k-means codebooks
`[MEASURED]`:

| RVQ stages | Bits per vector | SNR (dB) | Relative error |
|---|---|---|---|
| 1 | 10 | 6.47 | 0.4746 |
| 2 | 18 | 10.57 | 0.2962 |
| 3 | 26 | 13.72 | 0.2061 |
| 4 | 34 | 15.67 | 0.1646 |
| 5 | 42 | 16.68 | 0.1465 |
| 6 | 50 | **17.29** | 0.1366 |

And the flat alternative — one codebook, increasing size `[MEASURED]`:

| Flat codebook $K$ | Bits per vector | SNR (dB) |
|---|---|---|
| 64 | 6 | 3.79 |
| 256 | 8 | 5.20 |
| 1024 | 10 | 6.75 |
| 4096 | 12 | 8.72 |

Compare the two tables. Flat VQ buys roughly **1.4 dB per additional bit**, and each bit
*doubles* the codebook. RVQ reaches 17.29 dB using six codebooks totalling about 6 100
stored vectors. Extrapolating the flat trend, matching that SNR would need on the order of
18 bits — around 262 000 codebook entries, a **43× larger** codebook, and one whose
k-means training is impractical because most entries would see almost no data.

That is the whole argument for RVQ: it converts an exponential memory requirement into a
linear one, at the cost of a slightly suboptimal quantiser (greedy stage-wise quantisation
is not jointly optimal).

Two further observations from the table.

**Diminishing returns are real and they are informative.** Stages 5 and 6 add only 1.0 and
0.6 dB. The residual has become close to the noise floor of the data, so further stages are
quantising noise. In a real codec this is the **bitrate–quality frontier**, and it is why
codecs ship with a configurable number of active quantisers: you drop stages to reduce
bitrate and the degradation is graceful.

**Stage 1 carries the most information.** 10 bits buys 6.47 dB; the next 40 bits buy 10.8
more. This asymmetry is what makes the hierarchical generation strategy in §2.4 work —
the first stage is worth modelling carefully and autoregressively, the later stages can be
predicted in parallel because they are refinements.

### 2.3 Semantic versus acoustic tokens

A codec trained for reconstruction produces **acoustic tokens**: they contain everything
needed to rebuild the waveform, including speaker identity, room acoustics, and background
noise. That is what you want for fidelity and a poor representation for *meaning* — two
recordings of the same sentence by different speakers have completely different acoustic
tokens.

**Semantic tokens** come from self-supervised speech models (HuBERT, w2v-BERT and
relatives) whose training objective encourages phonetic content and discards speaker and
channel detail. They are close to a phoneme sequence and cannot reconstruct audio.

The distinction organises the field:

| | Semantic tokens | Acoustic tokens |
|---|---|---|
| Source | self-supervised encoder (HuBERT-like) | codec encoder (RVQ) |
| Contains | phonetic/linguistic content | everything, including speaker and channel |
| Rate | low (~25–50/s) | higher (frame rate × stages) |
| Reconstructable | no | yes |
| Good for | modelling *what* is said | reproducing *how* it sounds |

AudioLM's contribution was the hierarchy: model semantic tokens first to get coherent
content, then condition acoustic-token generation on them to get audio. This separation is
why modern systems can maintain long-range coherence — the semantic level plans, the
acoustic level renders.

### 2.4 The VALL-E paradigm

VALL-E framed TTS as conditional language modelling over codec tokens, with a
two-part structure that follows directly from §2.2's asymmetry:

**Autoregressive stage.** Predict the *first* quantiser's tokens autoregressively,
conditioned on the phoneme sequence and on the acoustic prompt (the enrolment audio). This
is where prosody, rhythm and speaker identity are decided, and it must be sequential
because those are long-range dependent.

**Non-autoregressive stage.** Predict the remaining quantiser levels in parallel,
conditioned on the first level. These are refinements — per §2.2, later stages carry
progressively less information — so they can be generated in one pass.

The zero-shot cloning mechanism is worth stating precisely because it is often described
mystically. The model is trained on a large multi-speaker corpus to continue audio token
sequences given text. At inference, the prompt is `[enrolment audio tokens] + [text of
enrolment] + [text to speak]`, and the model continues the token sequence. It reproduces
the prompt speaker's voice for the same reason a text LLM continues in the style of its
prompt: **it is doing in-context learning**, and the "style" happens to be a voice.

Consequences that follow from that being the mechanism rather than a feature:

- **Cloning quality depends on prompt quality.** Noisy or short enrolment gives a poor
  clone, and the model may also reproduce the prompt's *channel* — copy the room and the
  microphone along with the voice.
- **It is not controllable in the way a style vector is.** You steer by choosing a prompt,
  not by setting a parameter.
- **Output is stochastic.** Sampling means the same input produces different audio each
  time, which matters for caching, testing and regression detection
  ([`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md)).
- **The safety problem is inherent, not incidental.** Three seconds of anyone's voice is a
  cloning prompt, which is why watermarking and consent are engineering requirements
  rather than policy afterthoughts
  ([`04-prosody-and-voice.md`](04-prosody-and-voice.md)).

### 2.5 The latency floor

This is the decisive engineering property. An autoregressive codec-LM must generate tokens
sequentially before any audio exists. For a codec at frame rate $f$ with $n_{\text{AR}}$
autoregressive levels, one second of audio requires $f \times n_{\text{AR}}$ sequential
forward passes — and unlike text generation, you cannot show partial output early because a
partial token sequence does not decode to intelligible audio until the decoder has a
sufficient span.

Compare the branches structurally:

| | Parallel (VITS/StyleTTS) | Codec-LM (VALL-E lineage) |
|---|---|---|
| First audio requires | one forward pass | many sequential passes |
| TTFB scales with | model size | model size × tokens needed |
| Output determinism | deterministic | stochastic |
| Zero-shot cloning | no | yes |
| Streaming | natural | requires chunked generation |

The mitigations used in practice: **chunked generation** (produce a short span, decode,
emit, continue — trading some quality at chunk boundaries for streaming), **distillation**
into fewer steps, **flow-matching or diffusion** alternatives that generate in a fixed small
number of steps rather than token-by-token, and **smaller models**. All of them are attempts
to buy back the latency the architecture costs.

Flow-matching TTS (the E2/F5-TTS line) is worth flagging as a genuinely different tradeoff:
non-autoregressive generation of the whole utterance in a fixed number of solver steps,
which gives cloning without a per-token sequential floor — but it needs the *whole
utterance* before it starts, so it is good for latency-tolerant cloning and not for
streaming a long reply.

### 2.6 The codec landscape

| Codec | Contribution | Note |
|---|---|---|
| **SoundStream** (2021) | RVQ + adversarial training; a single model spanning a bitrate range | established the template |
| **EnCodec** (2022) | RVQ codec with a small transformer entropy model; widely used as a token source | the tokeniser in much early codec-LM work |
| **DAC** (2023) | improved fidelity at low bitrate; addresses codebook under-utilisation | "Descript Audio Codec" |
| **Mimi** | low-frame-rate codec designed for full-duplex streaming speech models | used in the Moshi line ([`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)) |

The engineering trend across these is toward **lower frame rate and fewer stages**, because
both directly reduce the number of tokens a language model must generate — which is
§2.5's latency floor attacked at its source. A codec designed for reconstruction quality
and a codec designed to be modelled by an LM are different optimisation problems, and the
second is now the dominant one.

---

## 3. From scratch

RVQ, and the flat-codebook comparison that justifies it. Standalone, numpy only. Note
that the k-means fits make this take tens of seconds.

```python
"""Residual vector quantisation vs a flat codebook: the memory argument, measured."""
import numpy as np

def kmeans(X, K, iters=12, seed=0):
    """Lloyd's algorithm, blocked to keep the distance matrix small."""
    rng = np.random.default_rng(seed)
    C = X[rng.choice(len(X), K, replace=False)].copy()
    for _ in range(iters):
        labels = assign(X, C)
        for k in range(K):
            m = labels == k
            if m.any():
                C[k] = X[m].mean(0)
    return C

def assign(X, C, block=2048):
    """Nearest-centroid assignment. Blocked because the full (N, K, D) broadcast
    is what makes naive VQ code run out of memory."""
    out = np.empty(len(X), dtype=int)
    for i in range(0, len(X), block):
        blk = X[i:i + block]
        out[i:i + block] = np.argmin(((blk[:, None, :] - C[None, :, :]) ** 2).sum(-1),
                                     axis=1)
    return out

def snr_db(x, x_hat):
    return 10 * np.log10((x ** 2).mean() / max(((x - x_hat) ** 2).mean(), 1e-20))

def rvq(X, stage_sizes, seed=0):
    """Quantise, take the residual, quantise again. Reconstruction is the sum.

    n stages of K entries give K**n effective combinations from n*K stored
    vectors -- the exponential-to-linear trade that makes neural codecs possible.
    """
    residual = X.copy()
    recon = np.zeros_like(X)
    rows = []
    bits = 0.0
    for stage, K in enumerate(stage_sizes, start=1):
        # Fit on a subset: codebook training does not need every vector.
        C = kmeans(residual[:4000], K, seed=seed + stage)
        q = C[assign(residual, C)]
        recon += q
        residual -= q
        bits += np.log2(K)
        rows.append((stage, bits, snr_db(X, recon),
                     np.linalg.norm(X - recon) / np.linalg.norm(X)))
    return rows

if __name__ == "__main__":
    rng = np.random.default_rng(11)
    D, N = 64, 20_000
    # Realistic latent structure: a low-rank subspace plus noise. Audio latents
    # behave this way, and the noise floor is what produces diminishing returns.
    U = rng.standard_normal((D, 8))
    X = (rng.standard_normal((N, 8)) @ U.T) + 0.3 * rng.standard_normal((N, D))

    print("residual VQ: 1024-entry first stage, 256-entry refinements")
    print(f"{'stages':>7} {'bits/vec':>9} {'SNR dB':>8} {'rel_err':>9}")
    for stage, bits, s, rel in rvq(X, [1024] + [256] * 5):
        print(f"{stage:7d} {bits:9.0f} {s:8.2f} {rel:9.4f}")

    print("\nflat codebook of increasing size (the alternative)")
    print(f"{'K':>7} {'bits/vec':>9} {'SNR dB':>8}")
    for K in (64, 256, 1024, 4096):
        C = kmeans(X[:8000], K, seed=1)
        print(f"{K:7d} {np.log2(K):9.0f} {snr_db(X, C[assign(X, C)]):8.2f}")
```

Two implementation details worth noticing because they generalise.

**`assign` is blocked.** The obvious `((X[:, None, :] - C[None, :, :]) ** 2).sum(-1)`
allocates an $N \times K \times D$ array — for the 4096 case here that is 20000 × 4096 × 64
float64, roughly 40 GiB. Blocking is not an optimisation, it is the difference between
running and not.

**Codebooks are fit on a subset.** 4000 vectors is enough to place 256 centroids, and this
is what real codec training does too — the codebook is small relative to the data, and the
binding constraint is having enough samples *per centroid*, which is exactly what fails
when a flat codebook grows too large.

---

## 4. How production does it

**EnCodec** (`facebookresearch/encodec`) is the token source used by much of the early
codec-LM literature, and the practical reason to know it is that "audio tokens" in a paper
usually means EnCodec tokens at a stated bitrate and number of quantisers.

**DAC** (`descriptinc/descript-audio-codec`) improved low-bitrate fidelity and addressed
codebook under-utilisation — the failure mode where most entries go unused, which §3's
subset-fitting note hints at.

**Open-weight codec-LM TTS** in this lineage includes XTTS (from Coqui), Fish Speech,
CosyVoice, Sesame's CSM and Chatterbox. Licences and cloning capabilities vary
substantially and change between releases, so verify both before building on one — the
combination of "open weights" and "commercial use permitted" and "cloning allowed" is not
automatic.

**Flow-matching alternatives** (F5-TTS, E2-TTS) are the non-autoregressive cloning branch
described in §2.5, and worth evaluating when you need cloning but can tolerate
whole-utterance generation.

**Hosted engines** in this branch are recognisable by their capabilities rather than their
documentation: zero-shot cloning from a short sample, expressive and emotional control, and
a time-to-first-byte higher than the parallel branch. If a vendor offers instant cloning,
you are talking to something in this family and you should measure its TTFB before
designing around it.

**Watermarking** matters here specifically because this is the branch that can clone. Open
tooling exists (AudioSeal is the notable example) and some vendors watermark by default.
Treated as an engineering and legal requirement in
[`04-prosody-and-voice.md`](04-prosody-and-voice.md).

---

## 5. At scale

**Token count is the cost driver, and it is the number to optimise.** Cost and latency both
scale with tokens generated per second of audio, which is frame rate × autoregressive
stages. This is why codec research moved toward lower frame rates (§2.6): halving the frame
rate halves the sequential work. When comparing two codec-LM systems, compare tokens per
second of audio before comparing parameter counts.

**Streaming requires chunked generation, and chunking has a quality cost.** Generate a span,
decode, emit, continue with the previous context. The seam between chunks is where prosody
breaks, and the mitigation is overlap plus cross-fade, which costs extra generation. Budget
for it rather than discovering it.

**Stochastic output breaks caching and testing.** The parallel branch is deterministic, so
you can cache synthesised audio by text hash and assert byte equality in tests. A
sampling-based codec-LM produces different audio every call, so caching requires storing the
first realisation and accepting it as canonical, and tests must assert on audio *properties*
rather than bytes ([`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md)).
This is a real operational tax that rarely appears in a model comparison.

**Cloning creates an enrolment-data problem.** Storing reference audio to clone a customer's
or agent's voice means storing biometric data, with the consent, retention and deletion
obligations that implies — the same category as speaker embeddings in
[`../02-asr/09-diarization-and-speaker-id.md`](../02-asr/09-diarization-and-speaker-id.md)
§5. Decide this deliberately, before someone adds a `voice_prompts` bucket.

**Hybrid deployment is usually the right answer.** Use the parallel branch for the
latency-critical conversational path and the codec-LM branch offline for anything
pre-renderable — greetings, prompts, marketing audio, or a brand voice generated once and
cached. You get cloning quality where latency does not matter and low latency where it
does, which is strictly better than choosing one for everything.

**Version the codec with the model.** Tokens are only meaningful to the decoder they were
trained against, so a codec upgrade invalidates any stored tokens and any cached
intermediate representations. Store audio, not tokens, unless you have a strong reason.

---

## 6. Exercises

**E4.2.1** Run the §3 code. Then change the noise scale in the synthetic data from 0.3 to
0.05 and re-measure. How many RVQ stages remain useful, and what does that tell you about
the relationship between the data's noise floor and the useful bitrate?

**E4.2.2** Extrapolate the flat-codebook trend to find the bits needed to match 6-stage RVQ
SNR. Compute the codebook size and the number of training vectors you would need for a
reasonable count per centroid. State why this is impractical rather than merely expensive.

**E4.2.3** Implement RVQ with **joint** refinement: after fitting all stages, re-fit each
codebook holding the others fixed, and iterate. Measure the SNR gain over greedy staging
and comment on whether it justifies the complexity.

**E4.2.4** Measure codebook utilisation per stage — the fraction of entries used at least
once. Identify the stage where utilisation drops and connect it to the diminishing returns
in §2.2.

**E4.2.5** Compute the sequential-step count for one second of audio at frame rates of 75,
50, 25 and 12.5 Hz with 1 and 2 autoregressive stages. Given a per-step latency of your
choosing, tabulate the resulting TTFB floor.

**E4.2.6** Take an open codec-LM TTS model and measure its actual time-to-first-audio-byte
for a 5-word and a 50-word input. Compare against a local Piper or Kokoro voice and state
the latency ratio.

**E4.2.7** Design the hybrid split from §5 for a specific agent: list which utterances are
pre-renderable and which must be live, and compute what fraction of spoken audio could come
from cache.

---

## 7. Interview drill

> "Leadership wants our voice agent to use a cloned voice of our CEO, generated from a
> podcast appearance. Engineering says it will make the agent slower. Adjudicate."

Engineering is right about the mechanism and should be able to explain *why* rather than
asserting it. Zero-shot cloning requires the codec-LM branch (§2.4), which is
autoregressive over audio tokens and therefore has a time-to-first-byte floor set by
sequential token generation (§2.5) — structurally higher than a parallel VITS or
StyleTTS-class model. That is architecture, not implementation, so it cannot be optimised
away by engineering effort alone; only by distillation, a smaller model, chunked generation
with its seam artefacts, or a flow-matching alternative that needs the whole utterance
before it starts.

Then the reframe, which is where the value is: **not all of the agent's speech is
latency-critical**. Greetings, menu prompts, hold messages and disclosures are fixed
strings. Render those offline in the cloned voice, cache them, and serve them instantly
(§5). The latency floor only applies to genuinely dynamic responses, and for those you can
either accept the higher TTFB or use a matched non-cloned voice — noting honestly that
mixing two voices in one call is jarring and probably worse than either alone.

The parts of the answer that separate a senior response:

**Raise consent and provenance without being asked.** A cloned executive voice used in an
automated system is exactly the case the emerging transparency rules target, and a podcast
appearance is not consent for voice cloning. This needs explicit written consent from the
person, a disclosure to callers that they are speaking with AI, and watermarking of
generated audio ([`04-prosody-and-voice.md`](04-prosody-and-voice.md),
[`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)).
Flagging this before the build starts is much cheaper than after.

**Name the operational taxes.** Stochastic output means caching needs a canonical
realisation and tests cannot assert byte equality (§5). Storing the reference audio creates
a biometric-data obligation. And the cloned voice becomes a single point of failure — if
that vendor has an outage, your fallback engine has a different voice, and a mid-call voice
change is very noticeable.

**Ask what the goal actually is.** If it is brand distinctiveness, a professionally recorded
voice actor rendered through the fast parallel branch achieves it with better latency, full
determinism, clean rights, and no cloning risk. That is very often the right answer, and
arriving at it requires questioning the requirement rather than optimising the request.

---

## Sources

- Zeghidour, N. et al. (2021). *SoundStream: An End-to-End Neural Audio Codec.* arXiv:2107.03312 — RVQ plus adversarial training, §2.6.
- Défossez, A., Copet, J., Synnaeve, G. & Adi, Y. (2022). *High Fidelity Neural Audio Compression* (EnCodec). arXiv:2210.13438.
- Kumar, R. et al. (2023). *High-Fidelity Audio Compression with Improved RVQGAN* (DAC). arXiv:2306.06546 — codebook utilisation, referenced in §2.6 and E4.2.4.
- Wang, C. et al. (2023). *Neural Codec Language Models are Zero-Shot Text to Speech Synthesizers* (VALL-E). arXiv:2301.02111 — the AR + NAR structure in §2.4.
- Borsos, Z. et al. (2022). *AudioLM: a Language Modeling Approach to Audio Generation.* arXiv:2209.03143 — the semantic/acoustic token hierarchy in §2.3.
- Hsu, W.-N. et al. (2021). *HuBERT.* arXiv:2106.07447 — the semantic-token source in §2.3.
- Chen, Y. et al. (2024). *F5-TTS.* arXiv:2410.06885 and Eskimez, S. E. et al. (2024). *E2 TTS.* arXiv:2406.18009 — the flow-matching branch in §2.5.
- Défossez, A. et al. (2024). *Moshi.* arXiv:2410.00037 — the Mimi codec referenced in §2.6.
- `facebookresearch/encodec`, `descriptinc/descript-audio-codec`, `coqui-ai/TTS` (XTTS), `fishaudio/fish-speech`, `FunAudioLLM/CosyVoice`, `resemble-ai/chatterbox`, `facebookresearch/audioseal` — the implementations in §4, checked 2026-08. Licences and cloning terms vary and must be verified per release.
- All `[MEASURED]` values in §2.2 were produced by the code in §3 on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2, on synthetic low-rank-plus-noise data. The exponential-versus-linear memory conclusion is structural; the absolute SNR figures depend on the data's noise floor.
