# Persona Design

**What you'll be able to do after this:** specify a voice agent's personality as a parameter
set rather than a paragraph of adjectives; quantify what each parameter costs in seconds and
dollars; keep a persona stable across model and provider changes with an automated linter; and
run an A/B that attributes a change in task success to a persona dimension rather than to
noise.

---

## 1. Intuition

Persona is usually written as a mood board — "friendly, professional, helpful" — and handed to
the prompt as prose. That is a category error. **Every persona choice is a setting on a system
that has a latency budget, a cost model and a measurable success rate.** Verbosity is
seconds of TTS and dollars per thousand calls. Disfluency is naturalness bought with words.
Formality is register, which changes which words the ASR must recognise. Apology policy
determines how a failed tool call sounds. None of these are decorative.

Two asymmetries make voice personas different from chat personas.

**Listeners judge competence from timing and prosody before content.** A correct answer
delivered after a two-second pause in a flat voice reads as less competent than a hedged answer
delivered promptly in a warm one. The persona dimensions that matter most — pace, promptness,
the noise made while thinking — are the ones a text-persona document never mentions.

**Persona is spread across three subsystems and must agree.** The words come from the LLM
prompt, the delivery from the TTS voice and its steering parameters, and the rhythm from the
turn-taking policy ([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)).
A brisk prompt with a languid voice and a 900 ms endpointing delay is three personas fighting.
Consistency is an engineering property, not a writing one.

---

## 2. Rigour

### 2.1 The persona spec as a data structure

Replace adjectives with parameters that can be set, tested and diffed:

| Dimension | Values | Where it is enforced |
|---|---|---|
| **Verbosity** | max words per turn; sentences per turn | prompt + speakability gate ([`01-prompting-for-speech.md`](01-prompting-for-speech.md) §3) |
| **Register** | contractions on/off; formality; address form | prompt + linter |
| **Pace** | slow / normal / fast, or explicit wpm | TTS parameter, not the prompt |
| **Disfluency** | filled pauses on/off, rate | TTS steering (§4) |
| **Non-verbal sounds** | laughter, breath, sighs allowed or not | TTS steering |
| **Hedging** | permitted / forbidden | prompt + linter |
| **Acknowledgement** | prefix acks ("sure", "got it") on/off | prompt |
| **Backchannels** | agent says "mm-hm" while listening | turn-taking policy ([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)) |
| **Apology policy** | apologise once / never / per failure | prompt + error templates |
| **Refusal style** | plain, brief, no moralising | prompt |
| **Brand lexicon** | must-say and never-say strings | linter, hard gate |
| **Pronunciation** | names, products, drug names | TTS lexicon ([`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md)) |
| **Disclosure** | the exact AI-disclosure sentence | uninterruptible scripted utterance |
| **Escalation warmth** | how the handoff to a human sounds | prompt + escalation path |

Two of these are hard gates rather than style: brand lexicon and disclosure. A never-say string
must be enforced deterministically, because a model instructed not to say something says it
eventually.

### 2.2 What each choice costs

The same eight-turn conversation, authored to four specs, measured by the §3 listing
`[MEASURED]`:

| Persona | Words/turn | Sentence p95 | Agent speech | Call length | Output tokens | TTS $/1000 calls | Contractions | Fillers |
|---|---|---|---|---|---|---|---|---|
| terse | 5.0 | 6 | 15.4 s | 46.6 s | 42 | $6.93 | 0 | 0 |
| warm | 11.6 | 9 | 32.0 s | 63.2 s | 97 | $14.40 | 3 | 2 |
| formal | 11.8 | 13 | 35.5 s | 66.7 s | 98 | $15.96 | 0 | 0 |
| chatty | 23.8 | 23 | 65.3 s | 96.5 s | 198 | $29.40 | 6 | 7 |

Holding the user's speech and `eou_to_ttfa` fixed, the chatty persona adds **49.9 seconds of
speech per call, a 324% increase, and doubles call length**. TTS spend rises from $6.93 to
$29.40 per 1000 calls, and at a million chatty-persona call-minutes a month the verbosity
premium alone is about **$14 000/month of TTS** — before counting the LLM output tokens, the
telephony minutes, or the agent capacity consumed by calls that take twice as long.

Note what does *not* change: `eou_to_ttfa` is held constant because persona does not affect it
directly. It affects it indirectly through sentence length — the formal persona's 13-word p95
sentence delays the first speakable clause more than the terse persona's 6-word one
([`../04-tts/03-streaming-tts.md`](../04-tts/03-streaming-tts.md) §2.4) — which is why sentence
p95, not just words per turn, belongs in the spec.

The honest caveat: those four reply sets are hand-authored to their specs, so the numbers
measure *the specs as written*, not a model's fidelity to them. Reproduce the table with your
own model's output and the ratios will shift; the mechanism will not.

### 2.3 Disfluency, and why the default is "on"

Filled pauses ("um", "well", "so") do three things in human speech: they hold the floor while
the speaker plans, they signal that a longer answer is coming, and they mark uncertainty. All
three are useful to an agent. A filled pause at the start of a reply also buys 200–400 ms of
real time, which is 200–400 ms of TTFT you no longer need to hide.

LiveKit ships `DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)`
(§4) — filled pauses on by default. The counter-arguments are real: disfluency in a
transcript looks like an error, some brands forbid it, and an agent that says "um" before every
turn sounds worse than one that never does. Treat rate as the parameter, not presence, and set
it to zero for high-formality deployments.

### 2.4 Pace belongs to the TTS, not the prompt

Asking a model to "speak slowly" changes word choice, not delivery — it produces longer
sentences, which is the opposite of what you wanted. Rate is a synthesis parameter. Three
consequences.

Faster speech shortens calls and lowers TTS cost per turn, but it degrades intelligibility on
narrowband telephony, where the 300–3400 Hz passband has already removed cues
([`../01-foundations/01-sound-and-sampling.md`](../01-foundations/01-sound-and-sampling.md)).
Faster speech also shortens the window in which a user can barge in cleanly on a given phrase,
so the interruption experience changes without anyone touching the interruption code. And pace
interacts with the endpointing delay: a fast agent following a long endpoint timeout feels
inconsistent, because the two halves of the rhythm disagree.

### 2.5 The three sentences that define the persona

Most turns are unremarkable. The persona is judged on the three that are not:

| Situation | Bad | Good | Why |
|---|---|---|---|
| Did not understand | "I'm sorry, I didn't quite catch that, could you please repeat?" | "Sorry — say that again?" | short, and the escalation ladder handles repeats ([`01-prompting-for-speech.md`](01-prompting-for-speech.md) §2.4) |
| Cannot do it | "Unfortunately, as an AI assistant, I'm not able to…" | "I can't do that one, but I can put you through to someone who can." | no self-narration; ends with a path forward |
| Something broke | "An error occurred while processing your request." | "The booking system isn't responding. Want me to take a message?" | names the failure in plain words, offers an action |

These three are worth writing as templates rather than leaving to generation, because they are
the moments where model variance is highest and where a bad sentence is most expensive.
Apology policy: at most one apology per failure, never stacked, never for things that are not
failures.

### 2.6 Persona under interruption

When the user barges in, persona *is* the stopping behaviour. Stop immediately and completely —
a persona that finishes its clause is a persona that does not listen. Do not acknowledge the
interruption ("sorry, go ahead") every time; once per call at most, and preferably never.
Resume by answering the new thing, not by returning to the old thing.

The important interaction: an agent that is interrupted often may have a persona problem rather
than a VAD problem. If `interruption_rate` is high and the interruptions cluster at the same
point in replies, the replies are too long — a verbosity setting, not a turn-taking bug
([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)).

### 2.7 Consistency across models and providers

A persona tuned against one model degrades against another in predictable directions: longer
replies, formal register creeping back, list structure returning, and stock phrases
("unfortunately", "I apologize for the inconvenience") reappearing. In the §3 measurement, the
same "warm" spec rendered by a second provider produced **zero contractions instead of three,
zero fillers instead of two, two hedges instead of zero, and two banned phrases instead of
zero** — while the word count barely moved from 11.6 to 12.6 per turn. Word count alone would
have called it a match.

Three defences. Carry style with **few-shot examples**, which port across models better than
adjectives, at a prefill cost
([`04-serving-llms-fast.md`](04-serving-llms-fast.md)). Enforce the hard parts
**deterministically** — banned phrases, must-say disclosures and length caps are code, not
requests. And **lint every model change**, which is what the §3 checker is for: the drift above
is invisible to a human reviewer reading five transcripts and obvious to a counter.

### 2.8 Measuring persona

Persona changes are testable. The metrics that move, and their direction:

| Metric | Expect |
|---|---|
| Agent speech seconds per call | direct function of verbosity |
| Call duration | verbosity plus repair rate |
| Turns to task completion | *falls* with clarity, *rises* with chattiness |
| `interruption_rate` | rises with reply length |
| Repair-loop rate | falls with plainer register |
| Task success | the metric that decides |
| Containment (no escalation) | second-order, but what the business tracks |
| Cost per successful task | the honest summary |

Run it as an A/B with one dimension changed at a time, matched cohorts by intent and by hour of
day, and a pre-declared minimum sample. The trap is comparing "persona A" to "persona B" where
five dimensions differ, which tells you nothing you can reuse. The other trap is optimising
call duration: a shorter call that failed is not better than a longer call that worked, which
is why **cost per successful task** is the metric that arbitrates.

---

## 3. From scratch

A persona budget calculator and drift linter. Standalone, stdlib only.

```python
"""Persona as an engineering artifact: what each style choice costs.

Four persona specs, the same eight-turn conversation answered in each, and the
measurable consequences: speech seconds, call duration, TTS spend, LLM output
tokens, and a lint pass that catches drift from the spec.

Conventions reused from earlier chapters: one audio-minute is ~900 characters
(04-tts/05), spoken text runs ~1.04 tokens per word (05-llm-layer/02).
"""

import re

CHARS_PER_AUDIO_SEC = 900 / 60          # 15 chars/s
TOKENS_PER_WORD = 1.04                  # measured, o200k_base on spoken transcripts
TTS_USD_PER_M_CHARS = 30.0              # hosted engine, 04-tts/05 [UNVERIFIED PRICE]
USER_SPEECH_S = 3.2                     # mean user turn, held constant across personas
EOU_TO_TTFA_S = 0.7                     # held constant; persona does not change it
CALLS = 1000

FILLERS = re.compile(r"\b(um|uh|well|so|you know|I mean|right)\b", re.I)
HEDGES = re.compile(r"\b(I think|maybe|possibly|perhaps|it seems|I believe|kind of|"
                    r"sort of|might be)\b", re.I)
CONTRACTIONS = re.compile(r"\b\w+['\u2019](s|re|ll|ve|t|d|m)\b", re.I)
BANNED = ["as an AI", "I apologize for the inconvenience", "unfortunately",
          "please be advised", "reach out"]

# The same eight agent turns, authored to four different persona specs.
REPLIES = {
    "terse": [
        "Northwind Clinic, how can I help?",
        "Sure. What date?",
        "Tuesday the third. Morning or afternoon?",
        "Four fifteen with Dr Rai. Book it?",
        "Booked. Text confirmation to the number ending four four two one?",
        "Sent.",
        "Anything else?",
        "Thanks for calling. Bye.",
    ],
    "warm": [
        "Hi there, you've reached Northwind Clinic. What can I do for you today?",
        "Of course, I can help you move that. So, what day were you thinking?",
        "Tuesday the third works. Would you prefer the morning or the afternoon?",
        "Right, I've got four fifteen with Dr Rai. Shall I lock that in for you?",
        "All set. Would you like a text confirmation to the number ending four four two one?",
        "That's on its way to you now.",
        "Is there anything else I can help with today?",
        "Lovely, thanks for calling, and take care.",
    ],
    "formal": [
        "Good afternoon, you have reached Northwind Clinic. How may I assist you?",
        "Certainly. May I ask which date you would like to move the appointment to?",
        "Tuesday the third is available. Would you prefer a morning or afternoon slot?",
        "There is an opening at four fifteen with Doctor Rai. Shall I reserve it?",
        "The appointment is reserved. May I send a confirmation by text message to the "
        "number ending four four two one?",
        "The confirmation has been sent.",
        "Is there anything further I can assist you with?",
        "Thank you for calling Northwind Clinic. Goodbye.",
    ],
    "chatty": [
        "Hey, thanks for calling Northwind Clinic. I'm the scheduling assistant here, "
        "so I can help with appointments, and I can also take a message if you need one.",
        "Absolutely, moving an appointment is no trouble at all. Do you know roughly which "
        "day suits you best, or would you like me to read out what we have open this week?",
        "Great, Tuesday the third has a few options. We've got some morning slots and a "
        "couple in the afternoon, so which end of the day works better for you?",
        "Perfect. There's a four fifteen with Doctor Rai, which is the same clinician you "
        "saw last time, so that should keep things nice and consistent. Want me to book it?",
        "Wonderful, that's all booked in for you. I can send a text confirmation over to "
        "the number ending four four two one if that's still the best one to use.",
        "Done, that should land in the next minute or so.",
        "Is there anything else at all I can help you with while I've got you?",
        "Great, well thanks so much for calling, have a lovely rest of your day, bye now.",
    ],
}

# Same persona spec, a different provider: the drift the linter must catch.
PROVIDER_B_WARM = [
    "Hello. You have reached Northwind Clinic. How can I help you today?",
    "I can help you with that. Unfortunately I think I will need the date first.",
    "Tuesday the third might be available. Do you want morning or afternoon?",
    "I have four fifteen with Dr Rai. Do you want me to book it?",
    "It is booked. I apologize for the inconvenience of the earlier change. Should I send "
    "a text confirmation to the number ending four four two one?",
    "The message has been sent to you.",
    "Is there anything else that I can help you with?",
    "Thank you for calling. Goodbye.",
]


def measure(turns):
    words = sum(len(t.split()) for t in turns)
    chars = sum(len(t) for t in turns)
    speech_s = chars / CHARS_PER_AUDIO_SEC
    sentences = [s for t in turns for s in re.split(r"(?<=[.!?])\s+", t) if s.strip()]
    return {
        "turns": len(turns),
        "words": words,
        "w_per_turn": words / len(turns),
        "chars": chars,
        "speech_s": speech_s,
        "call_s": speech_s + len(turns) * (USER_SPEECH_S + EOU_TO_TTFA_S),
        "out_tokens": words * TOKENS_PER_WORD,
        "tts_usd_1k": chars * CALLS * TTS_USD_PER_M_CHARS / 1e6,
        "sent_p95": sorted(len(s.split()) for s in sentences)[int(0.95 * (len(sentences) - 1))],
        "fillers": sum(len(FILLERS.findall(t)) for t in turns),
        "hedges": sum(len(HEDGES.findall(t)) for t in turns),
        "contractions": sum(len(CONTRACTIONS.findall(t)) for t in turns),
        "banned": sum(t.lower().count(b.lower()) for t in turns for b in BANNED),
    }


if __name__ == "__main__":
    print(f"same 8-turn conversation, four persona specs "
          f"(user speech {USER_SPEECH_S}s/turn, eou_to_ttfa {EOU_TO_TTFA_S}s, both fixed)\n")
    print(f"{'persona':9s} {'w/turn':>7} {'sent p95':>9} {'speech s':>9} {'call s':>8} "
          f"{'out tok':>8} {'$/1k calls':>11} {'contr':>6} {'fill':>5} {'hedge':>6} "
          f"{'banned':>7}")
    base = None
    rows = {}
    for name, turns in REPLIES.items():
        m = measure(turns)
        rows[name] = m
        base = base or m
        print(f"{name:9s} {m['w_per_turn']:7.1f} {m['sent_p95']:9d} {m['speech_s']:9.1f} "
              f"{m['call_s']:8.1f} {m['out_tokens']:8.0f} {m['tts_usd_1k']:11.2f} "
              f"{m['contractions']:6d} {m['fillers']:5d} {m['hedges']:6d} {m['banned']:7d}")

    t, c = rows["terse"], rows["chatty"]
    print(f"\nchatty vs terse: +{c['speech_s']-t['speech_s']:.1f}s of speech per call "
          f"(+{(c['speech_s']/t['speech_s']-1):.0%}), "
          f"call +{(c['call_s']/t['call_s']-1):.0%}, "
          f"TTS +${c['tts_usd_1k']-t['tts_usd_1k']:.2f} per 1000 calls")
    print(f"at 1,000,000 chatty-persona call-minutes/month, verbosity alone accounts for "
          f"${(c['tts_usd_1k']-t['tts_usd_1k'])*1e6/(c['call_s']/60*CALLS):,.0f}/month of TTS")

    print("\nsame 'warm' spec, second provider -- drift the linter must catch:")
    w, b = rows["warm"], measure(PROVIDER_B_WARM)
    for k in ("w_per_turn", "contractions", "fillers", "hedges", "banned", "speech_s"):
        print(f"  {k:14s} warm={w[k]:8.1f}   provider_b={b[k]:8.1f}")
```

Output `[MEASURED]`:

```
same 8-turn conversation, four persona specs (user speech 3.2s/turn, eou_to_ttfa 0.7s, both fixed)

persona    w/turn  sent p95  speech s   call s  out tok  $/1k calls  contr  fill  hedge  banned
terse         5.0         6      15.4     46.6       42        6.93      0     0      0       0
warm         11.6         9      32.0     63.2       97       14.40      3     2      0       0
formal       11.8        13      35.5     66.7       98       15.96      0     0      0       0
chatty       23.8        23      65.3     96.5      198       29.40      6     7      0       0

chatty vs terse: +49.9s of speech per call (+324%), call +107%, TTS +$22.47 per 1000 calls
at 1,000,000 chatty-persona call-minutes/month, verbosity alone accounts for $13,966/month of TTS

same 'warm' spec, second provider -- drift the linter must catch:
  w_per_turn     warm=    11.6   provider_b=    12.6
  contractions   warm=     3.0   provider_b=     0.0
  fillers        warm=     2.0   provider_b=     0.0
  hedges         warm=     0.0   provider_b=     2.0
  banned         warm=     0.0   provider_b=     2.0
  speech_s       warm=    32.0   provider_b=    35.2
```

Three load-bearing details. **Word count is the weakest signal in the table** — the drift check
shows 11.6 versus 12.6 words per turn while contractions, fillers, hedges and banned phrases
all moved, which is why a persona test that only checks length passes a broken persona.
**Speech seconds are derived from characters, not words**, using the 900-characters-per-audio-
minute convention from [`../04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md);
words are the wrong unit because "Northwind" and "at" take very different times to say. And
**user speech and `eou_to_ttfa` are held fixed on purpose**, so every difference in call length
is attributable to the persona rather than to the pipeline.

---

## 4. How production does it

**LiveKit exposes persona as typed configuration, not only as prose.** All verified in
`livekit-agents/livekit/agents/voice/agent_session.py` and
`livekit-agents/livekit/agents/llm/chat_context.py`, main branch, retrieved 2026-08-22.

`SpeechSteeringOptions` has three keys — `disfluencies: bool`, `nonverbal_sounds: bool |
NonverbalOptions`, and `pace: Literal["slow", "normal", "fast"]` — with
`DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)`. `NonverbalOptions`
enumerates the sound vocabulary explicitly: `laughing` ("laugh, chuckle, giggle — and
laugh-speak delivery"), `breathing`, `sighing`, `crying`, `vocalizing`, `mouth_sounds` ("tsk,
tongue-click, lip-smack"). Each key is a sparse opt-out: omitted means enabled. That is §2.1's
table as an API — pace is a delivery parameter rather than a prompt instruction (§2.4), and
disfluency is a boolean with a documented default (§2.3). `ExpressiveOptions` wraps it with
`tts_instructions_template` and `tts_instructions_append`, so brand rules can be appended
without replacing the provider-agnostic defaults.

`Instructions(common, *, audio=None, text=None)` with
`render(modality="audio" | "text")` is the mechanism for the same agent behaving differently by
channel — its own docstring's example is `audio="Keep responses short for voice."` versus
`text="Use markdown formatting."`. One persona, two renderings, one source of truth; the
alternative, two forked prompts, is how they drift apart.

`DEFAULT_TTS_TEXT_TRANSFORMS = ["filter_markdown", "filter_emoji"]` is the deterministic half of
§2.7 — the parts of the persona that are enforced rather than requested.

**Hosted speech-to-speech models split the persona differently.** The voice, pace and
disfluency come from the model, which means less control and no text to lint; you cannot run
the §3 checker because there is no intermediate transcript to check
([`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md)).
Persona consistency becomes a listening exercise, which does not scale.

**Voice selection is a persona decision with legal weight.** Cloned and celebrity-adjacent
voices carry consent and disclosure obligations
([`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md) §2.6), and the
mandatory AI-disclosure line is a scripted, uninterruptible utterance rather than something the
persona improvises.

---

## 5. At scale

**Verbosity compounds through every layer.** The measured 324% increase in agent speech does
not just cost TTS: it lengthens calls, which consumes telephony minutes, which occupies worker
slots, which raises the concurrent-session count you must provision
([`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)).
A single word-count regression is a fleet-capacity event.

**Localise personas, do not translate them.** Politeness conventions, expected formality, and
whether an agent should use a caller's first name differ by language and market. A translated
English persona is grammatically fine and socially wrong, and the failure shows up as lower
task success rather than as complaints.

**Govern the lexicon centrally.** Must-say and never-say lists come from legal, brand and
compliance, and they change. Keep them in one versioned artefact consumed by every agent and
enforced by the linter in CI, not copied into prompts.

**Persona must be re-tested on every model upgrade.** The drift measured in §2.7 — contractions
to zero, banned phrases to two, word count almost unchanged — is precisely what happens on a
model swap, and it is invisible unless counted. Gate the upgrade on the linter and on the
speakability detector from [`01-prompting-for-speech.md`](01-prompting-for-speech.md) §3.

**Multi-agent handoffs must preserve the persona.** A specialist agent taken from a different
team, with different instructions and possibly a different voice, produces a personality change
mid-call that callers notice immediately. Share the persona artefact across agents and change
only the task-specific instructions
([`../07-livekit/02-agents-framework.md`](../07-livekit/02-agents-framework.md)).

**Report cost per successful task, not cost per call.** The terse persona is cheapest per call;
if it fails more often it is not cheapest per outcome. That single ratio prevents the most
common persona optimisation mistake.

---

## 6. Exercises

**E5.5.1** Write your agent's persona as the §2.1 parameter table with concrete values. Mark
each row with where it is enforced: prompt, TTS parameter, code gate, or turn-taking policy.
Any row you cannot place is not yet a spec.

**E5.5.2** Run the §3 listing on your own agent's last 100 replies grouped by intent. Report
words per turn, sentence p95, and TTS spend per 1000 calls, and identify the intent with the
worst verbosity.

**E5.5.3** Add three checks to the linter: second-person pronoun rate, questions per turn, and
mean syllables per word as a formality proxy. State the persona dimension each one measures.

**E5.5.4** Run the drift check across two models with an identical prompt. Report which
dimensions moved and by how much, and decide whether the prompt or the enforcement code should
change.

**E5.5.5** Set `disfluencies` off and on and run a blind listening test with ten people on
five turns each. Report preference, and separately report whether they noticed.

**E5.5.6** Change only pace (slow / normal / fast) and measure call duration,
`interruption_rate`, and task success. Report which changed and which did not.

**E5.5.7** Design the A/B for one persona dimension: hypothesis, primary metric, cohort
matching, minimum sample size, and stopping rule. Then state, before running it, what result
would make you revert.

**E5.5.8** Compute cost per successful task for two personas using your own task-success rate.
Find the success-rate difference at which the cheaper persona stops being cheaper.

---

## 7. Interview drill

> "Marketing wants the agent to sound 'warmer and more conversational'. Engineering says that
> will hurt latency. Who is right, and what do you do?"

Both are describing real effects, and the disagreement is unresolvable while "warmer" remains
an adjective. The first move is to decompose it into the parameters that can be changed
independently — verbosity, register and contractions, disfluency, acknowledgement prefixes,
pace — because they have very different costs. Contractions and a friendlier register are
essentially free: same word count, same latency. Disfluency is nearly free and actually buys
time. Acknowledgement prefixes are cheap and improve perceived responsiveness because audio
starts sooner. Verbosity is the expensive one, and it is the one people usually mean.

Then quantify rather than argue. In the measurement in §2.2, moving from a terse to a chatty
persona on the same eight-turn conversation added 49.9 seconds of agent speech, doubled call
length, and took TTS spend from $6.93 to $29.40 per 1000 calls; a warm-but-disciplined persona
sat in between at 32 seconds. So engineering is right that verbosity is costly and wrong if it
claims warmth requires verbosity — those are separable, and the warm row proves it.

The important correction to engineering's framing is that warmth does not hurt
`eou_to_ttfa`, which is the latency users actually feel. Time to first audio is governed by
endpointing, TTFT and the first clause; only sentence length touches it, and only through the
aggregator. Longer replies hurt a different thing — call duration and the probability of being
interrupted — and conflating the two leads to rejecting cheap changes to protect a metric they
do not affect.

The way to settle it is an A/B on one dimension at a time with cost per successful task as the
arbitrating metric, plus a linter in CI that holds the agreed word-count and sentence-length
caps so the persona cannot drift back after the launch. What distinguishes a senior answer is
adding the constraint marketing did not ask about: warmth is also delivery, so the TTS voice,
pace and disfluency settings must move together with the words, and a warm script in a brisk
synthetic voice reads as insincere — which is worse than the terse version they had.

---

## Sources

- `livekit/agents`, `livekit-agents/livekit/agents/voice/agent_session.py` (main branch, retrieved 2026-08-22) — `SpeechSteeringOptions{disfluencies, nonverbal_sounds, pace}`, `DEFAULT_SPEECH_STEERING_OPTIONS = SpeechSteeringOptions(disfluencies=True)`, `NonverbalOptions{laughing, breathing, sighing, crying, vocalizing, mouth_sounds}`, `ExpressiveOptions{speech_steering, tts_instructions_template, tts_instructions_append}`, `DEFAULT_TTS_TEXT_TRANSFORMS`.
- `livekit/agents`, `livekit-agents/livekit/agents/llm/chat_context.py` (retrieved 2026-08-22) — `Instructions(common, audio=..., text=...)` and `render(modality=...)`, quoted in §4.
- Cost conventions (900 characters per audio-minute; hosted TTS at $30/M characters, `[UNVERIFIED PRICE]`): [`../04-tts/05-engine-selection.md`](../04-tts/05-engine-selection.md) §3.
- Spoken-text token ratio (1.04 tokens/word, `tiktoken` `o200k_base`): [`02-context-and-memory.md`](02-context-and-memory.md) §2.2.
- `[MEASURED]`: the §2.2 and §3 tables are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only. The four reply sets are hand-authored to their specs, so the table measures the specs as written rather than a particular model's fidelity to them; the drift row is likewise a constructed example of the failure the linter exists to catch.
