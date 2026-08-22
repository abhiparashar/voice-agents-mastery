# The RNN Transducer: the Streaming Architecture

**What you'll be able to do after this:** explain why CTC cannot model output
dependencies and RNN-T can; derive and implement the transducer loss over the
$T \times U$ lattice and verify it against a reference implementation; state the
memory blow-up in gigabytes and name the three real mitigations; and justify RNN-T
over CTC or attention for a streaming voice agent using latency rather than WER.

---

## 1. Intuition

CTC ([`02-ctc-from-scratch.md`](02-ctc-from-scratch.md)) makes one crippling
assumption: given the audio, each output frame's label is independent of every other
output label. It has no idea what it just emitted. That is why a CTC model trained on
speech will happily produce `recognise speech` and `wreck a nice beach` with similar
confidence — nothing in the model penalises a letter sequence that no word contains.
In practice you paper over this with an external language model at decode time, which
works and adds a decoder, a fusion weight to tune, and latency.

The transducer's idea is simple and structural: **add a second network that reads the
labels you have already emitted, and combine it with the acoustic encoder before
predicting the next symbol.** Now the model knows both what it is hearing and what it
has said. The language model is inside the architecture, trained jointly, and it
costs nothing at decode time beyond running the network you already have.

The second, subtler idea is about *time*. CTC produces exactly one output per input
frame, which forces a rigid correspondence: 500 frames in, 500 decisions out, and if
a word needs more symbols than it has frames it cannot be emitted at all. The
transducer decouples these. At each lattice position it makes a different kind of
choice: **emit a label and stay at the same time step, or emit blank and advance
time.** Blank stops meaning "no label here" and starts meaning "I am done with this
frame, move on". That change lets the model emit several symbols for one frame or
consume many frames before committing to anything.

That decoupling is precisely what makes RNN-T the natural streaming architecture. The
encoder can be causal, the prediction network only ever looks backwards, and emission
is a local decision that never needs to see the end of the utterance. Compare with an
attention encoder-decoder, whose cross-attention is over the *whole* encoder output
by construction — a model that must, in its unmodified form, hear you finish before it
starts. That is why Whisper is awkward to stream
([`05-streaming-asr.md`](05-streaming-asr.md)) and why essentially every on-device and
low-latency production recogniser — Google's, and the Zipformer-Transducer recipes in
`k2-fsa/icefall` — is a transducer.

---

## 2. Rigour

### 2.1 The three networks

| Network | Input | Output | Streaming role |
|---|---|---|---|
| **Encoder** (transcription net) | acoustic frames $x_{1..T}$ | $f_t \in \mathbb{R}^{d}$ | Causal or limited-lookahead; this is where latency is spent |
| **Prediction net** (predictor) | previously emitted labels $y_{1..u}$ | $g_u \in \mathbb{R}^{d}$ | A label-only LM; never sees audio |
| **Joint net** | $f_t, g_u$ | $h_{t,u} \in \mathbb{R}^{V}$ | Combines both, produces the output distribution |

The joint network is conventionally
$h_{t,u} = W \cdot \tanh(W_f f_t + W_g g_u + b)$ followed by a softmax over the
vocabulary $V$ (labels plus blank). The important structural fact is that the
prediction network is conditioned on the *label* history, not on time — so the same
$g_u$ is reused across all $t$, and the same $f_t$ across all $u$. That factorisation
is what makes the $T \times U$ lattice computable at all.

### 2.2 The lattice

Let $y = (y_1, \dots, y_U)$ be the target and $\varnothing$ be blank. Define lattice
nodes $(t, u)$ for $0 \le t < T$, $0 \le u \le U$, where being at $(t,u)$ means "I am
consuming frame $t$ and have emitted the first $u$ labels". Exactly two moves exist:

$$
(t, u) \xrightarrow{\ \varnothing\ } (t+1, u) \qquad \text{advance time}
$$
$$
(t, u) \xrightarrow{\ y_{u+1}\ } (t, u+1) \qquad \text{emit a label}
$$

A complete path runs from $(0,0)$ to $(T-1, U)$ and then emits a final blank. Two
consequences follow immediately, and both distinguish RNN-T from CTC:

- **A path may emit many labels at one time step** — a run of vertical moves. So $U$
  is not bounded by $T$. CTC cannot do this.
- **The number of blanks in any complete path is exactly $T$**, one per time
  advance, and the number of label moves is exactly $U$. Every path therefore has
  length $T + U$, which is what makes the anti-diagonal identity in §2.4 hold.

### 2.3 Forward and backward recursions

Let $\log p(k \mid t, u)$ be the log-probability of symbol $k$ from the joint network
at node $(t,u)$. The forward variable $\alpha(t,u)$ is the log-probability of reaching
$(t,u)$:

$$\alpha(0,0) = 0$$
$$\alpha(t,u) = \operatorname{logaddexp}\Big(
\underbrace{\alpha(t-1,u) + \log p(\varnothing \mid t-1, u)}_{\text{arrived by advancing time}},\;
\underbrace{\alpha(t,u-1) + \log p(y_u \mid t, u-1)}_{\text{arrived by emitting } y_u}
\Big)$$

with terms omitted when $t = 0$ or $u = 0$. The backward variable $\beta(t,u)$ is the
log-probability of completing the target from $(t,u)$:

$$\beta(T-1, U) = \log p(\varnothing \mid T-1, U)$$
$$\beta(t,u) = \operatorname{logaddexp}\Big(
\log p(\varnothing \mid t,u) + \beta(t+1,u),\;
\log p(y_{u+1} \mid t,u) + \beta(t,u+1)
\Big)$$

and the loss is

$$\mathcal{L} = -\log P(y \mid x) = -\beta(0,0) = -\alpha(T-1,U) - \log p(\varnothing \mid T-1,U)$$

Compare against the CTC recursions and the family resemblance is obvious: same
log-space dynamic programme, same forward-backward structure, different transition
graph. What differs is *what the graph permits* — and that difference is the entire
modelling contribution.

### 2.4 The identity that tests your implementation

A tempting but **wrong** check is $\alpha(t,u) + \beta(t,u) = -\mathcal{L}$ at every
node. That identity holds for CTC-style trellises where all paths pass through one
node per time step; it fails here, because not every path visits every lattice node.

The correct invariant uses the length property from §2.2. Every complete path has
length $T + U$ and advances exactly one step per move, so **every path crosses
exactly one node on each anti-diagonal** $t + u = k$. Therefore, for every $k$:

$$\operatorname*{logsumexp}_{\{(t,u)\,:\,t+u=k\}} \big[\alpha(t,u) + \beta(t,u)\big] = -\mathcal{L}$$

Measured on a $T=6$, $U=3$, $V=5$ random problem, across all nine anti-diagonals
`[MEASURED]`: every value equals $-13.1513249204$, maximum deviation
$1.776 \times 10^{-15}$. This is the unit test to write; it catches transposed
indices, off-by-one errors at the boundaries, and blank/label confusion, all of which
otherwise produce a loss that merely trains badly.

### 2.5 The memory problem, in gigabytes

The joint network is evaluated at every lattice node for every batch element, so its
output tensor is

$$B \times T \times U \times V$$

This is the defining practical problem of transducer training. Computed exactly
`[MEASURED]`:

| $B$ | $T$ | $U$ | $V$ | Elements | fp32 | fp16 |
|---|---|---|---|---|---|---|
| 32 | 1000 | 100 | 1000 | 3.20 G | 11.9 GiB | 6.0 GiB |
| 32 | 1500 | 200 | 5000 | 48.00 G | 178.8 GiB | 89.4 GiB |

The first row is a 10-second utterance at a 10 ms frame rate with a 1k word-piece
vocabulary — a modest configuration that already does not fit on a 12 GiB GPU with
room for activations. The second row, a 15-second utterance with a 5k vocabulary, is
178 GiB for a *single tensor*. And that is only the forward pass; the backward pass
needs it again.

Three real mitigations, in the order the field adopted them:

**Time-encoder subsampling.** Reduce $T$ before the joint network. Conformer and
Zipformer encoders subsample by 4× or more in their convolutional front end, so a
1000-frame input becomes 250 encoder steps. This is a 4× memory saving for free, and
it is why every production transducer has a strided front end. It also directly
raises emission granularity: with 4× subsampling your output timestamps are quantised
to 40 ms.

**Pruned loss.** Observe that the vast majority of the lattice carries negligible
probability — the plausible alignments occupy a narrow band around the diagonal. The
`k2` pruned transducer loss first computes a cheap "trivial joiner" pass to find that
band, then evaluates the full joint network only on a small number of $u$ positions
per $t$. This turns $T \times U$ into $T \times s$ for a small constant $s$, and it is
what makes transducer training tractable on ordinary hardware. It is the single most
important engineering contribution to transducer practicality.

**Stateless prediction network.** The predictor does not need to be an LSTM over all
history. Ghodsi et al. showed that a small embedding over only the last one or two
labels performs comparably. This does not reduce the lattice, but it removes recurrent
state from the decoder, which makes batched beam search dramatically simpler and
makes the predictor cheap enough to call inside a tight decoding loop.

A fourth variant worth knowing: **factorised / hybrid autoregressive transducer
(HAT)**, which separates the blank probability from the label distribution so that an
internal language-model score can be estimated and subtracted. This matters when you
want to fuse an external LM properly rather than double-counting the transducer's
implicit one.

### 2.6 Decoding

**Greedy.** At each $t$, evaluate the joint network; if the argmax is blank, advance
time; otherwise emit the label, update the predictor state, and stay at $t$. Two
details are load-bearing: you must cap the number of consecutive label emissions per
frame or a confident model can loop forever, and the predictor state must be updated
only on real emissions.

**Beam search.** Maintain a set of hypotheses, each with its own predictor state.
Because expansion at a single $t$ can emit multiple symbols, the naive algorithm has
an unbounded inner loop; practical versions cap expansions per frame and merge
hypotheses with identical label sequences. The cost driver is that **each hypothesis
needs its own predictor forward pass**, which is why stateless predictors help so
much, and why greedy decoding is common in production even at a small WER cost.

**Blank skipping.** Trained transducers emit blank for the large majority of frames.
If a cheap check (a small blank-only head, or a CTC head used as a gate) predicts
blank confidently, skip the full joint evaluation. This is a substantial inference
saving and is used in production runtimes.

### 2.7 The comparison that matters

| | CTC | RNN-T | Attention (AED) |
|---|---|---|---|
| Output dependencies | none | yes, via predictor | yes, via decoder |
| Native streaming | yes | yes | no (needs modification) |
| $U > T$ possible | no | yes | yes |
| Alignment | monotonic, implicit | monotonic, explicit lattice | unconstrained, can fail |
| External LM needed | usually | optional | optional |
| Training memory | $B{\times}T{\times}V$ | $B{\times}T{\times}U{\times}V$ | $B{\times}U{\times}V$ |
| Decoding cost | very low | low (greedy) to high (beam) | high |
| Typical use | fast/on-device, gating | streaming production ASR | offline, high accuracy |

The row that decides architecture for a voice agent is *native streaming*, and the
row that decides your training budget is *training memory*. RNN-T wins the first and
loses the second, which is exactly why the pruned loss exists.

---

## 3. From scratch

A complete transducer loss over the lattice, verified against
`torchaudio.functional.rnnt_loss`. Standalone; the torch import is used only for the
reference check.

```python
"""RNN-T loss over the T x U lattice, log-space, verified against torchaudio."""
import numpy as np

def logaddexp(a, b):
    m = max(a, b)
    return -np.inf if m == -np.inf else m + np.log(np.exp(a - m) + np.exp(b - m))

def rnnt_loss(logp, y, blank=0):
    """logp: (T, U+1, V) log-probabilities from the joint network.
    y: (U,) target labels. Returns (loss, alpha, beta).

    Two moves only: emit blank -> advance time; emit y[u] -> advance label.
    """
    T, U1, V = logp.shape
    U = U1 - 1

    # alpha(t,u) = log P(reach node (t,u))
    alpha = np.full((T, U1), -np.inf)
    alpha[0, 0] = 0.0
    for t in range(T):
        for u in range(U1):
            if t == 0 and u == 0:
                continue
            v = -np.inf
            if t > 0:                                    # arrived by advancing time
                v = logaddexp(v, alpha[t - 1, u] + logp[t - 1, u, blank])
            if u > 0:                                    # arrived by emitting y[u-1]
                v = logaddexp(v, alpha[t, u - 1] + logp[t, u - 1, y[u - 1]])
            alpha[t, u] = v

    # beta(t,u) = log P(complete the target from node (t,u))
    beta = np.full((T, U1), -np.inf)
    beta[T - 1, U] = logp[T - 1, U, blank]               # final blank terminates
    for t in range(T - 1, -1, -1):
        for u in range(U1 - 1, -1, -1):
            if t == T - 1 and u == U:
                continue
            v = -np.inf
            if t < T - 1:
                v = logaddexp(v, logp[t, u, blank] + beta[t + 1, u])
            if u < U:
                v = logaddexp(v, logp[t, u, y[u]] + beta[t, u + 1])
            beta[t, u] = v

    return -beta[0, 0], alpha, beta

def logsumexp(vals):
    v = np.array([x for x in vals if x > -np.inf])
    if v.size == 0:
        return -np.inf
    m = v.max()
    return m + np.log(np.exp(v - m).sum())

if __name__ == "__main__":
    rng = np.random.default_rng(3)
    T, U, V = 6, 3, 5
    logits = rng.standard_normal((T, U + 1, V))
    logp = logits - np.log(np.exp(logits).sum(-1, keepdims=True))
    y = np.array([1, 3, 2])

    loss, alpha, beta = rnnt_loss(logp, y)
    print(f"numpy RNN-T loss = {loss:.10f}")

    # Correct invariant: every path crosses exactly one node per anti-diagonal,
    # because every complete path has length T+U. Pointwise alpha+beta does NOT
    # equal -loss here -- not all paths visit all nodes.
    worst = 0.0
    for k in range(T + U):
        nodes = [alpha[t, k - t] + beta[t, k - t]
                 for t in range(T) if 0 <= k - t <= U]
        if nodes:
            worst = max(worst, abs(logsumexp(nodes) + loss))
    print(f"max anti-diagonal deviation from -loss = {worst:.3e}")

    try:
        import torch, torchaudio
        lg = torch.tensor(logits[None], dtype=torch.float32).log_softmax(-1)
        ref = torchaudio.functional.rnnt_loss(
            lg,
            torch.tensor(np.array([y]), dtype=torch.int32),
            torch.tensor([T], dtype=torch.int32),
            torch.tensor([U], dtype=torch.int32),
            blank=0, reduction="none")
        print(f"torchaudio       = {ref.item():.10f}   abs diff = {abs(ref.item()-loss):.3e}")
    except ImportError:
        print("torchaudio unavailable; anti-diagonal check above still validates the DP")
```

Measured output `[MEASURED]`, torch 2.13.0 / torchaudio 2.11.0 / numpy 2.5.2:

```
numpy RNN-T loss = 13.1513249204
max anti-diagonal deviation from -loss = 1.776e-15
torchaudio       = 13.1513252258   abs diff = 3.055e-07
```

The residual $3 \times 10^{-7}$ is float32 versus float64, not a disagreement — the
numpy path runs in double precision and torchaudio's kernel in single. The
$1.8 \times 10^{-15}$ anti-diagonal deviation is the real correctness signal, and it
is worth noting that it validates the dynamic programme *without any reference
implementation*: the forward and backward passes are independent computations
constrained to agree. When you port this to a new framework, that self-check is what
you write first.

---

## 4. How production does it

**`k2-fsa/icefall`** is where to read a real transducer. Its Zipformer-Transducer
recipes are the current reference for streaming ASR quality, and they combine every
mitigation in §2.5: a subsampling encoder, the pruned loss from `k2`, and a stateless
predictor. The recipe structure also shows the joint CTC+transducer training that has
become standard — a CTC head as an auxiliary loss stabilises early training and
doubles as a cheap blank gate at inference.

**`k2-fsa/sherpa-onnx`** is the deployment side: exported transducer encoders,
decoders and joiners as separate ONNX graphs, with C++ greedy and modified-beam
decoding, plus streaming servers. Reading how the encoder state is carried across
chunks is the clearest available explanation of what "streaming model" means at the
tensor level.

**`NVIDIA/NeMo`** ships transducer models (the Parakeet and Conformer-Transducer
families) with its own loss implementations, and exposes the fused
batched-decoding paths that matter for throughput.

**`torchaudio.functional.rnnt_loss`** is the reference used in §3 and is a reasonable
choice for research; it is not pruned, so §2.5's memory table applies in full.

The pattern worth extracting: production transducers separate the three networks into
independently exported graphs. That is not tidiness — it is because the encoder runs
once per chunk while the predictor and joiner run once per emitted symbol, so they
have completely different batching and caching characteristics.

---

## 5. At scale

**Training is memory-bound, inference is latency-bound, and they want opposite
things.** Training wants large $T$ and $U$ per batch for throughput; inference wants
small chunks for latency. The consequence is that you cannot infer serving cost from
training cost, and you must benchmark the exported streaming graph rather than the
training model.

**The lattice does not parallelise along its diagonal.** Both recursions have a serial
dependency, so the parallel structure is over the anti-diagonals from §2.4 — $T+U$
sequential steps, each internally parallel. GPU kernels exploit exactly this. It also
means the loss's wall-clock time grows with $T+U$ even when total work is pruned,
which is a second reason to subsample the encoder aggressively.

**Greedy decoding is why transducers serve cheaply.** One encoder pass per chunk, and
one predictor+joiner evaluation per frame plus one per emitted symbol. With blank
skipping, most frames cost only the cheap gate. Compare against attention decoding,
which needs a beam and full cross-attention per step. This asymmetry — comparable
accuracy, far lower decode cost — is the practical case for transducers in a
high-concurrency voice service ([`08-serving-asr.md`](08-serving-asr.md)).

**Emission latency is a trained property, not a config value.** A transducer is free
to delay emission to gather more acoustic context, and unregularised training will
learn to do exactly that because it lowers loss. The standard countermeasure is a
delay penalty (FastEmit and similar), which trades a small WER increase for
substantially earlier emission. This is a genuine product decision expressed as a
training hyperparameter, and it belongs in the latency budget
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md))
rather than in a model card.

**Vocabulary size is a cost multiplier in all three dimensions.** $V$ appears in the
lattice tensor, in the joiner's output projection, and in the beam's branching factor.
Word-piece vocabularies of 500–2000 are typical for transducers precisely because the
memory table in §2.5 scales linearly in $V$ — and a smaller vocabulary means longer
$U$, so there is an optimum rather than a monotone preference.

---

## 6. Exercises

**E2.3.1** Run the §3 code, then deliberately swap the two transition terms in the
forward recursion (use `y[u]` where `y[u-1]` belongs). Does the anti-diagonal check
still pass? Report the loss before and after, and explain why this class of bug is
invisible without the invariant.

**E2.3.2** Extend §3 to compute the gradient with respect to `logp` analytically
(the transducer posterior at each node), and verify it against
`torch.autograd` on the same problem. Report the maximum absolute difference.

**E2.3.3** Count the number of distinct complete paths through a $T \times U$ lattice
as a function of $T$ and $U$, in closed form. Verify your formula with a counting DP
for all $T \le 8$, $U \le 5$. How does this compare with the CTC alignment count for
the same $T$ and target length?

**E2.3.4** Reproduce the §2.5 memory table for your own configuration: a 30-second
utterance, 10 ms frames, 4× encoder subsampling, a 1000-piece vocabulary, batch 16.
Then compute the saving from 4× subsampling alone, and the further saving from pruning
to $s = 5$ label positions per frame.

**E2.3.5** Implement greedy transducer decoding against a random joint network.
Include the per-frame emission cap, and demonstrate a case where removing the cap
causes an infinite loop. Explain what property of the model produces it.

**E2.3.6** A stateless predictor sees only the last two labels. Construct a sentence
where this demonstrably loses information a full LSTM predictor would keep, then
argue why the empirical WER difference is nonetheless small.

**E2.3.7** Using the table in §2.7, write the one-paragraph architecture
recommendation you would give for each of: an on-device wake-word-to-command system;
a real-time phone agent; and an offline meeting transcription service. Each answer
must cite the row that decides it.

---

## 7. Interview drill

> "We run a streaming CTC recogniser with a 5-gram language model fused at decode
> time. WER is 11%, and the LM takes it to 7.5%. Someone proposes replacing the whole
> thing with an RNN-T. Should we?"

The reasoning an interviewer wants is that the LM's 3.5-point contribution is
*evidence*, not a nuisance. It quantifies exactly how much output-dependency
modelling your CTC model is missing, and a transducer internalises that
modelling. So the proposal is well-motivated, and the honest expectation is that
RNN-T recovers much of that gain architecturally rather than at decode time.

But the argument should not stop at accuracy, because the decisive factors are
elsewhere. **The LM buys more than WER**: shallow fusion is where contextual biasing
lives, so if that 5-gram is also how you force recognition of product or contact
names, a transducer removes the mechanism you were relying on, and you must
re-solve that problem
([`06-decoding-and-biasing.md`](06-decoding-and-biasing.md)). **Training cost changes
category**: §2.5's memory table means you now need the pruned loss and a subsampling
encoder, which is a real engineering investment rather than a config change.
**Decoding cost improves**: dropping WFST-style LM fusion for greedy transducer
decoding is a meaningful serving win, and worth quantifying alongside the WER.
**Emission latency becomes a training concern** rather than a decode parameter, so
your latency budget acquires a hyperparameter.

The strong recommendation is therefore conditional and testable: pursue it if
contextual biasing has a replacement plan and you can afford pruned-loss training,
and measure three things rather than one — WER, emission latency, and cost per audio
hour. A candidate who answers only with WER has missed that the question was about a
production system.

The senior-level addition: note that these are not exclusive. Joint CTC+transducer
training (§4) is standard practice, giving a transducer for quality and a CTC head as
a cheap blank gate and fallback — so the real recommendation may be "both heads, one
model" rather than a replacement.

---

## Sources

- Graves, A. (2012). *Sequence Transduction with Recurrent Neural Networks.* arXiv:1211.3711. The original transducer formulation, lattice and loss in §2.2–§2.3.
- Graves, A., Mohamed, A. & Hinton, G. (2013). *Speech recognition with deep recurrent neural networks.* ICASSP. Early transducer results on speech.
- Ghodsi, M., Liu, X., Apfel, J., Cabrera, R. & Weinstein, E. (2020). *RNN-Transducer with stateless prediction network.* ICASSP. The stateless predictor in §2.5.
- Kuang, F. et al. (2022). *Pruned RNN-T for fast, memory-efficient ASR training.* arXiv:2206.13236. The pruned loss in §2.5, as implemented in `k2`.
- Variani, E., Rybach, D., Allauzen, C. & Riley, M. (2020). *Hybrid Autoregressive Transducer (HAT).* ICASSP. The factorised-blank variant in §2.5.
- Yu, J. et al. (2021). *FastEmit: Low-latency streaming ASR with sequence-level emission regularization.* ICASSP. The emission-delay penalty in §5.
- Gulati, A. et al. (2020). *Conformer: Convolution-augmented Transformer for Speech Recognition.* arXiv:2005.08100. The subsampling encoder referenced throughout.
- `k2-fsa/icefall` (Zipformer-Transducer recipes), `k2-fsa/k2` (`pruned_rnnt_loss`), `k2-fsa/sherpa-onnx` (exported encoder/decoder/joiner and streaming decoding), `NVIDIA/NeMo` (Conformer/Parakeet transducers) — the production references in §4, checked 2026-08.
- `torchaudio.functional.rnnt_loss`, torchaudio 2.11.0 / torch 2.13.0 — reference implementation for the §3 comparison.
- All `[MEASURED]` values in §2.4, §2.5 and §3 were produced locally on Apple M5 / macOS 26.5.2 via `uv run --python 3.12`, numpy 2.5.2, float64 for the numpy path.
