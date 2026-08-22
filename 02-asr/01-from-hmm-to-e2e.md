# From HMMs to End-to-End: What ASR Used to Be, and What Survived

**What you'll be able to do after this:** read any speech paper written between 1985
and 2015 without getting lost; implement Viterbi decoding and explain what it
approximates; describe the four knowledge sources a classical recogniser composed and
where each one went in the neural era; and identify which "obsolete" component your
production system is still secretly relying on.

---

## 1. Intuition

Speech recognition has one structural difficulty that image classification does not:
**you are given a 5-second recording and the words "call me back tomorrow", and
nobody tells you which frames correspond to which word.** The input has 500 frames,
the output has 4 words or 22 characters, and the mapping between them is unknown,
monotonic, and variable — "tomorrow" might occupy 40 frames or 90 depending on how
fast the speaker talks.

Every ASR architecture ever built is an answer to that alignment problem. The
classical answer, which dominated for thirty years, was: **make alignment a hidden
variable and sum over all of it**. Model speech as a sequence of hidden states that
emit acoustic observations, define which state sequences are legal, and let dynamic
programming consider every legal alignment in $O(T \cdot N^2)$ instead of the
exponential $N^T$ you would need to enumerate them. That machinery is the Hidden
Markov Model.

The second idea, equally important and more often forgotten, is **factorisation into
independent knowledge sources**. The classical recogniser did not learn "audio →
text". It learned four separate things and composed them:

| Knowledge source | Question it answers | Trained on |
|---|---|---|
| Acoustic model | What sound is this frame? | audio + phone alignments |
| Lexicon | How is this word pronounced? | hand-written dictionary |
| Language model | What words are plausible next? | text (no audio needed) |
| Phone topology | How do sounds evolve in time? | fixed by design |

This factorisation was not an aesthetic choice, it was an economic one. Transcribed
audio is expensive; plain text is nearly free. A system that learns its language
model from text can be trained on a billion words of newspaper while its acoustic
model sees 100 hours of speech. When end-to-end models arrived, they collapsed these
four into one — and the thing they gave up was exactly this ability to train each
part on the data that is cheapest for it. That tension is still live in 2026, and it
is why contextual biasing exists ([`06-decoding-and-biasing.md`](06-decoding-and-biasing.md)).

The third intuition is that **"end-to-end" removed the pipeline, not the
mathematics**. CTC is a marginalisation over alignments, exactly like the HMM forward
algorithm ([`02-ctc-from-scratch.md`](02-ctc-from-scratch.md)); RNN-T's lattice is a
close cousin of an HMM trellis; the language model is still there, now implicit in a
decoder's weights. If you understand the classical stack, the modern one reads as a
set of deliberate simplifications rather than a new invention.

---

## 2. Rigour

### 2.1 The HMM

A discrete HMM is $\lambda = (A, B, \pi)$ over $N$ hidden states:

- $a_{ij} = P(q_{t+1} = j \mid q_t = i)$ — transition probabilities, rows summing to 1.
- $b_j(o) = P(o_t = o \mid q_t = j)$ — emission (observation) probabilities.
- $\pi_i = P(q_1 = i)$ — initial state distribution.

Two assumptions do all the work, and both are false about real speech:

1. **Markov property.** $P(q_{t+1} \mid q_1 \dots q_t) = P(q_{t+1} \mid q_t)$. State
   duration is therefore geometrically distributed, which is a poor model of phone
   duration — real phones have unimodal duration distributions with a minimum.
2. **Conditional independence of observations.** Given the state, $o_t$ is
   independent of everything else. Adjacent speech frames are strongly correlated, so
   this is badly violated; it is why classical systems needed delta and
   delta-delta features (explicit derivatives) to smuggle temporal context past the
   assumption.

Being wrong in known ways is not disqualifying. The assumptions buy exact,
polynomial-time inference, and every subsequent innovation — context-dependent
states, deltas, discriminative training, then neural emissions — was a patch on one
of these two holes.

Rabiner's 1989 tutorial frames HMM usage as three problems, and the framing is still
the clearest available:

| Problem | Question | Algorithm | Cost |
|---|---|---|---|
| 1. Evaluation | $P(O \mid \lambda)$? | Forward | $O(TN^2)$ |
| 2. Decoding | Most likely state sequence? | Viterbi | $O(TN^2)$ |
| 3. Learning | Best $\lambda$ given $O$? | Baum–Welch (EM) | $O(TN^2)$ per iteration |

### 2.2 Forward and Viterbi, and the difference that matters

The forward variable $\alpha_t(j) = P(o_1 \dots o_t, q_t = j \mid \lambda)$ obeys

$$\alpha_1(j) = \pi_j b_j(o_1), \qquad
\alpha_{t}(j) = \left[\sum_{i} \alpha_{t-1}(i)\, a_{ij}\right] b_j(o_t)$$

and $P(O) = \sum_j \alpha_T(j)$ — the probability of the observations summed over
**all** state sequences.

Viterbi replaces the sum with a max, and adds a backpointer:

$$\delta_1(j) = \pi_j b_j(o_1), \qquad
\delta_{t}(j) = \max_{i}\left[\delta_{t-1}(i)\, a_{ij}\right] b_j(o_t), \qquad
\psi_t(j) = \arg\max_i \left[\delta_{t-1}(i)\, a_{ij}\right]$$

The single-symbol change from $\sum$ to $\max$ is the **Viterbi approximation**:
identify the best path and treat it as if it were the whole distribution. §3
quantifies the error on a toy model — the best path there accounts for only 29.3% of
the total probability — and that gap is exactly what lattice rescoring and
$n$-best rescoring later tried to recover.

Both recursions must run in log space. Emission probabilities are small numbers
multiplied $T$ times; at $T = 500$ the product underflows float64 long before the
utterance ends. In log space, products become sums and the sum in the forward
recursion becomes a `logsumexp`. This is the same numerical structure you will meet
again in CTC and RNN-T.

### 2.3 From words to states: the four-level hierarchy

A recogniser does not have one HMM; it has a hierarchy assembled at decode time.

**Phone topology.** Each phone is a small left-to-right HMM, conventionally three
states (roughly onset, steady, offset) with self-loops and no skips. Self-loops
model duration; the strict left-to-right structure enforces that sounds do not run
backwards. Three states per phone is a compromise: enough to capture a transition
into and out of a steady portion, few enough to train.

**Context dependence.** A phone's acoustics depend heavily on its neighbours — the
/k/ in "keep" and "cool" are physically different sounds, because the tongue is
already moving toward the following vowel (coarticulation). Modelling **triphones**
(left phone, centre phone, right phone) captures this, but the parameter count
explodes: 40 phones gives $40^3 = 64{,}000$ triphones, times 3 states, and most
combinations never occur in the training data.

The fix was **decision-tree state tying**: cluster triphone states by asking
phonetic questions ("is the left context a nasal?", "is the right context a front
vowel?") and share parameters within each cluster. A typical system had 64k
triphones mapped onto a few thousand tied states, called *senones*. This is a
data-driven parameter-sharing scheme, and it is the direct ancestor of what a neural
network's hidden layers do implicitly — which is a large part of why neural acoustic
models made it obsolete.

**Lexicon.** A hand-written dictionary mapping words to phone sequences, with
pronunciation variants and probabilities. Out-of-vocabulary words simply cannot be
recognised: no entry, no path through the graph. This was the hardest operational
limit of the classical era, and it is why proper nouns were a permanent problem.

**Language model.** An $n$-gram over words, $P(w_i \mid w_{i-n+1} \dots w_{i-1})$,
smoothed (Kneser–Ney being the standard) and pruned to fit in memory. Trained on
text alone.

### 2.4 Emissions: GMM, then DNN

Classically, $b_j(o)$ was a **Gaussian mixture model** over the (39-dimensional MFCC
+ delta + delta-delta) feature vector:

$$b_j(o) = \sum_{m=1}^{M} c_{jm}\, \mathcal{N}(o; \mu_{jm}, \Sigma_{jm})$$

with diagonal covariances, for two reasons: parameter count, and the fact that MFCCs
were approximately decorrelated by the DCT precisely so that diagonal covariances
were defensible ([`../01-foundations/02-time-frequency.md`](../01-foundations/02-time-frequency.md) §2.7).
This is the entire reason MFCCs beat log-mel features for thirty years, and the
reason they stopped winning the moment GMMs were replaced.

The **hybrid DNN-HMM** (Hinton et al. 2012 and the work it summarised) kept the HMM
and replaced the GMM with a neural network predicting the posterior $P(q_j \mid o_t)$
over tied states, converted to a pseudo-likelihood by dividing by the state prior:

$$b_j(o_t) \propto \frac{P(q_j \mid o_t)}{P(q_j)}$$

This one substitution cut word error rates by roughly a third on standard benchmarks
and is the moment modern ASR began. Note what it did *not* change: the lexicon, the
language model, the WFST decoder, and the need for frame-level state alignments to
train against — which had to come from an existing GMM system. Early neural ASR was
bootstrapped by the thing it replaced.

### 2.5 WFSTs: how the four sources compose

The elegant part of the classical stack. Each knowledge source becomes a **weighted
finite-state transducer** — a finite automaton whose arcs carry an input symbol, an
output symbol, and a weight — and the recogniser is their composition:

$$HCLG = H \circ C \circ L \circ G$$

| Transducer | Maps | Encodes |
|---|---|---|
| $G$ | words → words | the language model |
| $L$ | phones → words | the lexicon |
| $C$ | triphones → phones | context dependency |
| $H$ | HMM states → triphones | the phone topology |

Composition is an operation on automata, so the whole recogniser becomes **one**
graph from HMM states to word sequences, which can then be determinised, minimised
and weight-pushed offline. Decoding is then a single beam search over one static
graph — token passing — rather than a nest of interacting search loops.

Two properties made this dominant. It is **modular**: swap the language model,
recompose, deploy, without touching the acoustic model. And it is **exact**: the
composed graph represents precisely the intended product of the knowledge sources,
with optimisation that provably preserves the weighted language.

The costs were equally real. A composed HCLG for a large-vocabulary system is
hundreds of megabytes to gigabytes; composition is memory-hungry and slow; and the
toolchain (Kaldi's recipe scripts) required genuine expertise to operate. When an
end-to-end model reached comparable accuracy with a single training script, the
operational argument became decisive even where the accuracy argument was close.

### 2.6 Forced alignment

Fix the transcript, and Viterbi tells you *when* each phone occurred. That is
**forced alignment**: constrain the graph to the known word sequence and decode for
the best state sequence. It was originally a training necessity — you needed
frame-level targets — and it outlived its original purpose entirely.

Forced alignment is still how you get word-level timestamps good enough for
subtitles, how WhisperX assigns word times to Whisper's output, how TTS corpora are
segmented ([`../04-tts/01-tts-architectures.md`](../04-tts/01-tts-architectures.md)),
and how you measure emission latency in a streaming recogniser
([`05-streaming-asr.md`](05-streaming-asr.md)). If you take one operational tool from
the classical era, take this one.

---

## 3. From scratch

A complete Viterbi decoder with backtrace on a left-to-right phone HMM, alongside the
forward algorithm so the approximation is visible rather than asserted. Standalone,
numpy only.

```python
"""Viterbi and forward on a 3-state left-to-right HMM, in log space."""
import numpy as np

# Word "ha": state 0 = /h/, 1 = /aa/, 2 = /aa/ offset.
# Self-loop or advance only -- the standard phone topology. No skips, no going back.
A = np.array([[0.6, 0.4, 0.0],
              [0.0, 0.7, 0.3],
              [0.0, 0.0, 1.0]])
pi = np.array([1.0, 0.0, 0.0])
# Four discrete observation symbols standing in for quantised feature vectors.
B = np.array([[0.5, 0.3, 0.1, 0.1],    # /h/      prefers symbol 0 (fricative noise)
              [0.1, 0.2, 0.5, 0.2],    # /aa/     prefers symbol 2 (voiced, low F1)
              [0.1, 0.1, 0.3, 0.5]])   # /aa/-off prefers symbol 3
obs = [0, 0, 2, 2, 3, 3]

T, N = len(obs), A.shape[0]
# Log space is mandatory: emissions multiply T times and underflow float64 fast.
lA, lB, lpi = np.log(A + 1e-300), np.log(B), np.log(pi + 1e-300)

def logsumexp(v):
    m = v.max()
    return -np.inf if m == -np.inf else m + np.log(np.exp(v - m).sum())

# ---- Viterbi: max over paths, with backpointers
delta = np.full((T, N), -np.inf)
psi = np.zeros((T, N), dtype=int)
delta[0] = lpi + lB[:, obs[0]]
for t in range(1, T):
    for j in range(N):
        score = delta[t - 1] + lA[:, j]      # arrive at j from any i
        psi[t, j] = int(np.argmax(score))
        delta[t, j] = score[psi[t, j]] + lB[j, obs[t]]

best = int(np.argmax(delta[T - 1]))
path = [best]
for t in range(T - 1, 0, -1):                # backtrace
    path.append(psi[t, path[-1]])
path = [int(s) for s in reversed(path)]

# ---- Forward: sum over ALL paths. Identical recursion, sum instead of max.
alpha = np.full((T, N), -np.inf)
alpha[0] = lpi + lB[:, obs[0]]
for t in range(1, T):
    for j in range(N):
        alpha[t, j] = logsumexp(alpha[t - 1] + lA[:, j]) + lB[j, obs[t]]
total = logsumexp(alpha[T - 1])

# ---- How large is the search space we avoided?
count = np.zeros((T, N), dtype=object); count[0, 0] = 1
for t in range(1, T):
    for j in range(N):
        count[t, j] = sum(count[t - 1, i] for i in range(N) if A[i, j] > 0)

print("observations        :", obs)
print("viterbi state path  :", path)
print(f"log P(best path, O) = {delta[T-1, best]:.6f}  P = {np.exp(delta[T-1, best]):.3e}")
print(f"log P(O) all paths  = {total:.6f}  P = {np.exp(total):.3e}")
print(f"best path is {100 * np.exp(delta[T-1, best] - total):.1f}% of total probability")
print(f"legal paths ending in final state: {count[T-1, N-1]}   brute force N^T = {N**T}")
```

Measured output `[MEASURED]`:

```
observations        : [0, 0, 2, 2, 3, 3]
viterbi state path  : [0, 0, 1, 1, 2, 2]
log P(best path, O) = -7.146647  P = 7.875e-04
log P(O) all paths  = -5.918339  P = 2.690e-03
best path is 29.3% of total probability
legal paths ending in final state: 10   brute force N^T = 729
```

Three things to take from that output.

**The recovered path is the linguistically correct one.** States $[0,0,1,1,2,2]$ —
two frames of /h/, two of the vowel, two of the offset — matching the observation
sequence's structure. The model was never told where the boundaries were; dynamic
programming found them. That is forced alignment in miniature.

**The Viterbi approximation discards 70.7% of the probability mass.** The best path
carries $7.875 \times 10^{-4}$ of a total $2.690 \times 10^{-3}$. On a toy problem
with 10 legal paths this is a large relative error, and it is the entire reason
lattices exist: you keep many paths so a later, more expensive model can rescore
them. Note also that this gap is *not* a bug — for the decoding problem you often
want the single best sequence — but confusing $\max$ with $\sum$ when you need a
likelihood is a genuine error, and it is the same distinction that separates
CTC greedy decoding from the CTC loss.

**The topology shrinks the search space by 73×, from 729 to 10.** Structural
constraints — no skips, no backward transitions, must end in the final state — do
more work than any pruning heuristic. In a real recogniser the same principle is why
the composed WFST is the object you search: the graph *is* the constraint.

---

## 4. How production does it

**Kaldi** is the reference implementation of everything in §2, and its layout still
repays reading even if you never run it: `src/gmmbin`, `src/nnet3`, `egs/` recipes
that chain feature extraction, monophone training, triphone training, LDA+MLLT,
speaker adaptation and finally neural training. The reason each recipe has so many
stages is bootstrapping — each model produces the alignments that train the next.
Understanding that dependency chain explains why classical ASR was slow to iterate
on in a way no architecture diagram conveys.

**k2 / icefall / sherpa** (`k2-fsa/*`) are the modern continuation: differentiable
FSAs, so WFST-style structure composes inside a PyTorch training graph rather than
outside it. This is the interesting synthesis — you keep the exactness and
modularity of automata while training end-to-end. Zipformer recipes in `icefall`
and the deployment runtimes in `sherpa-onnx` are where transducer models
([`03-rnnt-transducer.md`](03-rnnt-transducer.md)) meet FSA decoding in practice.

**Forced alignment as a product.** The Montreal Forced Aligner packages Kaldi-based
alignment for exactly the use case that outlived the era; `WhisperX` bolts a
phoneme-level alignment model onto Whisper output to obtain word timestamps Whisper
itself does not reliably provide. If you need word-level timing, you are using
1980s technology, and correctly so.

**Where WFSTs are still load-bearing.** Contextual biasing. When you must guarantee
that a fixed list of product names, drug names or contact names is recognisable, an
automaton over that list composed into the decoding graph gives you a hard guarantee
that prompt-based approaches do not. This is why `icefall` and `sherpa-onnx` ship
contextual-biasing and keyword-spotting support, and it is covered in
[`06-decoding-and-biasing.md`](06-decoding-and-biasing.md).

**Where hybrid systems still win.** Very low-resource languages, where a
hand-written lexicon plus a text-only language model beats end-to-end training on
ten hours of audio; and domains with hard vocabulary constraints, where the
automaton's guarantee matters more than average accuracy. `[INFERENCE]` — this
reflects the structure of the argument in §1 (each knowledge source trained on its
cheapest data) rather than a specific benchmark.

---

## 5. At scale

**Decoding cost is graph search, not arithmetic.** A hybrid decoder's cost is
dominated by beam search over HCLG: hypothesis expansion, hash lookups, and pruning
— irregular, pointer-chasing, memory-latency-bound work that vectorises poorly and
lives in C++. The lesson generalises to modern systems: as encoders get cheaper, the
*search* becomes the bottleneck, which is why greedy transducer decoding is so
attractive in production ([`08-serving-asr.md`](08-serving-asr.md)).

**Graph memory was the operational tax.** A large-vocabulary HCLG is hundreds of
megabytes to gigabytes, loaded per process. That constrains how many recognisers fit
on a machine, makes cold starts slow, and makes per-customer language models
(one graph each) expensive. Neural end-to-end models replaced a gigabyte-scale graph
with a few hundred megabytes of weights that a GPU can share across streams — an
ops win at least as important as the accuracy win.

**Lattices are how you buy accuracy with latency.** Keep the top hypotheses as a
lattice, rescore with a bigger LM, and recover some of the 70% probability mass
Viterbi discarded (§3). The cost is that rescoring cannot start until the lattice
exists, which for a voice agent is a non-starter mid-turn. This is the general shape
of the tradeoff: every accuracy technique that needs the whole utterance is
unavailable to a streaming agent, which is why
[`05-streaming-asr.md`](05-streaming-asr.md) is a separate discipline rather than a
configuration flag.

**The four-source factorisation is still the right way to think about adaptation.**
When a modern voice agent mis-hears a customer's product name, the classical
diagnosis still applies: is this an acoustic problem (accent, noise, bandwidth), a
lexicon problem (the word is unseen), or a language-model problem (the word is
implausible in context)? Each has a different fix, and treating them as one
"fine-tune the model" undifferentiated blob is how teams waste months.

---

## 6. Exercises

**E2.1.1** Extend the §3 HMM to allow a skip transition from state 0 to state 2.
Recompute the Viterbi path, the total probability, and the count of legal paths.
Explain what skips model physically, and why strict left-to-right topologies are
nonetheless the default.

**E2.1.2** Implement forced alignment: given the observation sequence and the
*constraint* that the state sequence must visit all three states in order, produce
phone boundaries in frames. Then corrupt one observation and report how the
boundaries move. Which boundary is least stable, and why?

**E2.1.3** Compute, for a 40-phone inventory, the number of triphones, the number of
triphone HMM states at 3 states each, and the number of GMM parameters at 16 mixture
components with diagonal covariance over 39-dimensional features. Then compute the
same figure after tying to 4 000 senones. State the compression ratio and what it
costs you.

**E2.1.4** Take the geometric duration distribution implied by a self-loop with
probability $p$. Derive its mean and variance, then compare against a phone whose
true duration is 80 ms $\pm$ 20 ms at a 10 ms frame rate. Quantify the mismatch and
name one architecture that fixes it.

**E2.1.5** Build tiny transducers by hand for a two-word vocabulary: an $L$ mapping
phones to words and a $G$ giving a unigram LM. Compose them on paper, then verify
your composition by enumerating the accepted weighted paths in code. How many arcs
does the composition have relative to the inputs?

**E2.1.6** Using the §3 code, plot the fraction of total probability captured by the
best path as the self-loop probabilities vary from 0.5 to 0.95. Explain the trend and
what it implies about when the Viterbi approximation is safe.

**E2.1.7** For each of the four knowledge sources in §1, name where its function
lives in a modern Whisper-based voice agent, and identify the one that has no clean
counterpart. What operational problem does that absence create?

---

## 7. Interview drill

> "Why did the industry abandon HMM-based ASR, and what did it lose in the process?"

The weak answer is "neural networks are better". The strong answer separates the
accuracy story from the operational story, and then names the regression, because a
senior interviewer is testing whether you believe progress is monotonic.

On accuracy, be precise about what actually changed: the DNN-HMM hybrid (§2.4)
replaced GMM emissions and produced a step change in word error rate while keeping
the lexicon, the language model and the WFST decoder. So the neural revolution in ASR
happened *inside* the HMM framework first. Fully end-to-end models came later and
their initial advantage was not accuracy — it was that one training script replaced a
recipe with a dozen bootstrapping stages, and a few hundred megabytes of weights
replaced a multi-gigabyte decoding graph.

Then name what was lost, which is the part most candidates miss. The
factorisation into independently trainable knowledge sources went away, and with it
three concrete capabilities. **Cheap language adaptation**: you could retrain $G$ on
domain text with no audio and recompose; now you fine-tune with paired data or
manipulate prompts. **Hard vocabulary guarantees**: an automaton over your product
names either accepts them or does not, whereas a prompt-biased end-to-end model
offers a soft preference. **Free alignments**: timestamps were a by-product of
decoding, and modern systems bolt on a separate aligner to recover them.

The honest conclusion is that the field is partly walking this back, and being able
to say so with specifics is what distinguishes a real answer: k2/icefall put
differentiable automata back inside training, every serious ASR vendor ships a
keyword-boosting API that is contextual biasing under a new name, and WhisperX exists
because forced alignment was too useful to lose. The design principle worth stating
explicitly: **the more knowledge you fold into a single set of weights, the harder it
becomes to change one thing without retraining everything** — and in production, the
ability to change one thing cheaply is often worth more than a point of WER.

---

## Sources

- Rabiner, L. R. (1989). *A tutorial on hidden Markov models and selected applications in speech recognition.* Proc. IEEE 77(2), 257–286. The canonical statement of the three problems and the forward/Viterbi/Baum–Welch algorithms in §2.1–§2.2.
- Rabiner, L. R. & Juang, B.-H. (1993). *Fundamentals of Speech Recognition.* Prentice Hall. Book-length treatment of everything in §2.
- Hinton, G. et al. (2012). *Deep neural networks for acoustic modeling in speech recognition: The shared views of four research groups.* IEEE Signal Processing Magazine 29(6), 82–97. The DNN-HMM hybrid result in §2.4.
- Mohri, M., Pereira, F. & Riley, M. (2002). *Weighted finite-state transducers in speech recognition.* Computer Speech & Language 16(1), 69–88. The $H \circ C \circ L \circ G$ construction in §2.5.
- Young, S. et al. *The HTK Book*; Povey, D. et al. (2011). *The Kaldi Speech Recognition Toolkit.* IEEE ASRU. Reference implementations of the classical stack.
- Jurafsky, D. & Martin, J. H. *Speech and Language Processing*, 3rd ed. draft — chapters on ASR, HMMs and $n$-gram language models; see [`../00-setup/04-reading-list.md`](../00-setup/04-reading-list.md).
- `k2-fsa/k2`, `k2-fsa/icefall`, `k2-fsa/sherpa-onnx` — differentiable FSAs, training recipes, and deployment runtimes referenced in §4.
- All `[MEASURED]` values in §3 were produced by the listed code on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2, float64.
