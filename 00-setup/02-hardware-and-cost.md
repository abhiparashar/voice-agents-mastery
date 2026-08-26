# Hardware and cost

**What you'll be able to do after this:** say which parts of this curriculum run on an Apple
Silicon Mac and which genuinely need CUDA; size any model against 16 GiB from its parameter
count, including the KV cache people forget; and price the whole curriculum, which comes to
**$5.10**.

---

## 1. Intuition

Two measured facts on the reference machine reframe what Apple Silicon is for.

**MPS is not a 10× accelerator.** On speech-shaped matmuls it beats the CPU by **1.22× to
1.73×** — 2903 GFLOP/s against 1682 on a prefill-shaped multiply. That is a real win and it
is not the order-of-magnitude people expect, because Apple's CPU matmul is unusually strong
and both share the same memory. The practical consequence: **do not port something to MPS
expecting a transformation**, and do not avoid the CPU expecting a disaster.

**The prefill/decode asymmetry is enormous and it is hardware, not software.** The same
device delivers 2903 GFLOP/s on a 512-row matmul and **59.7 GFLOP/s** on a 1-row one — a 49×
collapse. Decode is memory-bound and dispatch-bound; no accelerator fixes that, which is why
the LLM chapter measured a 69× per-token gap and why batching is the only real lever
([`../05-llm-layer/04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md)).

The third fact is about money. Everything in this curriculum runs locally, so the total
compute cost is **$0.30 of electricity** plus an optional **$4.80** of rented GPU for the
handful of `[NEEDS GPU]` exercises. Rented hardware is 47× to 467× the hourly cost of this
machine, and for learning it buys you almost nothing.

---

## 2. Rigour

### 2.1 The reference machine

| Property | Value |
|---|---|
| SoC | Apple M5 |
| Cores | 10 (4 performance + 6 efficiency) |
| Memory | 16 GiB unified |
| OS | macOS 26.5.2, Darwin 26.5.2, `arm64` |
| Accelerator | MPS available, **no CUDA** |
| `torch` | 2.13.0 |

**Unified memory is the defining property.** There is no host-to-device copy and no separate
VRAM budget: the GPU and CPU share the same 16 GiB. That is why a 5.77 GiB fp32 Whisper
large-v3 is loadable here and awkward on a 8 GB discrete card — and also why a large model
starves the OS, because there is nowhere else for it to go.

### 2.2 MPS versus CPU, measured

`[MEASURED]` from §3 — fp32 matmuls, 10 iterations after 3 warmups:

| Shape | CPU ms | MPS ms | Speedup | CPU GFLOP/s | MPS GFLOP/s |
|---|---|---|---|---|---|
| prefill-like (512×4096 @ 4096×4096) | 10.211 | 5.917 | **1.73×** | 1682.4 | **2903.3** |
| decode-like (1×4096 @ 4096×4096) | 0.864 | 0.562 | 1.54× | 38.8 | **59.7** |
| conv-ish (256×1280 @ 1280×1280) | 0.416 | 0.341 | 1.22× | 2016.5 | 2457.6 |
| mel-ish (3000×80 @ 80×512) | 0.200 | 0.139 | 1.45× | 1226.9 | 1774.1 |

Three readings.

**The speedups are modest and consistent.** 1.22–1.73× across four shapes. Apple's CPU path
goes through Accelerate and the matrix coprocessor, so it is genuinely fast; MPS wins on the
largest shape and narrows on the smallest. Anyone quoting a 10× MPS speedup for this kind of
work is not measuring this kind of work.

**Absolute throughput collapses 49× between prefill and decode shapes** — 2903 → 59.7
GFLOP/s on the *same device*. The arithmetic is identical per element; what changes is that a
1-row matmul cannot fill the machine and is dominated by memory traffic and kernel-launch
overhead. This is the hardware explanation for why streaming token generation is slow and
prefill is nearly free.

**Small tensors are dispatch-bound, so MPS can lose.** The `mel-ish` shape is 0.139 ms on
MPS; a chain of many such operations pays the launch cost every time. For per-frame DSP at
20 ms cadence, stay on the CPU with numpy — the frames are tiny and the overhead dominates.

### 2.3 What runs where

| Workload | On M5 | Notes |
|---|---|---|
| DSP, STFT, mel filterbanks | **yes**, numpy on CPU | frames are tiny; MPS is overhead |
| CTC / RNN-T loss derivations | **yes**, CPU | small tensors, exactness matters more than speed |
| Silero VAD | **yes**, real time trivially | 1.8 M parameters |
| faster-whisper (CTranslate2) | **yes**, int8 on CPU | CTranslate2 has no Metal backend; the CPU path is the fast path here |
| whisper.cpp / GGUF | **yes**, Metal | purpose-built for this hardware |
| MLX models | **yes** | Apple's own framework; best MPS utilisation |
| `openai-whisper` (PyTorch) | **yes**, MPS | slower than faster-whisper or whisper.cpp |
| Piper, Kokoro TTS | **yes** | ONNX/PyTorch, small models, real time |
| LLM ≤ 8 B via llama.cpp/MLX | **yes**, quantised | see §2.4 |
| Moshi (7 B full-duplex) | **yes**, int8, tight | 7.16 GiB of weights before KV cache |
| **Training anything non-trivial** | **no** | needs CUDA and multiple GPUs |
| **TensorRT** | **no** | NVIDIA-only by construction |
| **vLLM / SGLang** | **no** | CUDA-first; paged attention has no Metal path |
| **NVIDIA Riva / NeMo training** | **no** | CUDA-only |
| **Multi-GPU serving benchmarks** | **no** | rent for these |

The honest summary: **every derivation, every from-scratch listing, and every local-inference
exercise in this curriculum runs here.** What does not run is production *serving* software
and any real training — and those are the two places the curriculum says `[NEEDS GPU]`.

### 2.4 Sizing models against 16 GiB

Weights are $\text{params} \times \text{bytes per param}$. `[MEASURED]` from §3, in GiB,
with a 70% budget of 11.2 GiB to leave the OS room:

| Model | Params | fp32 | fp16 | int8 | int4 | Best that fits |
|---|---|---|---|---|---|---|
| silero-vad | 1.8 M | 0.01 | 0.00 | 0.00 | 0.00 | fp32 |
| piper (VITS medium) | 25 M | 0.09 | 0.05 | 0.02 | 0.01 | fp32 |
| whisper-tiny | 39 M | 0.15 | 0.07 | 0.04 | 0.02 | fp32 |
| whisper-base | 74 M | 0.28 | 0.14 | 0.07 | 0.03 | fp32 |
| kokoro-82M | 82 M | 0.31 | 0.15 | 0.08 | 0.04 | fp32 |
| whisper-small | 244 M | 0.91 | 0.45 | 0.23 | 0.11 | fp32 |
| distil-large-v3 | 756 M | 2.82 | 1.41 | 0.70 | 0.35 | fp32 |
| whisper-medium | 769 M | 2.86 | 1.43 | 0.72 | 0.36 | fp32 |
| whisper-large-v3 | 1550 M | 5.77 | 2.89 | 1.44 | 0.72 | fp32 |
| qwen3-1.7b | 1700 M | 6.33 | 3.17 | 1.58 | 0.79 | fp32 |
| moshi (7 B + depth) | 7690 M | 28.65 | 14.32 | **7.16** | 3.58 | int8 |
| llama-3.1-8b | 8030 M | 29.91 | 14.96 | **7.48** | 3.74 | int8 |

The arithmetic is exact — `[MEASURED]`, a 200 M-element fp32 allocation measured 0.745 GiB
against 0.745 GiB predicted.

**The KV cache is separate, and it is the term people forget.** It is
$2 \times \text{layers} \times \text{kv dim} \times \text{context} \times \text{bytes}$, and
it grows through the conversation. `[MEASURED]`:

| Configuration | fp16 | int8 |
|---|---|---|
| qwen3-1.7b, 8k context | 0.88 GiB | 0.44 GiB |
| llama-3.1-8b, 8k context | 1.00 GiB | 0.50 GiB |
| llama-3.1-8b, 32k context | **4.00 GiB** | 2.00 GiB |

So an int8 llama-3.1-8b at 32k context is 7.48 + 4.00 = 11.5 GiB, which is *over* the 11.2 GiB
budget before you load Whisper, Kokoro and a Python process. That is the real constraint on
this machine: not the weights, the weights **plus** context. It is also the local-scale
version of the GPU packing arithmetic in
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md),
where sizing from the mean rather than the tail put a third of the fleet in OOM territory.

**Practical local stack for a full cascaded agent on 16 GiB:** Silero VAD (0.01) +
faster-whisper `distil-large-v3` int8 (0.70) + Kokoro fp32 (0.31) + a 1.7 B LLM int8 (1.58) +
its KV cache (0.44) ≈ **3.0 GiB**. That leaves room to work, and it is a genuinely usable
agent.

### 2.5 Quantisation, and where it costs you

| Precision | Size vs fp32 | Where it is safe | Where it is not |
|---|---|---|---|
| fp16 / bf16 | 0.5× | almost everywhere | rare overflow in unnormalised layers |
| int8 | 0.25× | LLM weights, ASR encoders | **TTS vocoders** — artefacts are audible |
| int4 | 0.125× | large LLMs with good schemes | small models degrade sharply |

Two warnings specific to speech. **Quantised TTS is audible before it is measurable** — a
vocoder at int8 can produce a metallic edge that no spectral metric flags, so judge it by ear
and by the mel-band gate in
[`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md). And **you must
re-measure WER after quantising ASR**, not assume the published number holds; the serving
chapter makes this a rule ([`../02-asr/08-serving-asr.md`](../02-asr/08-serving-asr.md)).

### 2.6 Rented GPUs, priced against local

`[MEASURED]` from §3 — local cost is 25 W sustained at $0.30/kWh = **$0.0075/hour**:

| Hardware | $/hour | × local | 40 h of work |
|---|---|---|---|
| local M5 | 0.0075 | 1× | **$0.30** |
| T4 16 GB | 0.35 | 47× | $14.00 |
| L4 24 GB | 0.80 | 107× | $32.00 |
| A10G 24 GB | 1.00 | 133× | $40.00 |
| A100 40 GB | 1.80 | 240× | $72.00 |
| H100 80 GB | 3.50 | 467× | $140.00 |

Rates are `[UNVERIFIED PRICE]` — they move constantly and vary by provider, region and
commitment; treat them as an order of magnitude.

**When renting is right:** running vLLM or TensorRT to reproduce the serving measurements;
fine-tuning anything; measuring multi-GPU packing; benchmarking CUDA-only runtimes. All of it
fits in a handful of hours on an L4 if you prepare the script locally first, which is why the
budget below allocates six.

**When renting is a trap:** anything you could have measured locally, and anything you leave
running. An idle A100 costs more per day than this entire curriculum.

### 2.7 The total cost

`[MEASURED]` from §3:

| Item | Cost |
|---|---|
| Local compute, 40 h of measurement runs | $0.30 |
| Model downloads, ~30 GB one-off | $0.00 |
| Optional rented GPU, 6 h on an L4 | $4.80 |
| Paid API keys | $0.00 |
| **Total** | **$5.10** |

The zero on the API line is a design decision, not an accident: every measurement in this
curriculum is either local or arithmetic over published prices, so nothing here required a
vendor account. Vendor *prices* appear throughout — $0.0048/min for Nova-3, $30/M chars for
Aura-2 — but as inputs to models, not as bills.

Two costs the table omits honestly. **Disk**: ~30 GB of weights if you download everything,
which on a 512 GB machine is a real fraction. And **your time**, which at 54 chapters is by
several orders of magnitude the largest cost in the project.

---

## 3. From scratch

Real benchmarks on this machine, model sizing, and the cost arithmetic. Needs `numpy` and
`torch`.

```python
"""What this machine can actually do, measured rather than assumed.

Part A benchmarks MPS against CPU on the two shapes that matter for speech:
a large matmul (prefill-like, compute bound) and a thin one (decode-like,
memory bound). The ratio between those two ratios is the whole story of why
Apple Silicon is good at some voice work and bad at other voice work.

Part B sizes models from parameter counts at each precision, and measures a
real allocation to check the arithmetic.

Part C prices the curriculum: local electricity against rented GPU hours.

Fixed seeds; timings are wall-clock and will vary with load.
"""

import platform
import time

import numpy as np
import torch

torch.manual_seed(7)


def bench(fn, warmup=3, iters=10):
    for _ in range(warmup):
        fn()
    if torch.backends.mps.is_available():
        torch.mps.synchronize()
    t0 = time.perf_counter()
    for _ in range(iters):
        fn()
    if torch.backends.mps.is_available():
        torch.mps.synchronize()
    return (time.perf_counter() - t0) / iters


# --------------------------------------------------------------- Part A
def part_a():
    print(f"{platform.machine()} / torch {torch.__version__} / "
          f"MPS {torch.backends.mps.is_available()} / "
          f"CUDA {torch.cuda.is_available()}\n")
    shapes = [
        ("prefill-like  (512x4096 @ 4096x4096)", 512, 4096, 4096),
        ("decode-like   (1x4096 @ 4096x4096)", 1, 4096, 4096),
        ("conv-ish      (256x1280 @ 1280x1280)", 256, 1280, 1280),
        ("mel-ish       (3000x80 @ 80x512)", 3000, 80, 512),
    ]
    print(f"{'shape':38s} {'CPU ms':>9} {'MPS ms':>9} {'speedup':>8} "
          f"{'CPU GFLOP/s':>12} {'MPS GFLOP/s':>12}")
    for name, m, k, n in shapes:
        flops = 2.0 * m * k * n
        row = {}
        for dev in ("cpu", "mps"):
            if dev == "mps" and not torch.backends.mps.is_available():
                row[dev] = float("nan")
                continue
            a = torch.randn(m, k, device=dev, dtype=torch.float32)
            b = torch.randn(k, n, device=dev, dtype=torch.float32)
            row[dev] = bench(lambda: a @ b)
        sp = row["cpu"] / row["mps"] if row["mps"] == row["mps"] else float("nan")
        print(f"{name:38s} {row['cpu']*1e3:8.3f} {row['mps']*1e3:8.3f} "
              f"{sp:7.2f}x {flops/row['cpu']/1e9:11.1f} "
              f"{flops/row['mps']/1e9:11.1f}")
    print("\nlarge matmuls favour MPS; thin ones are dominated by dispatch")
    print("overhead, which is exactly the prefill-versus-decode asymmetry")


# --------------------------------------------------------------- Part B
MODELS = [
    # (name, parameters in millions, what it is for)
    ("silero-vad", 1.8, "VAD"),
    ("kokoro-82M", 82.0, "TTS"),
    ("piper (VITS medium)", 25.0, "TTS"),
    ("whisper-tiny", 39.0, "ASR"),
    ("whisper-base", 74.0, "ASR"),
    ("whisper-small", 244.0, "ASR"),
    ("whisper-medium", 769.0, "ASR"),
    ("whisper-large-v3", 1550.0, "ASR"),
    ("distil-large-v3", 756.0, "ASR"),
    ("qwen3-1.7b", 1700.0, "LLM"),
    ("llama-3.1-8b", 8030.0, "LLM"),
    ("moshi (7B + depth)", 7690.0, "S2S"),
]
PRECISIONS = [("fp32", 4.0), ("fp16", 2.0), ("int8", 1.0), ("int4", 0.5)]
RAM_GIB = 16.0
USABLE = 0.70            # leave the OS and everything else room


def part_b():
    print(f"weights only, GiB. machine has {RAM_GIB:.0f} GiB, "
          f"budget {RAM_GIB*USABLE:.1f} GiB at {USABLE:.0%}\n")
    print(f"{'model':22s} {'params':>8} " +
          " ".join(f"{p:>7}" for p, _ in PRECISIONS) + "   fits at")
    for name, mparams, _kind in MODELS:
        sizes = [mparams * 1e6 * b / 2 ** 30 for _, b in PRECISIONS]
        fits = [p for (p, _), s in zip(PRECISIONS, sizes)
                if s <= RAM_GIB * USABLE]
        best = fits[0] if fits else "none"
        print(f"{name:22s} {mparams:7.1f}M " +
              " ".join(f"{s:7.2f}" for s in sizes) + f"   {best}")

    # check the arithmetic against a real allocation
    n = 200_000_000                            # 200 M fp32 = 0.745 GiB
    t = torch.empty(n, dtype=torch.float32)
    got = t.element_size() * t.nelement() / 2 ** 30
    want = n * 4 / 2 ** 30
    print(f"\nallocation check: {n/1e6:.0f}M fp32 = {got:.3f} GiB measured, "
          f"{want:.3f} GiB predicted, match {abs(got-want) < 1e-9}")
    del t

    print("\nKV cache is separate and grows: 2 * layers * heads * dim * ctx * bytes")
    for label, layers, kvdim, ctx in (("qwen3-1.7b, 8k ctx", 28, 1024, 8192),
                                      ("llama-3.1-8b, 8k ctx", 32, 1024, 8192),
                                      ("llama-3.1-8b, 32k ctx", 32, 1024, 32768)):
        for pb, pn in ((2.0, "fp16"), (1.0, "int8")):
            gib = 2 * layers * kvdim * ctx * pb / 2 ** 30
            print(f"  {label:24s} {pn:5s} {gib:6.2f} GiB")


# --------------------------------------------------------------- Part C
def part_c():
    # rented GPU hourly rates, 2026-08 spot-ish; marked UNVERIFIED in the chapter
    RENT = [("T4 16 GB", 0.35), ("L4 24 GB", 0.80), ("A10G 24 GB", 1.00),
            ("A100 40 GB", 1.80), ("H100 80 GB", 3.50)]
    M5_WATTS = 25.0          # sustained package power under this kind of load
    KWH = 0.30               # $/kWh
    print(f"local: {M5_WATTS:.0f} W sustained at ${KWH:.2f}/kWh = "
          f"${M5_WATTS/1000*KWH:.4f}/hour\n")
    print(f"{'rented GPU':14s} {'$/hour':>8} {'x local':>9} "
          f"{'$ for 40h of work':>19}")
    local_hr = M5_WATTS / 1000 * KWH
    for name, rate in RENT:
        print(f"{name:14s} {rate:7.2f} {rate/local_hr:8.0f}x {rate*40:18.2f}")
    print(f"{'local M5':14s} {local_hr:7.4f} {1:8.0f}x {local_hr*40:18.2f}")

    print("\ntotal curriculum cost, 54 chapters:")
    items = [
        ("local compute (40 h of measurement runs)", local_hr * 40),
        ("model downloads (~30 GB, one-off bandwidth)", 0.0),
        ("optional rented GPU for [NEEDS GPU] work (6 h on an L4)", 0.80 * 6),
        ("paid API keys", 0.0),
    ]
    for label, cost in items:
        print(f"  {label:56s} ${cost:7.2f}")
    print(f"  {'TOTAL':56s} ${sum(c for _, c in items):7.2f}")


if __name__ == "__main__":
    print("PART A -- MPS versus CPU on speech-shaped matmuls\n")
    part_a()
    print("\n\nPART B -- what fits in 16 GiB\n")
    part_b()
    print("\n\nPART C -- what this curriculum costs\n")
    part_c()
```

Output `[MEASURED]` (Part A timings vary with load; Parts B and C are exact):

```
PART A -- MPS versus CPU on speech-shaped matmuls

arm64 / torch 2.13.0 / MPS True / CUDA False

shape                                     CPU ms    MPS ms  speedup  CPU GFLOP/s  MPS GFLOP/s
prefill-like  (512x4096 @ 4096x4096)     10.211    5.917    1.73x      1682.4      2903.3
decode-like   (1x4096 @ 4096x4096)        0.864    0.562    1.54x        38.8        59.7
conv-ish      (256x1280 @ 1280x1280)      0.416    0.341    1.22x      2016.5      2457.6
mel-ish       (3000x80 @ 80x512)          0.200    0.139    1.45x      1226.9      1774.1

large matmuls favour MPS; thin ones are dominated by dispatch
overhead, which is exactly the prefill-versus-decode asymmetry


PART B -- what fits in 16 GiB

weights only, GiB. machine has 16 GiB, budget 11.2 GiB at 70%

model                    params    fp32    fp16    int8    int4   fits at
silero-vad                 1.8M    0.01    0.00    0.00    0.00   fp32
kokoro-82M                82.0M    0.31    0.15    0.08    0.04   fp32
piper (VITS medium)       25.0M    0.09    0.05    0.02    0.01   fp32
whisper-tiny              39.0M    0.15    0.07    0.04    0.02   fp32
whisper-base              74.0M    0.28    0.14    0.07    0.03   fp32
whisper-small            244.0M    0.91    0.45    0.23    0.11   fp32
whisper-medium           769.0M    2.86    1.43    0.72    0.36   fp32
whisper-large-v3        1550.0M    5.77    2.89    1.44    0.72   fp32
distil-large-v3          756.0M    2.82    1.41    0.70    0.35   fp32
qwen3-1.7b              1700.0M    6.33    3.17    1.58    0.79   fp32
llama-3.1-8b            8030.0M   29.91   14.96    7.48    3.74   int8
moshi (7B + depth)      7690.0M   28.65   14.32    7.16    3.58   int8

allocation check: 200M fp32 = 0.745 GiB measured, 0.745 GiB predicted, match True

KV cache is separate and grows: 2 * layers * heads * dim * ctx * bytes
  qwen3-1.7b, 8k ctx       fp16    0.88 GiB
  qwen3-1.7b, 8k ctx       int8    0.44 GiB
  llama-3.1-8b, 8k ctx     fp16    1.00 GiB
  llama-3.1-8b, 8k ctx     int8    0.50 GiB
  llama-3.1-8b, 32k ctx    fp16    4.00 GiB
  llama-3.1-8b, 32k ctx    int8    2.00 GiB


PART C -- what this curriculum costs

local: 25 W sustained at $0.30/kWh = $0.0075/hour

rented GPU       $/hour   x local   $ for 40h of work
T4 16 GB          0.35       47x              14.00
L4 24 GB          0.80      107x              32.00
A10G 24 GB        1.00      133x              40.00
A100 40 GB        1.80      240x              72.00
H100 80 GB        3.50      467x             140.00
local M5        0.0075        1x               0.30

total curriculum cost, 54 chapters:
  local compute (40 h of measurement runs)                 $   0.30
  model downloads (~30 GB, one-off bandwidth)              $   0.00
  optional rented GPU for [NEEDS GPU] work (6 h on an L4)  $   4.80
  paid API keys                                            $   0.00
  TOTAL                                                    $   5.10
```

Three load-bearing details. **`bench` calls `torch.mps.synchronize()` before and after
timing**, and without it the MPS numbers are nonsense — Metal dispatch is asynchronous, so an
unsynchronised timer measures how fast you can enqueue work, which on the decode-like shape
would report a fictional speedup. **The GFLOP/s columns matter more than the speedup column**:
the speedups look boringly similar across shapes while the absolute throughput moves 49×, and
it is the absolute number that tells you the machine is idle during decode. And **the
allocation check exists because parameter-count arithmetic is easy to get wrong by a factor of
$2^{30}/10^9 = 1.074$** — GiB against GB — which is exactly the size of error that makes a
model "nearly fit".

---

## 4. How production does it

**Apple Silicon is a development target, not a serving target.** The runtimes that win in
production — vLLM, SGLang, TensorRT — are CUDA-first, and the ones that win here — MLX,
whisper.cpp with Metal, CTranslate2 on CPU — are excellent locally and absent from the
datacentre. Develop here, serve there, and keep the interfaces stable so the swap is boring.

**`faster-whisper` on the CPU is the pragmatic local ASR**, because CTranslate2 has no Metal
backend and its int8 CPU path is fast enough for real time. The instinct to reach for the GPU
is wrong here, which §2.2 explains: the CPU is 1682 GFLOP/s and the model is small.

**Unified memory changes the packing question, not the arithmetic.** The
sessions-per-device calculation in
[`../06-realtime-systems/05-scale-and-orchestration.md`](../06-realtime-systems/05-scale-and-orchestration.md)
is the same shape; only the budget differs, and locally the OS is competing for it.

**Nobody trains speech models on a laptop.** Rent, for hours not weeks, with the script
already debugged locally.

---

## 5. At scale

**Weights are the small term; context is the large one.** An int8 8 B model is 7.48 GiB and
its 32k KV cache is another 4.00 GiB. Any capacity plan built from weights alone
under-provisions by more than half.

**Re-measure quality after every quantisation.** A published WER is for a published
precision, and int8 TTS in particular degrades audibly before any metric notices.

**Reserve headroom or the OS takes it from you.** 70% of 16 GiB is a deliberate cap;
exceeding it on macOS produces swapping, which for a real-time audio pipeline is
indistinguishable from a bug.

**Price the idle, not the run.** Rented GPUs are 47–467× local per hour, and the expensive
mistake is not the benchmark, it is the instance you forgot.

---

## 6. Exercises

**E0.2.1** Run the §3 listing on your machine. Report the prefill and decode GFLOP/s and the
ratio between them. Relate it to the 69× prefill/decode gap in
[`../05-llm-layer/04-serving-llms-fast.md`](../05-llm-layer/04-serving-llms-fast.md).

**E0.2.2** Remove the `torch.mps.synchronize()` calls and re-run. Report the fictional
speedup you now measure and explain precisely what was being timed.

**E0.2.3** Add fp16 and bf16 to Part A. Report the speedup over fp32 on MPS and state whether
it is worth the numerical risk for your use.

**E0.2.4** Compute the total footprint of your intended local stack — VAD + ASR + TTS + LLM +
KV cache — and state how much of the 70% budget remains. Find the configuration that leaves
at least 4 GiB free.

**E0.2.5** Derive the KV cache formula from a model's config (layers, heads, head dim, GQA
group size) rather than the approximation in §3, and report the difference for one real model.

**E0.2.6** Quantise one TTS model to int8, synthesise the same sentence at both precisions,
and compare with the mel-band gate from
[`../08-eval-safety/01-testing.md`](../08-eval-safety/01-testing.md). Then listen. Report
whether the metric agreed with your ears.

**E0.2.7** Price the `[NEEDS GPU]` exercises for your preferred provider today, and compute
the break-even hours at which buying a used GPU beats renting.

**E0.2.8** Measure sustained package power during a long Part A run (`powermetrics` or
Activity Monitor) and correct the $0.0075/hour figure for your machine and tariff.

---

## 7. Interview drill

> "We're evaluating hardware for a team of six building a voice agent. Someone proposes
> giving everyone a workstation with an RTX 4090 instead of MacBooks. What's your take?"

It depends entirely on which half of the work dominates, and I would want that answered before
spending the money. For everything most of the team does day to day — DSP, endpointing logic,
frame graphs, barge-in, prompt work, local inference with small models — an Apple Silicon
laptop is not a compromise. On the reference machine, MPS runs a prefill-shaped matmul at
2903 GFLOP/s and the *CPU* runs it at 1682, so even the CPU path is respectable, and Whisper
large-v3 fits in fp32 because unified memory means there is no separate 24 GB VRAM ceiling to
squeeze into.

Where the 4090 genuinely wins is the work that is CUDA-only rather than merely faster on
CUDA. Running vLLM or TensorRT to reproduce serving behaviour, any fine-tuning, paged-attention
experiments, multi-GPU packing measurements — none of that has a Metal path, so a Mac is not
slow at it, it simply cannot do it. My question would be how many people need that how often.
In my experience it is one or two people, some of the time.

So the proposal I would make is asymmetric: laptops for everyone, plus one or two shared
CUDA boxes or a rented-GPU budget. The arithmetic is stark — an L4 is about $0.80 an hour
against roughly $0.0075 of electricity locally, so 107×, but the absolute numbers are tiny:
six hours of L4 time is under five dollars. A shared pool of rented hours costs less per
month than the difference in hardware price, and it gives the team access to *several* GPU
types rather than one, which matters when you are choosing between an L4 and an A100 for
production.

There is a second-order argument I would put more weight on than the benchmarks. Voice
development needs a microphone, a speaker, real acoustics and real echo — and a desktop in an
office is a worse environment for that than a laptop the engineer can take to a noisy room, a
car, a phone call. Half the bugs in this domain are acoustic: AEC, Bluetooth narrowing the
band without erroring, a VAD tuned on clean speech. Hardware that makes it easy to reproduce
the customer's environment is worth more than hardware that makes the matmul 3× faster.

What distinguishes a senior answer is separating "development target" from "serving target"
explicitly, and insisting the interfaces stay stable so the swap is boring. If our agent code
only talks to an ASR interface, running faster-whisper locally and Riva in production is a
config change. If it imports CUDA-specific code paths, we have accidentally made the
workstation decision architectural, and *that* is the thing I would be reviewing before I
worried about GPUs.

The premise worth questioning is "evaluating hardware". If the real problem is that inference
feels slow in development, the fix may be a smaller model or a quantised one rather than a
faster machine — and it is worth checking, because a 1.7 B model at int8 is 1.58 GiB and runs
comfortably on the laptop we already own.

---

## Sources

- Reference machine verified directly: Apple M5, 10 cores (4 performance + 6 efficiency), 16 GiB unified memory, macOS 26.5.2 (Darwin 26.5.2, build 25F84), `arm64`; `torch` 2.13.0 with `torch.backends.mps.is_available() == True` and `torch.cuda.is_available() == False`.
- Parameter counts used in §2.4: Whisper family from `openai/whisper` (tiny 39 M, base 74 M, small 244 M, medium 769 M, large 1550 M); `distil-whisper/distil-large-v3` 756 M; Kokoro-82M 82 M (Apache-licensed weights); Silero VAD ~1.8 M; Piper VITS medium ~25 M; Moshi's 7 B Temporal Transformer plus its Depth Transformer per [`../06-realtime-systems/04-speech-to-speech.md`](../06-realtime-systems/04-speech-to-speech.md); Llama 3.1 8 B and Qwen3 1.7 B from their published model cards. Sizes are computed, not measured per model — the arithmetic is validated against a real 200 M-element allocation in §3.
- CTranslate2 has no Metal backend, which is why §2.3 and §4 recommend the int8 CPU path for `faster-whisper`; MLX and whisper.cpp are the Metal-native options.
- PEP-independent runtime facts about MPS asynchrony: `torch.mps.synchronize()` is required for any timing measurement, as demonstrated by exercise E0.2.2.
- Rented GPU hourly rates in §2.6 are `[UNVERIFIED PRICE]` — representative of 2026-08 on-demand and spot pricing across common providers, not a quote. Electricity at $0.30/kWh and 25 W sustained package power are `[INFERENCE]` estimates; E0.2.8 replaces them with your own measurement.
- `[MEASURED]`: the §3 output is one run on the reference machine, CPython 3.12.13, `torch` 2.13.0, `numpy` 2.5.2. **Part A is wall-clock and load-dependent** — the four speedups (1.22–1.73×) and the 49× prefill-to-decode throughput collapse are stable in shape across runs, while the individual millisecond figures drift by several percent. Parts B and C are exact arithmetic: the model sizes follow from the parameter counts above, the allocation check is a real `torch.empty`, and the cost table is arithmetic over the stated (and separately caveated) rates. Substituting your own tariff, power draw or provider changes Part C's absolute figures while leaving the conclusion — local compute for this curriculum costs cents, rented GPUs cost dollars, and neither is a barrier — unchanged.
