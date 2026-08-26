# Safety and privacy

**What you'll be able to do after this:** place a guardrail where it costs 104 ms instead of
986 ms and still leaks nothing; explain why prompt injection through speech is a different
problem from the text version; build PII redaction that survives a caller reading a card
number aloud; state what the EU AI Act's Article 50 actually requires of a voice agent and
when; and refuse to let a voiceprint become an authenticator.

---

## 1. Intuition

Three things make safety in a voice agent harder than in a chat product, and each has a
measurable consequence.

**Audio cannot be unsent.** A text guardrail can inspect a response and refuse to render
it. Once a sentence has been spoken, the user has heard it, and every mitigation is
retrospective. Measured below: a guardrail that inspects the *whole* response cannot start
until the whole response exists, so running it in series costs **+986 ms** on `ttfa` — and
running it in parallel, the usual advice, still lets **830 ms of unsafe audio** reach the
user at p50 and 1910 ms at worst. The placement that actually works is neither: gate each
clause before it is spoken, for **+104 ms** and zero leak.

**Speech is a different injection surface.** The attacker's channel is your ASR, so the
payload is acoustic. That breaks text-based filters in both directions: an instruction can
arrive as homophones your blocklist does not match, and your filter can fire on an innocent
caller because the ASR misheard them.

**The data is biometric.** A transcript is personal data; the *audio* additionally contains
a voiceprint, which several regimes treat as biometric data with a higher bar. And callers
read card numbers aloud, which puts PCI data in your recordings. Measured below, the digit
regex everybody writes first catches **14%** of spoken PII; normalising spoken digits gets
to 57%; adding carrier phrases gets to 86%; and none of them is a guarantee, which is why
the real answer is architectural rather than a better regex.

---

## 2. Rigour

### 2.1 Threat model

| Threat | Vector | Impact | Mitigation |
|---|---|---|---|
| Prompt injection via speech | caller speaks instructions | tool misuse, data exfiltration, persona break | §2.2 |
| Injection via retrieved content | poisoned KB article read into context | same, and harder to see | treat retrieved text as untrusted data, never instructions |
| Injection via tool output | a field in an API response contains instructions | same | schema-validate and escape tool results |
| Unsafe generation | model says something harmful, wrong, or legally binding | liability | §2.3 clause gating |
| PII leakage into logs | transcripts, recordings, traces | GDPR/HIPAA/PCI exposure | §2.4 |
| PII leakage to the *caller* | agent reads back another customer's data | breach | authorisation at the tool boundary, not in the prompt |
| Voice cloning of the agent | attacker impersonates your brand | fraud against your customers | disclosure, watermarking (§2.6) |
| Voice cloning of the caller | attacker defeats voice auth | account takeover | §2.7 — do not use voice as the authenticator |
| Recording without consent | consent not captured or not provable | statutory damages | §2.5 |
| Undisclosed AI | caller not told they are talking to a machine | AI Act Art. 50(1) | §2.6 |
| Denial of wallet | attacker keeps calls open, forces expensive turns | cost | per-caller rate limits, max session duration |
| Toll fraud via transfer | agent tricked into dialling a premium number | direct financial loss | allow-list transfer destinations |

Two of these are voice-specific and routinely missed. **PII leakage *to* the caller** is a
worse breach than leakage to your logs, and it happens when authorisation lives in the
prompt ("only discuss the caller's own orders") instead of in the tool. The tool must take
the authenticated identity as a parameter and enforce it server-side; a prompt is not an
access-control mechanism. And **toll fraud via transfer** is the voice analogue of SSRF: any
agent that can dial or transfer must have an allow-list, because "please transfer me to
+880..." is a payload.

### 2.2 Prompt injection through speech

The text defences mostly transfer, but three properties are new.

**The payload is acoustic, so it is fuzzy.** "Ignore previous instructions" can arrive as
*"ignore preventions instructions"* through a noisy 8 kHz channel. A blocklist of exact
strings therefore has both worse recall (the attacker's phrase mutates for free) and worse
precision (an innocent caller's misrecognised speech trips it). Any detector must operate on
semantics, and it must be evaluated against *ASR output*, not clean text
([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)).

**The attack surface includes the audio channel itself.** Audio a human does not perceive as
speech can still be transcribed as words — the adversarial-example literature on ASR is a
decade old — and a phone call can carry a second audio source, so "the TV in the background
told your agent to issue a refund" is a real scenario rather than a joke.

**Turn structure is a defence.** Unlike a chat box you control the frame: every turn is a
separate, short, attributable utterance. Two mitigations follow cheaply — **structural
separation**, where transcripts enter the context as delimited user turns and never as
system-prompt text
([`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md)),
and **confirmation before consequence**, where a state-changing tool call is confirmed aloud,
converting a silent injection into one the caller must assent to.

The mitigation that matters most is the one that does not involve the model at all:
**capability limits at the tool boundary**. If the refund tool caps at $50 and requires the
authenticated account ID, then a successful injection costs $50 and cannot touch another
customer ([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)).
Assume injection succeeds sometimes and bound the damage.

### 2.3 Guardrail placement, measured

`[MEASURED]` from §3 — 20 000 turns, a guardrail costing 180 ms on a full response or 108 ms
on a single clause, 0.4% of responses unsafe:

| Placement | ttfa p50 | ttfa p95 | vs streaming | Leak p50 | Leak p95 | Worst | Unsafe heard |
|---|---|---|---|---|---|---|---|
| streaming, no guardrail | 784 ms | 1279 ms | +0 ms | 4671 ms | 7507 ms | 8326 ms | 100% |
| serial | 1770 ms | 2489 ms | **+986 ms** | 0 ms | 0 ms | 0 ms | 0% |
| parallel | 781 ms | 1277 ms | −2 ms | **830 ms** | 1640 ms | 1910 ms | **95%** |
| **clause-gated** | 888 ms | 1383 ms | **+104 ms** | **0 ms** | 0 ms | 0 ms | **0%** |

Read the serial row first. Its cost is **not** the guardrail's 180 ms — it is 986 ms, because
a guardrail that inspects the whole response cannot start until the whole response has been
generated, which destroys clause-level streaming
([`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md)). This is the single most
common mistake: teams budget for the classifier's latency and pay for the loss of streaming.

Now the parallel row, because it refutes the standard advice. Running the guardrail
concurrently is indeed nearly free on latency (−2 ms), and it **does not work**: the verdict
arrives after generation completes, by which time 830 ms of unsafe audio has been spoken at
p50, and 95% of unsafe turns leak something. Parallel guardrails are the right pattern for
*non-blocking* concerns — logging, analytics, post-hoc review, offline scoring — and the
wrong pattern for anything whose whole purpose is to prevent the user hearing something.

**Clause gating dominates.** Check each speakable clause before it is synthesised: 104 ms of
added latency, roughly a tenth of serial, and zero leak. It works because the unit of
checking matches the unit of streaming, and because a single clause is short enough that the
classifier is cheap. The costs are real but bounded: you run the classifier N times per
response instead of once, and a mid-response rejection needs a graceful recovery rather than
a hard stop, which is the fallback ladder from
[`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md).

The general rule: **put a guardrail in series with the thing it gates, and make the gated
unit small.** In parallel, only for what you do not need to block. Two corollaries: **input**
guardrails (is this turn an injection attempt?) run while the LLM is already prefilling, so
they are nearly free and should block; and every guardrail must **fail open**, because one
that can hang the agent is a worse availability risk than the content it was filtering.

### 2.4 PII redaction on speech

`[MEASURED]` from §3 — ten transcripts, three detector tiers:

| Detector | Recall | Precision |
|---|---|---|
| digits-only regex | **14%** | 100% |
| spoken-digit aware | 57% | 100% |
| spoken + carrier phrase | **86%** | 100% |

The failures of tier 1 are not exotic. `"my number is four one five five five five one two
one two"` contains a full phone number and not a single digit character, so a regex written
for typed input finds nothing. Tier 2 normalises spoken digit words — including `oh` for
zero and `double`/`triple` multipliers, both of which callers use constantly — and gets to
57%. Tier 3 adds the carrier phrase (`card`, `pin`, `account`, `zip`, `date of birth`) and
reaches 86%, because short runs like a four-digit PIN or a five-digit ZIP are only PII in
context.

The remaining miss in the measurement is instructive: `"date of birth is oh three eleven
nineteen ninety"` mixes digit-words with *number-words* (`eleven`, `nineteen ninety`), which
needs full spoken-number normalisation — the same inverse-text-normalisation problem as
[`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md), and the same
reason it is never finished.

So the engineering conclusion is architectural, not regex-shaped:

- **Do not capture what you cannot protect.** For card data, hand the caller to DTMF entry
  or a payment IVR and never let the digits reach your ASR. PCI DSS treats a recording
  containing sensitive authentication data as in-scope, and the cheapest way to stay out of
  scope is to not have it. Note that DTMF has its own trap: in-band DTMF puts loud tones in
  the audio you are recording ([`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)).
- **Pause the recording, not just the transcript.** If a caller will speak PII, stop
  recording audio for that span. Redacting the transcript while keeping the audio is
  theatre.
- **Redact at the earliest boundary and everywhere after it.** ASR output, LLM context,
  logs, traces, metrics labels, the analytics warehouse, and the vendor's side. A
  transcript redacted in your database but sent verbatim to three model vendors is not
  redacted.
- **Treat redaction as defence in depth.** 86% recall is useful and is not a control you can
  certify against.

### 2.5 Consent, recording, and retention

The rules that actually change designs, with the caveat that this is engineering guidance
and not legal advice.

| Regime | What it requires | Design consequence |
|---|---|---|
| **GDPR** (EU 2016/679) | lawful basis; Art. 9 special-category data includes biometrics *used for unique identification*; data minimisation; erasure | if you do voice *identification*, you likely need explicit consent; retention must be bounded and deletion must actually delete the audio |
| **EU AI Act** (2024/1689) Art. 50 | disclosure of AI interaction; marking of synthetic audio; notice for emotion recognition | §2.6 |
| **Two-party consent** (e.g. CA, PA, FL, IL, WA and others in the US) | all parties must consent to recording | announce recording and capture consent *before* the first recorded frame; per-jurisdiction routing |
| **HIPAA** (US) | PHI safeguards, BAAs with every processor | every model vendor in the path needs a BAA, which constrains vendor choice |
| **PCI DSS** | do not store sensitive authentication data; recordings are in scope | never let card data reach the recording (§2.4) |
| **TCPA** (US) | consent for automated outbound calls | outbound campaigns need a consent record per number, and an opt-out that works |

Four implementation notes that follow from the table rather than from any one rule.

**Consent must precede the first recorded frame.** That means the disclosure is spoken before
recording starts, and the consent decision gates recording — not the other way round. It is
a state machine, and getting it backwards is the common bug.

**Retention differs per artefact, and audio is the expensive one.** Metrics for a year,
traces for days, transcripts for as long as you have a reason, audio for as short as you can
manage ([`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md)).
Deletion must reach backups, vendor-side storage and the derived copies in your warehouse,
which is why "we'll add deletion later" is expensive.

**Jurisdiction is a routing decision.** Two-party-consent states and EU data residency both
imply that where the call lands determines what you must do and where the data may live —
and residency can override the latency arithmetic in
[`../06-realtime-systems/08-deployment.md`](../06-realtime-systems/08-deployment.md).

**Every model vendor is a processor.** The ASR, TTS and LLM providers all receive personal
data. Their retention defaults, training-on-your-data defaults, and sub-processor lists are
part of your compliance posture. Zero-retention and BAA tiers exist and cost money — the
$1k–2k/month figures previously noted for ZDR and HIPAA add-ons are the shape of it
([`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md)).

### 2.6 What Article 50 requires

Verified against Regulation (EU) 2024/1689, Article 50, which enters into force on
**2 August 2026** per Article 113.

**Art. 50(1) — disclosure.** Providers must ensure that AI systems "intended to interact
directly with natural persons are designed and developed in such a way that the natural
persons concerned are informed that they are interacting with an AI system, unless this is
obvious from the point of view of a natural person who is reasonably well-informed,
observant and circumspect". For a voice agent good enough to be mistaken for a person, the
"obvious" exemption is exactly the one you cannot rely on — and the better your agent, the
less you can rely on it.

**Art. 50(5) — timing.** The information "shall be provided … in a clear and distinguishable
manner at the latest at the time of the first interaction or exposure", and "shall conform to
the applicable accessibility requirements". So the disclosure belongs in the greeting, not in
a terms-of-service document, and it must be *audible* — which puts it directly in the
latency budget of the most sensitive moment of the call.

**Art. 50(2) — marking synthetic audio.** Providers of systems "generating synthetic audio,
image, video or text content" must ensure outputs "are marked in a machine-readable format
and detectable as artificially generated or manipulated", with technical solutions that are
"effective, interoperable, robust and reliable as far as this is technically feasible". This
is an obligation on the *provider* of the generating system, so if you use a third-party TTS
it is largely theirs — but you should know whether your engine watermarks, because the
obligation follows the generation
([`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md)).

**Art. 50(3) — emotion recognition.** Deployers of "an emotion recognition system or a
biometric categorisation system shall inform the natural persons exposed thereto of the
operation of the system", and process the data under GDPR. This one is easy to trip over
without noticing: **a speech-to-speech model advertised as adapting to the user's emotional
state is arguably an emotion recognition system**, and features like affective dialogue put
you in scope for a notice you probably have not written
([`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)).
The same applies to sentiment scoring for routing or QA.

Practical shape of a compliant greeting: identify the company, state plainly that this is an
automated assistant, say that the call is recorded and why, and offer a route to a human.
That is four clauses, about three seconds, and it is the one place in the call where you
should not optimise for brevity.

### 2.7 Voiceprints are not passwords

`[MEASURED]` from §3 — a speaker verification model at 2% equal error rate, with the ROC
family through that point:

| FRR (customers locked out) | FAR (impostor admitted) | Expected tries to break in |
|---|---|---|
| 0.10% | **40.000%** | 2 |
| 1.00% | **4.000%** | **25** |
| 2.00% | 2.000% | 50 |
| 5.00% | 0.800% | 125 |
| 10.00% | 0.400% | 250 |

A 2% EER sounds strong and is a terrible access-control primitive. At a threshold loose
enough to lock out only 1% of legitimate customers — already a lot of angry calls — an
impostor gets in **once every 25 attempts**. Tighten it to 0.1% FRR and 40% of impostor
attempts succeed. There is no operating point on this curve that a security reviewer should
accept as a sole factor.

The Bayesian view shows why the naive defence fails. `[MEASURED]`:

| Prior fraud rate | FRR | FAR | P(genuine \| match) | Odds |
|---|---|---|---|---|
| 0.1% | 1% | 4.000% | 99.9960% | 24 725:1 |
| 1.0% | 1% | 4.000% | 99.9592% | 2 450:1 |
| 5.0% | 1% | 4.000% | 99.7878% | 470:1 |
| 30.0% | 1% | 4.000% | **98.2979%** | **58:1** |

"99.996% of matches are genuine" is true and misleading: it is high because the *prior* is
high, not because the model is discriminating. Under attack — which is precisely when it
matters — the prior is not 0.1%, and the odds collapse to 58:1. Worse, a replay attack does
not move along this curve at all; it defeats the model **outright**, because a recording of
the enrolled speaker is, to the model, the enrolled speaker
([`../02-asr/09-diarization-and-speaker-id.md`](../02-asr/09-diarization-and-speaker-id.md)).

So: **voice is an identity claim and a convenience factor, never the authenticator of
record.** Use it to skip a question for a low-risk action, combine it with a real factor
(knowledge, a one-time code, a device signal) for anything consequential, and require
step-up authentication before any state change. And remember that enrolling voiceprints
creates biometric data, which under GDPR Art. 9 is special-category when used for unique
identification — you have added a compliance burden in exchange for a weak factor.

---

## 3. From scratch

Guardrail placement, spoken-PII detection, and speaker-verification operating points.
Standalone, stdlib only, deterministic.

```python
"""Safety mechanisms priced honestly.

Part A -- guardrail placement. A guardrail that inspects the whole response
cannot start until the whole response exists, so putting it in series costs the
full generation time plus its own. In parallel it costs nothing up front, but
audio the user already heard cannot be unheard. Gating clause by clause is the
middle. Measure the latency and the leaked audio for each.

Part B -- PII redaction on speech. Callers say "four one five, five five five"
rather than "415-555". A digit regex tuned on typed text finds none of it, and
normalising spoken digits is necessary but not sufficient: you also need the
carrier phrase. Three tiers, measured.

Part C -- voiceprint as authentication. Speaker verification has an equal error
rate, and an EER is not an access-control policy. Compute what an operating
point means for impostors and for locked-out customers, then the posterior odds
that a caller is who they claim.

Deterministic: fixed seed, stdlib only.
"""

import math
import random
import re

SEED = 131


# --------------------------------------------------------------- Part A
def part_a(n=20_000, guard_ms=180.0, unsafe_rate=0.004, ttfb_tts=130.0):
    """Serial / parallel / clause-gated guardrail on the response path."""
    rng = random.Random(SEED)
    print(f"guardrail {guard_ms:.0f} ms on the full response "
          f"({guard_ms*0.6:.0f} ms on one clause), TTS ttfb {ttfb_tts:.0f} ms, "
          f"{unsafe_rate:.1%} of responses unsafe\n")
    print(f"{'placement':14s} {'ttfa p50':>9} {'ttfa p95':>9} {'vs stream':>10} "
          f"{'leak p50':>9} {'leak p95':>9} {'worst':>8} {'unsafe heard':>13}")
    results = {}
    for placement in ("streaming (none)", "serial", "parallel", "clause-gated"):
        ttfa, leaks = [], []
        for _ in range(n):
            stream_ttfa = rng.triangular(320, 1500, 620)   # clause-streamed
            gen_full = rng.triangular(700, 2500, 1300)     # whole text exists
            audio_dur = rng.triangular(1500, 9000, 3800)   # spoken length
            unsafe = rng.random() < unsafe_rate
            if placement == "streaming (none)":
                t, leak = stream_ttfa, (audio_dur if unsafe else 0.0)
            elif placement == "serial":
                # nothing is synthesised until the full text is cleared
                t, leak = gen_full + guard_ms + ttfb_tts, 0.0
            elif placement == "parallel":
                t = stream_ttfa
                verdict = gen_full + guard_ms
                leak = min(max(0.0, verdict - stream_ttfa), audio_dur) \
                    if unsafe else 0.0
            else:                                          # clause-gated
                t, leak = stream_ttfa + guard_ms * 0.6, 0.0
            ttfa.append(t)
            if unsafe:
                leaks.append(leak)
        ttfa.sort()
        leaks.sort()
        results[placement] = (ttfa, leaks)
    base = results["streaming (none)"][0][n // 2]
    for placement, (ttfa, leaks) in results.items():
        p50 = ttfa[len(ttfa) // 2]
        lp50 = leaks[len(leaks) // 2] if leaks else 0.0
        lp95 = leaks[int(.95 * (len(leaks) - 1))] if leaks else 0.0
        worst = leaks[-1] if leaks else 0.0
        heard = sum(1 for x in leaks if x > 0) / len(leaks) if leaks else 0.0
        print(f"{placement:14s} {p50:8.0f}ms {ttfa[int(.95*len(ttfa))]:8.0f}ms "
              f"{p50-base:+9.0f}ms {lp50:8.0f}ms {lp95:8.0f}ms {worst:7.0f}ms "
              f"{heard:12.0%}")


# --------------------------------------------------------------- Part B
SPOKEN = {"zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2",
          "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
          "eight": "8", "nine": "9"}
CARRIER = re.compile(r"\b(card|visa|mastercard|amex|pin|passcode|account|acct|"
                     r"routing|sort ?code|social|ssn|zip|postcode|cvv|security "
                     r"code|date of birth|dob|policy|member(ship)? number)\b")
DIGIT_RUN = re.compile(r"\b(?:\d[\s-]?){6,}\b")


def spoken_to_runs(text):
    """Collapse spoken digit words into digit runs, honouring double/triple."""
    runs, cur, rep = [], [], 1
    for w in re.findall(r"[a-z]+|\d+", text.lower()):
        if w == "double":
            rep = 2
            continue
        if w == "triple":
            rep = 3
            continue
        d = SPOKEN.get(w) or (w if w.isdigit() else None)
        if d:
            cur.append(d * rep)
        else:
            if cur:
                runs.append("".join(cur))
                cur = []
        rep = 1
    if cur:
        runs.append("".join(cur))
    return runs


def tier1_digits(text):
    """The regex everybody writes first: it assumes typed input."""
    return bool(DIGIT_RUN.search(text))


def tier2_spoken(text):
    """Normalise spoken digits, then look for a long run."""
    return any(len(r) >= 6 for r in spoken_to_runs(text)) or tier1_digits(text)


def tier3_context(text):
    """Normalise, then require either a long run OR a carrier phrase + digits."""
    runs = spoken_to_runs(text)
    if any(len(r) >= 6 for r in runs) or tier1_digits(text):
        return True
    return bool(CARRIER.search(text.lower())) and any(len(r) >= 3 for r in runs)


def part_b():
    cases = [
        ("my card is 4111 1111 1111 1111", True),
        ("my number is four one five five five five one two one two", True),
        ("card four one one one one one one one double one one one", True),
        ("my zip is nine four one zero seven", True),
        ("the account ends in oh oh seven seven three one", True),
        ("my pin is one two three four", True),
        ("date of birth is oh three eleven nineteen ninety", True),
        ("I called you three times about four different orders", False),
        ("it costs two hundred and fifty dollars", False),
        ("give me option two please", False),
    ]
    tiers = (("digits-only", tier1_digits), ("spoken-aware", tier2_spoken),
             ("spoken+context", tier3_context))
    print(f"{'transcript':56s} {'PII':>4} " +
          " ".join(f"{n:>15}" for n, _ in tiers))
    counts = {n: [0, 0, 0, 0] for n, _ in tiers}          # tp fp tn fn
    for text, is_pii in cases:
        cells = []
        for name, fn in tiers:
            got = fn(text)
            idx = (0 if got else 3) if is_pii else (1 if got else 2)
            counts[name][idx] += 1
            cells.append("FLAG" if got else "-")
        show = text if len(text) <= 54 else text[:51] + "..."
        print(f"{show:56s} {'yes' if is_pii else 'no':>4} " +
              " ".join(f"{c:>15}" for c in cells))
    print()
    for name, _ in tiers:
        tp, fp, tn, fn_ = counts[name]
        rec = tp / (tp + fn_) if tp + fn_ else 0.0
        prec = tp / (tp + fp) if tp + fp else 0.0
        print(f"{name:16s} recall {rec:5.0%}  precision {prec:5.0%}  "
              f"(tp {tp} fp {fp} tn {tn} fn {fn_})")
    print("\neven tier 3 misses cases; redaction is defence in depth, not a")
    print("guarantee. the architectural fix is never to capture the audio:")
    print("hand the caller to DTMF or a payment IVR for card data")


# --------------------------------------------------------------- Part C
def part_c(eer=0.02):
    """Speaker verification as access control, priced in both error directions."""
    print(f"a speaker verification model with EER = {eer:.0%}; the ROC family "
          f"through that point is FAR = EER^2 / FRR\n")
    print(f"{'FRR (customers locked out)':>27} {'FAR (impostor admitted)':>25} "
          f"{'expected tries to break in':>28}")
    for frr in (0.001, 0.005, 0.01, 0.02, 0.05, 0.10):
        far = eer * eer / frr
        print(f"{frr:26.2%} {far:24.3%} {1/far:27.0f}")
    print(f"\nposterior probability the caller is genuine, given a match:")
    print(f"{'prior fraud rate':>17} {'FRR':>6} {'FAR':>8} "
          f"{'P(genuine|match)':>18} {'P(fraud|match)':>16} {'odds':>12}")
    for prior in (0.001, 0.01, 0.05, 0.30):
        for frr in (0.01, 0.05):
            far = eer * eer / frr
            gen = (1 - frr) * (1 - prior)
            imp = far * prior
            post = gen / (gen + imp)
            print(f"{prior:16.1%} {frr:6.0%} {far:8.3%} {post:17.4%} "
                  f"{1-post:15.4%} {gen/imp:11.0f}:1")
    print("\nvoice looks strong here mainly because the prior is. at a 30% fraud")
    print("prior it is 58:1, and a replay attack defeats the model outright")
    print("rather than statistically. voice is an identity CLAIM and a")
    print("convenience factor, never the authenticator of record.")


if __name__ == "__main__":
    print("PART A -- where the guardrail goes\n")
    part_a()
    print("\n\nPART B -- PII spoken aloud\n")
    part_b()
    print("\n\nPART C -- voiceprints are not passwords\n")
    part_c()
```

Output `[MEASURED]`:

```
PART A -- where the guardrail goes

guardrail 180 ms on the full response (108 ms on one clause), TTS ttfb 130 ms, 0.4% of responses unsafe

placement       ttfa p50  ttfa p95  vs stream  leak p50  leak p95    worst  unsafe heard
streaming (none)      784ms     1279ms        +0ms     4671ms     7507ms    8326ms         100%
serial             1770ms     2489ms      +986ms        0ms        0ms       0ms           0%
parallel            781ms     1277ms        -2ms      830ms     1640ms    1910ms          95%
clause-gated        888ms     1383ms      +104ms        0ms        0ms       0ms           0%


PART B -- PII spoken aloud

transcript                                                PII     digits-only    spoken-aware  spoken+context
my card is 4111 1111 1111 1111                            yes            FLAG            FLAG            FLAG
my number is four one five five five five one two o...    yes               -            FLAG            FLAG
card four one one one one one one one double one on...    yes               -            FLAG            FLAG
my zip is nine four one zero seven                        yes               -               -            FLAG
the account ends in oh oh seven seven three one           yes               -            FLAG            FLAG
my pin is one two three four                              yes               -               -            FLAG
date of birth is oh three eleven nineteen ninety          yes               -               -               -
I called you three times about four different orders       no               -               -               -
it costs two hundred and fifty dollars                     no               -               -               -
give me option two please                                  no               -               -               -

digits-only      recall   14%  precision  100%  (tp 1 fp 0 tn 3 fn 6)
spoken-aware     recall   57%  precision  100%  (tp 4 fp 0 tn 3 fn 3)
spoken+context   recall   86%  precision  100%  (tp 6 fp 0 tn 3 fn 1)

even tier 3 misses cases; redaction is defence in depth, not a
guarantee. the architectural fix is never to capture the audio:
hand the caller to DTMF or a payment IVR for card data


PART C -- voiceprints are not passwords

a speaker verification model with EER = 2%; the ROC family through that point is FAR = EER^2 / FRR

 FRR (customers locked out)   FAR (impostor admitted)   expected tries to break in
                     0.10%                  40.000%                           2
                     0.50%                   8.000%                          12
                     1.00%                   4.000%                          25
                     2.00%                   2.000%                          50
                     5.00%                   0.800%                         125
                    10.00%                   0.400%                         250

posterior probability the caller is genuine, given a match:
 prior fraud rate    FRR      FAR   P(genuine|match)   P(fraud|match)         odds
            0.1%     1%   4.000%          99.9960%         0.0040%       24725:1
            0.1%     5%   0.800%          99.9992%         0.0008%      118631:1
            1.0%     1%   4.000%          99.9592%         0.0408%        2450:1
            1.0%     5%   0.800%          99.9915%         0.0085%       11756:1
            5.0%     1%   4.000%          99.7878%         0.2122%         470:1
            5.0%     5%   0.800%          99.9557%         0.0443%        2256:1
           30.0%     1%   4.000%          98.2979%         1.7021%          58:1
           30.0%     5%   0.800%          99.6404%         0.3596%         277:1

voice looks strong here mainly because the prior is. at a 30% fraud
prior it is 58:1, and a replay attack defeats the model outright
rather than statistically. voice is an identity CLAIM and a
convenience factor, never the authenticator of record.
```

Three load-bearing details. **The serial row's cost comes from `gen_full`, not from
`guard_ms`** — 986 ms of penalty from a 180 ms classifier — and that term exists only because
a whole-response guardrail has to wait for the whole response; modelling it as
`stream_ttfa + guard_ms` would have made serial look almost free and hidden the entire
finding. **The `parallel` leak is clamped to `audio_dur`**, because a verdict that arrives
after the agent has stopped talking leaks the whole utterance and no more; without the clamp
the numbers grow without bound and stop meaning anything. And **Part C derives the ROC family
as `FAR = EER² / FRR`**, a one-parameter approximation that passes through the equal-error
point — real DET curves differ in shape, so the exact tries-to-break-in figures are
indicative while the structural result (a 2% EER admits impostors at a few per cent when the
false-reject rate is tolerable) holds for any plausible curve.

---

## 4. How production does it

**Clause-level output filtering is what shipped agents do**, though it is rarely described
that way — the aggregator that splits LLM tokens into speakable clauses
([`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md)) is already the right
interception point, and adding a check there is a small change with the §2.3 payoff.

**Vendors sell zero-retention and BAA tiers because they are load-bearing**, and the prices
previously noted — around $1k/month for ZDR, $2k/month for HIPAA on one platform — tell you
that compliance is a procurement line item, not a code change
([`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md)).

**Payment capture is routinely handed off** to a dedicated DTMF or PCI-scoped IVR flow rather
than transcribed, exactly as §2.4 concludes. If your agent takes payments and your ASR sees
the digits, that is a finding waiting to happen.

**Recording disclosure is spoken in the greeting** by every compliant contact centre, which
is also the Art. 50(5) requirement — the same three seconds satisfies the consent rule and
the AI-disclosure rule, and combining them is the obvious design.

**Voice biometrics are deployed as a *risk signal*** in the systems that use them well: a
match reduces friction, a mismatch triggers step-up, and neither is sufficient to move money.

---

## 5. At scale

**Guardrail cost multiplies by clause, not by call.** Clause gating runs the classifier
several times per turn, so at 10 000 concurrent calls it is a real inference budget. Use a
small, fast classifier and cache verdicts for repeated canned phrases.

**Redaction must run everywhere the data goes, and that set grows.** Each new vendor,
warehouse or dashboard is a new place PII can land. Make redaction a library on the boundary
rather than a step in one pipeline, and audit egress.

**Deletion at scale is a system, not a script.** Erasure requests must reach audio storage,
transcripts, traces, warehouse copies, backups and each vendor. Build the fan-out early and
test it, because the first request arrives with a deadline.

**Jurisdictional routing multiplies your regions**, which by
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)
costs you the trunking gain and more headroom per pool. That is the real price of residency,
and it should be quoted to whoever asks for it.

**Fail open, but log it.** A guardrail that times out must not fail the call; it must record
that it was skipped, so the offline review path can catch what the online path missed.

**Rate-limit per caller identity, not per session.** Denial-of-wallet and injection probing
both look like a small number of callers making many calls, and a per-session limit sees
nothing.

---

## 6. Exercises

**E8.3.1** Run the §3 listing. Add a fifth placement — clause-gated with a 400 ms classifier
— and report the latency and leak. State the classifier latency at which clause gating stops
being worth it.

**E8.3.2** Change Part A so the guardrail can inspect a *prefix* of the response as it
streams. Report where it lands between parallel and clause-gated, and what it costs in
classifier calls.

**E8.3.3** Extend Part B's normaliser to handle number-words (`eleven`, `nineteen ninety`)
and re-measure recall. Report which case still fails and why full spoken-number
normalisation is unbounded work.

**E8.3.4** Build the false-positive set for tier 3: find five innocent utterances containing
a carrier phrase and short digits that it wrongly flags. Report the precision cost and decide
your threshold.

**E8.3.5** Write the greeting that satisfies Art. 50(1), Art. 50(5), your recording-consent
obligation and a route to a human. Measure its duration and state where it sits in the
latency budget.

**E8.3.6** For your own deployment, list every processor that receives audio or transcripts,
and for each: retention default, training-on-data default, and whether a BAA or ZDR tier
exists. Identify the weakest link.

**E8.3.7** Compute the FAR at the FRR your product team would actually accept for voice
authentication, then the expected number of attempts for a targeted attacker. Present it as a
recommendation.

**E8.3.8** Write and run three prompt-injection attempts *through the audio path* — spoken,
not typed — against your agent. Report which succeeded, and whether your tool-boundary limits
bounded the damage.

---

## 7. Interview drill

> "We want to add a safety classifier to our voice agent's output. The plan is to run it on
> the model's response before we synthesise it. What's your review?"

The plan as stated is the expensive version of the right idea, and the cost is much larger
than it looks. A classifier that inspects the whole response cannot start until the whole
response exists, so putting it in series does not cost you the classifier's latency — it
costs you clause-level streaming. In the arithmetic I would bring, a 180 ms classifier placed
that way moved `ttfa` p50 from 784 ms to 1770 ms, a penalty of 986 ms, because the agent now
waits for generation to finish before it says anything. That is five times the classifier's
own latency, and it is the single most common mistake in this design.

The usual next suggestion is to run it in parallel, and that is worse in a way that is easy
to miss. Parallel is genuinely free on latency — it measured two milliseconds faster than
baseline — and it does not do the job: the verdict still arrives after generation completes,
by which time the agent has been speaking for a while. In the same measurement, 95% of unsafe
turns leaked something, with a median of 830 ms of unsafe audio already heard and a worst case
of 1910 ms. Audio cannot be unsent, so a guardrail that returns its verdict after the
sentence has been spoken is a logging system, not a control.

What I would build instead is clause gating: check each speakable clause before it is
synthesised, at the aggregator that already splits LLM tokens into clauses for streaming TTS.
That measured 888 ms — 104 ms over baseline, about a tenth of the serial penalty — with zero
leaked audio, because the unit being checked is the unit being streamed and a single clause is
short enough that the classifier is cheap. The costs are honest: the classifier runs several
times per turn, so it must be small and canned phrases should be cached, and a mid-response
rejection needs a graceful continuation rather than an abrupt stop. I would also block on the
*input* side, which is nearly free because a check on the caller's turn overlaps the LLM's
prefill, and I would make every guardrail fail **open** with a logged skip — a filter that can
hang the agent is a worse availability risk than the content it was catching.

What separates a senior answer is not treating the classifier as the security boundary. It
catches unsafe *language*; it does nothing about unsafe *actions*. If an injected instruction
persuades the agent to issue a refund, the response can be perfectly polite and the damage is
done. So the real control is at the tool boundary — caps on amounts, the authenticated
account ID as a required parameter enforced server-side rather than described in the prompt,
an allow-list for transfer destinations — and confirming state changes aloud before executing
them, which turns a silent injection into one the caller has to assent to.

The premise worth questioning is what "unsafe" means here. If we are filtering profanity, a
cheap clause-level check is plenty. If we are trying to prevent the agent making binding
commitments about refunds or medical advice, no output classifier is the right tool — that is
a matter of constraining what the agent can say and do structurally, and I would want to see
the actual failure cases before agreeing that a classifier is the fix at all.

---

## Sources

- Regulation (EU) 2024/1689 (Artificial Intelligence Act), **Article 50**, Official Journal version of 13 June 2024; date of entry into force **2 August 2026** per Article 113. Quoted in §2.6: Art. 50(1) providers must ensure systems "intended to interact directly with natural persons are designed and developed in such a way that the natural persons concerned are informed that they are interacting with an AI system, unless this is obvious from the point of view of a natural person who is reasonably well-informed, observant and circumspect"; Art. 50(2) synthetic audio/image/video/text outputs "marked in a machine-readable format and detectable as artificially generated or manipulated", with solutions "effective, interoperable, robust and reliable as far as this is technically feasible"; Art. 50(3) deployers of "an emotion recognition system or a biometric categorisation system shall inform the natural persons exposed thereto of the operation of the system"; Art. 50(4) deep-fake disclosure; Art. 50(5) information provided "in a clear and distinguishable manner at the latest at the time of the first interaction or exposure" and conforming to "the applicable accessibility requirements". Retrieved 2026-08-26.
- Regulation (EU) 2016/679 (GDPR) — Art. 4(14) definition of biometric data, Art. 9(1) special categories including "biometric data for the purpose of uniquely identifying a natural person", Art. 5(1)(c) data minimisation, Art. 17 erasure. Cited in §2.5 and §2.7.
- PCI DSS — the prohibition on storing sensitive authentication data after authorisation, and the treatment of call recordings containing it as in scope; the basis for §2.4's "do not capture what you cannot protect".
- HIPAA (45 CFR Parts 160, 164) — business-associate obligations extending to every processor in the audio path, §2.5.
- US state two-party (all-party) consent recording statutes — e.g. California Penal Code §632, Pennsylvania 18 Pa. C.S. §5703, Illinois 720 ILCS 5/14-2, Washington RCW 9.73.030 — cited in §2.5 as the reason consent must precede the first recorded frame. **This chapter is engineering guidance, not legal advice**; jurisdictional detail changes and must be confirmed with counsel.
- TCPA (47 U.S.C. §227) — consent for automated outbound calling, §2.5.
- Speaker-verification error rates, DET curves and the replay-attack failure mode: [`../02-asr/09-diarization-and-speaker-id.md`](../02-asr/09-diarization-and-speaker-id.md), where verification as an auth anti-pattern is introduced.
- Watermarking and cloning ethics: [`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md); the clause aggregator that §2.3 recommends gating at: [`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md).
- `[MEASURED]`: all three sections are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only, `SEED = 131`. Part A is a 20 000-trial Monte Carlo whose per-turn distributions — streamed `ttfa`, full-generation time, spoken duration, the 180 ms classifier and the 0.4% unsafe rate — are `[INFERENCE]` inputs chosen to be representative of a cascaded pipeline, not measurements of one system; the ranking (serial costs generation time, parallel leaks, clause gating dominates) follows from the structure and is robust to the inputs, while the specific milliseconds are not. Part B is exact evaluation on ten hand-written transcripts, so its recall figures describe that set only and are illustrative of the failure *modes*, not an estimate of production recall — a real evaluation needs a labelled corpus of ASR output. Part C is exact arithmetic over a one-parameter ROC family `FAR = EER² / FRR` through a 2% equal-error point, which is an `[INFERENCE]` approximation to a real DET curve; the qualitative conclusion is insensitive to the shape.
