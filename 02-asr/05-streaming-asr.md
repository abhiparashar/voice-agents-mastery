# Streaming ASR: Partial Truth Under Time Pressure

**What you'll be able to do after this:** distinguish architecturally-streaming
recognisers from window-and-recompute wrappers, and say which one you are running;
define partial and final transcripts as an API contract and enforce the rule that
partials never reach the LLM; implement LocalAgreement stabilisation and explain the
one failure it cannot fix; and measure emission latency rather than guessing at it.

---

## 1. Intuition

A non-streaming recogniser answers one question: *what was said?* A streaming
recogniser must answer a harder one continuously: *what has been said so far, and how
much of that am I willing to stand behind?*

That second clause is the whole subject. Recognition is inherently retrospective —
"I scream" and "ice cream" are distinguished by what follows, and a recogniser that
commits after every word will be wrong regularly. So a streaming system is
permanently trading two costs against each other: **emit early and be wrong**, or
**emit late and be slow**. There is no configuration that avoids the trade; there is
only choosing where to sit on it, and knowing which errors you have chosen to accept.

The critical realisation for a voice agent is that these two costs land on different
consumers, and they have opposite preferences.

- The **barge-in detector** wants the earliest possible signal. It does not care what
  the words are — the mere fact that a confident word appeared while the agent was
  speaking is enough to interrupt. Being wrong occasionally is cheap.
- The **LLM** wants the truth, once. Feeding it a hypothesis that later changes is
  not a small error; it is a *permanent* error, because the model has already
  conditioned on it and may have already spoken. There is no retraction mechanism in
  a conversation.
- The **UI**, if there is one, wants continuous updates and tolerates flicker,
  because humans read live captions with an implicit understanding that text may
  revise.

One recogniser, three consumers, three different tolerances. That is why partial and
final transcripts must be *typed differently* in your interfaces, and why the single
most common architectural bug in voice agents — appending partials to the LLM context
— is so damaging: it silently converts a normal, expected recogniser behaviour into
an unrecoverable conversational error.

---

## 2. Rigour

### 2.1 Two families, often confused

**Architecturally streaming.** The model is built to consume audio incrementally.
Concretely this requires: a causal or limited-lookahead encoder (no attention over
future frames beyond a fixed budget), carried state between chunks, and an output head
that can emit before the input ends. Transducers
([`03-rnnt-transducer.md`](03-rnnt-transducer.md)) are the canonical case; Conformer,
Zipformer and Emformer encoders provide the streaming-capable acoustic side.

**Window-and-recompute.** Take a non-streaming model and repeatedly re-run it on a
growing or sliding buffer. The model does not know it is streaming. This is what
almost everyone running Whisper in real time is actually doing, and it has a
distinctive signature: hypotheses that *revise* as context grows.

The distinction matters because the two families fail differently, and the mitigations
do not transfer:

| | Architecturally streaming | Window-and-recompute |
|---|---|---|
| Emission | monotonic, append-only by construction | non-monotonic; earlier words can change |
| Compute per second of audio | ~1× | $O(\text{buffer} / \text{hop})$ — repeated work |
| Latency floor | encoder lookahead + decode | recompute interval + model latency |
| Failure mode | early commit to a wrong word | flicker, contradiction, unbounded revision |
| Accuracy ceiling | limited by lookahead | full model quality |
| Fix for instability | delay penalty during training | a stabilisation policy at decode (§2.4) |

The single most useful diagnostic question about someone's "streaming ASR" is: *can
an already-emitted word change?* If yes, they are in the right column, whatever the
vendor called it.

### 2.2 Lookahead as the fundamental knob

For a streaming encoder, **right context** (lookahead) is the number of future frames
each output may attend to. It is the dial that connects accuracy to latency directly:

- **Zero lookahead (fully causal).** Minimum latency. Worst accuracy, because
  phoneme identity genuinely depends on what follows — coarticulation is bidirectional.
- **Chunked attention.** Process in chunks of $C$ frames, allowing attention within
  the chunk and to a limited number of future frames. Latency is bounded by the chunk
  boundary; a frame arriving at the start of a chunk waits for the whole chunk.
- **Unlimited lookahead.** Offline. Best accuracy, unusable for interaction.

The qualitative shape of the tradeoff is universal: WER falls steeply as lookahead
grows from zero, then flattens, so there is a knee where additional latency buys
almost nothing. The location of that knee is model- and language-specific and must be
measured on your own data — published curves in the Conformer, Emformer and Zipformer
literature show the shape, and quoting a specific millisecond figure from a paper as
if it applied to your system would be exactly the error this curriculum warns
against. `[INFERENCE]` on the universality of the shape; the mechanism (bidirectional
coarticulation with finite temporal span) is the reason to expect it.

Note the asymmetry that makes this a *design* choice rather than a tuning exercise:
chunk size affects **every** frame's latency, while lookahead affects accuracy
globally. A 320 ms chunk means the unluckiest frame waits 320 ms before the encoder
even sees its chunk completed — which is why chunk size, not model speed, is usually
the floor on a streaming recogniser's emission latency.

### 2.3 Partial and final: the API contract

Define the contract explicitly, because ambiguity here produces bugs that look like
model problems.

| Property | Partial | Final |
|---|---|---|
| May be revised later | **yes** | no |
| Safe to append to LLM context | **never** | yes |
| Safe to use for barge-in detection | yes | yes, but too late |
| Safe to display | yes, with the expectation of change | yes |
| Safe to trigger a side effect | **never** | yes, with idempotency |
| Emitted every | ~100–300 ms | once per turn |

Two rules follow, and both are worth stating as invariants your code enforces rather
than as guidance.

**Partials are for timing, finals are for content.** Any consumer that acts on
*meaning* must wait for a final. Any consumer that acts on *the existence of speech*
should use partials, because waiting for a final adds hundreds of milliseconds to
interruption response.

**A final is a commitment, not a confidence score.** Once emitted, downstream state
may have changed irreversibly — the LLM has been called, the agent has spoken, a tool
has run. This is why §2.4's contradiction case is a genuine dilemma rather than a bug
to be fixed.

The useful middle ground is a **stability** signal, where the engine provides one:
the probability that a partial's prefix will not change. It lets you do speculative
work — prefetch a retrieval, warm a prefix cache — on a partial that is 95% stable,
while still deferring the irreversible action to the final. See
[`../05-llm-layer/02-context-and-memory.md`](../05-llm-layer/02-context-and-memory.md).

### 2.4 LocalAgreement: making an unstable stream committable

The policy used by `ufal/whisper_streaming` (Macháček et al., 2023) and widely copied:
**commit the longest prefix on which the last $n$ hypotheses agree.** With $n = 2$,
run the model on a growing buffer, compare consecutive outputs, and treat their common
prefix as final.

The logic is that a prefix which survived one additional recompute — with more audio
context available — is unlikely to change again. It converts a revising stream into an
append-only one, at the cost of lagging by however long agreement takes.

Measured on an 11-step hypothesis stream containing one genuine late revision
(`"I want"` → `"I wanted"`) `[MEASURED]`:

```
--- LocalAgreement-2 ---
  hyp 1  I want to                                     commit: 'I want'
  hyp 2  I want to re                                  commit: 'to'
  hyp 4  I want to reschedule my                       commit: 'reschedule'
  hyp 5  I want to reschedule my appointment           commit: 'my'
  hyp 6  I want to reschedule my appointment for       commit: 'appointment'
  hyp 7  I wanted to reschedule my appointment for to  !! CONTRADICTION with committed prefix
  hyp 8-10  (same contradiction repeats; elided)
  committed prefix: 'I want to reschedule my appointment'

--- LocalAgreement-3 ---
  hyp 2  I want to re                                  commit: 'I want'
  hyp 3  I want to reschedule                          commit: 'to'
  hyp 5  I want to reschedule my appointment           commit: 'reschedule'
  hyp 6  I want to reschedule my appointment for       commit: 'my'
  hyp 7  I wanted to reschedule my appointment for to  !! CONTRADICTION with committed prefix
  hyp 8-10  (same contradiction repeats; elided)
  committed prefix: 'I want to reschedule my'

naive emit-latest: 8 word(s) retracted over 11 updates
```

Three findings, and the third is the important one.

**It suppresses flicker effectively.** A naive emit-latest policy retracted 8 words
over 11 updates. LocalAgreement retracted none — it committed only what two
consecutive hypotheses agreed on.

**$n$ is a latency dial.** LocalAgreement-2 had committed six words by step 6;
LocalAgreement-3 had committed five. Each increment of $n$ costs you one recompute
interval of additional lag and buys additional confidence. This is the same
early-versus-late trade as §2.2, relocated from training to decoding.

**It cannot fix a genuine late revision.** At step 7 the model changed `"want"` to
`"wanted"` — a real correction, made with more context, and *correct*. But `"want"`
was committed at step 1 and may already have been spoken or acted on. Both $n = 2$
and $n = 3$ hit the same contradiction; a larger $n$ only delays the boundary at which
it can occur. There is no stabilisation policy that eliminates this, because the
problem is not statistical, it is temporal: **you cannot un-commit.** The engineering
response is to choose where contradictions are cheap — commit aggressively for display
and barge-in, conservatively for anything irreversible — and to detect and log
contradictions rather than silently dropping them, since their rate is a direct
measure of how badly your commit point is tuned.

### 2.5 Measuring emission latency properly

"Streaming latency" is quoted loosely and usually means the wrong thing. Three
distinct quantities:

| Metric | Definition | What it is for |
|---|---|---|
| **Emission latency** | acoustic end of a word → that word appears in a *final* result | The honest number |
| Partial latency | acoustic end of a word → word appears in any hypothesis | Barge-in responsiveness |
| Finalisation latency | `t_eou` → complete final transcript | The `t_eou → stt_final` term of the budget |

The measurement procedure that works, and the only one that is not self-referential:
take audio with ground-truth word times from forced alignment
([`01-from-hmm-to-e2e.md`](01-from-hmm-to-e2e.md) §2.6), feed it to the recogniser in
real time, and timestamp every emission at the moment your code receives it. Emission
latency per word is then reception time minus the aligned acoustic end time. Report
the distribution, not the mean — the tail is what causes perceptible lag, and in a
window-and-recompute system the tail is set by the recompute interval.

A trap worth naming: measuring latency by replaying audio faster than real time
produces meaningless numbers, because the recogniser's internal buffering no longer
corresponds to wall-clock time. Streaming latency must be measured at 1× speed.

### 2.6 Interaction with endpointing

Streaming ASR and endpointing are frequently conflated and are different mechanisms.
The endpointer decides *when the turn is over*
([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)); the
recogniser decides *what the words are*. They interact in two places.

**Finalisation is triggered by the endpoint, so their latencies add.** A streaming
recogniser typically emits its final result when told the turn ended. If your
endpointer waits 700 ms and finalisation takes 150 ms, the LLM starts 850 ms after the
user stopped — and only the 150 ms is a model cost.

**Partial stability is a useful endpointing feature.** If the hypothesis has not
changed for 300 ms, that is evidence the speaker has stopped, and it is available
*before* a silence timer would fire. Combining VAD silence, partial stability and a
semantic completeness signal is the substance of a good endpointing policy, and the
recogniser supplies one of those three inputs.

---

## 3. From scratch

LocalAgreement-$n$ with explicit contradiction detection. Standalone, stdlib only.

```python
"""LocalAgreement-n stabilisation for a revising hypothesis stream."""

def common_prefix(a, b):
    out = []
    for x, y in zip(a, b):
        if x != y:
            break
        out.append(x)
    return out

def local_agreement(hypotheses, n=2):
    """Commit the longest prefix on which the last n hypotheses agree.

    Returns (committed_tokens, log). A 'contradiction' means a later, better
    hypothesis disagrees with something already committed -- which cannot be
    repaired, only detected. Its rate tells you whether n is large enough.
    """
    committed, window, log = [], [], []
    for i, hyp in enumerate(hypotheses):
        window.append(hyp.split())
        if len(window) > n:
            window.pop(0)

        if len(window) < n:
            log.append((i, "(warming up)"))
            continue

        agreed = window[0]
        for w in window[1:]:
            agreed = common_prefix(agreed, w)

        if agreed[:len(committed)] != committed:
            log.append((i, "!! CONTRADICTION with committed prefix"))
        elif len(agreed) > len(committed):
            new = agreed[len(committed):]
            committed = agreed[:]
            log.append((i, f"commit: {' '.join(new)!r}"))
        else:
            log.append((i, "(nothing new)"))
    return committed, log

def flicker_count(hypotheses):
    """Words a naive emit-latest policy would have to retract."""
    retracted, prev = 0, []
    for h in hypotheses:
        toks = h.split()
        retracted += len(prev) - len(common_prefix(prev, toks))
        prev = toks
    return retracted

if __name__ == "__main__":
    # A realistic stream: a growing prefix, then a genuine late revision at step 7
    # where more context corrects "want" to "wanted".
    HYP = [
        "I want",
        "I want to",
        "I want to re",
        "I want to reschedule",
        "I want to reschedule my",
        "I want to reschedule my appointment",
        "I want to reschedule my appointment for",
        "I wanted to reschedule my appointment for to",
        "I wanted to reschedule my appointment for tomorrow",
        "I wanted to reschedule my appointment for tomorrow afternoon",
        "I wanted to reschedule my appointment for tomorrow afternoon please",
    ]
    for n in (2, 3):
        committed, log = local_agreement(HYP, n)
        print(f"--- LocalAgreement-{n} ---")
        for i, note in log:
            if note not in ("(nothing new)", "(warming up)"):
                print(f"  hyp{i:2d}  {HYP[i][:48]:50s} {note}")
        print(f"  committed: {' '.join(committed)!r}\n")
    print(f"naive emit-latest: {flicker_count(HYP)} word(s) retracted "
          f"over {len(HYP)} updates")
```

The contradiction detection is the part worth keeping. Most implementations of this
policy silently take the new hypothesis and move on, which means the disagreement rate
— the one number that tells you whether your commit point is too aggressive — is never
observed. Log it, aggregate it, and treat a rising rate as a signal that your
recompute interval or your $n$ is wrong.

---

## 4. How production does it

**`ufal/whisper_streaming`** is the reference implementation of §2.4 and worth reading
in full because it is small. Beyond LocalAgreement it solves the problem the policy
creates: the buffer cannot grow forever, so it trims at committed sentence boundaries,
which keeps recompute cost bounded and provides the model with a clean context prefix.
That buffer-trimming logic is the part people omit when they reimplement the paper.

**`k2-fsa/sherpa-onnx`** is the architecturally-streaming counterpart: exported
Zipformer-Transducer encoder/decoder/joiner graphs with explicit state carried across
chunks, plus a WebSocket server. Reading how encoder state is threaded through chunk
boundaries is the clearest available explanation of what streaming means at the tensor
level, and it makes concrete why chunk size is the latency floor (§2.2).

**`ggml-org/whisper.cpp`** ships a sliding-window streaming example with a
VAD gate — the pragmatic combination that most local deployments end up at.

**Vendor streaming APIs** (Deepgram, AssemblyAI, Speechmatics, Google, Azure) all
expose the partial/final distinction over a WebSocket, though the vocabulary differs:
interim versus final, partial versus complete, `is_final`, `speech_final`, endpoint
events. Two things to verify for any vendor before you design around it: **whether
finals are guaranteed monotonic** (some engines can revise across a final boundary),
and **whether they expose an endpointing signal separate from the transcript**, since
if they do, their endpointer's policy becomes part of your latency budget and you must
find out its default.

**NVIDIA Riva and NeMo** provide streaming Conformer-Transducer models with
configurable chunk sizes and lookahead, which is the cleanest way to see §2.2's dial
exposed as a deployment parameter rather than a training decision.

---

## 5. At scale

**Window-and-recompute multiplies your compute bill by the recompute factor.** If you
re-run a model on a growing buffer every 500 ms, a 10-second utterance is processed
roughly 20 times. With Whisper's fixed 30-second window
([`04-attention-and-whisper.md`](04-attention-and-whisper.md) §2.2) each of those runs
costs a full 30-second encoder pass. The arithmetic is brutal and it is why
architecturally-streaming models dominate at high concurrency: they do work
proportional to the audio, once.

**Chunk size is the primary latency/throughput lever, and it moves both.** Larger
chunks mean fewer forward passes (better throughput, better GPU utilisation) and
higher worst-case emission latency. It is one number that trades cost against
responsiveness, so it belongs in the same review as the latency budget rather than in
a model config nobody revisits.

**Partial emission rate is a load multiplier you control.** Emitting partials every
100 ms rather than every 300 ms triples downstream message volume — WebSocket frames,
log lines, UI updates, and any consumer that recomputes on each partial. Choose the
rate from what the consumers actually need: barge-in needs fast partials, captions do
not.

**Stability degrades under load, and the mechanism is worth knowing.** If recompute
falls behind real time, the buffer grows, and hypotheses jump further per update —
which makes LocalAgreement commit in larger, later blocks and raises the contradiction
rate. So a capacity problem shows up as a *quality* problem, and the two are only
distinguishable if you are tracking contradiction rate alongside latency. This is a
general pattern in streaming systems and a good reason to export the metric.

**Never feed partials to the LLM, and enforce it in types.** At scale this bug does
not manifest as an obvious error — it manifests as an elevated rate of the agent
responding to something slightly different from what the user said, distributed
thinly across traffic, and nearly impossible to find by reading logs. The defence is
structural: make partials and finals different types so the compiler or the reviewer
catches the misuse
([`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)).

---

## 6. Exercises

**E2.5.1** Run the §3 code with $n = 1$ and $n = 4$. Report committed length at each
step and the number of contradictions. Plot committed-words-versus-step for all four
values of $n$ and identify the latency cost per increment.

**E2.5.2** Modify the hypothesis stream so the revision happens at step 3 instead of
step 7. Which values of $n$ avoid the contradiction entirely, and what does that tell
you about the relationship between $n$ and revision distance?

**E2.5.3** Construct a hypothesis stream where LocalAgreement-2 commits a word that
*no* later hypothesis contains, without triggering the contradiction check. What
property of the check does this exploit, and how would you strengthen it?

**E2.5.4** Take a real recogniser (faster-whisper on a growing buffer is sufficient),
feed it a 30-second recording in real time, and log every hypothesis with a receive
timestamp. Compute the flicker count and the LocalAgreement-2 contradiction rate on
real data.

**E2.5.5** Using forced alignment for ground truth, measure per-word emission latency
for the setup in E2.5.4. Report the distribution, and identify how much of the median
is attributable to your recompute interval rather than to the model.

**E2.5.6** Compute the total compute for window-and-recompute over a 20-second
utterance with recompute intervals of 250 ms, 500 ms and 1000 ms, assuming Whisper's
fixed 30-second window. Express each as a multiple of a single offline pass, then
compute the same for a hypothetical streaming model doing work proportional to audio.

**E2.5.7** Design the partial/final type contract for your own pipeline: write the two
type definitions, the invariant each consumer must satisfy, and one test per invariant
that would fail if someone passed a partial where a final was required.

---

## 7. Interview drill

> "We use a streaming ASR vendor. Occasionally our agent answers a question the user
> did not ask — close to it, but wrong. It is about 1 in 200 turns. Find it."

The rate is the clue, and a strong answer starts there: 1 in 200 is too frequent for a
model quality issue and too rare for a plumbing bug, which is the signature of a race
condition on a boundary condition. Combined with "close to what they said", this
points at the agent consuming a transcript that was later revised.

Two concrete mechanisms to name and distinguish. **Partials reaching the LLM**, either
directly or because the code treats "the most recent transcript" as authoritative
without checking `is_final`. The tell is that failures correlate with turns where the
final differs from the last partial. **Non-monotonic finals**, where the vendor revises
across a final boundary — which is why §4 says to verify monotonicity explicitly
rather than assuming it. The tell here is a vendor message sequence containing two
finals for one turn.

The diagnostic is cheap and should be proposed concretely: log every hypothesis with
its `is_final` flag and a timestamp, alongside the exact string the LLM was called
with, then join on turns where the agent's answer was reported wrong. One of the two
mechanisms will show up immediately, and the join is the whole investigation.

The fix must be structural rather than a guard clause, and this is what separates a
senior answer. Make partials and finals distinct types so that passing the wrong one
is a type error, not a runtime accident. Add an invariant check that a turn produces
exactly one final and that each final extends the previous committed prefix — logging
a contradiction when it does not, per §2.4, because that rate is a metric you want
permanently. And route consumers deliberately: partials to barge-in detection and the
UI, finals only to the LLM.

Worth closing on the residual: even with all of this, a genuine late revision (§2.4)
can still contradict something the agent already said. That is not solvable by
engineering the transcript path; it is handled conversationally, by having the agent
gracefully accept correction — which makes it a prompt-design requirement
([`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md))
rather than a pipeline one. Recognising which failures are unfixable is part of the
answer.

---

## Sources

- Macháček, D., Dabre, R. & Bojar, O. (2023). *Turning Whisper into Real-Time Transcription System.* arXiv:2307.14743 — the LocalAgreement-$n$ policy implemented in §3, and the buffer-trimming strategy discussed in §4.
- `ufal/whisper_streaming` — reference implementation of the above, checked 2026-08.
- Gulati, A. et al. (2020). *Conformer: Convolution-augmented Transformer for Speech Recognition.* arXiv:2005.08100.
- Shi, Y. et al. (2021). *Emformer: Efficient Memory Transformer Based Acoustic Model for Low Latency Streaming Speech Recognition.* arXiv:2010.10759 — chunked attention with carried memory, the mechanism behind §2.2.
- Yao, Z. et al. (2023). *Zipformer: A faster and better encoder for automatic speech recognition.* arXiv:2310.11230.
- `k2-fsa/sherpa-onnx` (streaming Zipformer-Transducer servers and exported graphs), `ggml-org/whisper.cpp` (sliding-window streaming example), NVIDIA Riva / `NVIDIA/NeMo` (configurable streaming chunk size and lookahead) — production references in §4, checked 2026-08.
- All `[MEASURED]` values in §2.4 were produced by the code in §3 on Apple M5 / macOS 26.5.2, CPython 3.12.
