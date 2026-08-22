# Barge-In: Interruption as a Distributed-State Problem

**What you'll be able to do after this:** enumerate the four candidate interruption
signals and choose which to act on from their false-positive costs; explain why stopping
the speaker is only half of a correct barge-in; truncate the conversation context to what
the user actually *heard*, and show what breaks if you do not; implement cancellation
that leaves no zombie tasks; and distinguish a genuine interruption from a backchannel.

---

## 1. Intuition

Your agent is mid-sentence. The user starts talking. Something must happen quickly, and
the naive implementation — "stop the audio" — is not merely incomplete, it introduces a
subtler bug than the one it fixes.

The reason is that a spoken sentence exists in **four different states simultaneously**,
spread across your system:

| State | Where it lives | At barge-in |
|---|---|---|
| **Generated** | the LLM's output, in your conversation context | complete, or nearly |
| **Synthesised** | TTS output bytes, in a queue | ahead of playback |
| **Transmitted** | in the jitter buffer / network / client buffer | ahead of playback |
| **Heard** | past the user's ear | the only one that is real |

The agent's *belief* about what it said comes from the first row. The user's belief comes
from the fourth. Barge-in is the moment those two diverge, and if you do not reconcile
them, the agent proceeds through the rest of the conversation confident that it
communicated information the user never received.

Measured on the simulation in §3: a 14-word reply, interrupted 1.2 seconds in. The LLM
generated all 14 words. TTS synthesised all 14. The user heard **5**. If you append the
generated text to the context, the agent now believes it told the user the account
balance. It did not. The next turn will be built on a false premise, and the failure is
invisible in logs unless you were looking for it.

So barge-in decomposes into three obligations, and most implementations do only the
first:

1. **Stop making sound**, fast — under roughly 100 ms or the agent seems deaf.
2. **Cancel the work in flight** — LLM generation, TTS synthesis — or you pay for tokens
   and audio nobody will hear, and risk a zombie task writing to a dead session.
3. **Truncate the conversation context** to the words actually heard, so the agent's
   belief matches the user's.

The second intuition is about *when* to act. You have four increasingly reliable and
increasingly late signals that the user is speaking, and choosing among them is a
cost-of-false-positive decision, not an accuracy decision.

---

## 2. Rigour

### 2.1 The four interruption signals

| Signal | Latency after speech onset | False positives from | Cost of acting wrongly |
|---|---|---|---|
| **Audio energy rises** | ~20 ms | any noise, echo of your own output | agent stops constantly; unusable |
| **VAD confirms speech** | ~50–150 ms | non-speech noise, TV, other people, own echo | agent stops mid-sentence for a door slam |
| **ASR emits a partial word** | ~200–500 ms | ASR hallucination on noise | mostly safe; costs a third of a second |
| **Semantic check: is it an interruption?** | ~400–800 ms | few | too slow to feel responsive |

The dominant consideration is that the two fast signals cannot distinguish the user's
voice from **the agent's own voice returning through the speaker**. That is not a rare
edge case; it is the default outcome on any device without echo cancellation, and it
produces an agent that interrupts itself every time it speaks
([`05-echo-and-aec.md`](05-echo-and-aec.md)). Before tuning any barge-in threshold,
confirm that AEC is working — otherwise you are tuning against your own output.

The practical resolution used in production is a **two-stage commit**: act on the fast
signal by *pausing* audio (cheap, instantly reversible), then confirm with a slower
signal and either commit to the interruption or resume. This gets the responsiveness of
VAD with the precision of ASR, and it is why frameworks expose both a debounce duration
and a false-interruption timeout (§4).

### 2.2 Debounce: requiring sustained speech

The simplest filter is a minimum duration: require $d$ milliseconds of continuous
detected speech before treating it as an interruption. It rejects clicks, coughs and
single-frame noise.

It also costs you exactly $d$ milliseconds of extra audio played into the user's
interruption. Measured `[MEASURED]`:

| Barge-in at | Debounce | Words heard by user | Words discarded |
|---|---|---|---|
| 1200 ms | 0 ms | 5 | 9 |
| 1200 ms | 200 ms | **6** | 8 |
| 2500 ms | 200 ms | 11 | 3 |

The 200 ms debounce let one additional word reach the user. That is the trade in
concrete terms: fewer false interruptions, slightly more talking over the user. For a
200 ms debounce the cost is under a word, which is why values in that range are common.

### 2.3 Word-count gating for backchannels

Duration alone cannot distinguish "mhm" from "wait, stop". Both are short bursts of
genuine speech. The discriminator is **content**, and the cheapest usable version is a
word count: require at least $n$ recognised words before committing to an interruption.

This is what the field converged on — `min_interruption_words` is a real parameter in
LiveKit Agents (§4) — and it works because backchannels are lexically closed. "mhm",
"yeah", "right", "okay", "uh-huh", "I see" acknowledge without claiming the floor.

Two refinements that matter:

**A word-count gate necessarily waits for ASR.** You cannot count words you have not
recognised, so this signal arrives on the ASR partial timeline (200–500 ms), not the VAD
timeline. Combined with the two-stage commit from §2.1, that is fine: pause on VAD,
count words on the partial, resume if it was a backchannel.

**Backchannels should not be discarded, only not treated as interruptions.** "Mhm" is
information — the user is following. Feeding it to the LLM as a user turn produces an
absurd exchange; ignoring it entirely loses the signal. The usual handling is to record
it in the transcript without triggering a response.

The genuinely hard case is prosody-dependent: "yeah" with falling pitch is agreement,
"yeah?" with rising pitch is a request for clarification, and "yeah, but—" is a
full-blooded interruption. Word count gets the first two wrong in opposite directions,
which is one motivation for audio-native turn models
([`03-semantic-turn-detection.md`](03-semantic-turn-detection.md)).

### 2.4 The false interruption, and resuming

If you commit on a fast signal and the confirmation never arrives — noise, a cough, a
third party — you have stopped the agent mid-sentence for nothing. Two possible
recoveries:

**Resume** the interrupted utterance from where it stopped. Preserves the information,
and sounds odd if the gap was long, because human speakers do not resume mid-clause
after four seconds of silence.

**Abandon and wait** for the user. Natural, and the information in the abandoned
sentence is lost — which matters if it was "your card was declined".

The mechanism both require is a timer: if no user speech is confirmed within $T$ after a
suspected interruption, treat it as false. LiveKit exposes exactly this pair —
`false_interruption_timeout` and `resume_false_interruption` (§4) — and the existence of
a `resume_false_interruption` flag tells you the answer is product-dependent rather than
universal.

### 2.5 Transcript truncation: the obligation everyone skips

This is the core of the chapter. When an utterance is interrupted, the conversation
context must record **what the user heard**, not what was generated.

Measured, 14-word reply interrupted at 1200 ms with a 200 ms debounce `[MEASURED]`:

```
words generated : 14
words HEARD     : 6  -> 'I have checked your account and'
words discarded : 8 (synthesised, never heard)
context must be truncated to the 6 heard words
```

Consider the two ways of recording this turn:

- **Wrong.** `assistant: "I have checked your account and the balance is four hundred and
  twelve dollars"`. The agent believes the balance was communicated. If the user's
  interruption was "sorry, what's my balance?", the agent's most likely next move is
  confusion or a curt "as I said…", because from its perspective it just answered.
- **Right.** `assistant: "I have checked your account and" (interrupted)`. The agent
  knows it was cut off mid-sentence and that the balance was never delivered. It can
  answer the question naturally.

The `interrupted` flag matters as much as the truncation. Without it, the model sees a
grammatically broken assistant turn and no explanation, and well-behaved models will
sometimes try to "repair" it by repeating from the start.

**Getting the boundary right requires alignment.** You know how many *bytes* were played,
and you need to know which *words* those bytes covered. Three approaches, in increasing
fidelity: assume a speaking rate and divide (crude, off by a word or two); use TTS
word-timing metadata where the engine provides it (accurate, not universally available);
or track which text chunk each audio buffer came from and truncate at chunk granularity
(always available if your aggregator preserves the mapping, which is why
[`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md) keeps text alongside
audio chunks).

Chunk granularity is usually the right engineering answer: a clause-level boundary is
close enough that the model's belief is correct in substance, and it requires no engine
support.

### 2.6 Cancellation without zombies

Barge-in is fundamentally a cancellation problem across a pipeline, and asyncio makes
several failure modes easy.

**Cancel upstream first, flush downstream second.** If you flush the playout buffer while
the TTS task is still running, it writes more audio into the buffer you just emptied.
Order matters: cancel producers, then clear buffers.

**Async generators need explicit cleanup.** A stage implemented as `async for chunk in
tts.stream(...)` holds a generator that must be closed, or its `finally` block may run
arbitrarily late — after the session ended, when the socket it writes to is gone. Use
`aclose()`, or structure stages so cancellation propagates through a `TaskGroup`.

**Cancellation is not instantaneous.** A task blocked in a network read cancels when its
await point resumes. If a TTS vendor call has no timeout, cancellation can lag
arbitrarily. Every network call in the response path needs a timeout for this reason as
much as for reliability
([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).

**The zombie TTS bug** is the canonical failure: user interrupts, a new turn begins, and
the *previous* turn's TTS task — never properly cancelled — resumes and writes audio into
the new turn's playout buffer. The user hears fragments of the old answer spliced into the
new one. It is intermittent, timing-dependent, and immediately recognisable once you have
seen it. The defence is structural: tag every audio buffer with its turn id and discard
buffers whose id is not current. Cheap, and it converts a baffling audio bug into a log
line.

### 2.7 The stop-latency budget

From interruption commit to silence, the terms are:

| Term | Typical | Controllable? |
|---|---|---|
| Cancel tasks, clear local buffer | ~1 ms | yes, and it is trivially fast |
| Clear the transport's send queue | 0–50 ms | partially |
| Audio already in the jitter buffer | 40–200 ms | yes — this is your jitter buffer depth |
| Client playout buffer | 20–100 ms | partially, via client config |
| Speaker and acoustic delay | ~5 ms | no |

Measured stop latency in the §3 simulation was 0.1–0.2 ms `[MEASURED]` — because the
simulation has no network. That is the point of showing it: **in-process cancellation is
effectively free, and your real stop latency is dominated entirely by buffers you have
already committed audio to.** A deep jitter buffer that protects against packet loss also
guarantees the agent keeps talking after it decided to stop. This is the same tradeoff as
[`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md) §2.7,
seen from the other direction, and it is why aggressive playout buffering makes an agent
feel unresponsive in a way no amount of model speed can fix.

---

## 3. From scratch

A barge-in with correct ordering, cancellation and truncation. The four states of §1 are
represented explicitly: `queued` is synthesised-but-not-heard, `spoken` is heard.
Standalone, stdlib asyncio only.

```python
"""Barge-in: cancel upstream, flush downstream, truncate context to what was HEARD."""
import asyncio
import time

class Player:
    """Playout buffer. Audio written here is not yet heard; audio popped IS heard.
    The distinction between `queued` and `spoken` is the whole problem."""

    def __init__(self, sec_per_word=0.25):
        self.queued: list[str] = []
        self.spoken: list[str] = []
        self.sec_per_word = sec_per_word

    def write(self, word):
        self.queued.append(word)

    async def run(self):
        while True:
            if self.queued:
                self.spoken.append(self.queued.pop(0))
                await asyncio.sleep(self.sec_per_word)
            else:
                await asyncio.sleep(0.01)

    def flush(self) -> int:
        """Discard un-played audio. Returns words the user will never hear."""
        n = len(self.queued)
        self.queued.clear()
        return n

async def llm(words, out, tok_per_s=20):
    for w in words:
        await asyncio.sleep(1 / tok_per_s)
        await out.put(w)
    await out.put(None)

async def tts(inp, player, synth_ms=60):
    while True:
        w = await inp.get()
        if w is None:
            return
        await asyncio.sleep(synth_ms / 1000)
        player.write(w)

REPLY = ("I have checked your account and the balance is "
         "four hundred and twelve dollars").split()

async def run_turn(barge_in_at_ms=None, debounce_ms=0):
    q, player = asyncio.Queue(), Player()
    tasks = [asyncio.create_task(llm(REPLY, q)),
             asyncio.create_task(tts(q, player)),
             asyncio.create_task(player.run())]

    if barge_in_at_ms is None:
        await asyncio.gather(tasks[0], tasks[1])          # let generation finish
        while player.queued:                             # let playout drain
            await asyncio.sleep(0.01)
        stop_ms, dropped = 0.0, 0
    else:
        await asyncio.sleep(barge_in_at_ms / 1000)       # user starts speaking
        await asyncio.sleep(debounce_ms / 1000)          # require sustained speech
        t0 = time.monotonic()
        # ORDER MATTERS: cancel producers first, or TTS refills the buffer we clear.
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        dropped = player.flush()
        stop_ms = (time.monotonic() - t0) * 1000

    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

    return {
        "generated": len(REPLY),
        "heard": list(player.spoken),
        "dropped": dropped,
        "stop_ms": stop_ms,
        "interrupted": barge_in_at_ms is not None,
    }

def context_entry(result):
    """What MUST go into the conversation context. Not what was generated."""
    text = " ".join(result["heard"])
    return {"role": "assistant", "content": text, "interrupted": result["interrupted"]}

async def main():
    print(f"reply is {len(REPLY)} words\n")
    for at, dbc in ((None, 0), (1200, 0), (1200, 200), (2500, 200)):
        r = await run_turn(at, dbc)
        print(f"barge_in_at={at} debounce={dbc}ms")
        print(f"  words generated : {r['generated']}")
        print(f"  words HEARD     : {len(r['heard'])}  -> {' '.join(r['heard'])!r}")
        print(f"  words discarded : {r['dropped']} (synthesised, never heard)")
        print(f"  stop latency    : {r['stop_ms']:.1f} ms")
        print(f"  context entry   : {context_entry(r)}\n")

asyncio.run(main())
```

Measured output `[MEASURED]`, abbreviated:

```
reply is 14 words

barge_in_at=1200 debounce=0ms
  words generated : 14
  words HEARD     : 5  -> 'I have checked your account'
  words discarded : 9 (synthesised, never heard)
  stop latency    : 0.2 ms

barge_in_at=1200 debounce=200ms
  words generated : 14
  words HEARD     : 6  -> 'I have checked your account and'
  words discarded : 8 (synthesised, never heard)

barge_in_at=2500 debounce=200ms
  words generated : 14
  words HEARD     : 11  -> 'I have checked your account and the balance is four hundred'
  words discarded : 3 (synthesised, never heard)
```

Three things this makes concrete.

**Generation runs far ahead of playback.** At 20 tokens/s the LLM finishes 14 words in
700 ms, while playback at 250 ms per word takes 3.5 seconds. So at any interruption the
gap between generated and heard is large — 9 words in the first case. This is not a
tuning artefact; it is the *normal* state of a streaming pipeline, and it is precisely why
truncation is mandatory rather than a nicety.

**The last row is the dangerous one.** The user heard "…four hundred" and was interrupted
before "and twelve dollars". Recording the full generated text means the agent believes it
stated $412. Recording the heard text means it knows it said "four hundred" and was cut
off — a materially different and *correctable* state.

**Stop latency of 0.1 ms is a warning, not a triumph.** In-process cancellation is free;
every real millisecond comes from network and playout buffers you cannot cancel (§2.7).
Do not read a fast local number as evidence that barge-in is responsive in production.

---

## 4. How production does it

**LiveKit Agents** exposes this as a coherent parameter set. Verified from
`livekit/agents`, `livekit-agents/livekit/agents/voice/agent_session.py` (main branch,
retrieved 2026-08-22): the individual keyword arguments are **deprecated in favour of
`turn_handling=TurnHandlingOptions(...)`**, and the parameter names are
`allow_interruptions`, `min_interruption_duration`, `min_interruption_words`,
`discard_audio_if_uninterruptible`, `false_interruption_timeout`,
`resume_false_interruption`, `agent_false_interruption_timeout`,
`min_endpointing_delay`, `max_endpointing_delay`, `turn_detection` and
`preemptive_generation`.

That list is worth reading as a summary of this module, because each name is a concept
from these chapters:

| Parameter | Chapter concept |
|---|---|
| `min_interruption_duration` | debounce, §2.2 |
| `min_interruption_words` | backchannel gating, §2.3 |
| `false_interruption_timeout` + `resume_false_interruption` | false interruption and recovery, §2.4 |
| `allow_interruptions` | uninterruptible utterances (legal disclosures, §5) |
| `discard_audio_if_uninterruptible` | what to do with user audio while not interruptible |
| `min_endpointing_delay` / `max_endpointing_delay` | the context floor and hard bound, [`02-endpointing.md`](02-endpointing.md) §2.7 |
| `turn_detection` | [`03-semantic-turn-detection.md`](03-semantic-turn-detection.md) |
| `preemptive_generation` | speculative generation on partials, [`../05-llm-layer/02-context-and-memory.md`](../05-llm-layer/02-context-and-memory.md) |

**Do not quote defaults from this chapter.** They live in the options module and change
between releases; read them from the version you deploy. The *names* are the durable part,
and the migration to `TurnHandlingOptions` is the thing to know if your team is on an
older release.

Two further verified details from the same file, both relevant here:
`DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` — the framework strips
markdown and emoji before synthesis, which is the failure mode catalogued in
[`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md)
being handled at the framework level; and `_DEFAULT_AEC_WARMUP_DURATION = 3.0`, an
acknowledgement that echo cancellation needs time to converge before its output can be
trusted ([`05-echo-and-aec.md`](05-echo-and-aec.md)).

**Pipecat** models interruption as control frames travelling in band with data frames, so
an interruption cannot overtake the audio it is meant to cancel — the ordering guarantee
that §2.6 says you need, enforced by the architecture rather than by discipline
([`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)).

**Hosted speech-to-speech APIs** handle interruption server-side and provide an event
plus a mechanism to truncate the assistant item, because the same four-state divergence
exists there. The API surface differs; the obligation does not
([`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)).

---

## 5. At scale

**Instrument both directions, because one alone is misleading.** Track
`interruption_rate` (interruptions per turn) and `barge_in_latency` (commit to silence).
A rising interruption rate has three distinct causes with opposite fixes: endpointing
became too aggressive so the agent starts talking too early
([`02-endpointing.md`](02-endpointing.md) §5); echo cancellation is failing so the agent
hears itself ([`05-echo-and-aec.md`](05-echo-and-aec.md)); or responses got longer, so
there is more agent speech to interrupt. Add response length to the same dashboard and the
three separate immediately.

**Truncation correctness is invisible without an explicit check.** No user reports "your
context is wrong" — they report that the agent is confusing. Add an invariant to your
transcript pipeline: an interrupted assistant turn must be a strict prefix of the
generated text and must carry the interrupted flag. Assert it in tests
([`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md)) and count
violations in production.

**Discarded synthesis is measurable waste.** §3 discarded 8 of 14 words — audio that was
generated, synthesised, possibly paid for per character, and never heard. At scale this is
a real line item, and it is the strongest argument for a smaller TTS lookahead: synthesise
one clause ahead rather than five, and an interruption wastes less. It is also an argument
against very long responses, which lose more work per interruption.

**Some utterances must not be interruptible**, and the mechanism must exist before you
need it. Legal disclosures, recording notices and consent statements often must be
delivered in full for compliance
([`../08-eval-safety/03-safety-and-privacy.md`](../08-eval-safety/03-safety-and-privacy.md)).
That is what `allow_interruptions=False` is for — and it needs a companion decision about
the user audio arriving during that period, which is what
`discard_audio_if_uninterruptible` decides. Dropping it loses what the user said; keeping
it means processing speech that overlapped your disclosure.

**Interruption rate varies by population and is a fairness signal.** Users who speak more
slowly, or with more pauses, are interrupted more by an agent whose endpointing was tuned
on fluent speakers — and they then interrupt back more often. Segment
`interruption_rate` the same way you segment cut-off rate
([`02-endpointing.md`](02-endpointing.md) §5); a disparity here is invisible in aggregate.

**Tag audio with turn ids in production, not just in tests.** §2.6's zombie bug is timing
dependent, so it appears under load and not in development. A turn-id check on every
buffer is a few bytes and turns an unreproducible audio artefact into a counter you can
alert on.

---

## 6. Exercises

**E3.4.1** Run the §3 code. Then change the LLM rate to 60 tokens/s and the playback rate
to 0.4 s per word, and re-measure words heard versus generated at a 1200 ms barge-in.
Explain how the generated/heard gap depends on the ratio of the two rates.

**E3.4.2** Reverse the cancellation order in `run_turn` — flush the player before
cancelling the tasks — and demonstrate the resulting bug. Report how many words are
written into the buffer after the flush.

**E3.4.3** Implement the two-stage commit from §2.1: pause playback on VAD, then confirm
or resume based on an ASR partial arriving 300 ms later. Measure the extra audio played in
the confirm case and the recovery quality in the false-positive case.

**E3.4.4** Add `min_interruption_words` behaviour: maintain a backchannel list, and commit
the interruption only when a non-backchannel word appears. Test it against "mhm", "yeah
but wait" and "sorry, stop".

**E3.4.5** Implement chunk-level truncation: have TTS carry the source text with each
audio chunk, and truncate the context at the last fully-played chunk. Compare its accuracy
against the word-count approximation in §3.

**E3.4.6** Simulate the zombie-TTS bug: interrupt, start a new turn, and let a
non-cancelled old task write into the new player. Then fix it with turn-id tagging and show
the buffers being discarded.

**E3.4.7** Model the §2.7 stop-latency budget for a WebRTC deployment with a 120 ms jitter
buffer and a 60 ms client playout buffer. Compute total stop latency and identify the
largest reducible term, then state what reducing it costs.

---

## 7. Interview drill

> "Our agent handles interruptions — audio stops within 80 ms. But users say it 'forgets
> what it just told them' and sometimes repeats itself. Diagnose."

The 80 ms figure is the tell: they solved obligation one from §1 and not obligation
three. Audio stops promptly, and the conversation context still records the *generated*
text rather than the *heard* text. Both reported symptoms follow from that single defect,
and being able to derive two different-looking complaints from one cause is the answer.

**"Forgets what it just told them"** is the agent's belief being *too complete*. It thinks
it delivered the balance, so it does not repeat it, and the user — who never heard it —
experiences the agent as having forgotten. The §3 measurement makes the scale concrete:
at a 1200 ms interruption, 9 of 14 words were never heard, so most of the sentence exists
only in the agent's belief.

**"Sometimes repeats itself"** is the same divergence from the other side. A truncated,
grammatically broken assistant turn with no `interrupted` marker invites the model to
repair it, and repair often means restarting the sentence. So the fix has two parts — the
truncation *and* the flag — and shipping only the truncation produces the second symptom.

The remedy, concretely: on interruption, record what was played, not what was generated;
mark the turn interrupted; and get the boundary from the audio-to-text mapping rather than
by estimating a speaking rate (§2.5). Chunk-level granularity is sufficient and needs no
TTS engine support, which makes it the pragmatic choice.

Then verification, because this class of bug is silent: add the invariant that an
interrupted assistant message is a strict prefix of the generated text and carries the
flag, assert it in tests, and count violations in production (§5).

The senior addition is to check the premise. "Repeats itself" is also the signature of the
zombie-TTS bug from §2.6, where an uncancelled previous turn resumes and splices old audio
into the new turn — and that is a cancellation defect, not a context defect. The
distinguishing evidence is whether the repetition is *audio* from the old turn or *newly
generated* text; those have different fixes, and a turn-id tag on every buffer decides it
in one log line. Confirming which mechanism you are looking at before fixing is what
separates a diagnosis from a guess.

---

## Sources

- `livekit/agents`, `livekit-agents/livekit/agents/voice/agent_session.py` (main branch, retrieved 2026-08-22) — the `AgentSession` parameter names `allow_interruptions`, `min_interruption_duration`, `min_interruption_words`, `discard_audio_if_uninterruptible`, `false_interruption_timeout`, `resume_false_interruption`, `agent_false_interruption_timeout`, `min_endpointing_delay`, `max_endpointing_delay`, `turn_detection`, `preemptive_generation`; their deprecation in favour of `turn_handling=TurnHandlingOptions(...)`; and the constants `DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` and `_DEFAULT_AEC_WARMUP_DURATION = 3.0`, all quoted in §4. Defaults for the individual options are deliberately not quoted; read them from your deployed version.
- `pipecat-ai/pipecat` — interruption as in-band control frames, the ordering guarantee referenced in §2.6 and §4; detailed in [`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md).
- Python `asyncio` documentation — task cancellation semantics, `TaskGroup`, and async-generator `aclose()`, the basis for §2.6.
- Schegloff, E. A. (2000). *Overlapping talk and the organization of turn-taking for conversation.* Language in Society 29(1) — how human speakers resolve overlap, and the distinction between backchannels and floor-claiming interruptions used in §2.3.
- All `[MEASURED]` values in §2.2, §2.7 and §3 were produced by the code in §3 on Apple M5 / macOS 26.5.2 via `uv run --python 3.12`, CPython 3.12. The simulation has no network, so its stop latency reflects in-process cancellation only — §2.7 explains why real stop latency is dominated by buffers instead.
