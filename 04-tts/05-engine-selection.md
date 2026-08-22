# Choosing a TTS Engine

**What you'll be able to do after this:** rank candidate engines against a stated
requirement instead of a demo impression; compute the cost per 1000 audio-minutes for
local and hosted engines with the arithmetic exposed; design an A/B listening test that
produces a defensible decision; and know which requirements make the choice for you.

---

## 1. Intuition

TTS selection is usually done by listening to three demos and picking the nicest voice.
That process reliably produces the wrong answer, because the demos are the vendor's best
sentences read at leisure, and the properties that will determine whether your agent works
are not audible in a demo at all: time-to-first-byte under load, behaviour on your product
names, whether synthesis can be cancelled mid-utterance, whether the voice survives a
failover, and what it costs at your volume.

The useful framing is that **a small number of requirements are decisive and the rest are
preferences.** If you need zero-shot voice cloning, you are in the codec-LM branch and its
latency floor is yours ([`02-codec-lm-tts.md`](02-codec-lm-tts.md) §2.5) — no amount of
voice-quality comparison changes that. If your data cannot leave your infrastructure, you
are self-hosting and the hosted engines are irrelevant regardless of quality. If you need
sub-150 ms first-byte on every turn, the parallel branch is the only candidate.

So the method is: identify the decisive constraints first, which usually eliminates most of
the field; then compare the survivors on cost and quality; then run a listening test to
confirm rather than to decide.

The second observation is that **quality is not a scalar and users do not perceive it as
one.** An engine can have superb prosody on long-form narration and mangle a spelled
reference number. For a voice agent the distribution of utterances is unusual — short
confirmations, digit strings, names, and repeated boilerplate — and it is nothing like the
audiobook-style text vendors optimise for. Evaluate on your traffic.

---

## 2. Rigour

### 2.1 The decisive constraints

Work through these before looking at any voice sample. Each one eliminates candidates
outright.

| Constraint | If it holds | Eliminates |
|---|---|---|
| **Audio cannot leave your infrastructure** (health, finance, government, on-prem) | self-host only | every hosted engine |
| **Zero-shot cloning required** | codec-LM branch | Piper, Kokoro, most parallel engines |
| **`ttfb_tts` p95 under ~150 ms required** | parallel branch, ideally local | autoregressive codec-LM engines |
| **Offline or intermittent connectivity** | local only | every hosted engine |
| **Language not in the engine's set** | whichever supports it | most |
| **Code-switching within a sentence** | multilingual model trained on mixed speech | monolingual engines |
| **Marginal cost must be ~zero at high volume** | local | per-character billing |
| **Deterministic output required** (byte-identical caching, snapshot tests) | parallel branch | sampling-based codec-LM |

The pattern is that most decisive constraints push toward **local, parallel** engines, and
the main one pushing the other way is cloning. That asymmetry is worth internalising: for a
typical production voice agent, a local VITS or StyleTTS-class engine satisfies more hard
constraints than a hosted codec-LM engine does, and the reason to choose the latter is a
specific product requirement rather than general quality.

### 2.2 The evaluation axes that matter

| Axis | How to measure it | Why demos do not show it |
|---|---|---|
| `ttfb_tts` p50/p95 | from your process, your region, on your text lengths | demos measure the vendor's edge on complete text |
| Throughput after first byte | must exceed 1× real time with margin | never the bottleneck in a demo |
| Cancellation latency | time from cancel to no more audio | demos never cancel |
| Streaming input support | can you send text incrementally? | affects prosody at seams ([`03-streaming-tts.md`](03-streaming-tts.md) §2.5) |
| Alignment metadata | word or character timings returned? | needed for barge-in truncation |
| Pronunciation control | phoneme input, lexicon support | demo text has no product names |
| Domain accuracy | entity error rate on **your** nouns, digits, codes | demo text is generic |
| Determinism | same input → same bytes? | affects caching and testing |
| Voice inventory | matched fallback voice available? | failover is invisible in a demo |
| Cost per 1000 min | see §2.3 | not in the demo |
| Licence | commercial use, cloning terms, weight licence | not in the demo |

The three that teams most often skip and later regret: **cancellation** (barge-in does not
work without it), **alignment metadata** (transcript truncation is approximate without it,
[`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md) §2.5), and **matched
fallback voice** (a mid-call voice change is jarring enough that users comment on it).

### 2.3 The cost model

Hosted engines bill per character or per second of audio; local engines cost compute. The
structure mirrors the ASR case ([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md)
§3): a per-minute advantage against a fixed-cost floor.

Two conversions you need. Speech runs at roughly 150 words per minute, and English averages
about 5 characters plus a space per word, so **one minute of speech is roughly 900
characters**. And an agent typically speaks a minority of the call — perhaps 40% — so audio
minutes are less than call minutes.

The model, with every assumption named, is implemented in §3. Its structure:

$$\text{hosted } \$/1000\text{ min} = \text{price per char} \times 900 \times 1000$$

$$\text{local } \$/1000\text{ min} = \frac{\text{machine } \$/\text{hour}}{\text{concurrent streams} \times 60 \times \text{utilisation}} \times 1000 \times (1 + \text{ops overhead})$$

The sensitivity structure is the important part, not the numbers: hosted cost is **linear in
volume with zero fixed cost**, local cost is **fixed capacity divided by realised
utilisation**. So hosted always wins at low volume and local wins above a breakeven that
depends almost entirely on concurrent streams per machine and on utilisation. Because a
small TTS model on CPU achieves high concurrency, that breakeven arrives much sooner for TTS
than for ASR.

Caching changes the arithmetic materially and is often ignored: if 40% of spoken audio is
fixed strings ([`03-streaming-tts.md`](03-streaming-tts.md) §2.7), a cache removes 40% of
hosted spend and nearly all of its latency for those utterances. Model cost *after*
caching, not before.

### 2.4 Designing the listening test

Once the field is narrowed, a listening test decides quality — and it has to be designed or
it produces noise.

**Use your own text distribution.** Sample 30–50 real utterances from your agent's traffic,
weighted as they actually occur: confirmations, digit strings, names, amounts, apologies,
and the two or three boilerplate strings that account for a large share of speech.

**Blind and randomise.** Listeners must not know which engine produced which clip, and order
must be randomised. Otherwise you measure brand expectation.

**Score specific attributes, not "quality".** Intelligibility, naturalness, appropriateness
of prosody, and — separately — correctness of pronunciation for domain terms. An engine can
win on naturalness and lose on correctness, and averaging those into one number destroys the
information you needed.

**Use pairwise comparison.** Asking "which of these two is better" is far more reliable than
asking for an absolute 1–5 score, because listeners are inconsistent on absolute scales and
consistent on comparisons.

**Get enough raters and check agreement.** Three to five listeners per clip, and compute
inter-rater agreement. If agreement is low, the difference you are trying to measure is
smaller than the noise, which is itself a decision-relevant finding: pick on cost and
latency instead.

**Include the hard cases deliberately.** A spelled reference over a narrowband channel, a
long digit string, an Indian surname, an amount above ₹1 lakh
([`04-prosody-and-voice.md`](04-prosody-and-voice.md) §2.2). These are where engines
differentiate and where demos never go.

### 2.5 Local engines on an M5 Mac

The two practical choices, with facts verified from PyPI (retrieved 2026-08-22):

| | Piper (`piper-tts` 1.7.0) | Kokoro (`kokoro` 0.9.4, Kokoro-82M) |
|---|---|---|
| Size | small per-voice VITS models | 82 M parameters |
| Weights licence | permissive per voice | Apache |
| Python | `>=3.9` | `<3.13,>=3.10` |
| Phonemisation | `espeak-ng` | `espeak-ng` (via misaki) |
| Cloning | no | no |
| Style control | limited | style vector / reference |
| Best for | maximum speed and minimum footprint, many languages | best quality in the small-model class |

Both give you: zero marginal cost, no network dependency, no per-character billing, in-process
cancellation, and deterministic output. That combination satisfies most of §2.1's constraint
table, and it is why this curriculum treats local TTS as the default rather than the fallback.

The honest limitation is expressive range. If your product needs a voice that conveys
emotion, or a specific cloned identity, these will not do it, and you are choosing between
the latency cost of a codec-LM engine and the quality cost of a small parallel one.

### 2.6 The hybrid pattern

The configuration that usually wins in practice, and it dissolves the main tradeoff:

- **Pre-rendered, cached audio** for every fixed string — greetings, disclosures, hold
  messages, menu prompts, common confirmations — synthesised offline by the *best* engine
  available, including a cloned or premium voice. Zero latency at serve time.
- **Fast local synthesis** for genuinely dynamic content, in a voice matched as closely as
  possible to the cached audio.
- **A hosted engine as fallback** for languages or capabilities the local engine lacks.

This gives premium quality where quality is visible and low latency where latency is
visible, and it reduces per-character spend to the dynamic fraction only. The cost is
voice-matching effort between the cached and live paths, and it is worth measuring whether
listeners notice the seam before assuming they will.

---

## 3. From scratch

The cost model, with assumptions exposed and sensitivity analysis. Standalone, stdlib only.

```python
"""TTS cost per 1000 audio-minutes: hosted vs local, with sensitivities."""
from dataclasses import dataclass

WORDS_PER_MIN = 150          # typical speaking rate
CHARS_PER_WORD = 6.0         # ~5 letters plus a space, English
CHARS_PER_MIN = WORDS_PER_MIN * CHARS_PER_WORD      # ~900

@dataclass
class Hosted:
    usd_per_million_chars: float
    cache_hit_rate: float = 0.0     # fraction of audio served from cache, unbilled

    def usd_per_1000_min(self) -> float:
        chars = CHARS_PER_MIN * 1000 * (1 - self.cache_hit_rate)
        return self.usd_per_million_chars * chars / 1e6

@dataclass
class Local:
    machine_usd_per_hour: float
    concurrent_streams: int          # measured, at your chunk size -- not a guess
    utilisation: float               # realised average, not peak capacity
    ops_overhead: float = 0.25
    cache_hit_rate: float = 0.0

    def usd_per_1000_min(self) -> float:
        # One machine delivers streams * 60 audio-minutes per wall-clock hour at
        # full occupancy; multiply by realised utilisation.
        audio_min_per_hour = self.concurrent_streams * 60 * self.utilisation
        raw = self.machine_usd_per_hour / audio_min_per_hour * 1000
        return raw * (1 + self.ops_overhead) * (1 - self.cache_hit_rate)

def breakeven_minutes(local: Local, hosted: Hosted, fixed_monthly_usd: float):
    """Monthly audio-minutes above which local is cheaper, including the fixed
    engineering cost of owning it."""
    delta = (hosted.usd_per_1000_min() - local.usd_per_1000_min()) / 1000
    return float("inf") if delta <= 0 else fixed_monthly_usd / delta

def call_minutes_to_audio_minutes(call_minutes, agent_talk_fraction=0.40):
    """The agent speaks only part of the call. Billing follows AUDIO minutes."""
    return call_minutes * agent_talk_fraction

if __name__ == "__main__":
    # ---- ASSUMPTIONS, not prices. Replace all of these with measurements.
    hosted = Hosted(usd_per_million_chars=30.0)
    local = Local(machine_usd_per_hour=0.10, concurrent_streams=20, utilisation=0.40)
    fixed_monthly = 1500.0

    print(f"one audio-minute is ~{CHARS_PER_MIN:.0f} characters")
    print(f"hosted : ${hosted.usd_per_1000_min():7.2f} / 1000 audio-min "
          f"(${hosted.usd_per_million_chars}/M chars)")
    print(f"local  : ${local.usd_per_1000_min():7.2f} / 1000 audio-min "
          f"({local.concurrent_streams} streams, util {local.utilisation:.0%}, "
          f"ops +{local.ops_overhead:.0%})")
    be = breakeven_minutes(local, hosted, fixed_monthly)
    print(f"breakeven: {be:,.0f} audio-min/month" if be != float("inf")
          else "breakeven: local is never cheaper at these rates")

    print("\neffect of caching fixed strings (hosted):")
    for hit in (0.0, 0.2, 0.4, 0.6):
        h = Hosted(hosted.usd_per_million_chars, cache_hit_rate=hit)
        print(f"  cache hit {hit:.0%} -> ${h.usd_per_1000_min():7.2f} / 1000 min")

    print("\nlocal sensitivity -- concurrent streams dominates:")
    for s in (5, 10, 20, 40, 80):
        print(f"  {s:3d} streams -> "
              f"${Local(0.10, s, 0.40).usd_per_1000_min():7.2f} / 1000 min")

    print("\nlocal sensitivity -- utilisation:")
    for u in (0.10, 0.25, 0.40, 0.70):
        print(f"  util {u:.0%} -> "
              f"${Local(0.10, 20, u).usd_per_1000_min():7.2f} / 1000 min")

    print("\nworked volume: 100,000 call-minutes/month, agent speaks 40%")
    audio = call_minutes_to_audio_minutes(100_000)
    print(f"  audio minutes = {audio:,.0f}")
    for label, engine in (("hosted", hosted), ("local", local)):
        print(f"  {label:7s} monthly = "
              f"${engine.usd_per_1000_min() * audio / 1000:,.2f}")
```

Measured output under those stated assumptions `[MEASURED]`:

```
one audio-minute is ~900 characters
hosted : $  27.00 / 1000 audio-min ($30.0/M chars)
local  : $   0.26 / 1000 audio-min (20 streams, util 40%, ops +25%)
breakeven: 56,097 audio-min/month

effect of caching fixed strings (hosted):
  cache hit  0% -> $  27.00 / 1000 min
  cache hit 20% -> $  21.60 / 1000 min
  cache hit 40% -> $  16.20 / 1000 min
  cache hit 60% -> $  10.80 / 1000 min

local sensitivity -- concurrent streams dominates:
    5 streams -> $   1.04 / 1000 min
   20 streams -> $   0.26 / 1000 min
   80 streams -> $   0.07 / 1000 min

worked volume: 100,000 call-minutes/month, agent speaks 40%
  audio minutes = 40,000
  hosted  monthly = $1,080.00
  local   monthly = $    10.42
```

The structural finding — which survives changing the assumptions — is the **size of the
gap**. Local synthesis is roughly two orders of magnitude cheaper per minute here, and the
breakeven lands at about 56 000 audio-minutes per month: on the order of 140 000 call-minutes
at a 40% talk ratio, which a modest deployment reaches.

Contrast that with the same model applied to ASR
([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md) §3), where breakeven landed
near 1.2 million audio-minutes per month — roughly **twenty times higher**. The asymmetry has
a clear cause: a TTS model in the parallel branch is small enough to serve many concurrent
streams from one cheap machine, while hosted TTS is billed per character at a rate that
reflects premium voice quality. **TTS is therefore the layer where self-hosting pays off
soonest**, and it is the first place to look when a bill needs reducing (§7).

Note also how much caching alone achieves: a 60% hit rate cuts hosted cost by 60% with no
quality change and a latency improvement. That is why §5 treats hit rate as an optimisation
target rather than an implementation detail.

Two modelling points worth stating explicitly. **The agent-talk fraction is easy to forget
and it changes the bill by more than half** — you are billed for audio minutes, not call
minutes, and a 40% talk ratio means a 100 000-call-minute month is a 40 000-audio-minute
bill. And **`concurrent_streams` must be measured, not guessed**, at the chunk size you
actually stream, for the same reason streaming RTF differs from offline RTF
([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md) §2.1).

`[UNVERIFIED PRICE]` applies to every number in the `__main__` block. They are placeholders
with plausible magnitudes chosen to exercise the model, not quotes. Substitute current
published prices and your own measured concurrency before drawing any conclusion.

---

## 4. How production does it

**Abstract the engine behind an interface from day one.** Concretely: a streaming
synthesise call taking text chunks and returning audio chunks, plus cancel. Every engine in
§2.5 and every hosted vendor fits behind that, and the abstraction is what makes a switch a
day of work rather than a rewrite. It is also what lets you run a shadow comparison in
production — send a copy of traffic to a candidate engine and compare offline without
affecting users.

**Frameworks already impose this shape**, which is a reason to lean on them: LiveKit Agents
takes a `tts` component on `AgentSession` and Pipecat has a TTS service interface, so
swapping engines is a constructor change. The corollary is to keep your business logic from
depending on engine-specific features — if you rely on one vendor's alignment metadata,
you have coupled to it, and the fallback must degrade gracefully to chunk-granularity
truncation.

**Run a fallback and test it.** A second engine, ideally with a matched voice, exercised by
a periodic synthetic call rather than only on incident day. Failover at utterance boundaries
rather than mid-utterance avoids the audible voice change
([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)).

**Pin engine and voice versions, and put them in the cache key.** Vendors update voices, and
an unpinned voice can change character without a deploy on your side — with cached audio in
the old voice still being served
([`03-streaming-tts.md`](03-streaming-tts.md) §2.7).

**Verify licences properly, at the level of detail that matters.** Three separate questions:
is commercial use permitted, are the *weights* licensed permissively (Kokoro's are Apache;
some model weights are not), and — for any engine offering cloning — what are the terms on
voice data you upload. Answer these before integration, not before launch.

---

## 5. At scale

**Latency is a product feature and cost is a finance line, so measure both continuously.**
Track `ttfb_tts` p95 per engine and per region alongside spend per 1000 audio-minutes. A
vendor's latency can regress without any change on your side, and without a dashboard the
first signal is user complaints.

**Push the cache hit rate up deliberately.** For a scripted agent it is the highest-leverage
optimisation available: it removes latency *and* cost for the cached fraction. Audit the
top 50 most-spoken strings monthly and ensure each is cached; this is usually a surprisingly
concentrated distribution.

**Measure entity pronunciation as a quality SLI, not a one-off check.** Product names change,
new customers arrive with new surnames, and pronunciation regressions arrive silently with
voice updates. A fixed set of domain terms, synthesised and checked on each engine or voice
version, catches it.

**Do not let voice consistency be an accident.** Decide whether a mid-call voice change is
acceptable, and if it is not, ensure the fallback voice is matched and that failover happens
only at utterance boundaries. This constrains engine choice — a fallback with no similar
voice is not really a fallback.

**Right-size per utterance type.** A one-word confirmation does not need your most expensive
engine, and routing short confirmations to a fast local voice while sending long dynamic
explanations to a premium engine is a real cost lever. The risk is voice inconsistency, so
this only works if the voices are close or if the split follows a natural boundary the
listener already perceives.

**Revisit the decision on a schedule.** This part of the stack moves quickly: prices fall,
open models improve, and the small-model quality frontier has moved substantially in recent
years. A selection made two years ago is unlikely to still be optimal, and the abstraction
from §4 is what makes revisiting cheap.

---

## 6. Exercises

**E4.5.1** Run the §3 model with current published prices for two hosted engines and your
own measured local concurrency. Report the breakeven and identify which single assumption
most changes the answer.

**E4.5.2** Measure `concurrent_streams` for a local engine properly: stream 1-clause chunks
from N simultaneous sessions and find the N at which p95 `ttfb_tts` exceeds your budget.
Compare against the naive figure from offline batch synthesis.

**E4.5.3** Compute the cost impact of the agent-talk fraction: recompute the §3 worked volume
at 25%, 40% and 60%. Then instrument a real call to measure your actual fraction.

**E4.5.4** Build the §2.4 listening test for two engines with 30 utterances drawn from your
own traffic, pairwise and blind, scoring intelligibility and pronunciation separately.
Report inter-rater agreement and state whether the difference is larger than the noise.

**E4.5.5** Measure cancellation latency for two engines: start synthesis of a long
utterance, cancel at 500 ms, and measure time until no further audio arrives. Include a
hosted engine over the network.

**E4.5.6** Take your agent's last 1000 spoken utterances and compute the cacheable fraction
by exact string match, then by normalised match. Report the achievable cache hit rate and
the resulting cost reduction.

**E4.5.7** Write the engine-selection decision record for a product of your choosing: the
decisive constraints from §2.1, the surviving candidates, the measured axes from §2.2, the
cost model output, and the chosen option with its rejection reasons. One page.

---

## 7. Interview drill

> "Our TTS bill is $40k a month and growing. The CFO wants it halved. What do you do, in
> order?"

The expected answer starts with the cheapest, least risky levers and only reaches "switch
vendors" late, because switching has costs the request has not priced.

**First, measure what you are paying for.** Break the bill down by utterance type and find
the cacheable fraction. For most agents a concentrated set of fixed strings — greeting,
disclosure, hold, confirmations, closing — accounts for a large share of spoken characters.
Caching them is a pure win: it removes both cost and latency, and §3 shows the cost falling
linearly with hit rate. This alone can approach the target with no quality change.

**Second, shorten the output.** Billing is per character, so verbosity is money. A prompt
that produces two-sentence answers instead of four-sentence ones halves the bill for dynamic
speech, *and* reduces latency, *and* usually improves the interaction
([`../05-llm-layer/01-prompting-for-speech.md`](../05-llm-layer/01-prompting-for-speech.md)).
This is the highest-value change in the list because it moves three metrics in the same
direction.

**Third, stop paying for audio nobody hears.** Reducing TTS lookahead means an interruption
discards less synthesised audio
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md) §5). Instrument
`chars_synthesised / chars_heard` to size this before doing it.

**Fourth, consider raising the speaking rate slightly.** At 1.1× the audio is shorter, which
reduces cost on TTS and on any per-minute telephony and ASR charges. Measure task success,
because comprehension has a limit (§2.5 of
[`04-prosody-and-voice.md`](04-prosody-and-voice.md)).

**Fifth, move to local synthesis** for the dynamic path. §2.5's engines have zero marginal
cost, and §3's sensitivity table shows local cost is dominated by concurrency and
utilisation. This is the structural fix, and its costs are honest: an ops burden, a voice
change unless matched carefully, and a capacity-management problem.

**Last, renegotiate or switch vendors.** Volume commitments can move the price, and a switch
is viable *because* of the abstraction in §4 — but it carries a voice change, a new latency
profile, and a re-run of the listening test.

The senior close is to reframe the target: cost per *successful conversation* is the metric
the business actually wants, not cost per minute. A change that halves the bill while
raising the escalation rate is a loss, so the proposal should pair the cost reduction with
task-success monitoring ([`../08-eval-safety/02-simulation-and-load.md`](../08-eval-safety/02-simulation-and-load.md))
and state the guardrail explicitly.

---

## Sources

- `piper-tts` 1.7.0 and `kokoro` 0.9.4 PyPI metadata (retrieved 2026-08-22) — the local-engine facts in §2.5, including Kokoro-82M's parameter count and Apache-licensed weights and the `<3.13` Python constraint. Architectural background in [`01-tts-architectures.md`](01-tts-architectures.md).
- `livekit-agents` 1.7.0 — the `tts` component on `AgentSession` referenced in §4; `pipecat-ai/pipecat` — its TTS service interface.
- The latency floor for autoregressive codec-LM engines is derived in [`02-codec-lm-tts.md`](02-codec-lm-tts.md) §2.5; the caching and cancellation requirements are from [`03-streaming-tts.md`](03-streaming-tts.md) §2.6–§2.7.
- `[UNVERIFIED PRICE]`: every price and machine cost in §3's `__main__` block is an illustrative placeholder, not a quote. Verify current vendor pricing and measure your own concurrency before using the model.
- Speaking-rate and characters-per-minute conversions in §2.3 are standard approximations for English at a conversational pace; measure your own corpus if precision matters.
