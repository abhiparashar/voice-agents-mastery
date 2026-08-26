# Simulation and load

**What you'll be able to do after this:** build script- and LLM-driven simulated callers
and the adversarial personas that actually find bugs; use an LLM judge without believing its
number, including the correction that recovers the true rate and the reason high agreement
can mean no signal; ramp load to the knee rather than to CPU saturation; and size a soak
test from the smallest leak it can detect.

---

## 1. Intuition

You cannot ship a voice agent on unit tests. The failures that matter are conversational —
the agent mishears an order number and confirms it confidently, loops when the caller says
"no, the *other* one", talks over an interruption, or degrades only after four hundred
concurrent calls. Finding those needs three things a test suite does not provide: **a
population of callers**, **a way to score conversations**, and **load**.

Each of the three has a standard implementation and a standard way of being wrong.

**Simulated callers** are easy to build and easy to build too politely. A synthetic caller
that speaks in clean sentences and waits its turn exercises none of the machinery that
breaks.

**LLM-as-judge** is how everyone scores conversations, and its output is a *biased estimate*
of what you care about, because a judge is a noisy classifier. Measured below: a judge with
80% sensitivity and 97% specificity, on a population whose true success rate is 90%, reports
**72.3%** — a 17.7-point understatement. Worse, a nearly useless judge can look fine: at a
90% base rate, a judge with 65%/60% accuracy still shows **90% raw agreement** with humans
while its Cohen's κ is **0.11**. Agreement is not evidence.

**Load testing** usually stops at the wrong place. The interesting point is not where CPU
saturates, it is the **knee** — where the queue starts winning. Measured below, on a
60-worker pool with three-minute sessions, p95 latency is flat at 1500 ms all the way to
ρ = 0.77 and then jumps to **5060 ms at ρ = 0.80**. Every infrastructure dashboard reads
"80% busy, fine".

---

## 2. Rigour

### 2.1 Simulated callers

Two kinds, and you need both.

**Scripted callers** are deterministic: a fixed sequence of utterances, played as recorded
audio or synthesised, with specified timing. They are reproducible, so they belong in CI and
they are what latency gates run against
([`01-testing.md`](01-testing.md)). Their limit is that they cannot react, so they cannot
test recovery.

**LLM-driven callers** hold a goal and a persona, listen to the agent, and decide what to
say next. They find the bugs scripted callers cannot: mid-conversation corrections, ambiguous
references, refusal to be handled. Their cost is nondeterminism, so they belong in nightly
runs with aggregate metrics, never in a per-commit gate.

The design that makes an LLM caller useful rather than decorative:

| Component | Requirement | Why |
|---|---|---|
| Goal | explicit, checkable success condition | otherwise you cannot score the run |
| Persona | register, pace, patience, cooperativeness | drives the acoustic and pragmatic variation ([`../05-llm-layer/05-persona-design.md`](../05-llm-layer/05-persona-design.md)) |
| Voice | varied TTS voices, rates, accents | one voice tests one acoustic condition |
| Barge-in policy | when and how often it interrupts | the only way to exercise §2.2's hardest case |
| Turn timing | pauses, hesitations, mid-sentence stops | this is what breaks endpointers ([`../03-turn-taking/02-endpointing.md`](../03-turn-taking/02-endpointing.md)) |
| Channel | wideband, 8 kHz telephony, added noise | 8 kHz is a different WER regime ([`../07-livekit/05-telephony-sip.md`](../07-livekit/05-telephony-sip.md)) |
| Termination | max turns, and a give-up condition | otherwise a looping agent runs forever |

The single highest-value property is **turn timing**, because a caller that pauses
mid-sentence for 900 ms is the input that separates a real endpointer from a demo one, and
no amount of text-level cleverness substitutes for it.

### 2.2 Adversarial personas

Ranked by bugs found per hour of implementation. These are not edge cases; they are Tuesday.

| Persona | Behaviour | What it breaks |
|---|---|---|
| **The interrupter** | speaks over the agent constantly | barge-in, truncation correctness, echo ([`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md)) |
| **The mumbler** | low SNR, trailing off, filler words | ASR confidence handling, confirmation policy |
| **The corrector** | "no, the *other* one", "actually, make that Tuesday" | context state, tool idempotency ([`../05-llm-layer/03-tools-and-agentic.md`](../05-llm-layer/03-tools-and-agentic.md)) |
| **The speller** | reads out alphanumeric IDs | entity WER, 8 kHz confusions ([`../04-tts/04-prosody-and-voice.md`](../04-tts/04-prosody-and-voice.md)) |
| **The pauser** | long mid-sentence pauses | endpointing; produces premature cut-offs |
| **The backchanneler** | "mm-hm", "right", "yeah" while listening | false interruptions ([`../03-turn-taking/04-barge-in.md`](../03-turn-taking/04-barge-in.md)) |
| **The rambler** | 45-second turns | ASR finalisation, context growth, timeouts |
| **The silent caller** | says nothing at all | idle timeouts, the never-dead-air invariant ([`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md)) |
| **The code-switcher** | changes language mid-call | language detection, voice consistency |
| **The prompt injector** | speaks instructions at the agent | guardrails ([`03-safety-and-privacy.md`](03-safety-and-privacy.md)) |
| **The dual-tone caller** | speakerphone with a TV on | AEC, VAD ([`../03-turn-taking/05-echo-and-aec.md`](../03-turn-taking/05-echo-and-aec.md)) |

Run each persona as a fixed cohort so you get a per-persona success rate rather than one
blended number. A blended 87% hides "97% cooperative, 41% interrupter", and the second
number is the product.

### 2.3 LLM-as-judge, done responsibly

A judge is a classifier with sensitivity (TPR) and specificity (TNR). If the true success
rate is $p$, the fraction it marks successful is

$$
p_{\text{obs}} = p \cdot \text{TPR} + (1-p)(1 - \text{TNR})
$$

which inverts to the **Rogan–Gladen estimator**:

$$
\hat{p} = \frac{p_{\text{obs}} - (1 - \text{TNR})}{\text{TPR} - (1 - \text{TNR})}
$$

`[MEASURED]` from §3:

| Judge | TPR | TNR | p true | Judge says | Bias | Corrected | Raw agree | κ |
|---|---|---|---|---|---|---|---|---|
| strict, accurate | 0.95 | 0.92 | 90% | 86.3% | −3.7% | **90.0%** | 94.7% | 0.75 |
| strict, accurate | 0.95 | 0.92 | 75% | 73.2% | −1.8% | **75.0%** | 94.2% | 0.85 |
| lenient | 0.98 | 0.70 | 75% | 81.0% | **+6.0%** | 75.0% | 91.0% | 0.74 |
| harsh | 0.80 | 0.97 | 90% | 72.3% | **−17.7%** | 90.0% | 81.7% | 0.43 |
| coin-flip-ish | 0.65 | 0.60 | 90% | 62.5% | **−27.5%** | 90.0% | **90.0%** | **0.11** |

Four rules follow, and they are the whole of responsible judging.

**Never report a raw judge score as a quality number.** The bias reaches 27.5 points, and
its *sign* depends on the judge's asymmetry — a lenient judge overstates, a harsh one
understates. Correct it, or report it explicitly as "judge score" and never as "task
success".

**Report κ, not agreement.** The last row is the trap: 90% raw agreement, κ = 0.11. At a 90%
base rate, a judge that says "success" almost always agrees almost always. Agreement measures
the base rate; κ measures the signal.

**Even relative comparisons are attenuated.** `[MEASURED]` — the same judge scoring two
systems whose true rates differ by 5.0 points:

| Judge | Judge-reported gap | Compression |
|---|---|---|
| strict, accurate | +4.4% | 0.87× |
| lenient | +3.4% | 0.68× |
| harsh | +3.8% | 0.77× |
| coin-flip-ish | +1.2% | **0.25×** |

The common defence — "the bias cancels when comparing A to B" — is only *half* true. The
offset cancels; the **scale does not**. A weak judge compresses a 5-point improvement into
1.2 points, so you will conclude your change did nothing.

**Calibration is a fixed, affordable cost.** `[MEASURED]` — human labels needed to pin TPR
and TNR to ±3% at 95% confidence: **203 per class** if the judge is ~95% accurate, **683 per
class** at ~80%. That is one or two days of labelling, once per judge version, and it
converts an uninterpretable number into an estimate with a known error. Re-calibrate whenever
the judge model, the prompt, or the traffic mix changes.

Two further practices. **Judge on the transcript plus the event log, not the audio**, unless
you are specifically judging audio quality — it is cheaper, more reproducible, and the
failures you are scoring are usually textual. And **judge narrow, checkable propositions**
("did the agent confirm the order number before mutating it?") rather than "was this a good
call"; narrow questions have higher TPR and TNR, which by the table above is worth more than
any prompt engineering.

### 2.4 The quality dashboard

The metric set that predicts whether users are happy, split by what it measures:

| Layer | Metric | Source |
|---|---|---|
| Perception | `wer`, entity WER | offline against labels ([`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md)) |
| Turn-taking | `endpoint_f1`, cut-off rate, `interruption_rate`, false-interruption rate | event log |
| Latency | `eou_to_ttfa` p50/p95, `ttfb_tts`, dead-air violations | metrics ([`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md)) |
| Outcome | task success (corrected), containment, escalation rate, turns-to-resolution | judge + calibration |
| Reliability | clean-call rate, call completion | [`../06-realtime-systems/07-reliability.md`](../06-realtime-systems/07-reliability.md) |
| Cost | $ per successful call | span attributes |

Two disciplines. **Segment by persona, channel and locale** — a blended number is the average
of things you would act on differently. And **cost per *successful* call**, because
cost-per-call improves when the agent fails faster.

### 2.5 Load to the knee

Ramp offered load and watch the p95 that users experience — pipeline latency *plus* queueing.
`[MEASURED]` from §3, 60 workers, 180 s mean session, 1500 ms in-pipeline p95:

| ρ | Busy workers | Queue p95 | Total p95 | vs baseline | Verdict |
|---|---|---|---|---|---|
| 0.50 | 30 | 0 ms | 1500 ms | 1.00× | ok |
| 0.68 | 41 | 0 ms | 1500 ms | 1.00× | ok |
| 0.74 | 44 | 0 ms | 1500 ms | 1.00× | ok |
| 0.77 | 46 | 0 ms | 1500 ms | 1.00× | ok |
| **0.80** | 48 | **3560 ms** | **5060 ms** | **3.37×** | past knee |
| 0.83 | 50 | 14 024 ms | 15 524 ms | 10.35× | past knee |
| 0.92 | 55 | 79 843 ms | 81 343 ms | 54.23× | past knee |

The knee is at **ρ = 0.80**, and it is sharp: nothing between 0.50 and 0.77, then a 3.4×
degradation in one 3-point step. Three consequences for how you run a load test.

**Ramp past the knee deliberately, then back off.** A test that ramps until "CPU looks
concerning" stops in the flat region and reports success. You must ramp until p95 breaks,
because the location of the break is the number you need.

**Report the knee as a load, not a utilisation.** "48 concurrent calls" is actionable;
"ρ = 0.80" requires everyone to remember the pool size. And note from
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)
that the safe ρ depends on pool size — so the knee moves when you resize the fleet, and the
load test must be re-run after any change to worker count.

**Measure the user-visible p95, not the stage p95.** Every per-stage metric stays flat
through the knee, because the stages are fine; it is the *wait for a stage* that explodes.
A load test instrumented only per-stage sees nothing.

Beyond the knee, what you want to observe is *how* it fails: does admission control reject
cleanly (§2.3 of the scale chapter), or does everything degrade together? Graceful rejection
at 105% load is a far better outcome than universal 15-second latency, and only a load test
run past the knee tells you which you have.

### 2.6 Soak tests and leaks

Leaks are found by regressing RSS on time, and the question is what slope you can resolve
against GC and allocator noise. With $m$ samples over $T$ hours and noise $\sigma$, the
standard error of the OLS slope is $\sigma / \sqrt{S_{xx}}$; requiring a $3\sigma$ slope
gives the minimum detectable leak.

`[MEASURED]` from §3 — 1200 sessions/hour, RSS sampled 12×/hour, σ = 18 MB:

| Leak / session | MB/hour | Hours to 8 GB | 1 h | 4 h | 12 h | 24 h | 72 h |
|---|---|---|---|---|---|---|---|
| 2000 KB | 2343.75 | 3 h | yes | yes | yes | yes | yes |
| 140 KB | 164.06 | 50 h | yes | yes | yes | yes | yes |
| 12 KB | 14.06 | 583 h | · | yes | yes | yes | yes |
| 2 KB | 2.34 | 3495 h | · | · | yes | yes | yes |
| 0.4 KB | 0.47 | 17 476 h | · | · | · | yes | yes |

| Soak length | Minimum detectable leak |
|---|---|
| 1 h | 54.19 MB/hour (46.24 KB/session) |
| 4 h | 6.75 MB/hour (5.76 KB/session) |
| 12 h | 1.30 MB/hour (1.11 KB/session) |
| 24 h | 0.46 MB/hour (0.39 KB/session) |
| 72 h | 0.09 MB/hour (0.08 KB/session) |

**A one-hour soak can only find leaks above ~46 KB per session**, which are the ones that
would have crashed in staging anyway. The leaks that page you at 4 a.m. on day nine are
single-digit KB per session, and they need a 12-to-24-hour soak. That is the argument for a
scheduled soak rather than a CI job.

And the check teams actually write is much weaker than a regression. `[MEASURED]` — "is RSS
higher at the end than at the start?" against the 2.34 MB/hour leak:

| Soak | Fires |
|---|---|
| 1 h | **54.0%** |
| 4 h | 62.4% |
| 12 h | 86.7% |
| 24 h | 98.4% |
| 72 h | 100.0% |

At one hour it is a **coin flip** — two noisy samples cannot see a real leak — and it stays
unreliable for hours. Fit the slope over all samples; do not compare two endpoints.

Leaks to look for specifically in a voice agent, because they are the recurring ones: tasks
never awaited after cancellation (assert `asyncio.all_tasks()` is clean per session,
[`01-testing.md`](01-testing.md)); audio buffers retained by a closure after the session
ends; per-session vendor connections not closed on the error path; growing conversation
context held in a module-level cache; and metrics labelled with a session ID, which leaks in
your *monitoring* system rather than your process.

---

## 3. From scratch

Judge calibration, the load knee, and soak-test detection power. Standalone, stdlib only,
deterministic.

```python
"""Simulation, judging, and load: three ways a dashboard lies to you.

Part A -- LLM-as-judge. A judge is a noisy classifier, so its reported score is
a biased estimate of the thing you care about. Derive the correction, show what
the bias costs, and compute how many human labels calibration needs. Also show
why raw agreement is a useless statistic when the base rate is skewed.

Part B -- load to the knee. Ramp offered load and watch p95 turn up. The knee is
not where CPU saturates; it is where the queue starts winning, and it arrives
much earlier than intuition suggests.

Part C -- soak tests. A small per-session leak is invisible for hours. Given
noisy memory samples, what is the smallest leak a soak of length T can detect?

Deterministic: fixed seeds, stdlib only.
"""

import math
import random

SEED = 103


# --------------------------------------------------------------- Part A
def observed_rate(p_true, tpr, tnr):
    """What fraction of calls the judge marks 'success'."""
    return p_true * tpr + (1 - p_true) * (1 - tnr)


def corrected(p_obs, tpr, tnr):
    """Rogan-Gladen: invert the judge's confusion matrix."""
    denom = tpr - (1 - tnr)
    if abs(denom) < 1e-9:
        return float("nan")
    return (p_obs - (1 - tnr)) / denom


def cohen_kappa(p_true, tpr, tnr):
    """Kappa between judge and human on the same population."""
    a = p_true * tpr                        # both say success
    b = p_true * (1 - tpr)                  # human yes, judge no
    c = (1 - p_true) * (1 - tnr)            # human no, judge yes
    d = (1 - p_true) * tnr                  # both say fail
    po = a + d
    pe = (a + b) * (a + c) + (c + d) * (b + d)
    return po, (po - pe) / (1 - pe) if pe < 1 else float("nan")


def part_a():
    judges = [("strict, accurate", 0.95, 0.92),
              ("lenient", 0.98, 0.70),
              ("harsh", 0.80, 0.97),
              ("coin-flip-ish", 0.65, 0.60)]
    print("a judge with sensitivity TPR and specificity TNR, on a population "
          "whose TRUE success rate is p\n")
    print(f"{'judge':18s} {'TPR':>5} {'TNR':>5} {'p_true':>7} {'judge says':>11} "
          f"{'bias':>7} {'corrected':>10} {'raw agree':>10} {'kappa':>7}")
    for name, tpr, tnr in judges:
        for p in (0.90, 0.75):
            obs = observed_rate(p, tpr, tnr)
            po, k = cohen_kappa(p, tpr, tnr)
            print(f"{name:18s} {tpr:5.2f} {tnr:5.2f} {p:7.0%} {obs:10.1%} "
                  f"{obs-p:+6.1%} {corrected(obs, tpr, tnr):9.1%} "
                  f"{po:9.1%} {k:7.2f}")
    print("\nthe same judge on two systems (A true 75%, B true 80%):")
    for name, tpr, tnr in judges:
        a, b = observed_rate(0.75, tpr, tnr), observed_rate(0.80, tpr, tnr)
        print(f"  {name:18s} judge gap {b-a:+.1%} vs true gap +5.0%  "
              f"(compression {(b-a)/0.05:.2f}x)")
    print("\nhuman labels needed to pin TPR and TNR to +/-3% at 95% confidence:")
    for rate in (0.95, 0.80):
        n = 1.96 ** 2 * rate * (1 - rate) / 0.03 ** 2
        print(f"  at true rate {rate:.0%}: {math.ceil(n)} labelled examples "
              f"per class")


# --------------------------------------------------------------- Part B
def mmn_wait_p95(n, rho, aht_s):
    """M/M/n: 95th percentile of waiting time, in ms."""
    if rho >= 1:
        return float("inf")
    a = rho * n
    b = 1.0
    for k in range(1, n + 1):
        b = a * b / (k + a * b)
    c = n * b / (n - a * (1 - b))
    rate = (n - a) / aht_s
    if c <= 0.05:
        return 0.0
    return math.log(c / 0.05) / rate * 1000.0


def part_b(n=60, aht_s=180.0, service_p95_ms=1500.0):
    print(f"pool of {n} workers, mean session {aht_s:.0f}s, "
          f"in-pipeline p95 {service_p95_ms:.0f} ms\n")
    print(f"{'rho':>6} {'busy workers':>13} {'queue p95':>11} {'total p95':>11} "
          f"{'vs baseline':>12} {'verdict':>11}")
    base = service_p95_ms
    knee = None
    for i in range(15):
        rho = 0.50 + i * 0.03
        q = mmn_wait_p95(n, rho, aht_s)
        total = service_p95_ms + q
        ratio = total / base
        if knee is None and ratio >= 1.2:
            knee = rho
        verdict = "ok" if ratio < 1.2 else ("KNEE" if ratio < 2 else "past knee")
        qs = f"{q:9.0f}ms" if math.isfinite(q) else "      inf  "
        ts = f"{total:9.0f}ms" if math.isfinite(total) else "      inf  "
        print(f"{rho:6.2f} {rho*n:13.0f} {qs} {ts} {ratio:11.2f}x "
              f"{verdict:>11}")
    print(f"\nknee at rho = {knee:.2f}: p95 is 20% worse while "
          f"{knee:.0%} of workers are busy and every dashboard looks healthy")
    print("a load test that ramps to 'CPU looks fine' stops before the knee")


# --------------------------------------------------------------- Part C
def slope_se(hours, samples_per_hour, noise_mb):
    m = int(hours * samples_per_hour)
    if m < 3:
        return float("inf")
    t = [i / samples_per_hour for i in range(m)]
    tbar = sum(t) / m
    sxx = sum((x - tbar) ** 2 for x in t)
    return noise_mb / math.sqrt(sxx) if sxx > 0 else float("inf")


def part_c(sessions_per_hour=1200.0, noise_mb=18.0, samples_per_hour=12,
           rss_budget_mb=8192.0):
    print(f"{sessions_per_hour:.0f} sessions/hour, RSS sampled "
          f"{samples_per_hour}x/hour, {noise_mb:.0f} MB of GC/arena noise (sd)")
    print(f"detection = OLS slope exceeds 3 standard errors\n")
    soaks = (1, 4, 12, 24, 72)
    print(f"{'leak/session':>13} {'MB/hour':>9} {'hours to 8 GB':>14}  " +
          "  ".join(f"{h:>4}h" for h in soaks))
    for kb in (2000.0, 140.0, 12.0, 2.0, 0.4):
        mbh = kb * sessions_per_hour / 1024.0
        to_oom = rss_budget_mb / mbh
        cells = []
        for h in soaks:
            cells.append(" yes " if mbh > 3 * slope_se(h, samples_per_hour,
                                                       noise_mb) else "  .  ")
        print(f"{kb:10.1f} KB {mbh:9.2f} {to_oom:13.0f}h  " + " ".join(cells))
    print(f"\nminimum detectable leak by soak length:")
    for h in soaks:
        se = slope_se(h, samples_per_hour, noise_mb)
        print(f"  {h:3d} h -> {3*se:7.2f} MB/hour "
              f"({3*se*1024/sessions_per_hour:6.2f} KB/session)")

    # the check teams actually write, on a leak that matters but is small
    rng = random.Random(SEED)
    small_mbh = 2.0 * sessions_per_hour / 1024.0
    print(f"\n'is RSS higher at the end than at the start?' on the "
          f"{small_mbh:.2f} MB/hour leak:")
    for h in soaks:
        wins = sum(1 for _ in range(2000)
                   if rng.gauss(1000 + small_mbh * h, noise_mb)
                   > rng.gauss(1000, noise_mb))
        print(f"  {h:3d} h: fires {wins/2000:5.1%} of the time "
              f"(a coin flip is 50.0%)")


if __name__ == "__main__":
    print("PART A -- LLM-as-judge is a noisy classifier\n")
    part_a()
    print("\n\nPART B -- find the knee, not the saturation point\n")
    part_b()
    print("\n\nPART C -- soak tests and what they can actually detect\n")
    part_c()
```

Output `[MEASURED]`:

```
PART A -- LLM-as-judge is a noisy classifier

a judge with sensitivity TPR and specificity TNR, on a population whose TRUE success rate is p

judge                TPR   TNR  p_true  judge says    bias  corrected  raw agree   kappa
strict, accurate    0.95  0.92     90%      86.3%  -3.7%     90.0%     94.7%    0.75
strict, accurate    0.95  0.92     75%      73.2%  -1.8%     75.0%     94.2%    0.85
lenient             0.98  0.70     90%      91.2%  +1.2%     90.0%     95.2%    0.72
lenient             0.98  0.70     75%      81.0%  +6.0%     75.0%     91.0%    0.74
harsh               0.80  0.97     90%      72.3% -17.7%     90.0%     81.7%    0.43
harsh               0.80  0.97     75%      60.8% -14.2%     75.0%     84.2%    0.65
coin-flip-ish       0.65  0.60     90%      62.5% -27.5%     90.0%     64.5%    0.11
coin-flip-ish       0.65  0.60     75%      58.8% -16.2%     75.0%     63.8%    0.21

the same judge on two systems (A true 75%, B true 80%):
  strict, accurate   judge gap +4.4% vs true gap +5.0%  (compression 0.87x)
  lenient            judge gap +3.4% vs true gap +5.0%  (compression 0.68x)
  harsh              judge gap +3.8% vs true gap +5.0%  (compression 0.77x)
  coin-flip-ish      judge gap +1.2% vs true gap +5.0%  (compression 0.25x)

human labels needed to pin TPR and TNR to +/-3% at 95% confidence:
  at true rate 95%: 203 labelled examples per class
  at true rate 80%: 683 labelled examples per class


PART B -- find the knee, not the saturation point

pool of 60 workers, mean session 180s, in-pipeline p95 1500 ms

   rho  busy workers   queue p95   total p95  vs baseline     verdict
  0.50            30         0ms      1500ms        1.00x          ok
  0.53            32         0ms      1500ms        1.00x          ok
  0.56            34         0ms      1500ms        1.00x          ok
  0.59            35         0ms      1500ms        1.00x          ok
  0.62            37         0ms      1500ms        1.00x          ok
  0.65            39         0ms      1500ms        1.00x          ok
  0.68            41         0ms      1500ms        1.00x          ok
  0.71            43         0ms      1500ms        1.00x          ok
  0.74            44         0ms      1500ms        1.00x          ok
  0.77            46         0ms      1500ms        1.00x          ok
  0.80            48      3560ms      5060ms        3.37x   past knee
  0.83            50     14024ms     15524ms       10.35x   past knee
  0.86            52     27666ms     29166ms       19.44x   past knee
  0.89            53     47283ms     48783ms       32.52x   past knee
  0.92            55     79843ms     81343ms       54.23x   past knee

knee at rho = 0.80: p95 is 20% worse while 80% of workers are busy and every dashboard looks healthy
a load test that ramps to 'CPU looks fine' stops before the knee


PART C -- soak tests and what they can actually detect

1200 sessions/hour, RSS sampled 12x/hour, 18 MB of GC/arena noise (sd)
detection = OLS slope exceeds 3 standard errors

 leak/session   MB/hour  hours to 8 GB     1h     4h    12h    24h    72h
    2000.0 KB   2343.75             3h   yes   yes   yes   yes   yes 
     140.0 KB    164.06            50h   yes   yes   yes   yes   yes 
      12.0 KB     14.06           583h    .    yes   yes   yes   yes 
       2.0 KB      2.34          3495h    .     .    yes   yes   yes 
       0.4 KB      0.47         17476h    .     .     .    yes   yes 

minimum detectable leak by soak length:
    1 h ->   54.19 MB/hour ( 46.24 KB/session)
    4 h ->    6.75 MB/hour (  5.76 KB/session)
   12 h ->    1.30 MB/hour (  1.11 KB/session)
   24 h ->    0.46 MB/hour (  0.39 KB/session)
   72 h ->    0.09 MB/hour (  0.08 KB/session)

'is RSS higher at the end than at the start?' on the 2.34 MB/hour leak:
    1 h: fires 54.0% of the time (a coin flip is 50.0%)
    4 h: fires 62.4% of the time (a coin flip is 50.0%)
   12 h: fires 86.7% of the time (a coin flip is 50.0%)
   24 h: fires 98.4% of the time (a coin flip is 50.0%)
   72 h: fires 100.0% of the time (a coin flip is 50.0%)
```

Three load-bearing details. **`corrected` returns exactly the true rate in every row**, and
that is the point of printing it: the correction is not an approximation, it is an exact
inversion of the confusion matrix, so the only thing standing between a judge score and a
real estimate is knowing TPR and TNR. **`cohen_kappa` computes the expected agreement `pe`
from the marginals rather than assuming 0.5**, which is why the coin-flip judge shows 90%
agreement and κ = 0.11 — hard-coding a 50% chance baseline would have hidden the entire
effect. And **Part C's `slope_se` depends on $S_{xx}$, not on the sample count alone**, so
sampling more often within a short window barely helps while extending the window helps
quadratically; that is why the 1 h → 24 h improvement is 118× rather than 24×.

---

## 4. How production does it

**Simulated-caller harnesses are almost always in-house**, built on the same client SDK the
real app uses so that the transport path is identical. The reusable idea is to drive them
through recorded audio for the scripted cohort and TTS for the LLM cohort, so the acoustic
conditions are controlled rather than incidental.

**Judge calibration is the step everyone skips.** The published voice-agent evaluation
harnesses report raw judge scores; §2.3's arithmetic says those numbers are uninterpretable
without a labelled sample. Two days of labelling, once, is the difference between a metric
and a vibe.

**Load generation must originate off-box and go through the real transport.** A load test
that injects frames directly into the pipeline skips SRTP, the jitter buffer and the
connection count — the three things that break first
([`../06-realtime-systems/02-webrtc-internals.md`](../06-realtime-systems/02-webrtc-internals.md)).
For telephony, load-test the SIP path separately, because trunk channel limits are a
different constraint entirely
([`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)).

**Soaks run on a schedule against a pinned build**, with RSS, task count, file descriptors
and open connections all regressed on time. The non-memory counters catch leaks that memory
misses — a leaked task is a few kilobytes and a correctness bug.

**Nightly persona cohorts, weekly human review.** Automated scores track the trend; a small
human sample each week keeps the judge honest and catches the failure modes the judge was
never asked about.

---

## 5. At scale

**Simulation cost is real and worth capping.** LLM-driven callers pay for the caller's model,
the agent's model, ASR and TTS on both sides — several times a production call. Run the large
cohorts on scripted callers and reserve LLM callers for the personas that need reactivity.

**Load-test the dependency, not just yourself.** Ramping to your knee sends the same ramp to
your ASR, TTS and LLM vendors, whose rate limits you will discover the hard way. Warn them,
or use stubs at the vendor boundary and load-test your own capacity separately.

**The knee moves with pool size, so re-run after any fleet change.** §2.5's ρ = 0.80 is for
60 workers; a smaller pool knees earlier. Any autoscaling change invalidates the previous
load test.

**Soak duration should exceed your longest deploy interval.** If you deploy daily, a leak
that needs 24 hours to appear is masked by your own release cadence — which sounds
convenient and means you will meet it during a code freeze.

**Adversarial cohorts belong in the release gate, weighted by traffic.** If 12% of real
callers interrupt constantly, the interrupter cohort's success rate should carry 12% of the
release decision, not an equal share with nine other personas.

**Keep a golden cohort frozen.** A small, unchanging set of conversations you never tune
against is the only way to detect drift across model, prompt and vendor changes over a year.

---

## 6. Exercises

**E8.2.1** Run the §3 listing. For a judge you actually use, estimate TPR and TNR from 100
labelled calls, apply the Rogan–Gladen correction to your current dashboard number, and
report the difference.

**E8.2.2** Show algebraically that the Rogan–Gladen estimator is exact, and find the
condition under which it becomes unusable. What does that condition mean about the judge?

**E8.2.3** Extend Part A to propagate the uncertainty in TPR and TNR into a confidence
interval on the corrected rate. With 203 labels per class, how wide is the interval?

**E8.2.4** Compute raw agreement and κ for a judge on a population with a 98% base rate.
State the agreement figure you could report and why it would be indefensible.

**E8.2.5** Re-run Part B for pool sizes 10, 60 and 400 and report the knee for each. Relate
the answer to the safe-utilisation table in
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md).

**E8.2.6** Run a real load test against your system past the knee. Report the concurrency at
which p95 doubles, and whether the system rejected cleanly or degraded uniformly.

**E8.2.7** Instrument RSS, `asyncio` task count and open file descriptors, run a 12-hour
soak, and fit slopes with confidence intervals for each. Report which counter is the most
sensitive leak detector for your system.

**E8.2.8** Implement three adversarial personas from §2.2 as LLM-driven callers, run 50
conversations each, and report per-persona success. State which persona you would fix first
and what it would cost.

---

## 7. Interview drill

> "Our eval harness says task success went from 82% to 84% after a prompt change, judged by
> GPT-class model with a rubric. Ship it?"

Not on that evidence, and the reason is that neither number means what it appears to. A judge
is a classifier with a sensitivity and a specificity, so the score it reports is a biased
estimate of the true success rate, and the bias can be large — in the arithmetic I would
bring, a judge at 80% sensitivity and 97% specificity reports 72.3% on a population that is
truly at 90%, an 17.7-point understatement. So "82%" is not our success rate; it is our
judge's reading of it, and until we have measured TPR and TNR on a labelled sample we cannot
convert one into the other.

The natural objection is that the bias cancels when comparing before and after, and that is
only half right. The *offset* cancels; the *scale* does not. The same measurement shows a
judge compressing a true 5-point improvement into as little as 1.2 points, a quarter of the
real effect. So a reported +2 points could be a true +2, or a true +8 seen through a weak
judge, and we cannot tell which without calibration. That matters in both directions: we
might be under-shipping a genuinely large win.

Then there is whether +2 is a real difference at all. That depends on how many conversations
were judged and how they were sampled. If it is a hundred conversations, the binomial
standard error on 82% is about 3.8 points, so a 2-point move is well inside noise and I would
expect it to reverse on a re-run. I would want the confidence interval and the sample size
before treating the direction as real, and I would want the result segmented by persona and
channel — a blended +2 can easily be +6 for cooperative callers and −4 for interrupters,
which is a different decision.

What I would actually do is cheap. Label two or three hundred conversations by hand once,
which pins TPR and TNR to about ±3% and is a day or two of work, then correct the score and
re-report it with an interval. Check κ rather than raw agreement while doing it, because at
these base rates a judge can show 90% agreement with κ of 0.11 and look excellent while
carrying almost no signal. And narrow the rubric: judging a checkable proposition like "did
the agent confirm the order number before mutating it" gives much higher sensitivity and
specificity than "was this a good call", and by the arithmetic that is worth more than any
amount of prompt tuning on the judge.

What distinguishes a senior answer is not stopping at the judge. A prompt change that moves
task success also moves response length, and response length moves latency, cost, and
interruption rate — so I would want `eou_to_ttfa`, turns-to-resolution and cost per
*successful* call alongside the quality number, because a change that buys two points of
success for four hundred milliseconds of latency is probably a regression. And I would ship
it as a canary on real traffic with call-level SLIs rather than deciding from the offline
harness at all; the harness's job is to stop bad changes reaching the canary, not to make the
final call.

The premise worth questioning is the rubric. If it was written by the same people who wrote
the prompt, and updated in the same change, then the two numbers are not comparable at all —
and that is a surprisingly common way for eval harnesses to report progress that does not
exist.

---

## Sources

- Rogan, W. J. & Gladen, B., "Estimating prevalence from the results of a screening test", *American Journal of Epidemiology* 107(1), 1978 — the estimator inverted in §2.3 and implemented as `corrected` in §3.
- Cohen, J., "A Coefficient of Agreement for Nominal Scales", *Educational and Psychological Measurement* 20(1), 1960 — κ, and the base-rate problem with raw agreement demonstrated in §2.3.
- Erlang C and the M/M/n conditional-wait distribution used for the knee in §2.5; derived and measured for capacity planning in [`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md).
- Ordinary least squares slope variance $\sigma^2 / S_{xx}$, applied to leak detection in §2.6.
- Metric definitions and the offline-versus-request-time split: [`../06-realtime-systems/06-observability.md`](../06-realtime-systems/06-observability.md); WER methodology and bootstrap intervals: [`../02-asr/07-evaluation.md`](../02-asr/07-evaluation.md).
- Prior measurements in this curriculum reused rather than repeated: the safe-utilisation-versus-pool-size table and the trunking gain from [`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md); the frames-heard-after-interrupt result that §2.2's interrupter persona exercises, from [`../06-realtime-systems/03-pipeline-architecture.md`](../06-realtime-systems/03-pipeline-architecture.md).
- `[MEASURED]`: all three sections are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only, `SEED = 103`. Parts A and B are exact evaluations of closed-form expressions — the Rogan–Gladen inversion, Cohen's κ from marginals, Erlang C and the M/M/n wait quantile — so they are analytic rather than simulated; the four judge operating points, the 60-worker pool, the 180 s mean session and the 1500 ms in-pipeline p95 are `[INFERENCE]` inputs chosen to be representative, not measurements of a specific system. Part C's OLS standard errors are exact given the stated noise level; the 18 MB sampling noise, 1200 sessions/hour and 12 samples/hour are `[INFERENCE]` inputs, and the final end-versus-start table is a 2000-trial Monte Carlo. Substituting your own noise level and traffic rate changes every absolute figure while leaving the structural conclusions — judge bias needs correcting, the knee precedes saturation, and short soaks cannot see small leaks — unchanged.
