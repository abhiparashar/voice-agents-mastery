# Decoding, Language Models, and Making ASR Hear *Your* Words

**What you'll be able to do after this:** explain why a wider beam can be worse than a
narrower one; write the shallow-fusion score and say what each term does; choose among
the four mechanisms for forcing recognition of domain vocabulary, with their
guarantees; and build a phonetic post-correction layer that recovers product names no
amount of prompting will fix.

---

## 1. Intuition

Every recogniser contains a language model whether you put one there or not. In a
classical system it was an explicit $n$-gram
([`01-from-hmm-to-e2e.md`](01-from-hmm-to-e2e.md)); in a transducer it is the
prediction network ([`03-rnnt-transducer.md`](03-rnnt-transducer.md)); in Whisper it is
the decoder, which is a language model that happens to be conditioned on audio
([`04-attention-and-whisper.md`](04-attention-and-whisper.md)). This is why ASR output
is grammatical: the model prefers word sequences it has seen.

That preference is what makes recognition work, and it is exactly what breaks on your
vocabulary. "Ozempic", "Thiruvananthapuram", your company's product names, your
customers' surnames — these are rare or absent in the training distribution, so the
model's prior actively pushes against them. It will confidently return a common word
sequence that sounds similar, because that is the correct behaviour given its beliefs.
The acoustics were fine. The prior was wrong.

**Contextual biasing** is the family of techniques for injecting the prior you actually
have. You know something the model does not: that this call is about diabetes
medication, that this user's contacts include a "Chandrasekhar", that your catalogue
contains 400 SKUs. The question is only *where* in the stack you inject it, and the
four available answers differ in a way worth being blunt about — some give you a
**preference**, and one gives you a **guarantee**.

The second idea in this chapter is that **decoding is search, and search has its own
pathologies independent of the model.** A beam search over a well-trained model can
return worse output than greedy decoding, for reasons that have nothing to do with
acoustics and everything to do with how probabilities of different-length sequences
compare. Knowing those failure modes is what lets you diagnose "the model got worse
after I widened the beam" instead of being confused by it.

---

## 2. Rigour

### 2.1 Beam search and its pathologies

For an autoregressive decoder, beam search keeps the $k$ highest-scoring partial
hypotheses at each step, scoring by cumulative log-probability:

$$s(y_{1..u}) = \sum_{i=1}^{u} \log p(y_i \mid y_{<i}, x)$$

Three pathologies follow directly from that definition.

**Length bias.** Every term in the sum is negative, so longer sequences score lower.
Beam search therefore systematically prefers short outputs, and the bias worsens as
$k$ grows because a wider beam finds more short candidates to compare. The standard
correction is length normalisation, dividing by $|y|^\alpha$ with $\alpha$ around 0.6–1.0,
or Google's NMT-style penalty $\big((5+|y|)/6\big)^\alpha$. Untuned, the visible symptom
is truncated transcripts on long utterances — which looks like an acoustic problem and
is not.

**Coverage failure.** Nothing in the objective requires the decoder to have attended
to all of the audio. An AED can emit end-of-sequence with encoder frames unconsumed,
producing a fluent transcript of the first half of the utterance. Coverage penalties —
rewarding hypotheses whose accumulated attention spans the input — mitigate this. This
is a pathology *unique to non-monotonic* architectures; CTC and transducers cannot skip
audio, because emission is tied to time advancement.

**Wider beams can be worse.** This is the counter-intuitive one, and it has two
distinct causes. The model is trained by teacher forcing to predict the next token
given *correct* prefixes, so its probabilities are miscalibrated for the unusual
prefixes a wide beam explores. And a wider beam is *more* successful at finding the
globally highest-probability sequence — which, under length bias, is often the empty
or near-empty output. Beam search working better as search can make it work worse as a
transcriber. In practice ASR beams are small (4–10); if a wider beam helps a lot, that
is evidence your length normalisation is wrong.

### 2.2 Shallow fusion

Add an external language model at decode time by combining log-probabilities:

$$s(y) = \log p_{\text{ASR}}(y \mid x) + \lambda \log p_{\text{LM}}(y) + \beta |y|$$

with $\lambda$ the fusion weight (typically 0.1–0.5) and $\beta$ a word-insertion bonus
that counteracts the LM's own length penalty. Both must be tuned together on held-out
data; tuning $\lambda$ alone reliably makes output shorter.

The conceptual problem with shallow fusion on an end-to-end model is
**double-counting**: the ASR model already contains an implicit LM learned from its
transcripts, so adding an external one applies language modelling twice. The
principled fix is **density-ratio** or HAT-style decoding, which estimates the internal
LM and subtracts it:

$$s(y) = \log p_{\text{ASR}}(y \mid x) + \lambda \log p_{\text{LM}}(y) - \mu \log p_{\text{internal}}(y)$$

For a factorised transducer the internal LM is directly estimable by running the
prediction network with the acoustic contribution removed, which is the main practical
argument for HAT-style architectures.

**Deep fusion** and **cold fusion** instead integrate the LM into the network during
training. Better in principle, and they give up the operational property that makes
shallow fusion valuable: you can swap the LM without retraining. For a production
voice agent where the domain vocabulary changes weekly, that property is usually worth
more than the accuracy difference.

### 2.3 Contextual biasing: four mechanisms, one of which is a guarantee

This is the section to remember, because the mechanisms are routinely conflated and
their guarantees differ qualitatively.

| Mechanism | Where it acts | Guarantee | Cost | Scales to |
|---|---|---|---|---|
| **Prompt / prefix conditioning** | decoder context | none — a soft nudge | tokens in the context | tens of terms |
| **Keyword boosting** | decode-time score adjustment | none — a bounded preference | small per-term | hundreds–thousands |
| **WFST class-LM composition** | the decoding graph itself | **structural** — the path exists and is cheap | graph build | thousands |
| **Phonetic post-correction** | after the transcript | none, but *independent* of the recogniser | one pass over tokens | tens of thousands |

**Prompt conditioning.** Whisper accepts `initial_prompt`, which is prepended as
decoder context, and `prefix`, which forces the start of the output. It genuinely
helps: putting "Ozempic, Metformin, Atorvastatin" in the prompt raises those tokens'
probability. Its limits are equally real: it consumes context window, has no
mechanism to *require* anything, degrades as the list grows (the model attends less to
each term), and — being decoder context — it also nudges style and can seed
hallucination, since the same channel carries "here is what to expect" and "here is
what you were just saying".

**Keyword boosting.** Add a bonus to the score of hypotheses containing a listed term,
typically implemented as a small automaton over the boost list contributing at each
token. Transducer stacks in `k2-fsa/icefall` and `k2-fsa/sherpa-onnx` support
contextual biasing and keyword spotting this way; every major hosted vendor exposes an
equivalent parameter (names vary by vendor and change between API versions, so verify
against current documentation rather than trusting an example). The important property
is that a boost is a *bounded* preference: raise it too high and you get false
insertions — the recogniser starts hearing your product name in unrelated audio. There
is a genuine precision/recall knob here, and it must be tuned per term class, because
a distinctive six-syllable drug name tolerates far more boost than a two-phoneme
brand name.

**WFST class-LM composition.** Build an automaton over your vocabulary and compose it
into the decoding graph, so the path through those words *exists with finite weight* by
construction. This is the only mechanism that provides a structural guarantee rather
than a preference, and it is why WFSTs survive in an end-to-end world
([`01-from-hmm-to-e2e.md`](01-from-hmm-to-e2e.md) §4). It requires a decoder that
searches a graph — available in `icefall`/`sherpa` and Kaldi-derived stacks, and not
available if you are calling a hosted API.

**Phonetic post-correction.** Accept the transcript, then map likely-misrecognised
spans onto your lexicon by phonetic similarity. It is the least elegant option and has
three properties that make it indispensable: it works with *any* recogniser including
hosted APIs, it scales to lexicons far larger than any prompt, and it is *independent*
of the ASR — so it catches errors the other three mechanisms missed. Implemented and
measured in §3.

In practice the right answer is usually two mechanisms in series: boosting or prompting
to raise the odds, plus post-correction to catch the residue. They fail differently,
which is exactly why they compose.

### 2.4 Inverse text normalisation

ASR models are typically trained to emit spoken-form tokens; the written form must be
produced by **inverse text normalisation** (ITN):

| Spoken form | Written form | Trap |
|---|---|---|
| "twenty twenty six" | "2026" | or "20 26", or a year, or a quantity |
| "four fifteen p m" | "4:15 PM" | vs "4.15" vs "415" |
| "forty two point five zero dollars" | "$42.50" | currency symbol placement is locale-specific |
| "double oh seven" | "007" | "double" as a digit modifier |
| "at gmail dot com" | "@gmail.com" | email/URL grammar |
| "one lakh twenty thousand" | "120,000" | Indian numbering: lakh/crore, and 1,20,000 grouping |

Two decisions matter for a voice agent, and they pull in opposite directions.

**Where ITN sits relative to the LLM.** Giving the LLM the written form makes
extraction easier ("$42.50" is unambiguous) but bakes in the ITN's mistakes. Giving it
the spoken form preserves ambiguity the LLM can resolve using context it has and the
ITN does not — it knows this is a phone number, not a year. For high-stakes slot
filling, passing the spoken form and letting the LLM normalise under a schema is
usually more robust, precisely because the LLM has the context.

**ITN is locale-specific and it is a correctness issue, not a formatting one.** An
en-IN deployment must handle lakh and crore and the 2-2-3 digit grouping, or every
monetary amount is wrong. This is the kind of requirement that never appears in a
model card ([`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md)
covers the mirror-image problem in synthesis).

**Punctuation and truecasing** are usually separate models applied to the raw
hypothesis, and they need the *whole* utterance for accuracy — a comma depends on what
follows. In a streaming agent this creates a real conflict: punctuation improves LLM
comprehension, but waiting for it delays the turn. The pragmatic resolution is to
punctuate the final transcript only, never the partials, and to accept that the LLM
must tolerate unpunctuated input if you decide to skip it.

---

## 3. From scratch

Phonetic post-correction: two independent phonetic keys, combined with orthographic
edit similarity, and a rejection threshold so ordinary words are left alone.
Standalone, stdlib only.

```python
"""Phonetic post-correction of ASR output against a domain lexicon."""
import re
from difflib import SequenceMatcher

def soundex(word):
    """Classic Soundex: first letter + 3 consonant-class digits. Coarse, and
    coarse is useful -- it is invariant to the vowel errors ASR makes most."""
    w = re.sub(r"[^a-z]", "", word.lower())
    if not w:
        return ""
    codes = {**dict.fromkeys("bfpv", "1"), **dict.fromkeys("cgjkqsxz", "2"),
             **dict.fromkeys("dt", "3"), **dict.fromkeys("l", "4"),
             **dict.fromkeys("mn", "5"), **dict.fromkeys("r", "6")}
    out, prev = "", codes.get(w[0], "")
    for ch in w[1:]:
        c = codes.get(ch, "")
        if c and c != prev:
            out += c
        if ch not in "hw":          # h and w do not break a run
            prev = c
    return (w[0].upper() + out + "000")[:4]

def metaphone_key(word):
    """Crude Metaphone: unify homophonic clusters, drop vowels, squash repeats.
    Retains more information than Soundex, so the two disagree usefully."""
    s = word.lower()
    for a, b in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("x", "ks"), ("wr", "r"),
                 ("kn", "n"), ("gh", "g"), ("ce", "se"), ("ci", "si"), ("cy", "sy"),
                 ("c", "k"), ("sh", "x"), ("ch", "x"), ("th", "0"), ("z", "s"),
                 ("v", "f"), ("y", "i")]:
        s = s.replace(a, b)
    s = re.sub(r"(.)\1+", r"\1", s)          # collapse doubled letters
    return re.sub(r"[aeiou]", "", s) or s[:1]

def ratio(a, b):
    return SequenceMatcher(None, a, b).ratio()

def correct(token, lexicon, phon_w=0.6, orth_w=0.4, threshold=0.62):
    """Return (match, score) or (None, best_score).

    Phonetic similarity dominates because ASR errors are phonetically motivated:
    'oh zenpick' is orthographically far from 'Ozempic' but phonetically close.
    Orthographic similarity is kept as a tie-breaker. The threshold is what stops
    the corrector from mangling ordinary words -- it must reject, not just rank.
    """
    tk_m, tk_s = metaphone_key(token), soundex(token)
    best = (None, 0.0)
    for cand in lexicon:
        phon = max(ratio(tk_m, metaphone_key(cand)),
                   1.0 if tk_s == soundex(cand) else 0.0)
        score = phon_w * phon + orth_w * ratio(token.lower(), cand.lower())
        if score > best[1]:
            best = (cand, score)
    return best if best[1] >= threshold else (None, best[1])

if __name__ == "__main__":
    LEXICON = ["Ozempic", "Metformin", "Atorvastatin", "Amlodipine", "Levothyroxine",
               "Kubernetes", "PostgreSQL", "Bengaluru", "Thiruvananthapuram",
               "Ahmedabad", "Chandrasekhar", "Venkataraman"]
    CASES = [("o zempic", "Ozempic"), ("oh zenpick", "Ozempic"),
             ("met foreman", "Metformin"), ("a tour of a statin", "Atorvastatin"),
             ("cuber netties", "Kubernetes"), ("post gress cue el", "PostgreSQL"),
             ("bangalore", "Bengaluru"), ("chandra shekhar", "Chandrasekhar"),
             ("venkat raman", "Venkataraman"), ("ahmed abad", "Ahmedabad"),
             ("appointment", "<none>"), ("tomorrow", "<none>")]

    print(f"{'ASR output':24s} {'expected':18s} {'predicted':18s} {'score':>6}  ok")
    hits = 0
    for asr, expected in CASES:
        # ASR splits unfamiliar names into familiar words; rejoin before matching.
        pred, score = correct(asr.replace(" ", ""), LEXICON)
        p = pred or "<none>"
        hits += (p == expected)
        print(f"{asr:24s} {expected:18s} {p:18s} {score:6.3f}  {'Y' if p == expected else 'n'}")
    print(f"\naccuracy {hits}/{len(CASES)} = {100 * hits / len(CASES):.0f}%")
```

Measured output `[MEASURED]`:

```
ASR output               expected           predicted           score  ok
o zempic                 Ozempic            Ozempic             1.000  Y
oh zenpick               Ozempic            Ozempic             0.900  Y
met foreman              Metformin          Metformin           0.937  Y
a tour of a statin       Atorvastatin       Atorvastatin        0.938  Y
cuber netties            Kubernetes         Kubernetes          0.927  Y
post gress cue el        PostgreSQL         PostgreSQL          0.900  Y
bangalore                Bengaluru          Bengaluru           0.867  Y
chandra shekhar          Chandrasekhar      Chandrasekhar       0.985  Y
venkat raman             Venkataraman       Venkataraman        0.983  Y
ahmed abad               Ahmedabad          Ahmedabad           1.000  Y
appointment              <none>             <none>              0.474  Y
tomorrow                 <none>             <none>              0.381  Y

accuracy 12/12 = 100%
```

The number to look at is not the accuracy, it is **the gap**. Correct matches score
0.867–1.000; correct rejections score 0.381–0.474. The threshold at 0.62 sits in a wide
empty band, which means the classifier is not marginal and will generalise to terms not
in this test set. If your own lexicon produces overlapping distributions, that is the
signal that your terms are too short or too similar to common words, and no threshold
will save you — you need boosting or graph composition instead.

Three engineering notes the code embodies.

**Rejection is the hard part.** A matcher that always returns its best candidate will
rewrite "appointment" into a drug name and destroy transcripts. The threshold, and
measuring the score distribution of *negatives*, is the whole safety mechanism.

**Join before matching.** ASR does not emit one wrong token; it decomposes an unknown
word into known words — "a tour of a statin". Matching token-by-token cannot recover
that. Real implementations slide a window of 1–4 consecutive tokens and match each
joined span, which is the natural extension of this code.

**Two keys are better than one.** Soundex and Metaphone fail on different inputs, and
taking the max recovers cases either alone would miss. Adding a third — a real
grapheme-to-phoneme model producing IPA, then edit distance over phonemes — is the
principled version, and it is what you graduate to when accuracy matters more than
having zero dependencies.

---

## 4. How production does it

**Whisper's prompt path.** `initial_prompt` conditions the decoder and `prefix` forces
output onset. Both are genuinely useful and neither is a guarantee. Note the coupling
described in [`04-attention-and-whisper.md`](04-attention-and-whisper.md) §2.4: the
same context channel is used by `condition_on_previous_text`, so a biasing prompt
interacts with cross-window conditioning, and a badly chosen prompt can seed the
hallucination it was meant to prevent.

**`k2-fsa/icefall` and `k2-fsa/sherpa-onnx`** implement contextual biasing and keyword
spotting for transducer models, with a boost list supplied as a text file of phrases
and a tunable score. This is the closest thing to the classical guarantee available in
a modern stack, and it is a strong argument for self-hosting when domain vocabulary is
business-critical.

**Hosted vendors** (Deepgram, AssemblyAI, Speechmatics, Google, Azure) all expose
keyword or key-term boosting on their streaming APIs. Parameter names and limits differ
and change between API versions, so verify against current documentation; the
engineering point that does not change is that these are bounded preferences with a
term-count limit, and you should measure their false-insertion rate on audio that does
*not* contain the terms. That second measurement is the one teams skip, and it is how
boosting quietly degrades general accuracy.

**ITN and punctuation** are separate models in every serious stack — NeMo ships text
normalisation and punctuation/capitalisation models; hosted APIs apply their own,
usually not configurable, which means their locale assumptions become yours. If you
operate in en-IN, test lakh/crore handling explicitly before you trust any of them.

**Post-correction in the wild** is usually the unglamorous layer that makes a
deployment work: a per-tenant lexicon of product names, contacts and place names, a
phonetic index, and a windowed matcher. It belongs in your code rather than the
vendor's, because it is where your domain knowledge lives.

---

## 5. At scale

**Per-tenant lexicons are the norm, and they are cheap in the right place.** A contact
list, a product catalogue and a place-name gazetteer differ per customer. Prompt
conditioning cannot hold thousands of terms; graph composition means rebuilding a graph
per tenant; boosting is limited by term count. Post-correction scales best because its
cost is a lookup against an index, so it is the mechanism that survives multi-tenancy
unchanged.

**Boosting has a global accuracy cost that only shows on negative audio.** Every
boosted term raises the probability of hearing it, including when it was not said. The
correct evaluation is two-sided: entity recall on audio containing the terms, and false
insertion rate on audio that does not
([`07-evaluation.md`](07-evaluation.md)). Reporting only the first is how a biasing
change ships and quietly raises overall WER.

**Beam width is a cost multiplier with a sharp diminishing return.** Each beam element
is a decoder state and, for transducers, a predictor pass. Given §2.1 — wider beams
can be worse without correct length normalisation — the practical position is a small
beam, or greedy plus post-correction, which is cheaper *and* often better for domain
terms because post-correction acts on exactly the tokens a beam would have struggled
with.

**Lexicon hygiene is an operational discipline.** A stale lexicon containing a
discontinued product name creates persistent false corrections. Version the lexicon,
measure per-term correction rates in production, and remove terms that only ever fire
incorrectly. Terms that are short, common-sounding, or near-homophones of ordinary
words should be excluded on principle, not tuned.

**Where to spend first.** For an agent mis-hearing domain vocabulary, the order that
maximises benefit per unit of work is: pin the language, add the twenty highest-value
terms to a prompt or boost list, then add post-correction with a measured threshold.
Fine-tuning the acoustic model is the last resort, not the first, because the failure
is a prior problem and fine-tuning is an expensive way to change a prior.

---

## 6. Exercises

**E2.6.1** Run the §3 code, then add "Ozempic" plus five two-syllable invented brand
names to the lexicon and re-measure the score distribution on the negative cases. At
what term length does the gap between matches and rejections close?

**E2.6.2** Extend `correct` to a windowed matcher over 1–4 consecutive tokens on a full
transcript, choosing non-overlapping spans by score. Apply it to a paragraph containing
three domain terms and two decoys, and report precision and recall.

**E2.6.3** Implement length-normalised beam scoring with the $|y|^\alpha$ penalty and
demonstrate, on a synthetic decoder, a case where beam 10 is worse than beam 1 without
normalisation and better with it.

**E2.6.4** Write the shallow-fusion score from §2.2 and grid-search $\lambda$ and
$\beta$ on a small set. Plot WER against $\lambda$ for $\beta = 0$ and for a tuned
$\beta$, and explain the difference in shape.

**E2.6.5** Build an ITN function for en-IN covering lakh, crore and 2-2-3 digit
grouping, and test it against en-US expectations on the same spoken inputs. Enumerate
every case where the two locales disagree.

**E2.6.6** Take a hosted vendor's keyword-boosting parameter. Measure entity recall on
20 utterances containing your terms and false-insertion rate on 20 that do not, at
three boost levels. Plot the two curves and pick an operating point.

**E2.6.7** For each of the four mechanisms in §2.3, state one deployment where it is
the *only* viable option, and justify from the constraints rather than from preference.

---

## 7. Interview drill

> "Our medical voice agent mis-transcribes drug names about 30% of the time. The ASR
> vendor says their WER is 5%. Both statements are true. Explain, and fix it."

The reconciliation is the first thing to say, because it demonstrates you understand
what WER measures: overall WER is dominated by common words, and drug names are a
tiny fraction of tokens. A system can be 95% correct overall and 70% correct on the
0.5% of tokens that carry all the clinical meaning. The right metric was never overall
WER; it is **entity WER** on the term class you care about
([`07-evaluation.md`](07-evaluation.md)), and the fact that nobody measured it is the
real finding.

Then the mechanism, stated as a prior problem rather than an acoustic one: the
recogniser's language model has barely seen these words, so it maps the acoustics onto
plausible common sequences — "Ozempic" becomes "oh zenpick", "Metformin" becomes "met
foreman". The audio was fine. Nothing about the acoustic model needs to change, which
is why "fine-tune on our data" is the expensive wrong answer to reach for first.

The fix is layered, and the layering is the answer. **Boost or prompt the high-value
terms** — a formulary is a few thousand entries, and the top few hundred cover most
traffic — while measuring false insertions on audio that does not contain them,
because that is the cost side of boosting and it is the check teams omit. **Add
phonetic post-correction** against the full formulary, because §2.3's guarantee table
says boosting is a bounded preference and will leave residue; §3 shows a
dependency-free implementation with a measurable rejection margin. **Consider
self-hosting a transducer with graph-level biasing** if the guarantee matters more than
the vendor's convenience, which in a medical context it plausibly does.

The senior addition is about safety rather than accuracy: in this domain a *confident
wrong* drug name is more dangerous than a refusal. So the design should carry the
correction score forward and have the agent confirm explicitly when it is low — "I
heard Ozempic, is that right?" — which converts a silent error into a conversational
repair. That is a prompt and policy decision
([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)),
and noticing that the transcript pipeline must *expose confidence* to make it possible
is the part that distinguishes a systems answer from a model answer.

---

## Sources

- Wu, Y. et al. (2016). *Google's Neural Machine Translation System.* arXiv:1609.08144 — the length and coverage penalties in §2.1.
- Gülçehre, Ç. et al. (2015). *On Using Monolingual Corpora in Neural Machine Translation.* arXiv:1503.03535 — shallow and deep fusion.
- McDermott, E., Sak, H. & Variani, E. (2019). *A Density Ratio Approach to Language Model Fusion in End-to-End Automatic Speech Recognition.* ASRU — the internal-LM subtraction in §2.2.
- Variani, E., Rybach, D., Allauzen, C. & Riley, M. (2020). *Hybrid Autoregressive Transducer.* ICASSP — factorised blank enabling internal-LM estimation.
- Le, D. et al. (2021). *Contextualized Streaming End-to-End Speech Recognition with Trie-Based Deep Biasing and Shallow Fusion.* arXiv:2104.02194 — trie-based biasing, the mechanism behind keyword boosting in §2.3.
- Pundak, G. et al. (2018). *Deep Context: End-to-End Contextual Speech Recognition.* SLT — attention-based biasing over a context list.
- `openai/whisper` — `initial_prompt` and `prefix` decoder conditioning (`whisper/decoding.py`), checked 2026-08-22.
- `k2-fsa/icefall`, `k2-fsa/sherpa-onnx` — contextual biasing and keyword spotting for transducers; `NVIDIA/NeMo` — text normalisation and punctuation/capitalisation models. Checked 2026-08.
- Vendor keyword-boosting parameters (Deepgram, AssemblyAI, Speechmatics, Google, Azure) change between API versions and are deliberately not quoted here; verify against current documentation.
- All `[MEASURED]` values in §3 were produced by the listed code on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only.
