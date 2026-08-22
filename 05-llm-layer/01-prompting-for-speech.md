# Prompting for Speech

**What you'll be able to do after this:** enumerate the specific ways a text-tuned LLM
produces unspeakable output, and automatically detect them; write a production voice system
prompt where every line traces to a failure it prevents; choose a confirmation strategy from
the cost of being wrong rather than by habit; and make an LLM robust to the fact that its
input is a noisy transcript rather than typed text.

---

## 1. Intuition

Every LLM you can call was trained overwhelmingly on written text and tuned to be helpful in
a chat window. That optimisation target is close to the opposite of what a voice agent needs.

A chat interface rewards structure: headings, bullet points, bold key terms, code blocks,
links, tables, and thoroughness. A reader scans, skips ahead, and re-reads. **A listener can
do none of those things.** Speech is strictly linear, unskippable, and has no visual
hierarchy. The reader's ability to skim is what makes a long structured answer good in text
and unbearable aloud.

So the default output of a good chat model is a bad voice response, and the failure is not
subtle. Asterisks are either pronounced or silently dropped, changing the meaning. A bulleted
list becomes a flat monotone sequence with no signal about where items begin. A URL takes
twenty seconds to read and cannot be written down by ear. A four-sentence paragraph has no
breath points, so the synthesiser produces a wall of sound.

Three shifts in framing follow.

**Length is a latency decision, not a style decision.** A 60-token reply at 40 tokens per
second takes 1.5 seconds to generate, and if your aggregator waits for a sentence boundary
the first audio waits too ([`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md)
§2.4). Brevity buys measurable milliseconds, not just goodwill.

**The input is a noisy observation, not a fact.** The model receives an ASR hypothesis that
is wrong some percentage of the time
([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)), and it must behave sensibly
when the transcript is garbled — never quoting it back verbatim as though it were certain,
and never proceeding confidently on a misheard account number.

**The prompt is a component with a test suite.** Each instruction exists to prevent a
specific, reproducible failure, which means each one can be tested. Treating the prompt as
prose to be tweaked is how it accumulates contradictory instructions nobody can remove.

---

## 2. Rigour

### 2.1 The failure catalogue

Every item here is a real, reproducible failure of an untuned chat model used for voice.

| Failure | Example output | What the listener gets |
|---|---|---|
| **Markdown emphasis** | `**Your balance** is important` | "star star your balance star star" or silent loss of emphasis |
| **Headings** | `## Account Summary` | "hash hash" or nothing |
| **Bullet lists** | `- Reschedule\n- Cancel` | "dash reschedule dash cancel", or a flat run with no boundaries |
| **Numbered lists** | `1. First 2. Second` | ambiguous with quantities |
| **Code spans** | `` `pip install x` `` | unspeakable |
| **URLs** | `https://bank.example.com/acct/1` | ~20 s of "h t t p s colon slash slash…", untranscribable by ear |
| **Emoji** | `Done 🎉` | no pronunciation |
| **Tables** | pipe-delimited rows | unreadable |
| **LaTeX** | `$x^2$` | unspeakable |
| **Long sentences** | 40-word sentence | no breath point; delays first audio |
| **Over-long replies** | four paragraphs | listener loses the thread; cannot skim |
| **Digit runs** | `4152229999` | must be grouped and spaced ([`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md)) |
| **Slashes** | `and/or`, `24/7` | no consistent spoken form |
| **Ampersand** | `A & B` | read inconsistently |
| **Restating the question** | "You asked about your balance. Your balance is…" | wastes the listener's time and your latency budget |
| **Over-hedging** | "I may not be able to fully confirm, however…" | evasive aloud, and long |
| **Parentheticals** | long aside inside brackets | listener loses the main clause |

Measured with the detector in §3 `[MEASURED]`:

| Sample | Words | Issues detected |
|---|---|---|
| markdown-heavy reply | 9 | **5** — emphasis, code span, URL, parenthetical, slash |
| bulleted list | 13 | 1 — bullet list |
| table | 12 | 1 — table row |
| single 48-word sentence | 48 | 1 — long sentence |
| digits + emoji + slash + ampersand | 13 | 4 |
| good reply | 14 | **0** |
| good reply 2 | 13 | **0** |

The nine-word markdown sample containing five distinct violations is the point: unspeakable
output is *dense*, not occasional. A single short reply can violate five rules at once, which
is why post-hoc filtering of one pattern at a time does not work.

### 2.2 Filtering is necessary and insufficient

Two defences, and you need both.

**Filter deterministically at the boundary.** Strip markdown, remove emoji, replace URLs
with something speakable, and verbalise numbers. This is cheap, reliable, and testable — and
LiveKit Agents does exactly this by default:
`DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` (verified in
`livekit-agents/livekit/agents/voice/agent_session.py`, main branch, 2026-08-22).

**Prompt so the problem does not arise.** Filtering removes the *symbols* and cannot fix the
*structure*. A bulleted list stripped of its dashes is still a list — a flat sequence with no
spoken cues about how many items there are or where each begins. The fix is to make the model
say "you have two options: reschedule, or cancel", which is a different sentence, not the
same sentence with characters removed.

So: prompt for spoken structure, filter as a safety net, and monitor the filter's hit rate.
A rising hit rate means the prompt is drifting or the model changed.

### 2.3 Length policy

Tie it to the latency budget rather than picking a number:

| Turn type | Target | Rationale |
|---|---|---|
| Acknowledgement | 1–3 words | "sure", "got it" — buys time during a tool call |
| Confirmation | one short sentence | must be verifiable in one breath |
| Answer | 1–2 sentences | fits a conversational turn |
| Explanation | 2–3 sentences, then offer more | "there are three parts to this — want me to go through them?" |
| Never | more than ~60 words unprompted | the listener has lost the thread |

The **chunking-with-consent** pattern in the explanation row is the important one. Rather
than delivering a long answer, deliver the first part and offer the rest. This is how humans
handle complex information in speech, it keeps every turn short, and it lets the user redirect
before you have wasted twenty seconds. It also converts one long unstreamable reply into
several short streamable ones (§2.4 of
[`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md)).

### 2.4 Robustness to ASR error

The model's input is wrong some of the time, so the prompt must encode behaviour for that.

**Never quote the transcript verbatim as fact.** "You said your account is 6127" is actively
harmful when the caller said 6217 — it launders an ASR error into an apparent confirmation.
Prefer reading back a *normalised, grouped* form the listener can check: "let me confirm, six
two one seven".

**Confirmation strategy is a cost decision.** Three options:

| Strategy | Form | Cost | Use when |
|---|---|---|---|
| None | proceed silently | fastest | error is cheap and reversible |
| **Implicit** | weave it into the next sentence: "booking Tuesday at four fifteen — is that right?" | ~1 s | default for most slots |
| **Explicit** | dedicated turn: "I heard four one five. Correct?" | one full turn | irreversible or high-stakes actions |

Confirming everything is exhausting and slow; confirming nothing is dangerous. The rule that
works: confirm when the action is irreversible, when the value is high-stakes, or when ASR
confidence is low — and use implicit confirmation everywhere else. Note that this requires
the transcript pipeline to *expose* confidence
([`../02-asr/06-decoding-and-biasing.md`](../02-asr/06-decoding-and-biasing.md) §7), which is
a plumbing requirement generated by a prompt decision.

**Handle non-understanding gracefully and escalate.** A model that says "I didn't catch that"
three times in a row is a dead end. The pattern is to escalate the repair strategy: repeat
the question, then simplify it to a closed question, then offer an alternative input channel
or a human. Encode that ladder in the prompt rather than hoping.

**Expect fragments.** With aggressive endpointing the model receives half-sentences
([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)). It should
respond to a fragment by inviting completion, not by guessing — and it must tolerate being
corrected mid-conversation, because a late ASR revision or a barge-in can make its previous
turn wrong ([`../02-asr/05-streaming-asr.md`](../02-asr/05-streaming-asr.md) §2.4).

### 2.5 A production voice system prompt

Annotated so every line traces to a failure above.

```
You are the voice assistant for Northwind Clinic. You are speaking with a
patient on the telephone.
```
Establishes the medium explicitly. Models behave measurably differently when told the channel
is speech, and "on the telephone" additionally implies narrowband audio and a caller who may
be distracted.

```
SPEAK, DO NOT WRITE.
- Never use markdown, asterisks, bullet points, numbered lists, headings,
  tables, code, emoji, or URLs. There is no screen.
- Write numbers, dates and money the way a person says them: "four fifteen
  in the afternoon", "twelve thousand rupees", "the third of March".
- Never read out a web address. Offer to send it by text message instead.
```
Directly targets §2.1. The reason for stating the *why* ("there is no screen") is that models
generalise from a stated reason to cases the list did not enumerate.

```
LENGTH.
- One or two sentences per turn. Under forty words.
- If a full answer needs more, give the most useful part first, then ask
  whether to continue.
- Do not repeat the question back before answering.
```
§2.3. The "do not repeat the question" line removes a specific, common habit that costs a
second of latency on every turn.

```
LISTENING.
- The transcript you receive comes from speech recognition and may contain
  errors. Treat it as what you probably heard, not as what was certainly said.
- Never quote the transcript back as if it were exact. To check a value,
  say it back in grouped spoken form: "let me confirm, six two one seven".
- Confirm explicitly before anything irreversible: booking, cancelling,
  paying, or sending information.
- If a reply seems cut off mid-sentence, invite the caller to finish rather
  than guessing.
```
§2.4. The last line handles aggressive endpointing, which is a *system* property the model
cannot otherwise know about.

```
WHEN YOU DO NOT UNDERSTAND.
- First time: ask again in different words.
- Second time: ask a yes-or-no question instead.
- Third time: offer to transfer to a member of staff.
- Never say "I did not understand" more than twice in a row.
```
The escalation ladder from §2.4, made explicit so it cannot degenerate into a loop.

```
WHILE WORKING.
- Before a lookup that may take a moment, say something brief such as
  "let me check that" — then do it.
- Never narrate what you are doing in detail.
```
The filler-speech pattern that converts latency into apparent thoughtfulness
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md) §2.3).
"Never narrate in detail" prevents the model from over-applying it.

```
BOUNDARIES.
- You are an AI assistant. If asked, say so plainly.
- Do not give medical advice. For clinical questions, offer to take a message
  for a clinician or transfer the call.
- Do not discuss any patient other than the caller.
```
Disclosure, scope and privacy. The disclosure line supports the transparency obligation in
[`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md) §2.6 — and note that
the mandatory *opening* disclosure is a separate, uninterruptible utterance, not something
left to the model's discretion.

Two structural notes about this prompt. It uses **short imperative bullets grouped under
headings** — for the model's benefit, not the listener's; the prompt is text and should
exploit structure even while forbidding it in the output. And it states **prohibitions with
reasons** rather than as bare rules, because a stated reason generalises to unlisted cases
while a bare list does not.

### 2.6 Evaluating speakability

Make it measurable rather than a matter of taste:

| Metric | Definition |
|---|---|
| Speakability violations per reply | count from the §3 detector |
| Median and p95 reply length in words | tracks length drift over time |
| Filter hit rate | fraction of replies where the markdown/emoji filter changed the text |
| Confirmation rate | fraction of turns containing a confirmation — too high is exhausting |
| Repair-loop rate | fraction of conversations with two or more consecutive non-understanding turns |
| `first_clause` fraction | how far into the reply the first speakable chunk arrives |

Run the detector in CI over a fixed set of prompts and gate on it. This is the cheapest
quality gate in the whole system, it catches prompt regressions and model upgrades
immediately, and it requires no human listening.

---

## 3. From scratch

A speakability detector. Standalone, stdlib only. Run it in CI.

```python
"""Detect unspeakable LLM output. Each rule maps to a failure in Section 2.1."""
import re

CHECKS = [
    ("markdown_emphasis", r"\*\*?[^*\n]+\*\*?|__[^_\n]+__",
     "asterisks/underscores are read aloud or silently drop the emphasis"),
    ("markdown_heading", r"(?m)^\s{0,3}#{1,6}\s",
     "heading marks have no spoken form"),
    ("bullet_list", r"(?m)^\s*([-*+]|\d+\.)\s",
     "list markers become 'dash' or vanish; enumeration must be words"),
    ("code_span", r"`[^`\n]+`|```",
     "backticks are silent; code is unspeakable"),
    ("url", r"https?://\S+|www\.\S+",
     "URLs take ~20s to read and cannot be transcribed by ear"),
    ("emoji", r"[\U0001F300-\U0001FAFF\u2600-\u27BF]",
     "emoji have no pronunciation"),
    ("table_pipe", r"(?m)^\s*\|.*\|\s*$",
     "table rows are unreadable aloud"),
    ("parenthetical", r"\([^)]{25,}\)",
     "long parentheticals lose the listener before the main clause resumes"),
    ("latex", r"\$[^$\n]+\$|\\\w+\{",
     "math markup is unspeakable"),
    ("digit_run", r"\d{5,}",
     "long digit runs must be grouped and spaced for speech"),
    ("slash", r"\w+/\w+",
     "'and/or' style slashes have no spoken form"),
    ("ampersand", r"\s&\s",
     "ampersand is read inconsistently"),
]

MAX_WORDS_REPLY = 60
MAX_WORDS_SENTENCE = 25

def check(text):
    """Return [(rule, explanation)] for every speakability violation."""
    hits = [(name, why) for name, pat, why in CHECKS if re.search(pat, text)]
    if len(text.split()) > MAX_WORDS_REPLY:
        hits.append(("too_long",
                     f"reply over {MAX_WORDS_REPLY} words is too long for a spoken turn"))
    for sentence in re.split(r"(?<=[.!?])\s+", text):
        if len(sentence.split()) > MAX_WORDS_SENTENCE:
            hits.append(("long_sentence",
                         f"sentences over {MAX_WORDS_SENTENCE} words exceed a breath "
                         "and delay first audio"))
            break
    return hits

def assert_speakable(text):
    """CI gate. Fails with the specific rule and reason, not a generic message."""
    hits = check(text)
    if hits:
        detail = "; ".join(f"{n}: {w}" for n, w in hits)
        raise AssertionError(f"unspeakable output ({len(hits)} issue(s)) -- {detail}")

if __name__ == "__main__":
    SAMPLES = [
        ("bad_markdown", "**Your balance** is `$412.50`. See the "
                         "[details](https://bank.example.com/acct/1) for more."),
        ("bad_list",     "Here are your options:\n- Reschedule\n- Cancel\n"
                         "1. Speak to an agent"),
        ("bad_table",    "| Date | Amount |\n|---|---|\n| Mar 3 | $42 |"),
        ("bad_long",     "I have checked your account and I can confirm that the "
                         "outstanding balance currently stands at four hundred and "
                         "twelve dollars and fifty cents which was last updated on "
                         "the third of March following the payment that you made "
                         "using the card ending in four four two one."),
        ("bad_misc",     "Your ref is 4152229999 and/or the code A7F & the emoji is 🎉"),
        ("good",         "Your balance is four hundred twelve dollars and fifty cents. "
                         "Want the recent transactions?"),
        ("good2",        "Sure. I can reschedule that. Would Tuesday morning or "
                         "Thursday afternoon work better?"),
    ]

    print(f"{'sample':14s} {'words':>6} {'issues':>7}  detail")
    for name, text in SAMPLES:
        hits = check(text)
        detail = ", ".join(n for n, _ in hits) if hits else "clean"
        print(f"{name:14s} {len(text.split()):6d} {len(hits):7d}  {detail}")

    print("\nworst offender explained:")
    for name, why in check(SAMPLES[0][1]):
        print(f"  {name:18s} {why}")
```

Two design choices worth noting. Each rule carries its **explanation**, so a CI failure tells
the engineer *why* rather than just which regex matched — which is the difference between a
gate people fix and a gate people disable. And the reply-length and sentence-length checks are
**separate**, because they fail for different reasons: total length loses the listener, while
a single long sentence delays first audio and gives the synthesiser no breath point.

---

## 4. How production does it

**Framework-level filtering.** LiveKit Agents applies
`DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` before synthesis, and
sets `SpeechSteeringOptions(disfluencies=True)` by default (both verified in
`livekit-agents/livekit/agents/voice/agent_session.py`, main branch, 2026-08-22). The first
is the safety net from §2.2; the second is a deliberate naturalness choice. Note what the
transforms do *not* fix: list structure, reply length, and URLs remain your problem.

**Instructions live in the `Agent`, not scattered through the code.** LiveKit's `Agent` takes
`instructions`, which makes the prompt a single reviewable artefact. Treat it as source code:
version it, diff it, and gate it with the §3 detector.

**Hosted speech-to-speech models need the same prompting and give you less control.** They
generate audio directly, so a text filter has nothing to filter — the constraints must come
entirely from the instructions, and you cannot verify the output was speakable because there
is no text to check
([`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)).
That loss of a checkable intermediate is a real cost of the S2S architecture and is
under-appreciated.

**Model upgrades change prompt adherence.** A prompt tuned for one model version can regress
on the next — typically as longer replies or the return of list structure. This is the
strongest argument for the CI gate: it catches the regression on the day you change models
rather than in production.

**Few-shot examples beat prose for style.** Two or three example exchanges in the target
register are more effective at fixing tone and length than another paragraph of instruction,
at the cost of prompt tokens — which is a prefill-latency cost
([`04-serving-llms-fast.md`](04-serving-llms-fast.md)).

---

## 5. At scale

**Prompt tokens are latency on every single turn.** A 2000-token system prompt is prefill
work repeated for the entire conversation. The mitigation is prefix caching, and it imposes a
discipline: **put the stable prompt first and volatile content last**, or every turn misses
the cache ([`04-serving-llms-fast.md`](04-serving-llms-fast.md)). This makes prompt
*ordering* a performance decision, which surprises people.

**Reply length is simultaneously latency, cost and quality.** Shorter replies generate
faster, cost less on TTS per character
([`../04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md) §7), and are easier
to listen to. Length is the rare metric where three objectives align, so track median and
p95 word count as a first-class SLI and alert on drift.

**Filter hit rate is a leading indicator.** If the markdown filter starts firing on 5% of
replies when it used to fire on 0.1%, either the prompt drifted or the model changed. Cheap
to compute, and it catches problems before users notice.

**Watch the confirmation rate from both directions.** Too low is dangerous; too high makes
every interaction twice as long. Segment by slot type — irreversible actions should be near
100%, routine slots near zero — and review the ones in between.

**Repair loops are the worst user experience and they are measurable.** Two or more
consecutive non-understanding turns means the caller is stuck. Track the rate, and treat a
rise as an ASR or endpointing problem rather than a prompt problem, since the model is usually
responding correctly to a bad transcript
([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)).

**Localise the prompt, do not translate it.** The register, politeness conventions and
confirmation norms differ by language and culture, and a translated English prompt produces
an agent that is grammatically correct and socially wrong. This also interacts with
verbalisation ([`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md) §2.2).

---

## 6. Exercises

**E5.1.1** Run the §3 detector. Then extend it with three rules of your own: nested
parentheses, ALL-CAPS words longer than three letters, and repeated punctuation. For each,
state the spoken failure it prevents.

**E5.1.2** Take an untuned chat model, ask it five questions from your domain, and run the
detector on the raw output. Report violations per reply. Then add the §2.5 prompt and
re-measure. Quantify the reduction.

**E5.1.3** Build the CI gate: a test that runs the detector over twenty fixed prompts and
fails the build on any violation. Verify it fails by deliberately relaxing one prompt line.

**E5.1.4** Implement the chunking-with-consent pattern from §2.3 for a question whose full
answer needs 120 words. Measure the `first_clause` fraction for the long answer and for the
chunked version.

**E5.1.5** Design and test the confirmation policy: enumerate every slot your agent collects,
assign each None/Implicit/Explicit with a justification, then compute the expected number of
extra turns per conversation.

**E5.1.6** Simulate ASR error by corrupting 10% of words in the transcript before the model
sees it. Compare a prompt with and without the §2.5 LISTENING section on how often the agent
proceeds confidently with wrong data.

**E5.1.7** Measure the prefill cost of your system prompt: time first-token latency with a
200-token and a 2000-token prompt, with and without prefix caching. Report the per-turn
latency difference.

---

## 7. Interview drill

> "Our voice agent's answers are accurate but users hang up halfway through. Transcripts look
> fine. What is wrong?"

"Transcripts look fine" is the diagnostic clue and should be treated as such: reading well is
exactly the property that makes output *fail* aloud. So the hypothesis is that the model is
producing good written answers, which is what it was trained to do, and nobody has checked
whether they are speakable.

The specific mechanisms to name, in order of likely impact. **Length** — a four-sentence
answer that scans well in a transcript is twenty-five seconds of uninterruptible monologue,
and a listener with no ability to skim will abandon it (§2.3). **Structure** — a list reads
clearly on a page and is a flat, boundary-less run of words in speech, so even after markdown
filtering (§2.2) the listener cannot tell where one item ends. **No consent checkpoints** —
the agent never pauses to ask whether to continue, so the user's only way to stop it is to
hang up, which is precisely what they are doing.

Then the diagnosis, which should be cheap and concrete: run the §3 detector over recent
replies and report violations and word-count distribution. If p95 length is high and bullet
structure is common, the finding is confirmed without listening to a single call. And listen
to three calls anyway, because reading a transcript is the failure mode that produced the
problem.

The fixes follow: a length policy with the chunk-and-offer pattern (§2.3), spoken enumeration
instead of lists, and the filter as a net rather than the solution. Then the CI gate (§2.6) so
it does not regress on the next model upgrade.

The senior addition is to check the premise that this is a prompt problem at all. Users
hanging up mid-reply is also the signature of a **barge-in failure**: if the user tries to
interrupt and the agent does not stop, hanging up is the only remaining option. That is a
completely different fix ([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md),
[`../03-turn-taking/05-echo-and-aec.md`](../03-turn-taking/05-echo-and-aec.md)), and the
distinguishing evidence is whether the hang-ups are preceded by user speech that the agent
ignored. Checking that before rewriting the prompt is the difference between fixing the
problem and shipping a better prompt into a broken interruption path.

---

## Sources

- `livekit/agents`, `livekit-agents/livekit/agents/voice/agent_session.py` (main branch, retrieved 2026-08-22) — `DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` and `DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)`, quoted in §2.2 and §4; the `Agent(instructions=...)` surface referenced in §4.
- The latency arithmetic connecting reply length to first-audio time is derived in [`../01-foundations/00-what-is-a-voice-agent.md`](../01-foundations/00-what-is-a-voice-agent.md) §2 and [`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md) §2.4, both with measured output.
- Confirmation-strategy framing follows the cost-asymmetry argument in [`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md) §2.1.
- All `[MEASURED]` values in §2.1 were produced by the code in §3 on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. The detector is a heuristic: it will produce occasional false positives (a URL's slashes also trigger the slash rule) and it cannot detect structural problems such as an unmarked list, which is why §2.2 argues prompting and filtering are complementary rather than alternatives.
