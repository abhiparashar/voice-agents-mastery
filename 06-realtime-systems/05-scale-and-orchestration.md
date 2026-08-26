# Scale and orchestration

**What you'll be able to do after this:** build a per-session resource model and size SIP
trunks, worker pools and GPU slots from it with classical capacity maths rather than
guesswork; explain why a pool of five needs 75% headroom and a pool of a thousand needs
7.5%; pick autoscaling signals that lead rather than lag; drain a fleet during a deploy
without dropping calls; and put a defensible number on $/1000 call-minutes.

---

## 1. Intuition

Scaling a voice agent is not scaling a web service, and the difference is one word:
**sessions are held**. An HTTP request occupies a worker for 80 ms; a call occupies one for
three minutes. That single change breaks most of the reflexes a backend engineer brings.

Autoscaling on CPU lags by minutes when your sessions last minutes. Rolling deploys that
drain in 30 seconds cut off live conversations. Load balancers that spread requests evenly
are useless when what matters is which node already holds the media. And the reflex that
"we're only at 70% CPU, we have room" is quantitatively wrong at small scale: measured
below, a pool of **5 workers at 70% utilisation makes 37.8% of callers wait**, with a mean
wait of 45 seconds. The same 70% on a pool of 1000 makes 0.0% wait.

That last result is the one idea this chapter is really about, and it is a hundred years
old. Erlang derived it for telephone trunks: **the utilisation you can safely run at is a
function of how many servers you have**, not a universal constant. Small pools must carry
enormous headroom; large pools barely any. It applies identically to SIP channels, agent
worker processes, and sessions packed onto a GPU — three problems that look unrelated and
are the same integral.

---

## 2. Rigour

### 2.1 The per-session resource model

Everything downstream depends on getting this table right for *your* system, so measure it
rather than adopting mine. The dimensions that bind in practice:

| Resource | Typical per session | Scales with | Notes |
|---|---|---|---|
| Media packets | 50 pkt/s each way | call duration | per-packet SRTP cost, not bandwidth ([`02-webrtc-internals.md`](02-webrtc-internals.md)) |
| Bandwidth | ~40 kbit/s each way wire | call duration | doubles on TURN relay |
| Agent process CPU | 3–15% of a core | continuous | Opus decode + VAD + orchestration |
| Agent process RSS | 150–400 MB | prewarm set | LiveKit warns at `job_memory_warn_mb=1000` |
| ASR compute | continuous, streaming | call duration | the only always-on model |
| LLM KV cache | 0.2–1.5 GB | context length | grows through the call |
| TTS compute | bursty, ~25% duty | agent speech time | idle during user turns |
| File descriptors | 3–30 | vendor connections | one per streaming vendor socket |

Two properties matter more than the numbers. **ASR is always on and TTS is not** — the
agent speaks perhaps a quarter of the time, so TTS capacity is sized on duty cycle while
ASR is sized on concurrency. And **KV cache grows monotonically within a session**, so the
last minute of a call costs more than the first, which is why capacity computed from
session *starts* under-provisions ([`../05-llm-layer/02-context-and-memory.md`](../05-llm-layer/02-context-and-memory.md)).

Offered load in erlangs is the unit that ties it together:

$$
A = \lambda \cdot h
$$

for arrival rate $\lambda$ (calls/s) and mean holding time $h$ (s). 20 calls/minute at
3 minutes each is $A = (20/60) \times 180 = 60$ erlangs — 60 simultaneous calls on average.
Everything below is a function of $A$.

### 2.2 Trunks: Erlang B, and the trunking gain

A SIP channel that is busy cannot queue a call; the call is rejected (SIP 486/503). That is
the lost-calls-cleared model, and its blocking probability is Erlang B, best computed by
the recursion rather than the factorial form:

$$
B(0, A) = 1, \qquad B(n, A) = \frac{A \cdot B(n-1, A)}{n + A \cdot B(n-1, A)}
$$

`[MEASURED]` from §3 — channels required to hold blocking at 1% and 0.1%:

| Offered load | Channels @1% | Utilisation | Channels @0.1% | Utilisation |
|---|---|---|---|---|
| 1 E | 5 | 20.0% | 6 | 16.7% |
| 5 E | 11 | 45.5% | 14 | 35.7% |
| 10 E | 18 | 55.6% | 21 | 47.6% |
| 25 E | 36 | 69.4% | 41 | 61.0% |
| 50 E | 64 | 78.1% | 71 | 70.4% |
| 100 E | 117 | 85.5% | 128 | 78.1% |
| 250 E | 273 | 91.6% | 291 | 85.9% |
| 500 E | 527 | **94.9%** | 555 | 90.1% |

This is the **trunking gain**, and it is strongly non-linear in the useful direction: 1
erlang needs 5 channels, but 500 erlangs needs 527 — capacity grows almost linearly with
load while efficiency climbs from 20% to 94.9%. Three practical consequences. Doubling your
traffic costs well under double the trunks, so per-minute carrier pricing that assumes
linear scaling is leaving margin on the table. Splitting one pool into per-region or
per-tenant pools **destroys** the gain — two pools of 50 E need 128 channels where one pool
of 100 E needs 117. And tightening the target from 1% to 0.1% costs roughly 5–10% more
channels, which is usually cheap enough to just do.

### 2.3 Worker pools: Erlang C, and why "70% is fine" is wrong

When a call that finds every worker busy *waits* instead of being dropped, the model is
Erlang C:

$$
C(n, A) = \frac{n \cdot B(n, A)}{n - A\left(1 - B(n, A)\right)}
$$

and the wait, conditioned on waiting, is exponential with rate $(n - A)/h$. So
$P(W > t) = C(n,A)\, e^{-(n-A)t/h}$.

The critical term is $h$, the holding time. For a web service $h$ is milliseconds and
queueing is invisible. For a voice session $h$ is **180 seconds**, so any queueing at all
is a disaster. `[MEASURED]` from §3:

| Pool | ρ | P(wait) | P(wait > 0.5 s) | P(wait > 2 s) | Mean wait |
|---|---|---|---|---|---|
| 5 | 0.70 | 37.8% | 37.6% | 37.2% | 45.3 s |
| 5 | 0.90 | 76.2% | 76.1% | 75.8% | 274.5 s |
| 10 | 0.70 | 22.2% | 22.0% | 21.4% | 13.3 s |
| 50 | 0.70 | 1.1% | 1.1% | 0.9% | 0.1 s |
| 50 | 0.90 | 36.4% | 35.9% | 34.4% | 13.1 s |
| 200 | 0.80 | 0.1% | 0.1% | 0.1% | 0.0 s |
| 200 | 0.90 | 9.4% | 8.9% | 7.6% | 0.9 s |
| 1000 | 0.90 | 0.1% | 0.0% | 0.0% | 0.0 s |

Note the first three columns are nearly identical in every row: **if a caller waits at all,
they wait a long time**, because the queue drains at the rate sessions end, which is
minutes. There is no "waits a little" regime for held sessions. That single observation
kills the intuition that a small overload is harmless.

Inverting the model gives the operating point directly. `[MEASURED]` — highest utilisation
at which fewer than 1% of calls wait more than 500 ms:

| Pool size | Safe ρ | Headroom required |
|---|---|---|
| 5 | 25.0% | **75.0%** |
| 10 | 40.5% | 59.5% |
| 50 | 69.5% | 30.5% |
| 200 | 84.0% | 16.0% |
| 1000 | 92.5% | **7.5%** |

**"Never run above 70%" is a statement about a pool of about fifty.** Below that it is
dangerously optimistic; above it, wasteful. This is also the honest answer to "why is our
staging environment fine and production not" — they are different pool sizes, so they have
different physics. And it is the argument for one large shared pool over many small
dedicated ones, in tension with the isolation argument in §2.5.

LiveKit's dispatch encodes exactly this policy. From `worker.py` 1.7.0: `load_threshold` is
**0.7** in production (and `inf` in dev), load is a five-sample moving average of
`cpu_percent(interval=0.5)` updated every `UPDATE_LOAD_INTERVAL = 0.5` s, and
`ASSIGNMENT_TIMEOUT = 7.5` s bounds how long the server waits for a worker to accept a job.
A worker above threshold stops accepting, which converts §2.3's queueing into §2.2's
rejection — the right choice, and one previously measured to reject 10% under a surge where
an unbounded threshold spent 38 s above load 1.0
([`../07-livekit/04-self-hosting-and-scale.md`](../07-livekit/04-self-hosting-and-scale.md)).

### 2.4 GPU packing: the same law, third form

A GPU holds model weights once and one KV cache per session. Naive packing divides the
free VRAM by the *mean* per-session footprint, and it is wrong for the same reason as §2.3:
sessions vary, and the sum of the tail overflows. `[MEASURED]` from §3 — 24 GB card, 9 GB
resident weights, per-session 0.42 GB mean / 0.11 GB sd, 20 GPUs:

| Sessions/GPU | P(OOM) per GPU | Expected OOMs | Fleet capacity | Headroom |
|---|---|---|---|---|
| 35 (naive) | **31.85%** | 6.37 | 700 | 2.0% |
| 34 | 13.38% | 2.68 | 680 | 4.8% |
| 33 | 4.08% | 0.82 | 660 | 7.6% |
| 32 | 0.68% | 0.14 | 640 | 10.4% |
| 31 | 0.07% | 0.01 | 620 | 13.2% |
| 30 | 0.00% | 0.00 | 600 | 16.0% |

Naive packing puts a third of your GPUs in OOM territory. The fix costs three sessions per
GPU — **8.6% of nominal capacity for a 47× reduction in failure probability**, which is one
of the better trades available in infrastructure. Two details matter operationally: a GPU
OOM in a voice system usually kills *every* session on that device, not the marginal one,
so the blast radius is the packing density; and because KV cache grows through a call, a
GPU that is safe at admission can overflow later, so admission control must reserve for the
projected footprint, not the current one.

### 2.5 Affinity, isolation, and process model

Media is stateful, so **session affinity is mandatory** — not an optimisation. The
consequences are structural: media servers need direct addressability rather than an HTTP
load balancer in front of them, and routing state (which node holds which room) lives in a
shared store, which is why LiveKit needs Redis for multi-node
([`../07-livekit/01-architecture.md`](../07-livekit/01-architecture.md)).

Within a worker, the choice is between many sessions per process and one process per
session. Held sessions and a shared event loop mean the former couples failures: one stage
doing 30 ms of synchronous work stalls every session on that loop
([`03-pipeline-architecture.md`](03-pipeline-architecture.md)), and one segfault in a
native audio library takes them all. Process-per-session converts correlated failure into
isolated failure, at the cost of memory and start-up time — which is why prewarming exists.
LiveKit's `num_idle_processes` is `min(ceil(cpu_count), 4)` in production and **0** in dev,
and that default is load-bearing: idle=0 was measured to put a **2.74 s cold start on every
call**, while idle=2 removed it entirely.

### 2.6 Autoscaling signals that actually work

The general rule for held sessions: **scale on admission-side signals, not
consumption-side ones.** CPU tells you what happened; you need what is about to happen.

| Signal | Lag | Verdict |
|---|---|---|
| CPU utilisation | minutes | too late — sessions already landed |
| Memory | minutes | lagging, and a cliff rather than a curve |
| Concurrent sessions | none | good — this is the erlang count |
| Sessions / capacity (ρ) | none | **best** — compare against §2.3's safe ρ for your pool size |
| Call arrival rate | leads by $h$ | **best leading signal** — arrivals now are load for the next 3 minutes |
| Available worker slots | none | good, and directly actionable |
| Queue depth / rejections | seconds | last resort: you are already failing |

Two corrections to the standard playbook. **Scale up on arrival rate, scale down on
session count**, because scaling up must anticipate and scaling down must wait for real
sessions to end — asymmetric policies for an asymmetric problem. And **cap scale-down
velocity below your drain time**: removing capacity faster than sessions naturally end is
just the deploy problem (§2.7) triggered by your own autoscaler.

### 2.7 Draining, and deploys during live calls

You cannot restart a process holding a three-minute conversation. The only correct pattern
is **drain, don't drop**: mark the worker ineligible for new jobs, let existing sessions run
to natural completion, then exit. That implies a drain window at least as long as your
longest session, and LiveKit sets `DRAIN_TIMEOUT = 3600` — one hour — which is a statement
about how long a support call can legitimately last, together with
`session_end_timeout = 300.0` and `shutdown_process_timeout = 10.0`.

Three failure modes to design against. **A drain that is shorter than your p99 session
kills the tail** — and long calls are disproportionately your most important ones. **A
simultaneous drain of many nodes is a thundering herd** of ICE restarts and reconnects
(§2.5 of [`02-webrtc-internals.md`](02-webrtc-internals.md)); stagger it. And **capacity
must be added before it is removed**, because during a rolling deploy your effective pool
shrinks, which by §2.3 raises ρ and can push a comfortable pool into the waiting regime for
the duration of the deploy.

### 2.8 The $/1000 call-minutes model

Build it as a sum of per-minute rates so that each term is separately attackable. Using
this curriculum's verified published prices (retrieved 2026-08-22):

| Layer | Component | $/min | $/1000 min |
|---|---|---|---|
| Media | WebRTC participant minutes | 0.0004 | 0.40 |
| Media | data egress (~0.6 MB/min at $0.10/GB) | 0.00006 | 0.06 |
| Telephony | US local inbound | 0.0100 | 10.00 |
| Orchestration | agent minutes (managed) | 0.0100 | 10.00 |
| Model | ASR (Nova-3) | 0.0048 | 4.80 |
| Model | TTS (Aura-2, ~150 wpm × 25% duty) | ~0.0108 | 10.80 |
| Model | LLM (Gemini 2.5 Flash-Lite) | 0.00009 | 0.09 |

Two structural facts fall out. **The LLM is negligible** — $0.00009 of roughly $0.0157 per
call-minute in the model layer, **0.6%** — so optimising the LLM to save money is
misdirected effort, while optimising it for *latency* is not. And **TTS and telephony
dominate**, which is why the local-TTS breakeven arrives so early (~56k audio-min/month
against ~1.2M for local ASR) and why the platform crossovers land where they do: Vapi below
~15.5k min/mo, LiveKit Cloud to ~133k, Cloud with your own agents to ~2.04M, fully
self-hosted beyond ([`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md)).

What this table omits is what capacity maths adds: you do not pay for the mean, you pay for
the provisioned peak. A pool sized at §2.3's safe ρ for 50 workers carries 30.5% headroom,
so the *effective* cost of any self-hosted term is roughly 1.44× its utilised cost. Vendor
per-minute pricing includes their trunking gain, which at small scale is genuinely cheaper
than buying your own headroom — the crossover is a capacity argument, not just a price
argument.

---

## 3. From scratch

Erlang B for trunks, Erlang C for worker pools, and Monte Carlo bin packing for GPUs.
Standalone, stdlib only, deterministic.

```python
"""Capacity for voice agents: trunks, workers, and GPUs.

Three questions, three pieces of classical maths that voice teams keep
rediscovering badly.

Part A -- how many SIP channels for a given call load? Erlang B, derived from
the recursion, because a blocked call is lost rather than queued.

Part B -- how many agent workers? Erlang C, because a call that finds every
worker busy waits (briefly) rather than being dropped. This is also where the
"never run above 70% utilisation" rule comes from, quantitatively.

Part C -- how many sessions per GPU? Bin packing with real variance. Average
demand tells you nothing useful; the tail decides whether you reject calls.

Standalone, stdlib only, deterministic.
"""

import math
import random

SEED = 23


# --------------------------------------------------------------- Part A
def erlang_b(n, a):
    """Blocking probability for n servers, offered load a erlangs (lost calls).

    Recursion B(0,a)=1, B(k,a) = a*B(k-1,a) / (k + a*B(k-1,a)). Numerically
    stable for large n, unlike evaluating the factorial form directly.
    """
    b = 1.0
    for k in range(1, n + 1):
        b = a * b / (k + a * b)
    return b


def trunks_for(a, target):
    n = 1
    while erlang_b(n, a) > target and n < 100_000:
        n += 1
    return n


def part_a():
    print(f"{'offered load':>13} {'trunks @1%':>11} {'utilisation':>12} "
          f"{'trunks @0.1%':>13} {'utilisation':>12} {'+trunks for 10x load':>21}")
    prev = None
    for a in (1, 5, 10, 25, 50, 100, 250, 500):
        n1 = trunks_for(a, 0.01)
        n01 = trunks_for(a, 0.001)
        grow = "" if prev is None else f"{n1 / prev[1]:.2f}x load {a/prev[0]:.0f}x"
        print(f"{a:10d} E {n1:11d} {a/n1:11.1%} {n01:13d} {a/n01:11.1%} "
              f"{grow:>21}")
        prev = (a, n1)


# --------------------------------------------------------------- Part B
def erlang_c(n, a):
    """Probability an arriving call must wait, n servers, offered load a."""
    if a >= n:
        return 1.0
    b = erlang_b(n, a)
    return n * b / (n - a * (1 - b))


def safe_rho(n, aht_s, budget_ms=500.0, target=0.01):
    """Highest utilisation at which P(wait > budget) stays under `target`."""
    best = 0.0
    rho = 0.01
    while rho < 0.995:
        a = rho * n
        c = erlang_c(n, a)
        rate = (n - a) / aht_s
        p_over = c * math.exp(-rate * budget_ms / 1000.0)
        if p_over <= target:
            best = rho
        rho += 0.005
    return best


def part_b(aht_s=180.0):
    """A session holds a worker for minutes, so 'queue a little' is not an option."""
    print(f"mean session {aht_s:.0f} s; a caller cannot wait, so the useful "
          f"question is P(wait at all)\n")
    print(f"{'pool':>6} {'rho':>6} {'P(wait)':>9} {'P(wait>0.5s)':>13} "
          f"{'P(wait>2s)':>11} {'mean wait':>10}")
    for n in (5, 10, 50, 200, 1000):
        for rho in (0.70, 0.80, 0.90):
            a = rho * n
            c = erlang_c(n, a)
            rate = (n - a) / aht_s
            over = lambda t: c * math.exp(-rate * t)
            mean_wait = c / rate if rate > 0 else float("inf")
            print(f"{n:6d} {rho:6.2f} {c:8.1%} {over(0.5):12.1%} "
                  f"{over(2.0):10.1%} {mean_wait:9.1f}s")
        print()
    print(f"{'pool':>6} {'safe rho @ P(wait>0.5s)<1%':>28} {'headroom needed':>16}")
    for n in (5, 10, 50, 200, 1000):
        r = safe_rho(n, aht_s)
        print(f"{n:6d} {r:27.1%} {1-r:15.1%}")


# --------------------------------------------------------------- Part C
GPU_VRAM_GB = 24.0
MODEL_RESIDENT_GB = 9.0          # weights, loaded once per GPU
PER_SESSION_GB_MEAN = 0.42       # KV cache + audio buffers
PER_SESSION_GB_SD = 0.11         # sessions differ: context length, history


def part_c(n_gpus=20, trials=4000):
    rng = random.Random(SEED)
    budget = GPU_VRAM_GB - MODEL_RESIDENT_GB
    naive = int(budget / PER_SESSION_GB_MEAN)
    print(f"VRAM {GPU_VRAM_GB:.0f} GB - model {MODEL_RESIDENT_GB:.0f} GB "
          f"= {budget:.0f} GB for sessions")
    print(f"mean session {PER_SESSION_GB_MEAN:.2f} GB (sd {PER_SESSION_GB_SD:.2f}) "
          f"-> naive packing {naive} sessions/GPU\n")
    print(f"{'sessions/GPU':>13} {'p(OOM) per GPU':>15} {'expected OOMs':>14} "
          f"{'usable capacity':>16} {'headroom':>10}")
    for k in range(naive, naive - 9, -1):
        oom = 0
        for _ in range(trials):
            used = sum(max(0.0, rng.gauss(PER_SESSION_GB_MEAN, PER_SESSION_GB_SD))
                       for _ in range(k))
            if used > budget:
                oom += 1
        p = oom / trials
        print(f"{k:13d} {p:14.2%} {p*n_gpus:13.2f} {k*n_gpus:15d} "
              f"{1 - k*PER_SESSION_GB_MEAN/budget:9.1%}")


if __name__ == "__main__":
    print("PART A -- SIP trunks (Erlang B, blocked calls are lost)\n")
    part_a()
    print("\n\nPART B -- worker pools (Erlang C, blocked calls wait)\n")
    part_b()
    print("\n\nPART C -- GPU packing with real per-session variance\n")
    part_c()
```

Output `[MEASURED]`:

```
PART A -- SIP trunks (Erlang B, blocked calls are lost)

 offered load  trunks @1%  utilisation  trunks @0.1%  utilisation  +trunks for 10x load
         1 E           5       20.0%             6       16.7%                      
         5 E          11       45.5%            14       35.7%         2.20x load 5x
        10 E          18       55.6%            21       47.6%         1.64x load 2x
        25 E          36       69.4%            41       61.0%         2.00x load 2x
        50 E          64       78.1%            71       70.4%         1.78x load 2x
       100 E         117       85.5%           128       78.1%         1.83x load 2x
       250 E         273       91.6%           291       85.9%         2.33x load 2x
       500 E         527       94.9%           555       90.1%         1.93x load 2x


PART B -- worker pools (Erlang C, blocked calls wait)

mean session 180 s; a caller cannot wait, so the useful question is P(wait at all)

  pool    rho   P(wait)  P(wait>0.5s)  P(wait>2s)  mean wait
     5   0.70    37.8%        37.6%      37.2%      45.3s
     5   0.80    55.4%        55.3%      54.8%      99.7s
     5   0.90    76.2%        76.1%      75.8%     274.5s

    10   0.70    22.2%        22.0%      21.4%      13.3s
    10   0.80    40.9%        40.7%      40.0%      36.8s
    10   0.90    66.9%        66.7%      66.1%     120.4s

    50   0.70     1.1%         1.1%       0.9%       0.1s
    50   0.80     8.7%         8.5%       7.8%       1.6s
    50   0.90    36.4%        35.9%      34.4%      13.1s

   200   0.70     0.0%         0.0%       0.0%       0.0s
   200   0.80     0.1%         0.1%       0.1%       0.0s
   200   0.90     9.4%         8.9%       7.6%       0.9s

  1000   0.70     0.0%         0.0%       0.0%       0.0s
  1000   0.80     0.0%         0.0%       0.0%       0.0s
  1000   0.90     0.1%         0.0%       0.0%       0.0s

  pool   safe rho @ P(wait>0.5s)<1%  headroom needed
     5                       25.0%           75.0%
    10                       40.5%           59.5%
    50                       69.5%           30.5%
   200                       84.0%           16.0%
  1000                       92.5%            7.5%


PART C -- GPU packing with real per-session variance

VRAM 24 GB - model 9 GB = 15 GB for sessions
mean session 0.42 GB (sd 0.11) -> naive packing 35 sessions/GPU

 sessions/GPU  p(OOM) per GPU  expected OOMs  usable capacity   headroom
           35         31.85%          6.37             700      2.0%
           34         13.38%          2.68             680      4.8%
           33          4.08%          0.82             660      7.6%
           32          0.68%          0.14             640     10.4%
           31          0.07%          0.01             620     13.2%
           30          0.00%          0.00             600     16.0%
           29          0.00%          0.00             580     18.8%
           28          0.00%          0.00             560     21.6%
           27          0.00%          0.00             540     24.4%
```

Three load-bearing details. **The Erlang B recursion is not a stylistic choice** — the
textbook factorial form overflows and loses precision well before 500 servers, and the
recursion is exact, allocation-free and $O(n)$; anyone who has seen a capacity spreadsheet
return `inf` has met this. **`P(wait>0.5s)` is nearly equal to `P(wait)` in every row of
Part B**, and that is the substantive result rather than a rounding artefact: the queue
drains at the rate sessions *end*, so for a 180 s holding time there is no brief-wait
regime — you either get a worker immediately or you wait tens of seconds. And **Part C
samples the per-session footprint rather than multiplying the mean**, which is the entire
point: the mean says 35 sessions fit, and sampling says 35 sessions overflow 31.85% of the
time. Capacity is a property of the tail.

---

## 4. How production does it

**LiveKit Agents** implements §2.3 and §2.7 with defaults worth quoting because they are a
policy, not arbitrary: `load_threshold` 0.7 in production and `inf` in dev, load as a
five-sample moving average of `cpu_percent(interval=0.5)` refreshed every
`UPDATE_LOAD_INTERVAL = 0.5` s, `ASSIGNMENT_TIMEOUT = 7.5` s, `DRAIN_TIMEOUT = 3600`,
`num_idle_processes = min(ceil(cpu_count), 4)` in production and 0 in dev,
`job_memory_warn_mb = 1000`, `job_memory_limit_mb = 0` (off), `initialize_process_timeout =
10.0`, `session_end_timeout = 300.0`, `max_retry = 16`. Read that list as the answer sheet
to this chapter: threshold-based admission, process isolation, prewarming, and an hour-long
drain ([`../07-livekit/02-agents-framework.md`](../07-livekit/02-agents-framework.md)).

**Media planes are addressed directly, never load-balanced at layer 7.** Every production
WebRTC deployment ends up with node-addressable media and a shared routing store, and the
teams that fight it lose ([`../07-livekit/04-self-hosting-and-scale.md`](../07-livekit/04-self-hosting-and-scale.md)).

**Carriers have sold Erlang B for a century.** When a SIP provider quotes "channels", they
are quoting §2.2, and the reason burst pricing exists is that your peak needs the trunks
and your mean pays the bill. Buying channels from one provider rather than three preserves
the trunking gain.

**Inference servers implement §2.4 as admission control.** vLLM-class servers track KV
blocks and preempt or queue rather than OOM, which is the correct architecture: refuse the
marginal session instead of losing the resident ones
([`../05-llm-layer/04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md)). If
you self-host, use a server that does this rather than computing a static batch size.

---

## 5. At scale

**One pool, many regions is a contradiction — resolve it deliberately.** Pooling maximises
the trunking gain; regionalisation minimises RTT. The tempting resolution — regionalise
*media* and pool *model capacity* centrally — does not work: with central inference the
media edge lies on the path to the model region, so it cannot shorten mouth-to-ear latency,
and with few edges it lengthens it. Measured in
[`08-deployment.md`](08-deployment.md): three media regions with central inference were
*worse* than one central region (756 ms mean, 38% of traffic over 800 ms, against 730 ms and
22%). Either co-locate models with media and pay the pooling tax per region, or stay central
and accept the RTT — the middle option is the one that loses on both axes.

**Per-tenant isolation costs the trunking gain, and you should price it.** Two pools of
50 E need 128 channels where one pool of 100 E needs 117 — a 9% tax on capacity for
isolation. That is often worth paying; it should be a decision, and enterprise tiers should
be priced with it in mind.

**Capacity for the peak, not the mean, and know the ratio.** Voice traffic is diurnal with
a 3–5× peak-to-mean, so the provisioned fleet is several times the average load, and
§2.3's headroom multiplies that again. Reserved-plus-burst is the natural shape.

**The GPU is the constraint you will hit first if you self-host models.** §2.4 fixes
sessions per device, and the LLM is 0.6% of your model spend — so self-hosting the LLM to
save money is close to pointless, while self-hosting TTS crosses over at roughly 56k
audio-minutes per month. Attack the expensive layer.

**Test the drain, not the deploy.** The only way to know your drain works is to deploy under
synthetic load and watch whether any session terminates non-naturally. Put that in the
release process ([`../08-eval-safety/02-simulation-and-load.md`](../08-eval-safety/02-simulation-and-load.md)).

**Watch for correlated arrivals.** Erlang assumes Poisson arrivals; an outbound campaign, a
TV advertisement, or a retry storm after an outage is not Poisson, and correlated arrivals
break every table in this chapter. Rate-limit outbound dialling and jitter your retries
([`07-reliability.md`](07-reliability.md)).

---

## 6. Exercises

**E6.5.1** Run the §3 listing. Compute the trunks needed for your own peak offered load at
1% and 0.1% blocking, and state the cost difference.

**E6.5.2** Show numerically that two pools of 50 E need more channels than one pool of
100 E at the same blocking target. Express the difference as a percentage tax on capacity
and decide whether your isolation requirement is worth it.

**E6.5.3** Extend Part B to compute the safe ρ for a 30-second mean session (an IVR-style
agent) and for a 900-second one (technical support). Explain how holding time changes the
operating point at fixed pool size.

**E6.5.4** Replace Part C's Gaussian per-session footprint with a right-skewed distribution
(lognormal, same mean and sd) and report how the safe packing density changes. Which
distribution do you believe for KV cache, and why?

**E6.5.5** Model KV-cache growth: make each session's footprint increase with its age and
re-run Part C with sessions at mixed ages. Report the admission rule you would implement.

**E6.5.6** Build the $/1000-min table for your own stack with your real prices and duty
cycles. Identify the largest term and the second largest, then state what you would
actually optimise and why the LLM is not it.

**E6.5.7** Take one week of your call arrival data. Compute peak-to-mean, fit an offered
load per hour, and produce a provisioning schedule using §2.3's safe ρ for your pool size.

**E6.5.8** Instrument a rolling deploy under synthetic load. Report how many sessions ended
non-naturally, and the longest session you successfully drained. If any were dropped,
compute the drain timeout you actually need from your session-duration p99.

---

## 7. Interview drill

> "Our voice agent handles 200 concurrent calls at peak on ten worker nodes. We're at about
> 70% CPU and callers are complaining about failures at busy times. Marketing wants to 3×
> the traffic next quarter. What do you do?"

The complaint and the metric are consistent, not contradictory, and saying why is the whole
answer. Seventy per cent utilisation is safe advice for a pool of about fifty servers; on a
pool of ten it is not close to safe. With held sessions the queue drains only as calls end,
so at ρ = 0.70 on ten workers roughly 22% of arrivals find no free worker, and the ones that
wait wait a mean of about thirteen seconds — which no caller experiences as a queue, they
experience it as a failure. To get fewer than 1% of calls waiting more than half a second
on a pool of ten, the safe utilisation is around 40%, so we are running at nearly double the
correct operating point. The failures are not a bug, they are the capacity plan.

So the immediate fix is more, smaller workers rather than bigger ones. Going from ten nodes
to fifty at the same total capacity raises the safe utilisation from about 40% to about 70%
for free — that is the trunking gain, and it is the cheapest performance win available here
because it is a repackaging rather than a purchase. I would also check that admission is
threshold-based, so an overloaded worker rejects rather than queues; converting a
thirteen-second wait into an immediate overflow to another node is strictly better for the
caller.

For the 3×, I would resist scaling the current shape by three. At 600 concurrent calls the
right pool is large enough to run at 80–85%, so the fleet grows sub-linearly with traffic if
we also increase the pool count — that is the good news I would bring to the capacity
conversation. What I would not assume is that the bottleneck stays where it is: I would want
the per-session resource model measured, because CPU is the current binding constraint but
KV cache, GPU packing or vendor connection limits may bind at 600, and each has a different
fix. And I would change the autoscaling signal from CPU to call arrival rate, because
arrivals lead load by the holding time while CPU lags it by minutes — with three-minute
calls, CPU-based autoscaling is always reacting to a peak that has already landed.

The senior addition is noticing that Erlang assumes Poisson arrivals and marketing does not.
If the 3× arrives as a campaign or an advertisement, the arrival process is correlated and
every number above understates the peak; I would ask for the shape of the growth, not just
the multiple, and rate-limit anything outbound that we control. I would also want to
validate the drain path before we triple the fleet, because deploys during peak temporarily
shrink the pool, which by the same maths is how a healthy system becomes an incident on a
Tuesday afternoon.

The premise worth questioning is "failures". If callers mean rejected or dropped calls,
this is capacity. If they mean the agent got slower or started talking over people, that is
queueing inside the pipeline or an interruption policy, and adding nodes will not touch it.
I would want the failure classified before spending the budget.

---

## Sources

- Erlang, A. K., "Solution of some Problems in the Theory of Probabilities of Significance in Automatic Telephone Exchanges", 1917 — the lost-calls-cleared model implemented as the recursion in §2.2. The numerically stable recursion $B(k,A) = A B(k-1,A) / (k + A B(k-1,A))$ is standard; see also Erlang C for the delay model in §2.3.
- Little, J. D. C., "A Proof for the Queuing Formula $L = \lambda W$", *Operations Research* 9(3), 1961 — the offered-load identity $A = \lambda h$ in §2.1; the utilisation-versus-p95 consequence is derived in [`../01-foundations/04-latency-budget.md`](../01-foundations/04-latency-budget.md).
- `livekit/agents` 1.7.0, `worker.py` — `ASSIGNMENT_TIMEOUT = 7.5`, `UPDATE_LOAD_INTERVAL = 0.5`, `DRAIN_TIMEOUT = 3600`, load computed as a five-sample moving average of `cpu_percent(interval=0.5)`, `load_threshold` `inf` in dev / **0.7** in production, `num_idle_processes` 0 in dev / `min(ceil(cpu_count), 4)` in production, `job_memory_warn_mb = 1000`, `job_memory_limit_mb = 0`, `shutdown_process_timeout = 10.0`, `session_end_timeout = 300.0`, `initialize_process_timeout = 10.0`, `max_retry = 16`, `port` 0 in dev / 8081 in production. Quoted in §2.3, §2.5, §2.7 and §4.
- Published prices retrieved 2026-08-22, used in §2.8: LiveKit Cloud WebRTC participant minutes $0.0004/min, agent minutes $0.01/min, data $0.10/GB; US local inbound $0.01/min; Deepgram Nova-3 $0.0048/min; Deepgram Aura-2 $30/M characters; Gemini 2.5 Flash-Lite $0.10/$0.01/$0.40 per M tokens. Marked `[UNVERIFIED PRICE]` where a vendor page could not be re-confirmed at the time of writing; the crossover conclusions are reproduced from [`../07-livekit/06-alternatives.md`](../07-livekit/06-alternatives.md) rather than re-derived here.
- Prior measurements in this curriculum reused rather than repeated: queueing p95 141 ms at ρ = 0.70 rising to 675 ms at ρ = 0.90; dispatch with `num_idle_processes = 0` imposing a 2.74 s cold start on every call, removed at idle = 2; `load_threshold = 0.7` rejecting 10% under a surge where `inf` spent 38 s above load 1.0; local TTS breakeven ≈ 56k audio-min/month versus local ASR ≈ 1.2M; the LLM at 0.6% of the model layer.
- `[MEASURED]`: all three tables are the output of the §3 listing on Apple M5 / macOS 26.5.2, CPython 3.12, stdlib only, `SEED = 23`. Parts A and B are exact evaluations of Erlang B and Erlang C plus the M/M/n conditional-wait exponential, so they are analytic rather than simulated; the 180 s mean holding time is an assumption stated in the code, not a measurement of any particular deployment. Part C is Monte Carlo over 4000 trials per packing density with a Gaussian per-session footprint (0.42 GB mean, 0.11 GB sd) that is an `[INFERENCE]` model of KV cache plus audio buffers, not a measurement of a specific model — the shape of the result (naive packing from the mean is badly unsafe) is robust to the distribution, the exact percentages are not.
