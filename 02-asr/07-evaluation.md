# Evaluation: Measuring What Actually Matters

**What you'll be able to do after this:** compute WER correctly and explain why it can
exceed 100%; demonstrate that the *same* hypothesis scores 128.6% or 66.7% depending
only on the normaliser; name the four metrics that predict agent quality better than
WER does; and refuse to believe a 2-point improvement measured on 10 utterances,
with a bootstrap interval to prove it.

---

## 1. Intuition

Word error rate is the metric everyone quotes and almost nobody computes the same way
twice. That is not a minor annoyance — it makes cross-system comparison meaningless
unless the normalisation is specified, and it lets a vendor honestly claim a number
you cannot reproduce.

Worse, WER is only loosely related to whether your voice agent works. Consider two
recognisers on `"transfer me to Dr. Chandrasekhar in cardiology"`:

- System A: `"transfer me to Dr. Chandra Shekhar in cardiology"` — one word split,
  WER around 12%, and the agent **still routes the call correctly** if you have
  post-correction ([`06-decoding-and-biasing.md`](06-decoding-and-biasing.md)).
- System B: `"transfer me to Dr. Chandrasekhar in radiology"` — one word wrong, WER
  around 12%, and the patient is routed to **the wrong department**.

Identical WER, categorically different outcomes. WER weights every word equally, and
your product does not. It cares about entities, intents and slots — a tiny fraction of
tokens carrying nearly all the consequence.

So this chapter has two halves. First, compute WER *correctly*, because a metric
computed wrongly is worse than no metric. Then measure the things that actually
predict agent quality, and put confidence intervals on all of it — because the third
recurring failure in this field, after inconsistent normalisation and wrong metrics, is
drawing conclusions from sample sizes that cannot support them.

---

## 2. Rigour

### 2.1 WER and the alignment that defines it

WER is edit distance at the word level, normalised by reference length:

$$\mathrm{WER} = \frac{S + D + I}{N}$$

where $S$, $D$, $I$ are substitutions, deletions and insertions from the optimal
alignment, and $N = |{\text{reference}}|$. The alignment is computed by
Levenshtein dynamic programming: $O(RH)$ time and, with a backpointer matrix, a
recoverable edit path.

Measured on a realistic pair `[MEASURED]`:

```
REF: i want to reschedule my appointment for tomorrow afternoon
HYP: i wanted to schedule my appointment tomorrow at afternoon
S=4 D=0 I=0 N=9  WER=44.4%

op  ref            hyp
=   i              i
S   want           wanted
=   to             to
S   reschedule     schedule
=   my             my
=   appointment    appointment
S   for            tomorrow
S   tomorrow       at
=   afternoon      afternoon
```

Notice what the alignment did at the end: rather than reporting a deletion plus an
insertion, it chose two substitutions (`for`→`tomorrow`, `tomorrow`→`at`). Both
analyses have cost 2, and the DP is free to pick either. **The error categories are
therefore not unique even when the WER is** — which means any analysis that reasons
about the S/D/I breakdown must acknowledge the tie-breaking, and any tool that reports
"mostly substitutions" may be reporting an artefact of its traceback order.

$N$ in the denominator is the reference length, so **WER is unbounded above**.
Measured: reference `"hello"` against hypothesis `"hello hello hello hello"` gives
**300%** `[MEASURED]` — three insertions over a one-word reference. This is not a bug
and it matters practically, because a hallucinating recogniser
([`04-attention-and-whisper.md`](04-attention-and-whisper.md) §2.5) produces
four-figure WER on silent segments, which will dominate any corpus average. Report the
median utterance WER alongside the corpus WER, or a few hallucinations will make an
otherwise good system look broken — and, more dangerously, a fix that only suppresses
hallucination will look like a massive general improvement.

**Corpus WER is a weighted average, not a mean of utterance WERs.** Sum the errors and
sum the reference lengths, then divide. Averaging per-utterance WERs over-weights
short utterances, and short utterances have high variance, so the two numbers can
differ by several points on the same data.

### 2.2 The normalisation trap

This is the most consequential section in the chapter. The *same* reference and
hypothesis, scored under three progressively more aggressive normalisers `[MEASURED]`:

Reference: `I'll pay $42.50 on Feb 3rd, OK?`
Hypothesis: `i will pay forty two dollars fifty on february third ok`

| Normaliser | WER |
|---|---|
| Raw, no normalisation | **128.6%** |
| Lowercase, strip punctuation | **77.8%** |
| Also expand contractions | **66.7%** |

One transcript pair, three defensible normalisers, WERs spanning 62 points. And none
of these is yet doing the work that matters here: number verbalisation (`$42.50` ↔
`forty two dollars fifty`) and date expansion (`Feb 3rd` ↔ `february third`). A full
normaliser would drive this pair toward 0%, because the hypothesis is, as speech,
*correct*.

The lesson is blunt: **a WER without a specified normaliser is not a measurement.**
Any comparison between systems, vendors or model versions must fix the normaliser
first, and any reported number must say which one was used.

**What Whisper's normaliser actually does.** Read from
`whisper/normalizers/english.py` (main branch, 2026-08-22), `EnglishTextNormalizer`:

- **Deletes filler words** — `ignore_patterns = r"\b(hmm|mm|mhm|mmm|uh|um)\b"`.
- Applies a `replacers` dictionary of regex rewrites (contractions and common
  variants).
- Applies a British→American **spelling normaliser** from a bundled mapping.
- Calls `remove_symbols_and_diacritics(s, keep=".%$¢€£")` — strips punctuation and
  diacritics but deliberately keeps numeric symbols.
- Runs `EnglishNumberNormalizer` to standardise spelled and digit forms.

`BasicTextNormalizer` is the non-English fallback, with optional `remove_diacritics`
and `split_letters` (the latter for languages where character-level scoring is
appropriate).

Two consequences worth flagging for voice-agent work specifically.

**The filler deletion is a problem for you, not for Whisper.** For a transcription
benchmark, dropping "um" is obviously right. For a voice agent, fillers and
backchannels are *signal*: they are how you distinguish a thinking pause from a
finished turn ([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md))
and how you detect that "mhm" is an acknowledgement rather than an interruption
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)). Evaluating
your recogniser with a normaliser that erases them means you are blind to regressions
in exactly the tokens your turn-taking depends on.

**The spelling and number normalisation can hide real errors.** If your agent must
read back an amount, `$42.50` versus `$42.05` is a defect; a normaliser that maps both
to a canonical numeric form may score them identically. Which is the correct argument
for §2.3.

### 2.3 The metrics that predict agent quality

WER is a proxy. These are closer to the thing you care about.

| Metric | Definition | Why it predicts quality |
|---|---|---|
| **Entity WER** | WER restricted to a tagged term class (drug names, product names, cities, digits) | These tokens carry the action. A 5% overall WER with 30% entity WER is a broken agent ([`06-decoding-and-biasing.md`](06-decoding-and-biasing.md) §7) |
| **Slot accuracy** | Fraction of turns where every required slot was extracted correctly | The turn either accomplished its purpose or did not |
| **Semantic WER** | Embedding distance, or an LLM judging semantic equivalence | Credits paraphrases and punishes meaning changes; catches the A-versus-B case from §1 |
| **`endpoint_f1`** | Precision/recall of turn-end detection against human-labelled boundaries | Directly drives both cut-offs and dead air |
| **Latency-to-final** | Distribution of `t_eou` → `stt_final` | A budget term, and it trades against WER |
| **`barge_in_latency`** | Interrupt detected → agent audio stops | Perceived responsiveness during overlap |
| **False-barge-in rate** | Interruptions triggered by backchannels or noise | The cost side of aggressive interruption |
| **Turn success / task success** | Did the turn (or call) achieve its goal? | The only metric a business recognises |

Two definitional cautions, because these metrics are easy to compute wrongly.

**`endpoint_f1` needs an explicit tolerance.** A true positive is an endpoint detected
within $\pm\tau$ of a human-labelled boundary; without stating $\tau$ the number is
meaningless. Choose $\tau$ from the product — a couple of hundred milliseconds is
typical — and report it alongside.

**Entity WER needs the entities tagged in the *reference*, not found in the
hypothesis.** Searching the hypothesis for your term list measures only precision and
silently ignores every entity the recogniser destroyed so thoroughly it no longer
resembles the term — which is precisely the failure you are trying to detect.

### 2.4 Datasets, and the 30-minute golden set

Public benchmarks are necessary and insufficient:

| Dataset | Use | Limitation for voice agents |
|---|---|---|
| LibriSpeech | sanity baseline | Read audiobook speech, clean, wideband. Everything scores well; nothing transfers |
| Common Voice | accent robustness | Read prompts, not conversation; variable recording quality |
| AMI / ICSI | meetings, overlap | Far-field microphones, unlike a phone or headset |
| FLEURS | multilingual breadth | Read speech again |
| TEDLIUM | long-form, prepared | Monologue, not dialogue |
| Switchboard / Fisher | conversational telephone | Genuinely close for phone agents; dated audio conditions |

None of them contains your product names, your callers' accents, your codec, or your
acoustic conditions. So build a golden set, and it takes half an hour:

1. **Collect 30 utterances** spanning what your agent actually receives: the five most
   common intents, three with domain entities, three with digit strings (phone numbers,
   amounts, dates), two with background noise, two accented, two very short ("yes",
   "no"), two with a mid-sentence pause, and one with a backchannel over the agent.
2. **Record through the real path.** If production is 8 kHz telephony, your golden set
   must be 8 kHz telephony — including the codec. Evaluating on studio audio when you
   serve phone calls invalidates the whole exercise
   ([`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)).
3. **Transcribe by hand**, verbatim, with fillers and false starts preserved. Tag the
   entity spans while you are there.
4. **Fix one normaliser** and write it down.
5. **Version it.** It is a test fixture, so it belongs in the repository.

Thirty utterances will not resolve a 1-point difference (§2.5), and that is fine —
its job is to catch the 10-point regressions, which are the ones that actually happen:
a wrong sample rate, a lost biasing list, a model swap, a bad quantisation.

### 2.5 Confidence intervals, or why your improvement is noise

WER is an aggregate over a sample, so it has sampling error. The right tool is the
**bootstrap**: resample utterances with replacement, recompute corpus WER, and take
percentiles of the resulting distribution. Resample *utterances*, not words — words
within an utterance are correlated, so resampling them understates the interval.

Measured on a 10-utterance set, $B = 10{,}000$ resamples `[MEASURED]`:

```
corpus WER = 16.67%   bootstrap 95% CI = [9.26%, 25.00%]
CI width = 15.74 points
```

A 15.7-point confidence interval on a 16.7% WER. Any claim of a 2-point improvement
on this sample is indistinguishable from noise. This is the arithmetic behind a rule
worth adopting: **a WER without an interval is not evidence**, and a golden set of 30
utterances cannot support a claim finer than roughly 5–10 points.

To resolve smaller differences you need either far more data or a **paired** test.
Pairing is the cheaper win: evaluate both systems on the *same* utterances and
bootstrap the per-utterance *difference*. Much of the variance is utterance difficulty,
which is common to both systems and cancels, so a paired interval is substantially
tighter at the same sample size. If you compare systems any other way, you are
throwing away most of your statistical power.

---

## 3. From scratch

Levenshtein alignment with traceback, corpus WER, and the paired-capable bootstrap.
Standalone, numpy only.

```python
"""WER with a recoverable alignment, plus a bootstrap confidence interval."""
import numpy as np

def align(ref, hyp):
    """Levenshtein DP with backpointers. Returns (distance, ops).
    ops is a list over the alignment path: '=' match, 'S' sub, 'D' del, 'I' ins.
    Note: ties between (S) and (D,I) are broken by the option order below, so the
    S/D/I breakdown is not unique even though the distance is."""
    R, H = len(ref), len(hyp)
    D = np.zeros((R + 1, H + 1), dtype=int)
    B = np.empty((R + 1, H + 1), dtype=object)
    for i in range(R + 1):
        D[i, 0], B[i, 0] = i, "D"
    for j in range(H + 1):
        D[0, j], B[0, j] = j, "I"
    B[0, 0] = None
    for i in range(1, R + 1):
        for j in range(1, H + 1):
            if ref[i - 1] == hyp[j - 1]:
                D[i, j], B[i, j] = D[i - 1, j - 1], "="
            else:
                D[i, j], B[i, j] = min(((D[i - 1, j - 1] + 1, "S"),
                                        (D[i - 1, j] + 1, "D"),
                                        (D[i, j - 1] + 1, "I")), key=lambda x: x[0])
    i, j, ops = R, H, []
    while i > 0 or j > 0:
        op = B[i, j]
        ops.append(op)
        if op in ("=", "S"):
            i, j = i - 1, j - 1
        elif op == "D":
            i -= 1
        else:
            j -= 1
    return D[R, H], ops[::-1]

def wer_counts(reference, hypothesis):
    """Returns (errors, n_ref, ops). Errors/n_ref is the utterance WER."""
    r, h = reference.split(), hypothesis.split()
    dist, ops = align(r, h)
    return dist, max(len(r), 1), ops

def corpus_wer(pairs):
    """Sum errors, sum reference lengths, then divide. NOT a mean of WERs."""
    errs = np.array([wer_counts(r, h)[0] for r, h in pairs], dtype=float)
    lens = np.array([wer_counts(r, h)[1] for r, h in pairs], dtype=float)
    return errs.sum() / lens.sum(), errs, lens

def bootstrap_ci(errs, lens, B=10_000, alpha=0.05, seed=11):
    """Resample UTTERANCES with replacement. Words within an utterance are
    correlated, so resampling words would understate the interval."""
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(errs), (B, len(errs)))
    boot = errs[idx].sum(axis=1) / lens[idx].sum(axis=1)
    return np.percentile(boot, [100 * alpha / 2, 100 * (1 - alpha / 2)])

def print_alignment(reference, hypothesis):
    r, h = reference.split(), hypothesis.split()
    dist, ops = align(r, h)
    S, Dd, I = ops.count("S"), ops.count("D"), ops.count("I")
    print(f"REF: {reference}\nHYP: {hypothesis}")
    print(f"S={S} D={Dd} I={I} N={len(r)}  WER={100 * dist / len(r):.1f}%\n")
    i = j = 0
    for op in ops:
        a = r[i] if op in ("=", "S", "D") else ""
        b = h[j] if op in ("=", "S", "I") else ""
        print(f"{op:3s} {a:14s} {b:14s}")
        if op in ("=", "S"):
            i, j = i + 1, j + 1
        elif op == "D":
            i += 1
        else:
            j += 1

if __name__ == "__main__":
    print_alignment("i want to reschedule my appointment for tomorrow afternoon",
                    "i wanted to schedule my appointment tomorrow at afternoon")

    d, n, _ = wer_counts("hello", "hello hello hello hello")
    print(f"\nWER is unbounded above: {100 * d / n:.0f}%")

    pairs = [
        ("the appointment is on tuesday",    "the appointment is on tuesday"),
        ("i need to cancel my booking",      "i need to cancel my bookings"),
        ("call me back at four fifteen",     "call me back at four fifty"),
        ("my name is chandrasekhar",         "my name is chandra shekhar"),
        ("thanks for your help today",       "thanks for your help today"),
        ("can you transfer me to billing",   "can you transfer me to building"),
        ("what is the total amount due",     "what is the total amount do"),
        ("please send the receipt by email", "please send the receipt by e mail"),
        ("i want the earliest slot",         "i want the earliest slot"),
        ("that works perfectly for me",      "that works perfect for me"),
    ]
    point, errs, lens = corpus_wer(pairs)
    lo, hi = bootstrap_ci(errs, lens)
    print(f"\ncorpus WER = {100 * point:.2f}%   "
          f"bootstrap 95% CI = [{100 * lo:.2f}%, {100 * hi:.2f}%]  (n={len(pairs)})")
    print(f"CI width = {100 * (hi - lo):.2f} points")
```

Measured output `[MEASURED]` — the alignment table and the 300% case are reproduced in
§2.1 and §2.2; the interval:

```
corpus WER = 16.67%   bootstrap 95% CI = [9.26%, 25.00%]  (n=10)
CI width = 15.74 points
```

Look at the error set in `pairs`, because it is deliberately realistic and every entry
is a distinct failure class you should be able to name: a plural inflection
(`booking`→`bookings`, harmless), a digit error (`fifteen`→`fifty`, **changes the
appointment time**), a name split (`chandrasekhar`→`chandra shekhar`, recoverable by
post-correction), a routing error (`billing`→`building`, **wrong department**), a
function-word error (`due`→`do`, harmless), and a tokenisation difference
(`email`→`e mail`, purely a normalisation artefact).

Six errors; two are business-critical, two are harmless, one is a normaliser bug, one
is fixable downstream. WER assigns them all the same weight. That is the argument for
§2.3 in a single data structure, and it is why the first thing to add to this harness
is an entity tag per reference.

---

## 4. How production does it

**Use a standard scorer, and pin its version.** NIST `sclite` (from SCTK) is the
reference implementation and produces the alignment reports that ASR papers cite;
`jiwer` is the common Python choice; `kaldi`'s `compute-wer` remains in use. All of
them expose normalisation options that change the answer, so pin the tool version and
the option set together, in code, in the repository.

**Whisper's normaliser is the de facto standard for Whisper-family comparisons**, which
is precisely why cross-family comparisons are treacherous — its filler deletion and
number standardisation (§2.2) are choices, not neutrality. When comparing Whisper
against a vendor API, run *both* outputs through the *same* normaliser, and be aware
that you may be normalising away differences that matter to your product.

**Hosted vendor WER claims are marketing until reproduced.** They are measured on the
vendor's chosen datasets with the vendor's normaliser, typically on clean wideband
audio. The only number that means anything for your deployment is the one you measure
on your golden set through your audio path. This is not cynicism; it is the same
argument as §2.2 applied to a party with an interest.

**Continuous evaluation is what catches regressions.** Run the golden set on every
model, prompt or configuration change, in CI, and gate on the interval rather than the
point estimate. The statistical machinery for a non-flaky latency gate is the same
idea and is developed in
[`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md).

**Log what you need to evaluate later.** Audio, transcript, timing marks and the
config hash, together, per turn. Without the audio you cannot re-score; without the
config you cannot attribute a change; without the timing you cannot separate a quality
regression from a capacity problem
([`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md)).
Retention of that audio is a compliance decision, not a technical one
([`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)).

---

## 5. At scale

**Human transcription is the cost floor, so spend it deliberately.** Verbatim
transcription runs several times real time, which makes a large golden set genuinely
expensive. The efficient strategy is stratified: a small, hand-verified set for
regression gating, plus a large auto-scored set using a stronger offline model as
pseudo-reference for *relative* comparisons. The pseudo-reference cannot establish
absolute WER — it inherits the strong model's errors — but it detects large relative
regressions cheaply, which is most of what CI needs.

**Sample selection biases everything.** Evaluating on turns your agent already handled
successfully measures nothing. Deliberately over-sample the failures: turns where the
user repeated themselves, turns followed by an escalation, turns with low ASR
confidence, and turns where the agent asked for clarification. These are also the turns
where labelling effort pays back most.

**Entity WER needs an entity inventory, and that is a data-engineering task.** Tagged
references, versioned alongside the lexicon
([`06-decoding-and-biasing.md`](06-decoding-and-biasing.md) §5), per tenant if your
vocabulary is per tenant. Teams skip this and then cannot answer whether a biasing
change helped, which is the whole point.

**Report distributions, not points, and separate the modes.** A single p50 WER hides
that phone calls score worse than web calls, that accented speech scores worse, and
that hallucination on silence produces four-figure outliers (§2.1). Segment by codec,
locale and turn length, and report each; the aggregate is the least informative view
of your system.

**Guard against the metric you optimise.** If you tune only on WER, you will happily
accept a change that improves function words and degrades digits, because the arithmetic
rewards it. Gate on entity WER and slot accuracy *as well*, so that the thing being
optimised is the thing you want.

---

## 6. Exercises

**E2.7.1** Run the §3 code, then find a reference/hypothesis pair where the traceback
reports 2 substitutions and an equally optimal alignment reports 1 deletion plus 1
insertion. Explain which analysis a human would prefer and what that implies for
error-category reporting.

**E2.7.2** Implement four normalisers of increasing aggressiveness — raw, case and
punctuation, contraction expansion, and number/date verbalisation — and score the §2.2
pair under all four. Report the full spread and state which normaliser you would adopt
for a voice agent, with the reason.

**E2.7.3** Implement entity WER: tag the entity spans in the ten references from §3,
then compute overall and entity WER separately. Construct a hypothesis set where
overall WER improves while entity WER degrades.

**E2.7.4** Implement the **paired** bootstrap over per-utterance differences between
two systems. Compare its interval width against two independent unpaired intervals on
the same data, and quantify the gain in statistical power.

**E2.7.5** Compute the sample size needed to resolve a 1-point WER difference at 95%
confidence, given the per-utterance error variance in the §3 set. Then state what that
implies about the 30-utterance golden set in §2.4.

**E2.7.6** Add one hallucinated segment (30 words of invented text against a 3-word
reference) to the §3 corpus. Report corpus WER before and after, and the median
utterance WER before and after. Which statistic survives, and what does that tell you
about which to gate on?

**E2.7.7** Build the golden set from §2.4 for a domain of your choosing, through a real
audio path. Report WER with a bootstrap interval, entity WER, and the distribution of
latency-to-final. Then state the smallest improvement your set can detect.

---

## 7. Interview drill

> "A vendor tells you their WER is 4.8% and your current system is 7.2%, so switching
> will cut errors by a third. Interrogate that."

Almost nothing in that sentence is comparable yet, and a good answer works through the
reasons in order of how much they can move the number.

**Normalisation first**, because §2.2 showed a 62-point swing on a single pair from
normaliser choice alone. Were both numbers produced by the same scorer with the same
options? If the vendor's pipeline expands numbers and deletes fillers and yours does
not, the entire 2.4-point gap can be an artefact, and this is the cheapest thing to
check.

**Then the data.** Which utterances? Almost certainly not yours. If your traffic is
8 kHz telephony with accented speakers and theirs is clean wideband read speech, the
two numbers describe different problems. And the golden-set discipline from §2.4 says
the only comparable measurement is both systems on *your* audio through *your* path.

**Then the interval.** §2.5 measured a 15.7-point interval on 10 utterances. Ask for
$n$ and a confidence interval; if the evaluation set is small, a 2.4-point difference
may be noise. And insist on a *paired* comparison on identical utterances, which is
both tighter and the only fair test.

**Then the metric.** Even granting the number, overall WER may not be the thing that
determines whether your agent works. Entity WER on your domain vocabulary is the
metric that predicts routing and slot-filling correctness, and a vendor with better
overall WER can be worse on your product names — which is exactly the situation in
[`06-decoding-and-biasing.md`](06-decoding-and-biasing.md) §7. Ask whether the vendor
supports keyword boosting, and evaluate with it enabled, since that is how you would
actually run it.

**Finally, the things WER cannot see.** Latency-to-final, partial stability and whether
finals are monotonic ([`05-streaming-asr.md`](05-streaming-asr.md)) all affect the
agent's felt quality and appear nowhere in a WER figure. A recogniser that is 2 points
better and 300 ms slower to finalise is a worse voice agent.

The proposal to close on is concrete: build the golden set, run both systems paired
through the production audio path with biasing configured as you would deploy it,
report entity WER and latency-to-final alongside overall WER with bootstrap intervals,
and decide on that. That is roughly a day of work and it replaces a marketing claim
with a measurement.

---

## Sources

- `openai/whisper`, `whisper/normalizers/english.py` and `whisper/normalizers/basic.py` (main branch, retrieved 2026-08-22) — `EnglishTextNormalizer` with `ignore_patterns = r"\b(hmm|mm|mhm|mmm|uh|um)\b"`, the `replacers` map, `EnglishNumberNormalizer`, `remove_symbols_and_diacritics(s, keep=".%$¢€£")`, the bundled spelling normaliser, and `BasicTextNormalizer`'s `remove_diacritics` / `split_letters` options, all as described in §2.2.
- NIST SCTK / `sclite` — the reference WER scorer and alignment report format.
- `jiwer` — the common Python WER implementation referenced in §4.
- Bisani, M. & Ney, H. (2004). *Bootstrap estimates for confidence intervals in ASR performance evaluation.* ICASSP — the utterance-level bootstrap used in §2.5 and §3.
- Panayotov, V. et al. (2015). *LibriSpeech.* ICASSP; Ardila, R. et al. (2020). *Common Voice.* LREC; Carletta, J. et al. (2006). *The AMI Meeting Corpus*; Conneau, A. et al. (2022). *FLEURS.* arXiv:2205.12446 — the datasets tabulated in §2.4.
- All `[MEASURED]` values in §2.1, §2.2, §2.5 and §3 were produced by the listed code on Apple M5 / macOS 26.5.2 via `uv run --python 3.12 --with numpy`, numpy 2.5.2.
