# Streaming TTS: Time to First Audio Byte

**What you'll be able to do after this:** define `ttfb_tts` precisely and explain why it
dominates perceived responsiveness more than any other single number; build a clause
aggregator that survives decimals, abbreviations, initials, URLs and ellipses; quantify
the tradeoff between early first audio and prosodic integrity; and design flush and cancel
semantics that barge-in actually requires.

---

## 1. Intuition

The single largest latency win available in a cascaded voice agent is not a faster model.
It is **starting to speak before the reply is finished**.

The arithmetic was established in
[`../01-foundations/00-what-is-a-voice-agent.md`](../01-foundations/00-what-is-a-voice-agent.md)
§2: a 60-token reply at 40 tokens/second takes 1.5 seconds to generate. If you synthesise
after the last token, you have added 1.5 seconds of pure waiting to every turn. If you
synthesise after the *first clause*, that 1.5 seconds happens while the user is already
listening, and it disappears from the critical path entirely.

That makes the component between the LLM and the TTS engine — the thing that decides *when
enough text has accumulated to speak* — one of the highest-leverage pieces of code in the
system. It is usually thirty lines, it is usually written in an afternoon, and it usually
splits "The total is $42.50" into "The total is 42." and "50 dollars."

The tension it manages is genuine and unavoidable:

- **Flush early** and the first audio arrives sooner. The cost is prosody: a synthesiser
  given "The total is" alone will place a falling, sentence-final intonation on "is",
  because it has no idea a number follows. The result sounds like a person who forgot what
  they were saying.
- **Flush late** and prosody is natural, because the engine sees a complete syntactic unit.
  The cost is latency, paid on every turn.

Measured in §2.4: a clause-heavy sentence can emit its first chunk after 35% of the reply,
while a sentence with no internal punctuation cannot flush until 100% of it exists. The
aggregator does not control that distribution — the *LLM's writing style* does, which is why
prompting for short sentences is a latency optimisation
([`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md)).

---

## 2. Rigour

### 2.1 Defining the metric

`ttfb_tts` is the interval from handing text to the TTS engine to receiving its first
audio byte. Three related quantities are routinely conflated:

| Metric | From → To | What it measures |
|---|---|---|
| `ttfb_tts` | text submitted → first audio byte returned | the engine |
| `first_clause` → `ttfb_tts` | aggregator released text → first byte | engine plus transport |
| `ttft_llm` → `ttfa` | first LLM token → first audio at the user | the whole response path |

The third is what the user experiences and the first is what a vendor advertises. A vendor
quoting "75 ms TTFB" is measuring at their edge, from receipt of *complete* text, on a warm
connection, in their region. Your number includes TLS, queueing, your region, and — critically
— the aggregator's buffering delay, which is often larger than the engine's contribution.
Measure the third quantity; the first is a component of it.

Two properties make `ttfb_tts` unusually important. It is **on the critical path with
nothing to hide behind** — there is no way to mask it, unlike LLM decode time which overlaps
with playback. And it is **paid once per utterance, not per byte**, so the throughput of the
engine after the first byte barely matters as long as it exceeds real time. An engine with
150 ms TTFB and 10× real-time throughput beats one with 400 ms TTFB and 50× throughput, every
time.

### 2.2 The aggregator's job

The LLM emits token fragments: `"The"`, `" total"`, `" is"`, `" $"`, `"42"`, `"."`, `"50"`.
The TTS engine wants text that is a plausible speech unit. The aggregator's contract:

**Flush on a terminal boundary** — `.`, `?`, `!` followed by whitespace or end of stream,
*when it is genuinely terminal*.

**Flush on a clause boundary past a soft minimum** — `,`, `;`, `:` once enough characters
have accumulated that the fragment is worth speaking.

**Flush on a hard maximum** so a run-on sentence cannot buffer forever.

**Never flush inside** a decimal number, an abbreviation, a set of initials, a URL or
domain, or an ellipsis.

That last rule is where implementations fail, and each case has a different test.

### 2.3 The adversarial cases

Measured on a small aggregator with a 24-character soft minimum, 8-character hard minimum
and 180-character cap `[MEASURED]`:

| Case | Input | Chunks produced |
|---|---|---|
| plain | `Your appointment is confirmed. See you Tuesday.` | `'Your appointment is confirmed.'` / `'See you Tuesday.'` |
| **decimal** | `The total is 42.50 dollars. Shall I charge it?` | `'The total is 42.50 dollars.'` / `'Shall I charge it?'` |
| **abbreviation** | `Dr. Smith will see you now. Room 4.` | `'Dr. Smith will see you now.'` / `'Room 4.'` |
| **initials** | `J. R. Patel is on the line. Shall I connect?` | `'J. R. Patel is on the line.'` / `'Shall I connect?'` |
| **URL** | `Details are at example.com and support.example.co.uk today.` | one chunk, unsplit |
| **ellipsis** | `Well... let me check that for you.` | one chunk, unsplit |
| no terminal | `I can look that up for you if you would like me to do so right now` | one chunk |
| clause-heavy | `First, I will check the balance, then I will confirm the address, and finally I will book it.` | three chunks at the commas |
| digit string | `Your reference is 4 1 5 2 2 2 9 9 9 9. Please keep it.` | `'Your reference is 4 1 5 2 2 2 9 9 9 9.'` / `'Please keep it.'` |

The discriminating tests, each of which is one line of code:

- **Decimal:** a period with a digit on both sides is not a sentence end.
- **Abbreviation:** a period preceded by a word in a closed abbreviation list. Note this is
  a *list*, so it is locale- and domain-specific and needs extending for your vocabulary.
- **Initials:** a period preceded by a single letter. `J.` is not a sentence.
- **URL/domain:** a period with alphanumerics on both sides and no following space.
- **Ellipsis:** three consecutive periods.

The digit-string row deserves a note: the aggregator keeps `4 1 5 2 2 2 9 9 9 9.` together,
which is correct, because splitting a reference number across two synthesis calls
introduces a pause in the middle of it and the listener loses their place. Long digit
strings are a case where you want *less* chunking than the character count suggests.

### 2.4 The latency cost of correctness

Characters buffered before the first chunk is emitted `[MEASURED]`:

| Case | Chars before first flush | Fraction of reply |
|---|---|---|
| clause-heavy | 33 | **35%** |
| decimal | 28 | 61% |
| initials | 28 | 64% |
| plain | 31 | 66% |
| digit string | 39 | 72% |
| abbreviation | 28 | 80% |
| ellipsis | 34 | **100%** |
| URL | 59 | **100%** |
| no terminal | 66 | **100%** (no early flush) |

This table is the real content of the chapter. The aggregator's benefit is entirely
determined by *where punctuation falls in the reply*, and it varies from 35% to 100%.

Three actionable conclusions.

**Prompting is a latency lever.** A reply written as one long clause cannot be streamed
early no matter how good your aggregator is. Instructing the LLM to use short sentences
converts the 100% rows into the 35% row, and that is worth several hundred milliseconds. The
prompt and the aggregator are one system.

**The soft minimum sets the floor.** With a 24-character soft minimum, no flush can happen
before 24 characters exist, so at 40 tokens/second (roughly 4 characters per token) that is
about 150 ms of unavoidable buffering. Lowering it buys latency and costs prosody; this is
the dial, and it should be set from your latency budget
([`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md)) rather
than left at a default.

**Correctness sometimes costs latency directly.** The URL and ellipsis rows flush at 100%
*because* the aggregator correctly refused to split them. That is the right trade — a mangled
URL is worse than 200 ms — but it means these safety rules have a measurable latency cost,
and you should know which of your traffic hits them.

### 2.5 Prosody damage at seams

When you split a sentence, the engine synthesises each piece independently, with three
consequences:

**Sentence-final intonation on a non-final fragment.** "The total is" gets a falling
contour, then "$42.50" starts fresh. The result sounds like two utterances, because it is.

**Discontinuity in pitch and energy.** Independent synthesis calls have no shared state, so
the second chunk may start at a different pitch than the first ended.

**Lost co-articulation across the boundary.** Minor, and audible on close listening.

Mitigations, in increasing sophistication. **Split at real syntactic boundaries** rather
than character counts — commas and clause boundaries are where a human would breathe.
**Use engine continuation** where the API supports it: some engines accept a context or
session so successive chunks are synthesised as one prosodic unit; this is the real fix and
its availability should influence engine selection
([`05-engine-selection.md`](05-engine-selection.md)). **Overlap and cross-fade** at the
audio level, which hides discontinuity at the cost of extra synthesis. And **prompt for
short complete sentences** so the seams coincide with sentence boundaries where a reset is
natural.

### 2.6 Flush and cancel semantics

Barge-in imposes requirements on the TTS interface that a batch API does not have
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)).

**Cancel mid-synthesis.** When interrupted, in-flight synthesis must stop. For an HTTP
request this means closing the connection; for a WebSocket, sending a cancel message and
ignoring subsequent audio. Both need a timeout, or cancellation waits on the network.

**Discard un-played audio and report how much.** The playout buffer must be cleared, and the
amount cleared is what the transcript truncation needs.

**Preserve the text-to-audio mapping.** To truncate the assistant's message at the word the
user actually heard, you need to know which text produced which audio. The cheapest reliable
mechanism is to keep the source text alongside each audio chunk, so truncation happens at
chunk granularity — no engine support required. This is why the chunk is the right unit for
the whole pipeline.

**Do not synthesise far ahead.** Every chunk synthesised beyond the current playback point
is work that an interruption discards. In the barge-in measurement, 8 of 14 words were
synthesised and never heard. Synthesising one clause ahead rather than five reduces that
waste — a direct argument against aggressive lookahead, and it also reduces the wasted spend
on per-character billing.

### 2.7 Caching

Fixed strings — greetings, hold messages, disclosures, menu prompts, error apologies — are
synthesised thousands of times identically. Caching them removes `ttfb_tts` entirely for
those utterances.

The cache key must include everything that changes the audio:

$$\text{key} = H(\text{text},\ \text{voice},\ \text{speed},\ \text{pitch},\ \text{engine},\ \text{engine version},\ \text{sample rate})$$

Omitting **engine version** is the classic bug: you upgrade the engine or switch voices,
and cached audio in the old voice continues to be served indefinitely, producing a call
that switches voice halfway through. Omitting **sample rate** produces chipmunk audio when
a telephony path expects 8 kHz.

Two additional notes. Stochastic engines (§2.5 of
[`02-codec-lm-tts.md`](02-codec-lm-tts.md)) produce different audio per call, so caching
means blessing the first realisation as canonical — which is fine, and worth doing
deliberately. And pre-warming the cache at deploy time avoids a burst of cold synthesis
when a new version rolls out.

---

## 3. From scratch

The aggregator, with all five safety rules and the latency instrumentation. Standalone,
stdlib only.

```python
"""LLM tokens -> speakable chunks. The safety rules are the whole difficulty."""
import re

# Closed list: locale- and domain-specific, extend for your vocabulary.
ABBREV = {"mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "inc",
          "ltd", "co", "no", "approx", "dept", "est", "fig", "eg", "ie", "am", "pm"}
TERMINAL = ".?!"
CLAUSE = ",;:"

class Aggregator:
    """Flush on a terminal boundary, on a clause boundary past soft_min, or at
    max_chars. Never inside a decimal, abbreviation, initial, URL or ellipsis."""

    def __init__(self, soft_min=24, hard_min=8, max_chars=180):
        self.buf = ""
        self.soft_min = soft_min      # chars before a comma counts as a boundary
        self.hard_min = hard_min      # never emit a fragment shorter than this
        self.max_chars = max_chars    # run-on guard

    def _is_sentence_end(self, s, i):
        """Is s[i] a real sentence terminator? Only '.' is ambiguous."""
        if s[i] != ".":
            return True
        if s[i:i+3] == "...":                                  # ellipsis
            return False
        if 0 < i < len(s) - 1 and s[i-1].isdigit() and s[i+1].isdigit():
            return False                                       # decimal: 42.50
        m = re.search(r"([A-Za-z]+)\.$", s[:i+1])
        if m:
            word = m.group(1)
            if word.lower() in ABBREV:
                return False                                   # Dr. Mrs. etc.
            if len(word) == 1:
                return False                                   # initial: J.
        if i + 1 < len(s) and s[i+1].isalnum() and i > 0 and s[i-1].isalnum():
            return False                                       # example.com
        return True

    def push(self, token):
        """Add a token, return zero or more chunks ready for synthesis."""
        self.buf += token
        out = []
        while True:
            s = self.buf
            flushed = False

            # 1. terminal punctuation followed by space or end of buffer
            for i, ch in enumerate(s):
                if ch in TERMINAL and (i + 1 == len(s) or s[i+1] == " "):
                    if not self._is_sentence_end(s, i):
                        continue
                    if len(s[:i+1].strip()) >= self.hard_min:
                        out.append(s[:i+1].strip())
                        self.buf = s[i+1:]
                        flushed = True
                        break
            if flushed:
                continue

            # 2. clause boundary, but only once the fragment is worth speaking
            if len(s) >= self.soft_min:
                for i, ch in enumerate(s):
                    if (ch in CLAUSE and i + 1 < len(s) and s[i+1] == " "
                            and len(s[:i+1].strip()) >= self.soft_min):
                        out.append(s[:i+1].strip())
                        self.buf = s[i+1:]
                        flushed = True
                        break
            if flushed:
                continue

            # 3. run-on guard: break at the last space before the cap
            if len(s) > self.max_chars:
                cut = s.rfind(" ", 0, self.max_chars)
                if cut > 0:
                    out.append(s[:cut].strip())
                    self.buf = s[cut:]
                    continue
            break
        return out

    def flush(self):
        """End of stream: emit whatever remains."""
        tail = self.buf.strip()
        self.buf = ""
        return [tail] if tail else []

if __name__ == "__main__":
    CASES = [
        ("plain",        "Your appointment is confirmed. See you Tuesday."),
        ("decimal",      "The total is 42.50 dollars. Shall I charge it?"),
        ("abbrev",       "Dr. Smith will see you now. Room 4."),
        ("initials",     "J. R. Patel is on the line. Shall I connect?"),
        ("url",          "Details are at example.com and support.example.co.uk today."),
        ("ellipsis",     "Well... let me check that for you."),
        ("no terminal",  "I can look that up for you if you would like me to do so right now"),
        ("clause heavy", "First, I will check the balance, then I will confirm the "
                         "address, and finally I will book it."),
        ("digits",       "Your reference is 4 1 5 2 2 2 9 9 9 9. Please keep it."),
    ]

    for name, text in CASES:
        agg = Aggregator()
        chunks = []
        for tok in re.findall(r"\S+\s*", text):      # simulate LLM token stream
            chunks += agg.push(tok)
        chunks += agg.flush()
        print(f"{name:12s} -> {len(chunks)} chunk(s)")
        for c in chunks:
            print(f"               | {c!r}")

    print("\ntime-to-first-clause (characters buffered before the first emit):")
    for name, text in CASES:
        agg, n = Aggregator(), 0
        for tok in re.findall(r"\S+\s*", text):
            n += len(tok)
            if agg.push(tok):
                print(f"  {name:12s} {n:4d} chars ({100*n/len(text):3.0f}% of reply)")
                break
        else:
            print(f"  {name:12s} {n:4d} chars (100% - no early flush)")
```

The `while True` loop matters: one token can complete two boundaries at once (a token
containing `". "` in the middle of a long buffer), so a single-pass implementation drops
chunks. And the ordering of the checks matters — terminal before clause — because a sentence
end is a stronger boundary than a comma and should win when both are available.

---

## 4. How production does it

**Streaming protocols.** Three shapes, with different cancellation properties. **HTTP
chunked** is simplest: POST text, read audio as it arrives; cancellation means closing the
connection. **WebSocket** allows sending text incrementally and receiving audio
continuously, which is what enables engine-side prosodic continuation across chunks, and
gives a clean cancel message. **gRPC bidirectional streaming** is equivalent with better
typing. For a voice agent, prefer whichever supports (a) incremental text input and (b)
explicit cancellation — those two features matter more than the protocol.

**Alignment metadata.** Several hosted engines return word or character timing alongside
audio. That is exactly what §2.6 wants for accurate transcript truncation, and it also
enables lip-sync and word-level highlighting. Where it is unavailable, chunk-granularity
truncation is the fallback and it is usually sufficient.

**Local engines** (Piper, Kokoro) are synchronous function calls rather than network
services, which changes the picture: `ttfb_tts` is model inference with no network
component, cancellation is task cancellation, and there is no per-character billing to
waste on discarded synthesis. For latency-critical agents this is a strong argument for
local synthesis independent of cost
([`01-tts-architectures.md`](01-tts-architectures.md) §5).

**Framework-level text handling.** LiveKit Agents defines
`DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` (verified in
`livekit-agents/livekit/agents/voice/agent_session.py`, main branch, 2026-08-22) — the
framework strips markdown and emoji before synthesis by default, handling at the framework
level a failure mode that would otherwise reach the engine
([`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md)).
It also sets `SpeechSteeringOptions(disfluencies=True)` by default, which is a deliberate
naturalness choice rather than an accident.

**Pipecat** implements aggregation as frame processors in the pipeline, so the sentence
aggregator is an explicit, swappable stage — the right structure, since the aggregation
policy is exactly the thing you will want to tune per product
([`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)).

---

## 5. At scale

**Measure `ttfb_tts` at the p95, per engine and per region.** It is a network-dependent
number for hosted engines, so a single average hides the tail that users actually notice.
Track it separately from total synthesis time, since only the first byte is on the critical
path.

**Discarded synthesis is measurable waste with a direct cost.** Per-character billing means
audio synthesised past an interruption is money spent on silence. Instrument
`chars_synthesised` against `chars_heard` and treat the ratio as an efficiency metric. It
also tells you whether your lookahead is too aggressive (§2.6).

**Cache hit rate is worth a dashboard.** For a scripted agent — an IVR replacement,
appointment confirmations — a large fraction of spoken audio can be fixed strings. A high
hit rate removes both latency and cost for those utterances, and a *falling* hit rate is an
early signal that prompts changed and cache keys are missing.

**Connection reuse matters more than it looks.** For hosted engines over HTTP, a new TLS
handshake per utterance can exceed the engine's own TTFB. Keep a warm connection pool per
worker, and count handshakes — a rising handshake rate is a latency regression hiding in the
transport layer.

**Aggregation policy is a per-product decision, so make it configurable.** A digit-heavy
domain wants a long soft minimum and few splits; a conversational assistant wants
aggressive early flushing. Hard-coding the constants in §3 guarantees you will be wrong for
one of your use cases.

**Voice consistency across a failover is a real user-visible risk.** If the primary engine
fails mid-utterance and the fallback has a different voice, the caller hears the speaker
change. Either keep a matched voice on the fallback or fail over only at utterance
boundaries ([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).

---

## 6. Exercises

**E4.3.1** Run the §3 code. Then set `soft_min` to 8 and to 60 and re-measure the
time-to-first-clause column. Plot first-flush fraction against `soft_min` and identify the
knee.

**E4.3.2** Construct five more adversarial inputs that break the §3 aggregator. Candidates:
version numbers (`v1.2.3`), times (`3.30 p.m.`), file names, quoted sentences ending inside
quotes, and non-English abbreviations. For each, write the discriminating rule.

**E4.3.3** Add a rule that never splits inside a run of digits longer than four, and verify
it on a phone number spelled with separating spaces. Explain why this rule is about
listener memory rather than syntax.

**E4.3.4** Instrument the aggregator to report, for a corpus of 100 real agent replies, the
distribution of first-flush fraction. Then rewrite the ten worst replies to be more
streamable and re-measure. Quantify the latency won by prompt style alone.

**E4.3.5** Implement chunk-level text-to-audio mapping: carry the source text with each
audio chunk and, given a playback position, return the exact prefix heard. Test it against
the barge-in scenario in
[`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md) §3.

**E4.3.6** Build the §2.7 cache with a correct key. Then demonstrate three failures:
omitting engine version, omitting sample rate, and omitting speed. Describe the user-visible
symptom of each.

**E4.3.7** Measure `chars_synthesised / chars_heard` for lookahead depths of one, two and
five clauses under a simulated interruption distribution. Recommend a depth and justify it
with the cost figure.

---

## 7. Interview drill

> "Our agent's first word arrives 1.4 seconds after the user stops talking. The ASR
> finalises in 120 ms, the LLM's first token comes at 280 ms, and our TTS vendor advertises
> 90 ms TTFB. Where is the missing second?"

The stated numbers sum to under 500 ms, so the answer is in what was *not* measured, and
naming the two candidates is the substance.

**The aggregator.** If it waits for a sentence-terminating boundary and the LLM writes long
sentences, no text reaches the TTS engine until the reply is nearly complete. At 40
tokens/second a 60-token reply takes 1.5 seconds to generate, so a full-reply flush puts
first audio at roughly `280 ms + 1500 ms + 90 ms`. That single design choice accounts for
the entire missing second, and §2.4's measurement shows the effect directly: the
`no terminal` case cannot flush until 100% of the reply exists.

**The endpointing wait, if the 1.4 s was measured from the user's last word rather than from
`t_eou`.** Establishing which mark the measurement started from is the first clarifying
question, because if it is `speech_end` then several hundred milliseconds are endpointing
policy and belong to a different chapter
([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)).

The vendor's 90 ms should also be treated sceptically but not blamed: it is measured at
their edge from complete text (§2.1), so your real figure includes TLS, region and
queueing — likely 150–250 ms rather than 90 ms. That is a real discrepancy and it is not
where the second went.

The fix, in order of leverage. **Flush on clause boundaries, not just sentences**, which
§2.4 shows can move first audio to 35% of the reply. **Prompt for short sentences**, because
the aggregator cannot create boundaries that the text does not contain — this is the part
candidates miss, and it is the reason the prompt and the aggregator must be tuned as one
system. **Keep connections warm** to remove per-utterance handshakes. And **instrument the
real span**, `ttft_llm` to `ttfa`, so the aggregator's contribution is visible instead of
inferred.

The senior close is to note the tradeoff being accepted rather than presenting the fix as
free: aggressive clause splitting damages prosody at the seams (§2.5), and the mitigation is
either engine-side continuation — which is an engine *selection* criterion, so it belongs in
the procurement decision — or accepting the seam. Stating that explicitly, and proposing a
listening test alongside the latency measurement, is what distinguishes a complete answer
from a latency-only one.

---

## Sources

- `livekit/agents`, `livekit-agents/livekit/agents/voice/agent_session.py` (main branch, retrieved 2026-08-22) — `DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` and `DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)`, quoted in §4.
- `pipecat-ai/pipecat` — sentence aggregation as an explicit pipeline stage, referenced in §4.
- `piper-tts` and `kokoro` PyPI metadata (retrieved 2026-08-22) — the local, in-process synthesis path discussed in §4; architectural detail in [`01-tts-architectures.md`](01-tts-architectures.md).
- The batch-versus-streaming latency arithmetic in §1 is derived in [`../01-foundations/00-what-is-a-voice-agent.md`](../01-foundations/00-what-is-a-voice-agent.md) §2, with its own measured output.
- All `[MEASURED]` values in §2.3 and §2.4 were produced by the code in §3 on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. The first-flush fractions depend on the specific test sentences; the transferable result is that the range spans 35% to 100% and is governed by punctuation placement rather than by the aggregator.
