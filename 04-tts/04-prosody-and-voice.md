# Prosody, Verbalisation, and Voice Ethics

**What you'll be able to do after this:** control pronunciation at the phoneme level and
know when SSML will not help; implement locale-correct verbalisation of numbers, money,
dates and phone numbers, and demonstrate why en-IN is not a translation of en-US; choose a
confirmation strategy for alphanumerics that survives a bad line; and state the consent,
disclosure and watermarking obligations that attach to a synthetic voice.

---

## 1. Intuition

A synthesiser given the string `1,234,567` has to decide what to say, and there is no
universally correct answer. In the United States it is "one million two hundred thirty four
thousand five hundred sixty seven". In India the same quantity is "twelve lakh thirty four
thousand five hundred sixty seven" — and it is *written* `12,34,567`, with different digit
grouping. This is not a formatting preference. Reading a rupee amount with American
grouping to an Indian customer is as wrong as reading the digits in the wrong order.

That example is the shape of this entire chapter. The neural model gets the *voice* right;
almost everything users complain about lives in the boring layer around it — text
normalisation, pronunciation dictionaries, locale conventions, and the decision of how to
confirm a reference number on a noisy line.

Three framing observations.

**Control has been lost and partially regained.** Classical parametric TTS was extremely
controllable: pitch, duration, and emphasis were explicit parameters, and it sounded robotic.
Neural TTS is natural and largely opaque — the prosody comes from a learned distribution you
cannot address directly. The recovered control surfaces (phoneme input, style vectors,
reference audio, speed) are narrower than what was lost, so designing around what you
*cannot* control is part of the job.

**Verbalisation is a correctness problem, not a polish problem.** A misread amount, date or
account number in a financial or medical context is a defect with consequences, and it comes
from a rule layer you own. It is also the layer that vendors implement differently and
usually do not let you configure, which is why doing it yourself is the defensible choice
([`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md) §2.4 is the
same argument in the input direction).

**A cloned voice is a legal artefact.** The moment your system speaks in a recognisable
person's voice, you have consent, disclosure and provenance obligations. These are launch
blockers rather than footnotes, and the engineering — watermarking, consent records,
disclosure prompts — has to exist before the feature ships.

---

## 2. Rigour

### 2.1 Pronunciation control

Three levers, in increasing precision.

**Text spelling tricks.** Rewriting "Ozempic" as "Oh-ZEM-pick" sometimes works. It is
fragile, engine-dependent, and pollutes your transcripts with text nobody said. Acceptable
as a stopgap.

**Phoneme input.** Most engines accept IPA or ARPAbet either inline or through a lexicon.
This is the real mechanism: you specify the phoneme sequence and the model renders it.
Because Piper and Kokoro both phonemise with `espeak-ng`
([`01-tts-architectures.md`](01-tts-architectures.md) §2.3), you can inspect the phonemiser's
output for a word, see exactly what it got wrong, and override it — a debugging loop that
neural front ends do not offer.

**Lexicon management.** A per-tenant dictionary mapping surface forms to phonemes. This is
the durable answer for product names, drug names, place names and customer surnames, and it
should be versioned alongside the ASR biasing lexicon because it is frequently the same
list of words read in the opposite direction.

**SSML** deserves a blunt assessment. The W3C standard specifies markup for emphasis,
breaks, prosody, `say-as` interpretation, and phoneme substitution. In practice support is
partial and inconsistent across engines: `<break>` and `<phoneme>` are widely honoured,
`<prosody>` is variably effective, and `<emphasis>` is often ignored. It also composes badly
with streaming, since markup spanning a chunk boundary is broken markup
([`03-streaming-tts.md`](03-streaming-tts.md)). The workable subset is breaks, phonemes and
`say-as` — and even then, verify per engine rather than assuming.

### 2.2 Verbalisation, measured

The rule layer, with locale divergence made explicit. Measured `[MEASURED]`:

**Integers**

| Value | en-US | en-IN |
|---|---|---|
| 105 | one hundred and five | one hundred and five |
| 1 250 | one thousand two hundred and fifty | one thousand two hundred and fifty |
| 120 000 | one hundred and twenty thousand | **one lakh twenty thousand** |
| 1 234 567 | one million two hundred and thirty four thousand five hundred and sixty seven | **twelve lakh thirty four thousand five hundred and sixty seven** |
| 12 345 678 | twelve million three hundred and forty five thousand six hundred and seventy eight | **one crore twenty three lakh forty five thousand six hundred and seventy eight** |

**Written grouping** — the same divergence in the visual form

| Value | en-US | en-IN |
|---|---|---|
| 1 250 | 1,250 | 1,250 |
| 120 000 | 120,000 | **1,20,000** |
| 1 234 567 | 1,234,567 | **12,34,567** |
| 12 345 678 | 12,345,678 | **1,23,45,678** |

**Currency**

| Amount | en-US | en-IN |
|---|---|---|
| 42.50 | forty two dollars and fifty cents | forty two rupees and fifty paise |
| 120 000.75 | one hundred and twenty thousand dollars and seventy five cents | one lakh twenty thousand rupees and seventy five paise |

**Phone numbers** — grouping is a *convention*, not arithmetic

| Input | en-US | en-IN |
|---|---|---|
| 415-222-9999 | four one five, two two two, nine nine nine nine | four one five two two, two nine nine nine nine |
| 9876543210 | nine eight seven, six five four, three two one zero | nine eight seven six five, four three two one zero |

Note that the divergence begins at $10^5$ — below that the two systems agree, which is
exactly why this bug survives testing. A test suite full of two- and three-digit examples
passes, and the first customer with a six-figure balance hears nonsense.

Four rules worth extracting:

- **Grouping is a locale property in both directions.** The written form and the spoken form
  must agree with each other and with the customer's expectation.
- **Digit strings are read digit-by-digit with grouping pauses**, and the grouping differs
  by locale and by number type. Reading a phone number as a quantity ("four billion one
  hundred fifty two million…") is a classic and comically bad failure.
- **"and" placement varies** even within English — British usage inserts it before the final
  group, American often omits it. Minor, and audible.
- **Zero has special cases.** "oh" for phone digits, "nought" in some registers, "zero" for
  quantities. `007` is "double oh seven", never "seven".

### 2.3 Dates, times, and other traps

| Written | Read as | Trap |
|---|---|---|
| 03/04/2026 | March fourth vs fourth of March | **US vs rest-of-world day/month order** |
| 2026 | twenty twenty six (year) vs two thousand and twenty six (quantity) | context-dependent |
| 4:15 PM | four fifteen p m | vs "quarter past four" register |
| 1st, 2nd, 3rd | first, second, third | ordinal suffixes |
| 12:00 | noon vs twelve p m | ambiguity users notice |
| ₹ / $ / £ before the digits | spoken *after* the quantity | symbol position inverts in speech |

The date order is the dangerous one because it is silently wrong rather than obviously
wrong. `03/04/2026` is unambiguous to neither the model nor the listener, and the only safe
handling is to pass structured dates through your own formatter and never let an ambiguous
string reach the engine.

The currency-symbol inversion is worth stating explicitly: `$42.50` places the symbol first
in writing and last in speech. A naive left-to-right verbaliser produces "dollars forty
two point fifty", which is the sort of error that survives to production because it is
grammatical.

### 2.4 Confirming alphanumerics

Reading a booking reference like `A7F-22K` aloud is a distinct problem, because letters are
acoustically confusable — B/D/E/P/T/V/C/G/Z form a cluster, and F/S another. On a narrowband
phone line ([`../01-foundations/01-sound-and-sampling.md`](../01-foundations/01-sound-and-sampling.md)) the
fricatives lose their distinguishing energy entirely.

Strategies, with their costs:

| Strategy | Example | Cost | Use when |
|---|---|---|---|
| Plain letters | "A seven F dash two two K" | fast, error-prone | low stakes |
| **NATO alphabet** | "Alpha seven Foxtrot…" | ~3× longer | reference numbers, spelling names |
| "as in" phrasing | "A as in Apple…" | longest, most natural to untrained listeners | consumer-facing |
| Grouped with pauses | "A seven F … two two K" | small | always, in combination |
| Read-back confirmation | agent reads, user confirms | one extra turn | irreversible actions |

Two design rules. **Use spelling alphabets for output but accept anything on input** — the
caller will say "B for bravo", "B as in boy", or just "B", and all three must parse. And
**confirm before irreversible actions, not always** — a read-back on every field is
exhausting, and the decision of where to place confirmations is a cost-of-error judgement
([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)).

### 2.5 Prosody and style control

The surfaces that actually exist:

**Speaking rate.** Usually a multiplier. Genuinely useful: slowing to 0.9× for digit strings
measurably helps comprehension, and speeding to 1.1× for boilerplate reduces call duration.
Rate is also a cost lever, since per-minute billing scales with audio duration.

**Pauses.** Inserted breaks around important information. The most reliable prosodic control
available, because `<break>` is widely honoured and because a pause is unambiguous.

**Pitch and volume.** Available in SSML, inconsistently implemented, and easy to make sound
unnatural.

**Style and emotion.** Modern engines expose either a named style, a style vector, or a
reference audio prompt. Reference-audio conditioning is the most expressive and the least
controllable — you steer by choosing an example, not by setting a value
([`02-codec-lm-tts.md`](02-codec-lm-tts.md) §2.4).

**Disfluencies.** Deliberate "um" and "so" make an agent sound more natural and buy real
latency ([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md)
§2.3). Note that LiveKit Agents enables this by default:
`DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)`, verified in
source. It is a deliberate design position, not an accident.

**Multilingual and code-switching** is the hardest case. A sentence mixing Hindi and English
requires a model trained on code-switched speech; a monolingual model will apply English
phonotactics to Hindi words and produce something recognisably wrong. If your users
code-switch — and in India they routinely do — this is a model *selection* criterion, not a
tuning parameter.

### 2.6 Consent, disclosure and provenance

Three distinct obligations that are frequently conflated.

**Consent to clone.** Using a specific person's voice requires that person's informed,
documented, revocable permission, scoped to the use. Public recordings are not consent. A
several-jurisdiction patchwork of voice-and-likeness rules is emerging, and US state-level
right-of-publicity law already covers some of this ground.

**Disclosure to the listener.** The EU AI Act's Article 50 sets transparency obligations for
AI systems that interact directly with people and for synthetic audio content, with the
practical implication that callers should be told they are speaking with an AI and that
generated audio should be marked as such. Verify current text, applicability and dates with
counsel — this chapter is not legal advice, and the compliance detail belongs in
[`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md).
The engineering consequence is concrete regardless of the legal specifics: a disclosure
utterance at call start, which must be *uninterruptible*
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md) §5 —
`allow_interruptions=False` exists for this).

**Provenance marking.** Audio watermarking embeds an imperceptible, robust signal
identifying content as synthetic. Open implementations exist — AudioSeal is the notable
one — and several hosted vendors watermark by default. Watermarking is not tamper-proof, and
it is defence in depth rather than a guarantee.

A practical policy checklist for shipping a synthetic or cloned voice:

1. Written, scoped, revocable consent from the voice owner, with a retention and deletion
   commitment for the reference audio (which is biometric data —
   [`../02-asr/09-diarization-and-speaker-id.md`](../02-asr/09-diarization-and-speaker-id.md) §5).
2. A disclosure utterance at the start of every conversation, marked uninterruptible.
3. Watermarking of generated audio, with the detector retained so you can verify your own
   output later.
4. An audit log of which voice was used for which call.
5. A revocation path: if consent is withdrawn, the voice must be removable from production
   quickly — which means it must not be baked into cached audio without a purge mechanism
   ([`03-streaming-tts.md`](03-streaming-tts.md) §2.7).
6. Refusal rules for impersonation requests, enforced in the system prompt and in
   deployment policy.

---

## 3. From scratch

Locale-aware verbalisation. Standalone, stdlib only. This is the layer that produces the
errors users report, and it is worth owning rather than delegating.

```python
"""Locale-correct verbalisation of numbers, money and phone numbers."""
import re

ONES = ("zero one two three four five six seven eight nine ten eleven twelve "
        "thirteen fourteen fifteen sixteen seventeen eighteen nineteen").split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()

def under_1000(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        t, r = divmod(n, 10)
        return TENS[t] + (" " + ONES[r] if r else "")
    h, r = divmod(n, 100)
    return ONES[h] + " hundred" + (" and " + under_1000(r) if r else "")

def say_int(n, locale="en-US"):
    """Western system groups by thousands; Indian system uses lakh (1e5) and
    crore (1e7). The two agree below 100,000 -- which is why this bug survives
    testing on small examples."""
    if n == 0:
        return "zero"
    scales = (((10**7, "crore"), (10**5, "lakh"), (1000, "thousand"))
              if locale == "en-IN" else
              ((10**9, "billion"), (10**6, "million"), (1000, "thousand")))
    parts = []
    for div, name in scales:
        if n >= div:
            q, n = divmod(n, div)
            head = say_int(q, locale) if q >= 1000 else under_1000(q)
            parts.append(f"{head} {name}")
    if n:
        parts.append(under_1000(n))
    return " ".join(parts)

def group_digits(n, locale="en-US"):
    """Written grouping. en-IN is 2-2-3 from the right, not 3-3-3."""
    if locale != "en-IN":
        return f"{n:,}"
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts + [tail])

def say_money(amount, locale="en-US"):
    """Note the symbol inversion: '$42.50' writes the unit first and SAYS it last."""
    whole = int(amount)
    frac = round((amount - whole) * 100)
    major, minor = (("rupees", "paise") if locale == "en-IN"
                    else ("dollars", "cents"))
    out = f"{say_int(whole, locale)} {major}"
    if frac:
        out += f" and {under_1000(frac)} {minor}"
    return out

def say_digits(text, locale="en-US"):
    """Digit-by-digit with grouping pauses. Grouping is a CONVENTION per locale
    and per number type -- never arithmetic."""
    d = re.sub(r"\D", "", text)
    spell = lambda s: " ".join(ONES[int(c)] for c in s)
    if len(d) == 10:
        groups = ([d[:5], d[5:]] if locale == "en-IN"
                  else [d[:3], d[3:6], d[6:]])
        return ", ".join(spell(g) for g in groups)
    return spell(d)

NATO = {"a": "Alpha", "b": "Bravo", "c": "Charlie", "d": "Delta", "e": "Echo",
        "f": "Foxtrot", "g": "Golf", "h": "Hotel", "i": "India", "j": "Juliet",
        "k": "Kilo", "l": "Lima", "m": "Mike", "n": "November", "o": "Oscar",
        "p": "Papa", "q": "Quebec", "r": "Romeo", "s": "Sierra", "t": "Tango",
        "u": "Uniform", "v": "Victor", "w": "Whiskey", "x": "X-ray",
        "y": "Yankee", "z": "Zulu"}

def say_reference(code):
    """Spelling alphabet for output. Letters are acoustically confusable, and
    narrowband telephony destroys exactly the cues that separate them."""
    out = []
    for ch in code:
        if ch.isalpha():
            out.append(NATO[ch.lower()])
        elif ch.isdigit():
            out.append(ONES[int(ch)])
        elif ch in "-/ ":
            out.append("dash" if ch == "-" else "slash")
    return " ".join(out)

if __name__ == "__main__":
    print("integers")
    for n in (105, 1250, 120_000, 1_234_567, 12_345_678):
        print(f"  {n:>10}  US: {say_int(n)}")
        print(f"  {'':>10}  IN: {say_int(n, 'en-IN')}")

    print("\nwritten grouping")
    for n in (1250, 120_000, 1_234_567, 12_345_678):
        print(f"  {n:>10}  US: {group_digits(n):>14}   "
              f"IN: {group_digits(n, 'en-IN'):>14}")

    print("\ncurrency")
    for a in (42.50, 120_000.75):
        print(f"  {a:>10}  US: {say_money(a)}")
        print(f"  {'':>10}  IN: {say_money(a, 'en-IN')}")

    print("\nphone numbers")
    for p in ("415-222-9999", "9876543210"):
        print(f"  {p:>14}  US: {say_digits(p)}")
        print(f"  {'':>14}  IN: {say_digits(p, 'en-IN')}")

    print("\nreference codes")
    for c in ("A7F-22K", "BD3-EPV"):
        print(f"  {c:>10} -> {say_reference(c)}")
```

Two notes on the implementation. `say_int` **recurses** for the Indian system, because a
crore count can itself exceed a thousand (`say_int(q, locale) if q >= 1000`) — a detail that
a flat implementation gets wrong above $10^{10}$. And `say_money` places the unit *after*
the quantity, which is the symbol inversion from §2.3 handled structurally rather than by
string manipulation.

---

## 4. How production does it

**NeMo text normalisation** (`NVIDIA/NeMo`) ships WFST-based text normalisation and inverse
normalisation with locale grammars — the industrial version of §3, and the right thing to
reach for if you need many locales rather than two.

**`espeak-ng`** is where pronunciation debugging happens for the Piper and Kokoro stacks.
Running it by hand on your product names tells you in seconds whether a lexicon entry will
fix a mispronunciation ([`01-tts-architectures.md`](01-tts-architectures.md) §4).

**Hosted engines** each implement their own normalisation, usually not configurable, and
their locale assumptions become yours. Two consequences: test lakh/crore handling explicitly
if you serve en-IN, and prefer to verbalise numbers, dates and currency **in your own code**
so the behaviour is testable and portable across engines. This is the same
own-the-critical-layer argument as post-correction on the ASR side.

**SSML support** must be verified per engine rather than assumed from the specification.
The reliable subset in practice is `<break>`, `<phoneme>` and `<say-as>`.

**Watermarking**: `facebookresearch/audioseal` is the notable open implementation, and
several hosted vendors watermark by default — worth confirming, because it affects whether
you need to add your own layer.

**LiveKit Agents** enables disfluencies by default
(`SpeechSteeringOptions(disfluencies=True)`, verified in
`livekit-agents/livekit/agents/voice/agent_session.py`, main branch, 2026-08-22) and strips
markdown and emoji before synthesis
(`DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]`). Both are framework-level
answers to problems in this chapter and the next.

---

## 5. At scale

**Verbalisation bugs are per-locale and invisible in aggregate.** A lakh error affects only
customers with balances above $10^5$ in one locale, so it will not move any aggregate metric
and will generate support tickets. Test verbalisation with a per-locale golden set of
values that specifically straddle the divergence points — $10^5$, $10^7$, decimal
boundaries, and zero.

**The pronunciation lexicon is per-tenant data with an operational lifecycle.** It needs
versioning, review, and a way to add entries without a deploy — because the request "our new
product is pronounced this way" arrives weekly. Sharing it with the ASR biasing list is
usually right, since the same names must be both heard and said.

**Rate is a cost lever with a comprehension limit.** Per-minute billing on TTS, ASR and
telephony all scale with audio duration, so a 1.1× rate is a several-percent cost reduction
across three line items. It also reduces comprehension, particularly for digit strings and
for non-native listeners, so measure task success rather than assuming it is free.

**Cache invalidation is a compliance mechanism, not just an optimisation.** If consent for a
cloned voice is withdrawn, cached audio in that voice must be purgeable. That means the cache
key must record the voice identity and you must be able to enumerate and delete by voice
(§2.6 item 5).

**Disclosure must be uninterruptible and logged.** If regulation requires telling callers
they are speaking with AI, then that utterance must actually complete — which is what
`allow_interruptions=False` is for — and you need a per-call record that it played, because
the compliance question is not "was it implemented" but "was it delivered on this call".

**Code-switching capability is a hiring-level model decision.** If your users mix languages
mid-sentence, evaluate engines on code-switched audio specifically. This will not appear in
any vendor benchmark, and a monolingual engine cannot be tuned into a multilingual one.

---

## 6. Exercises

**E4.4.1** Run the §3 code, then extend `say_int` to handle en-GB "and" placement and
compare all three locales on the same five values. Identify every difference.

**E4.4.2** Implement date verbalisation for en-US, en-GB and en-IN from a structured date,
and enumerate the ambiguities that arise if you accept `03/04/2026` as a *string* instead.
State the rule you would enforce at the API boundary.

**E4.4.3** Build a locale golden set of 30 values that straddle every divergence point in
§2.2, and write the test that asserts correct output for two locales. Which values would a
naive test suite have missed?

**E4.4.4** Implement input parsing for spelling alphabets: accept "B for bravo", "B as in
boy", "bravo" and "B" as the letter B. Test against ten realistic caller utterances.

**E4.4.5** Measure comprehension empirically: synthesise a 10-digit reference at rates
0.85×, 1.0× and 1.15×, and have three listeners transcribe it. Report accuracy per rate and
state your recommendation with the cost implication.

**E4.4.6** Take the §3 `say_reference` and evaluate it over a narrowband (8 kHz) channel by
downsampling the synthesised audio. Which letters remain confusable even with NATO words,
and why ([`../01-foundations/01-sound-and-sampling.md`](../01-foundations/01-sound-and-sampling.md))?

**E4.4.7** Write the consent and disclosure implementation plan for a cloned-voice
deployment: the data model for consent records, the disclosure utterance and its
interruption policy, the watermarking step, and the revocation procedure including cache
purge.

---

## 7. Interview drill

> "We are launching our voice agent in India. The English model sounds fine in testing. What
> will break?"

The expected weak answer is "accents". The strong answer enumerates specific, testable
failures, ordered by how badly they break the product.

**Number verbalisation, and it is the most severe.** §2.2 shows the systems diverge at
$10^5$: `1,234,567` is "twelve lakh thirty four thousand…" in en-IN, not "one million two
hundred thirty four thousand…". The written grouping also differs (`12,34,567`). For any
agent quoting balances, prices or loan amounts this is a correctness defect, and it passes
testing because small test values agree. The fix is a locale-aware verbaliser you own (§3),
plus a golden set that straddles the divergence points.

**Code-switching.** Indian English speakers routinely mix Hindi or a regional language
mid-sentence, in both directions. On output, a monolingual English model applies English
phonotactics to Hindi words; on input, the ASR must handle it too
([`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md)) and the turn
detector may be weaker on mixed speech
([`../03-turn-taking/03-semantic-turn-detection.md`](../03-turn-taking/03-semantic-turn-detection.md) §2.6).
This is a model-selection question, not a configuration one.

**Names.** Indian surnames are largely absent from English G2P dictionaries and will be
mispronounced systematically. This is a lexicon problem with a known fix and it needs to be
in scope from the start, because it affects every call.

**Narrowband telephony.** If the channel is 8 kHz, fricative cues are gone, which degrades
both recognition and the intelligibility of spelled references (§2.4,
[`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)). Spelling
alphabets become mandatory rather than optional.

**Phone-number and currency conventions.** Grouping differs (§2.2), and rupee amounts need
paise rather than cents.

The strongest version of this answer closes on process rather than a list: build a
locale-specific golden set through the real audio path, measure entity WER and task success
rather than overall WER
([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)), and treat "sounds fine in
testing" as evidence about the *voice* only — because the voice is the part the neural model
handles, and every failure above lives in the rule layer around it.

---

## Sources

- W3C *Speech Synthesis Markup Language (SSML) Version 1.1* — the markup discussed in §2.1; support in practice is partial and must be verified per engine.
- `NVIDIA/NeMo` text normalisation and inverse text normalisation (WFST-based, locale grammars) — the production reference in §4.
- `rhasspy/espeak-ng` — rule-based phonemisation used by the Piper and Kokoro stacks, §2.1 and §4.
- `facebookresearch/audioseal` — open audio watermarking, §2.6 and §4.
- Regulation (EU) 2024/1689 (the AI Act), **Article 50** — transparency obligations for AI systems interacting with natural persons and for synthetic audio content, referenced in §2.6. Applicability, timing and precise requirements must be confirmed with counsel; this chapter is not legal advice and the compliance treatment is in [`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md).
- ITU / NATO phonetic alphabet — the spelling alphabet in §2.4 and §3.
- `livekit/agents`, `livekit-agents/livekit/agents/voice/agent_session.py` (main branch, retrieved 2026-08-22) — `DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)` and `DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]`, quoted in §2.5 and §4.
- All `[MEASURED]` values in §2.2 were produced by the code in §3 on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. The verbaliser is a teaching implementation covering en-US and en-IN; a production system needs a maintained grammar library per locale.
