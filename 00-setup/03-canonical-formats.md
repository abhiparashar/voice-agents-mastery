# Canonical Formats: the contract every module obeys

**What you'll be able to do after this**
State, from memory, the exact byte layout of one frame of curriculum audio and defend every
number in it. Convert losslessly between every representation the stack uses, and name which
conversions are lossy and by how many dB. Read a WAV header with a hex dump and no library.
Explain to a colleague why 8 kHz telephony deletes `/s/` and what your ASR must do about it.

---

## 1. Intuition

A voice pipeline is a chain of eight or nine components written by eight or nine different
groups of people: a browser's `AudioWorklet`, an SFU, a resampler, a VAD, an ASR encoder, an
LLM, a TTS vocoder, a jitter buffer, a speaker. Each one has an opinion about sample rate,
sample type, channel count, endianness, and chunk size.

Every place where two opinions meet is a place where a bug hides. Not an exciting bug — a
boring, expensive one: audio that is silently 2× too fast because someone treated 16 kHz data
as 8 kHz; a VAD that never fires because it was handed float32 in a buffer typed int16 (every
sample rounds to 0); 30 ms of latency added by a resampler that nobody knew was in the path;
clicks every 320 samples because a frame boundary got a discontinuity.

The fix is not cleverness. It is a **contract**: one format, declared once, obeyed everywhere,
with conversions permitted *only* at named edges. This chapter is that contract, plus the
derivation of every constant in it, because a contract you cannot derive is a contract you
will violate under pressure.

```
                internal pipeline: 16 kHz mono s16le, 20 ms frames
   ┌──────────┐                                                    ┌──────────┐
   │ 48 kHz   │  resample                                resample  │ 48 kHz   │
   │ Opus     │───────────▶  VAD ▶ ASR ▶ LLM ▶ TTS  ───────────────▶│ Opus     │
   │ (WebRTC) │                                                    │ (WebRTC) │
   └──────────┘                                                    └──────────┘
   ┌──────────┐  µ-law decode + upsample          downsample + µ-law encode
   │ 8 kHz    │───────────▶                                ───────────▶┌──────┐
   │ G.711    │                                                        │ SIP  │
   └──────────┘                                                        └──────┘
```

Two edges. Two conversions in, two out. Anything else is a bug.

### The contract, in one table

| Property | Value | Rationale (derived in §2) |
|---|---|---|
| Sample rate | 16 000 Hz | Nyquist 8 kHz covers the sibilant band; matches every open ASR model |
| Channels | 1 (mono) | Speech is one talker; stereo doubles cost for no ASR gain |
| Sample type on the wire | signed 16-bit **little-endian** (`s16le`) | 98 dB SQNR — 30 dB below any microphone's noise floor is wasted |
| Sample type at model boundary | `np.float32` in $[-1, 1)$ | What PyTorch/ONNX kernels want; scale factor exactly $2^{15}$ |
| Frame duration | 20 ms | Opus's recommended frame; 40 % RTP header overhead; 20 ms endpointing resolution |
| Frame samples | 320 | $16000 \times 0.020$ |
| Frame bytes | 640 | $320 \times 2$ |
| Byte rate | 32 000 B/s = 256 kbit/s | $16000 \times 2$ |
| WebRTC / browser edge | 48 000 Hz Opus | Opus's native internal rate; what `getUserMedia` gives you |
| Telephony / SIP edge | 8 000 Hz µ-law (G.711 PT 0) | The PSTN, unchanged since 1972 |
| Timestamps | monotonic float seconds, `time.monotonic()` | Wall clock jumps; NTP steps; monotonic does not |

---

## 2. Rigour

### 2.1 Why 16 kHz and not 8, 22.05, or 48

**The sampling theorem gives the floor.** A signal band-limited to $f_{\max}$ is perfectly
reconstructible from samples taken at $f_s > 2 f_{\max}$. Inverted: a sample rate $f_s$ can
represent content up to the Nyquist frequency $f_s/2$, and everything above it *folds* down —
a component at $f$ appears at $|f - k f_s|$ for the integer $k$ minimising that distance.
Folding is measured, not asserted, in §3.

**Speech is not band-limited at 4 kHz.** Decompose it:

| Component | Frequency range | Carried by 8 kHz sampling (4 kHz Nyquist)? |
|---|---|---|
| Fundamental $F_0$ (pitch) | 85–180 Hz (male), 165–255 Hz (female) | yes |
| $F_1, F_2$ — vowel identity | 250–2500 Hz | yes |
| $F_3$ — /r/ vs /l/, speaker identity | 1700–3500 Hz | mostly |
| $F_4$, nasal zeros | 3000–4500 Hz | partially |
| Sibilant fricative noise `/s/ /z/ /ʃ/ /ʒ/` | primary spectral peak ≈ 4–5 kHz for `/s, z/`; energy to 10 kHz+ | **no** |
| Non-sibilant fricatives `/f/ /θ/` | flat, diffuse, 1–10 kHz, low amplitude | **no** |
| Stop bursts `/t/ /k/` transients | broadband, 2–8 kHz | **partially** |

Jongman, Wayland & Wong (2000), *JASA* 108(3):1252–1263, is the standard reference: `/s, z/`
are produced with a short anterior cavity and therefore show their primary spectral peak
"around 4 to 5 kHz". Spectral centre-of-gravity measurements for English `/s/` land near
6.1 kHz (Li, Edwards & Beckman, ICPhS 2007).

**Quantify the damage.** Model sibilant frication as a noise band with flat spectral density
over $[f_{lo}, f_{hi}] = [3.5, 10]$ kHz — an illustrative model, not a measurement. The
fraction of energy surviving a brickwall lowpass at $f_c$ is

$$\eta(f_c) = \frac{\max(0,\ \min(f_c, f_{hi}) - f_{lo})}{f_{hi} - f_{lo}}$$

- $f_c = 8$ kHz (16 kHz sampling): $\eta = 4.5/6.5 = 0.69 = -1.6$ dB. Nearly all of it.
- $f_c = 4$ kHz (8 kHz sampling): $\eta = 0.5/6.5 = 0.077 = -11.1$ dB. Eight percent.
- G.711's actual passband, 300–3400 Hz: $\eta = 0$. **All** of it is gone.

That last line is the one that matters, and it is why telephony ASR is a different problem
rather than a slightly harder one. On a PSTN call the recogniser cannot see `/s/` at all. It
must infer sibilants from what remains: frication *duration*, the amplitude notch, the
coarticulated formant transitions in the adjacent vowel, and — mostly — the language model.
This is precisely why plurals, `/s/`-final verbs, and spelled-out identifiers ("F as in
Frank") are where narrowband agents fail. See `../07-livekit/05-telephony-sip.md`.

**Why not go higher?** Three reasons, in order of force.

1. **The models are 16 kHz.** Whisper's front end is fixed at 16 kHz — `ggml-org/whisper.cpp
   include/whisper.h` defines `WHISPER_SAMPLE_RATE 16000`, `WHISPER_N_FFT 400` (25 ms window),
   `WHISPER_HOP_LENGTH 160` (10 ms hop), `WHISPER_CHUNK_SIZE 30` (s). `faster-whisper`'s
   `faster_whisper/audio.py:decode_audio` defaults `sampling_rate=16000` and resamples with
   PyAV. Silero VAD accepts 8 kHz or 16 kHz and nothing else. Feeding a 16 kHz model 48 kHz
   audio does not improve it; it breaks it.
2. **Cost is linear in samples.** Tripling the rate triples the STFT work and, for
   convolutional front ends, the tokens per second the encoder must chew.
3. **Diminishing phonetic return.** Above 8 kHz there is speaker-identity and "air" quality
   information, which matters for *synthesis* (TTS output is commonly 22.05 or 24 kHz) but
   almost nothing for *recognition*.

Note the asymmetry: **ASR wants 16 kHz, TTS wants more.** Kokoro outputs 24 kHz; Piper models
are 16 or 22.05 kHz. So the TTS→transport edge involves an upsample to 48 kHz for WebRTC or a
downsample to 8 kHz for SIP. Budget for it (`../01-foundations/04-latency-budget.md`).

### 2.2 Why 20 ms frames

RFC 6716 §2.1.4: "Opus can encode frames of 2.5, 5, 10, 20, 40, or 60 ms. It can also combine
multiple frames into packets of up to 120 ms." And, decisively: "the gain becomes small for
frame sizes above 20 ms. For this reason, 20 ms frames are a good choice for most
applications." WebRTC's default `ptime` is 20 ms. Choosing 20 ms internally means the frame
boundary in your pipeline coincides with the packet boundary on the wire — no re-framing, no
partial frames straddling packets.

**The tradeoff is packet overhead against latency.** Each RTP packet costs 40 bytes of header
on IPv4 (IP 20 + UDP 8 + RTP 12; 60 bytes on IPv6), regardless of payload. At an Opus bitrate
of 24 kbit/s:

| frame ms | samples @16k | int16 B | packets/s | Opus payload B | header share | wire kbit/s | added one-way latency |
|---|---|---|---|---|---|---|---|
| 2.5 | 40 | 80 | 400 | 7.5 | 84 % | 152.0 | 2.5 ms |
| 5 | 80 | 160 | 200 | 15 | 73 % | 88.0 | 5 ms |
| 10 | 160 | 320 | 100 | 30 | 57 % | 56.0 | 10 ms |
| **20** | **320** | **640** | **50** | **60** | **40 %** | **40.0** | **20 ms** |
| 40 | 640 | 1280 | 25 | 120 | 25 % | 32.0 | 40 ms |
| 60 | 960 | 1920 | 16.7 | 180 | 18 % | 29.3 | 60 ms |
| 120 (repacketised) | 1920 | 3840 | 8.3 | 360 | 10 % | 26.7 | 120 ms |

Header share is $40/(40 + \text{payload})$; wire rate is $(\text{payload} + 40) \times
\text{pps} \times 8 / 1000$. Going from 20 ms to 10 ms buys you 10 ms of latency for +40 %
wire bandwidth and 2× the packet rate (which is what actually hurts an SFU — packets per
second, not bytes per second, is the SFU's scaling variable). Going from 20 ms to 40 ms saves
20 % bandwidth and costs 20 ms of a ~300 ms budget, plus doubles the audio lost per dropped
packet. 20 ms is the knee.

**Frame size is also your control-loop resolution.** Every timing decision in turn-taking is
quantised to the frame:

- A 500 ms end-of-utterance silence timer is 25 frames. The decision jitter is ±1 frame =
  ±20 ms, i.e. ±2 % of a 1 s response budget. At 60 ms frames it becomes ±6 %.
- Barge-in detection cannot fire faster than one frame after the speech onset that triggers
  it. 20 ms is well under human perceptual thresholds for turn-taking; 60 ms starts to be
  noticeable when stacked with everything else.

**Frames do not always divide evenly, and you must not pretend they do.** Silero VAD is the
canonical example: `snakers4/silero-vad src/silero_vad/utils_vad.py:OnnxWrapper.__call__`
raises unless the input window is exactly **512 samples at 16 kHz** (or 256 at 8 kHz) — that
is 32 ms, which is not a multiple of 320. So:

$$\mathrm{lcm}(320, 512) = 2560 \text{ samples} = 160 \text{ ms}$$

The 320-in / 512-out pattern repeats only every 160 ms. Consequence: the VAD needs its own
re-framing buffer, and its decisions arrive on a 32 ms grid offset from your 20 ms grid. Any
"speech started at frame N" bookkeeping must convert through *sample indices*, never frame
counts. Detail lives in `../03-turn-taking/01-vad.md`.

### 2.3 int16 vs float32 on the wire

**Signal-to-quantisation-noise ratio.** Uniform quantisation with $b$ bits over a full-scale
range, driven by a full-scale sinusoid, gives

$$\mathrm{SQNR} = 6.02\,b + 1.76 \ \text{dB}$$

So int16 delivers **98.1 dB** and 8-bit linear PCM delivers 49.9 dB. Now compare against the
analogue chain: a good consumer MEMS microphone has an equivalent-input-noise floor giving
roughly 60–70 dB of usable dynamic range, and a room with an HVAC system contributes far more
noise than that. `[INFERENCE]` — the exact figure depends on the capsule, but the direction is
not in doubt: **int16 already quantises 30 dB below the noise floor of the signal you actually
have.** float32 adds 24-bit mantissa precision to a signal whose lowest meaningful bit is
around bit 10.

**What float32 costs.** `[MEASURED]` on the arithmetic:

| Representation | bits/sample | bytes/s @16 kHz mono | kbit/s | bytes per 20 ms frame |
|---|---|---|---|---|
| µ-law (G.711 at 16 kHz) | 8 | 16 000 | 128.0 | 320 |
| **int16 (the contract)** | **16** | **32 000** | **256.0** | **640** |
| float32 | 32 | 64 000 | 512.0 | 1280 |

Doubling per-stream bytes doubles socket buffers, doubles ring-buffer RAM, doubles memcpy
cost, doubles the pressure on every queue. At 1000 concurrent streams that is 32 MB/s versus
64 MB/s of pure copying — before any model runs. For zero perceptual gain.

**So: int16 on the wire, float32 only at the model boundary.** The conversion is a single
multiply and it belongs immediately before `model(x)`, not three layers earlier.

**The scale factor is $2^{15} = 32768$, not 32767.** int16 spans $[-32768, 32767]$ —
asymmetric, because two's complement has one more negative code than positive. Dividing by
32768 maps every code into $[-1, 1)$ exactly and is exactly invertible for all $2^{16}$ codes.
Dividing by 32767 maps $-32768 \mapsto -1.0000305$, outside the range every model documents,
and is not exactly invertible.

**Clip before you cast, always.** `numpy` casts float→int16 by truncating modulo $2^{16}$, so
a float of $1.9$ becomes $-3277$: a sign flip at full amplitude, which is a click or, over a
burst, a sound like tearing paper. `[MEASURED]` in §3: `to_int16(np.float32([1.9, -1.9]))`
returns `[32767, -32768]` with the clip, and `[-3277, 3277]` without it.

**dBFS.** Level in decibels relative to full scale is $20 \log_{10}(|x| / x_{\text{FS}})$.
Two conventions bite people:
- **Peak dBFS** uses $\max|x|$; **RMS dBFS** uses $\sqrt{\overline{x^2}}$.
- A full-scale *sine* has RMS $1/\sqrt2$, i.e. **−3.01 dBFS RMS** and 0 dBFS peak. Only a
  full-scale square wave reads 0 dBFS RMS. `[MEASURED]` in §3.

Speech gates and AGC thresholds are RMS; clipping detectors are peak. Confusing them gives you
a VAD that fires on breath or an AGC that never engages.

### 2.4 Endianness

`s16le` means the low-order byte first. Sample $-2$ is `FE FF`, not `FF FE`.

| Container / protocol | Byte order | Note |
|---|---|---|
| RIFF/WAVE (`.wav`) | little-endian | `RIFX` is the big-endian variant; rare |
| AIFF (`.aiff`) | big-endian | Apple/SGI heritage |
| RTP payload type 11, `L16` | **big-endian** | RFC 3551 §4.5.11: "transmitted in network byte order (most significant byte first)" |
| Opus, µ-law, A-law in RTP | n/a | byte-oriented payloads; no endianness to get wrong |
| PortAudio / CoreAudio buffers | host order | little-endian on arm64 and x86-64 |

The `L16` row is the trap. If you ever transport raw PCM over RTP rather than Opus, you must
byte-swap. This is one more reason the contract says "convert only at named edges": there is
exactly one place to put the swap.

In numpy, spell the dtype explicitly — `"<i2"` — never `np.int16` when the bytes are going
somewhere. `np.int16` means *host* order, which is correct today on every machine you own and
wrong the day someone runs your code on an s390x container in CI.

### 2.5 WAV / RIFF, field by field

A canonical 44-byte mono PCM16 header. All integers little-endian; all four-character chunk
IDs are ASCII and are *not* byte-swapped.

| Offset | Size | Field | Value for our contract | Meaning |
|---|---|---|---|---|
| 0 | 4 | `ChunkID` | `"RIFF"` = `52 49 46 46` | container magic |
| 4 | 4 | `ChunkSize` | `36 + data_bytes` | file size minus 8 (the first two fields) |
| 8 | 4 | `Format` | `"WAVE"` | RIFF form type |
| 12 | 4 | `Subchunk1ID` | `"fmt "` (trailing space) | format chunk |
| 16 | 4 | `Subchunk1Size` | `16` | 16 for plain PCM; 18 or 40 for extensible |
| 20 | 2 | `AudioFormat` | `1` | 1 = PCM, 3 = IEEE float, 6 = A-law, 7 = µ-law, `0xFFFE` = extensible |
| 22 | 2 | `NumChannels` | `1` | |
| 24 | 4 | `SampleRate` | `16000` = `80 3E 00 00` | |
| 28 | 4 | `ByteRate` | `32000` = `00 7D 00 00` | $= \text{rate} \times \text{ch} \times \text{bits}/8$; redundant, must agree |
| 32 | 2 | `BlockAlign` | `2` | bytes per sample *frame* (all channels) |
| 34 | 2 | `BitsPerSample` | `16` | |
| 36 | 4 | `Subchunk2ID` | `"data"` | |
| 40 | 4 | `Subchunk2Size` | `data_bytes` | |
| 44 | … | samples | interleaved `s16le` | |

Header for 1600 samples (100 ms), `[MEASURED]` by generating it and comparing byte-for-byte
against Python's stdlib `wave` module — identical:

```
52494646 a40c0000 57415645 666d7420 10000000 01000100 803e0000 007d0000 02001000 64617461 800c0000
R I F F  <size>   W A V E  f m t ␠  <16>     PCM,1ch  16000    32000    2 ,  16  d a t a  <3200>
```

Five gotchas that cost real time:

1. **Chunk sizes are unsigned 32-bit.** WAV cannot exceed 4 GiB (≈37 hours of our format).
   Long recordings need RF64/W64 or a raw `.pcm` file plus a sidecar.
2. **Streaming writers cannot know the size.** Many write `0xFFFFFFFF` or `0`; some write a
   guess and never fix it. A parser must tolerate a `data` size that disagrees with the file
   length, and prefer the file length.
3. **`data` is not always at offset 44.** `LIST`/`INFO`, `fact`, `cue `, and PyAV/ffmpeg's own
   metadata chunks appear between `fmt ` and `data`. A parser that hardcodes 44 will
   eventually decode metadata as audio, which sounds like a burst of static.
4. **Chunks are word-aligned.** An odd-sized chunk is followed by one pad byte that is *not*
   counted in its size field. Forgetting `+ (size & 1)` desynchronises everything after it.
5. **`AudioFormat = 3`** means the samples are float32 in $[-1,1]$, not int16. ffmpeg produces
   these when you ask for `pcm_f32le`. Reading them as int16 gives near-silence, because a
   float32 in $[-1,1]$ reinterpreted as two int16s is dominated by exponent bits.

---

## 3. From scratch

One module, numpy plus stdlib only. Every number reported below is produced by running it.

```python
"""Canonical-format conversions: bytes <-> int16 <-> float32, rate changes, G.711."""
import struct
import numpy as np

SAMPLE_RATE   = 16_000
FRAME_MS      = 20
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000   # 320
FRAME_BYTES   = FRAME_SAMPLES * 2                # 640
INT16_SCALE   = 32768.0                          # 2**15: exact for every negative code

# ---- dtype / container -----------------------------------------------------
def unpack(b: bytes) -> np.ndarray:
    """s16le bytes -> np.int16 (zero-copy read-only view)."""
    return np.frombuffer(b, dtype="<i2")

def pack(x: np.ndarray) -> bytes:
    """np.int16, or float in [-1,1), -> s16le bytes."""
    return to_int16(x).astype("<i2", copy=False).tobytes()

def to_float32(x) -> np.ndarray:
    if isinstance(x, (bytes, bytearray, memoryview)):
        x = unpack(x)
    if x.dtype == np.float32:
        return x
    return x.astype(np.float32) / INT16_SCALE

def to_int16(x) -> np.ndarray:
    x = unpack(x) if isinstance(x, (bytes, bytearray, memoryview)) else np.asarray(x)
    if x.dtype == np.int16:
        return x
    # clip BEFORE the cast: numpy wraps on overflow, which sounds like a gunshot
    return (np.clip(x, -1.0, 32767.0 / INT16_SCALE) * INT16_SCALE).astype(np.int16)

def rms_dbfs(x) -> float:
    f = to_float32(x).astype(np.float64)
    r = float(np.sqrt((f * f).mean())) if f.size else 0.0
    return 20.0 * np.log10(r) if r > 0 else float("-inf")

# ---- framing ---------------------------------------------------------------
class Framer:
    """Re-chunk an arbitrary byte stream into fixed-size frames. Never reorders."""
    def __init__(self, frame_bytes: int = FRAME_BYTES):
        self.frame_bytes = frame_bytes
        self._buf = bytearray()

    def push(self, data: bytes) -> list[bytes]:
        self._buf += data
        out, n = [], self.frame_bytes
        while len(self._buf) >= n:
            out.append(bytes(self._buf[:n])); del self._buf[:n]
        return out

    def flush(self, pad: bool = True) -> list[bytes]:
        if not self._buf:
            return []
        tail = bytes(self._buf); self._buf.clear()
        if pad and len(tail) < self.frame_bytes:
            tail += b"\x00" * (self.frame_bytes - len(tail))
        return [tail]

# ---- rational resampling (polyphase windowed sinc) ------------------------
def _sinc_taps(up: int, down: int, half: int = 16, beta: float = 8.6) -> np.ndarray:
    """Kaiser-windowed sinc lowpass, cutoff at 1/max(up,down) of the interpolated rate."""
    m = max(up, down)
    n = 2 * half * m + 1
    t = np.arange(n) - (n - 1) / 2.0
    h = np.sinc(t / m) * np.kaiser(n, beta)
    return (h * up / h.sum()).astype(np.float64)

def resample(x: np.ndarray, in_rate: int, out_rate: int) -> np.ndarray:
    """Band-limited rational resample. Preserves int16-ness of the input."""
    if in_rate == out_rate:
        return x
    was_i16 = x.dtype == np.int16
    f = to_float32(x).astype(np.float64)
    g = np.gcd(in_rate, out_rate)
    up, down = out_rate // g, in_rate // g       # 48k<->16k: 1/3 or 3/1; 16k->8k: 1/2
    y = np.zeros(len(f) * up, dtype=np.float64)
    y[::up] = f                                  # zero-stuff, then filter the images away
    y = np.convolve(y, _sinc_taps(up, down), mode="same")[::down]
    return to_int16(y) if was_i16 else y.astype(np.float32)

# ---- G.711 mu-law (ITU-T G.711; bit-exact with the Sun/audioop reference) --
_BIAS = 0x84
_SEG_UEND = np.array([0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF], dtype=np.int32)

def mulaw_encode(pcm) -> np.ndarray:
    v = to_int16(pcm).astype(np.int32) >> 2      # 16-bit -> 14-bit, arithmetic (floor) shift
    mask = np.where(v < 0, 0x7F, 0xFF).astype(np.int32)
    v = np.abs(v) + (_BIAS >> 2)                 # +33; the bias linearises the first segment
    seg = np.searchsorted(_SEG_UEND, v, side="left").astype(np.int32)   # 0..8
    s = seg.clip(0, 7)
    code = (s << 4) | ((v >> (s + 1)) & 0x0F)    # 3-bit exponent, 4-bit mantissa
    return (np.where(seg >= 8, 0x7F, code) ^ mask).astype(np.uint8)    # seg==8 is the clip

def mulaw_decode(u) -> np.ndarray:
    v = (~np.asarray(u, dtype=np.uint8).astype(np.int32)) & 0xFF
    sign, exp, mant = v & 0x80, (v >> 4) & 0x07, v & 0x0F
    mag = (((mant << 3) + _BIAS) << exp) - _BIAS
    return np.where(sign != 0, -mag, mag).astype(np.int16)

# ---- WAV ------------------------------------------------------------------
def wav_header(n_samples: int, rate: int = SAMPLE_RATE, ch: int = 1, bits: int = 16) -> bytes:
    nbytes = n_samples * ch * bits // 8
    return (b"RIFF" + struct.pack("<I", 36 + nbytes) + b"WAVE"
            + b"fmt " + struct.pack("<IHHIIHH", 16, 1, ch, rate,
                                    rate * ch * bits // 8, ch * bits // 8, bits)
            + b"data" + struct.pack("<I", nbytes))

def wav_write(path: str, pcm: np.ndarray, rate: int = SAMPLE_RATE) -> None:
    pcm = to_int16(pcm)
    with open(path, "wb") as fh:
        fh.write(wav_header(len(pcm), rate)); fh.write(pcm.astype("<i2").tobytes())

def wav_read(path: str) -> tuple[np.ndarray, int]:
    """Minimal RIFF parser that skips unknown chunks (LIST, fact, cue, ...)."""
    raw = open(path, "rb").read()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", "not a RIFF/WAVE file"
    off, rate, fmt, ch, bits, data = 12, None, None, None, None, None
    while off + 8 <= len(raw):
        cid, size = raw[off:off + 4], struct.unpack_from("<I", raw, off + 4)[0]
        body = raw[off + 8: off + 8 + size]
        if cid == b"fmt ":
            fmt, ch, rate, _, _, bits = struct.unpack_from("<HHIIHH", body, 0)
        elif cid == b"data":
            data = body
        off += 8 + size + (size & 1)             # odd-sized chunks carry a pad byte
    assert fmt == 1 and bits == 16 and ch == 1, f"want mono PCM16: fmt={fmt} bits={bits} ch={ch}"
    return np.frombuffer(data, dtype="<i2"), rate
```

### The µ-law measurement

µ-law is an 8-bit *companded* code: 1 sign bit, 3 exponent bits, 4 mantissa bits, giving 255
distinct output levels (two codes decode to 0, so 255 not 256 are reachable from 16-bit
input). Because the step size grows with the exponent, the quantisation error grows
*proportionally* to the signal — which is the whole point: near-constant SNR across a wide
dynamic range, unlike linear 8-bit PCM's 49.9 dB at full scale and nothing at all quietly.

Run against Python 3.12's stdlib `audioop` (removed in 3.13 by PEP 594 — one of the reasons
this curriculum pins 3.12; see `01-environment.md`), over the **entire** int16 domain:

```
encode mismatches vs audioop / 65536 : 0
decode mismatches vs audioop / 65536 : 0
distinct codes emitted               : 255
roundtrip over all 65536 codes       : max|e| = 644 LSB, rms = 226.5 LSB
```

`[MEASURED]` — bit-exact, both directions, all 65 536 inputs. Broken out by amplitude band,
the proportional-error property is visible:

| $|x|$ band (LSB) | max abs error | rms error | band SNR (dB) |
|---|---|---|---|
| [0, 256) | 11 | 4.5 | 30.3 |
| [256, 1024) | 35 | 11.4 | 35.5 |
| [1024, 4096) | 131 | 35.4 | 37.7 |
| [4096, 16384) | 515 | 136.1 | 38.0 |
| [16384, 32768) | 643 | 297.4 | 38.5 |

Absolute error spans 60× across the range; SNR is flat within 8 dB. On a speech-like signal
(300 Hz + 1200 Hz + noise, 1 s at 8 kHz) driven to a range of levels, `[MEASURED]`:

| input level (dBFS RMS) | µ-law SNR (dB) |
|---|---|
| −3 | 36.1 |
| −6 | 37.7 |
| −12 | 37.8 |
| −20 | 37.2 |
| −30 | 36.5 |
| −40 | 34.0 |
| −50 | 28.2 |
| −60 | 19.6 |

**Reading of this table:** µ-law holds ~37 dB SNR over a 30 dB input range, then degrades.
Practical consequence for telephony agents: your input gain matters. A caller 30 dB below
nominal loses ~18 dB of SNR *on top of* the narrowband loss from §2.1 — which is why
soft-spoken callers on PSTN produce the worst WER you will ever see.

**A one-LSB trap worth knowing.** A common shortcut implements the encoder as
"`abs()` the 16-bit value, add BIAS = 132, take `floor(log2)` for the exponent". It differs
from the ITU-T/Sun reference on **381 of 65 536 inputs** `[MEASURED]`, with an amplitude
divergence up to 1024 LSB. The reference right-shifts to 14 bits *first*, and `>> 2` on a
negative two's-complement value floors rather than truncating toward zero — so the sign is
taken after the shift, not before. Bit-exactness matters when you are diffing your µ-law
against a carrier's.

### The resampling and aliasing measurements

```
16k -> 48k -> 16k round trip (interior, edges excluded): SNR = 110.0 dB
source @16 kHz, 1000 Hz + 5500 Hz tones : [(1000, 0.0 dB), (5500, -0.0 dB)]
naive x[::2] to 8 kHz, no filter        : [(1000, 0.0 dB), (2500, -0.0 dB)]
band-limited resample to 8 kHz          : [(1000, 0.0 dB), (2500, -99.4 dB)]
```

`[MEASURED]`. Three readings:

1. **A 3:1 up / 1:3 down round trip is effectively lossless** at 110 dB — 12 dB better than
   int16's own 98 dB SQNR, so the resampler is not your error source. Going 48 k → 16 k → 48 k
   on the *inbound* path is lossy in the other sense: content above 8 kHz is gone forever.
   That is deliberate, and it is why the TTS path must not round-trip through 16 kHz if the
   voice was synthesised at 24 kHz.
2. **Decimation without a filter is catastrophic, not merely degraded.** Dropping every other
   sample folded the 5500 Hz tone onto 2500 Hz at *full amplitude* — an artefact
   indistinguishable from real speech content, sitting squarely in the $F_2$ region. This is
   the single most common audio bug in hand-rolled telephony bridges.
3. **The correct resampler suppressed the same fold by 99.4 dB.** Below the int16 noise floor.

Production uses `soxr` (via `soxr` or `librosa`), `libswresample` (via PyAV/ffmpeg), or
WebRTC's own resampler — all polyphase FIR, all with published passband ripple and stopband
attenuation. The code above is for understanding; do not ship an $O(N \cdot \text{taps})$
`np.convolve` in a 50-frames-per-second loop.

### The other checks

```
framer: 1000 B in -> 640 B emitted in whole frames, 360 B held
full-scale sine rms_dbfs = -3.01
clip check: to_int16([1.9, -1.9]) = [32767, -32768]   (naive cast wraps to [-3277, 3277])
wav bytes identical to stdlib `wave`: True
wav roundtrip exact: True, rate 16000
```

`[MEASURED]`. Note the framer holds 360 bytes rather than emitting a short frame — that is the
correct behaviour, and the reason `flush()` exists as a separate, explicit call. A framer that
silently emits short frames breaks every downstream component that assumes fixed sizes.

---

## 4. How production does it

**LiveKit Agents.** Audio is carried as `rtc.AudioFrame`, which bundles `data`,
`sample_rate`, `num_channels`, and `samples_per_channel` — the format travels *with* the
buffer instead of being an ambient assumption. Re-framing is a first-class utility:
`livekit/agents livekit-agents/livekit/agents/utils/audio.py:AudioByteStream` (checked against
`main`) accumulates a byte stream and emits fixed-size frames, defaulting to
`samples_per_channel = sample_rate // 10`, i.e. **100 ms**. It also has a `progressive=True`
mode that starts at `_MIN_PROGRESSIVE_MS = 20` ms and doubles toward the target, explicitly
"to minimise time-to-first-audio". That is the latency/overhead tradeoff of §2.2, implemented:
small frames while the listener is waiting, large frames once the stream is flowing. The
adjacent helpers `silence_frame` and `calculate_audio_duration` in the same file exist because
"how long is this buffer" is a question you ask constantly and get wrong constantly.

**faster-whisper.** `SYSTRAN/faster-whisper faster_whisper/audio.py:decode_audio` takes
`sampling_rate: int = 16000` and builds an `av.audio.resampler.AudioResampler` with
`rate=sampling_rate` — i.e. it delegates decoding *and* rate conversion to libav rather than
trusting the caller. Note the comment in that file about explicitly `del`-ing the resampler
because "some objects related to the resampler are not freed": resampler state is real state,
and it leaks if you create one per utterance.

**whisper.cpp.** The contract is compile-time: `include/whisper.h` fixes
`WHISPER_SAMPLE_RATE 16000`, `WHISPER_N_FFT 400`, `WHISPER_HOP_LENGTH 160`,
`WHISPER_CHUNK_SIZE 30`. There is no runtime sample-rate parameter to get wrong.

**Silero VAD.** `snakers4/silero-vad src/silero_vad/utils_vad.py` refuses anything but
512 samples at 16 kHz or 256 at 8 kHz, with an explicit `ValueError`. Good design: a hard
failure at the boundary instead of garbage predictions.

**Twilio Media Streams** and most SIP paths deliver 8 kHz µ-law, 20 ms per message = 160
payload bytes, base64-encoded inside JSON over a WebSocket. Base64 inflates it by 4/3, so you
pay ~214 bytes of text per 20 ms plus JSON overhead — a case where the transport, not the
codec, dominates. Detail in `../07-livekit/05-telephony-sip.md`.

**The pattern across all of them:** the format is either compiled in (whisper.cpp), carried
with the buffer (LiveKit), or enforced with an exception (Silero). None of them accepts
"whatever the caller sent" — and neither should your code.

---

## 5. At scale

**Count your copies.** Each conversion is a full-buffer traversal. A pipeline that converts
opportunistically does something like: Opus decode → float32 (1) → int16 (2) → resample (3) →
float32 for VAD (4) → int16 for the queue (5) → float32 for ASR (6) → back to int16 (7). Seven
touches of every sample. The contract reduces it to: Opus decode + resample at the edge (1) →
float32 immediately before each model (2 per model, unavoidable). At 20 ms frames and 1000
streams you are doing **50 000 frames per second**; five avoidable copies of 640 bytes each is
160 MB/s of memory traffic bought for nothing.

**Per-stream bandwidth arithmetic** (16 kHz mono):

| concurrent streams | Opus @24 kbit/s | int16 PCM | float32 PCM | frames/s @20 ms |
|---|---|---|---|---|
| 1 | 3 kB/s | 32 kB/s | 64 kB/s | 50 |
| 100 | 0.30 MB/s | 3.2 MB/s | 6.4 MB/s | 5 000 |
| 1 000 | 3.0 MB/s | 32 MB/s | 64 MB/s | 50 000 |
| 10 000 | 30 MB/s | 320 MB/s | 640 MB/s | 500 000 |

Two things to notice. First, the internal PCM bandwidth is 10× the wire bandwidth — the
expensive network hop is *inside* your cluster, between the SFU and the agent worker, not
between the caller and the SFU. Second, at 10 000 streams float32 internally means 640 MB/s of
PCM crossing process boundaries, which is a serious fraction of a NIC and all of a Python
process's ability to `memoryview` things.

**Per-frame fixed cost dominates at scale.** 50 000 frames/s across 1000 streams means that
50 µs of Python overhead per frame — one `asyncio` hop, a couple of `bytes` allocations, a
`logging` call that formats a string even when the level is disabled — consumes 2.5 CPU cores
doing *nothing but framing*. This is why real frame runtimes pass `memoryview`s, pre-allocate,
and keep the per-frame path free of allocation. See
`../06-realtime-systems/03-pipeline-architecture.md`.

**Resampling is not free at fleet scale.** A high-quality polyphase resampler runs at maybe
0.1–1 % of a core per stream `[INFERENCE]` — negligible for one stream, one to ten cores at
10 000. The scaling lesson: put the resample where it happens once (the media edge), not in
every plugin that "just wants 16 kHz". Every plugin resampling defensively means the same
audio is resampled three times.

**Format mismatches at scale are silent.** A single stream with a wrong sample rate is
obvious — the audio is chipmunked. One tenant out of 500 whose carrier negotiated A-law
instead of µ-law produces *plausible-sounding* garbage transcripts and a WER regression you
will chase for a week. Mitigation: assert the contract at every ingress, export the observed
(rate, channels, dtype, frame size) tuple as a low-cardinality metric label, and alarm on any
value you did not expect. `../06-realtime-systems/06-observability.md`.

---

## 6. Exercises

**E0.3.1** Write a function that, given only a `bytes` object, decides whether it is more likely
`s16le` or `s16be` audio. Justify your statistic (hint: consider the distribution of
$|x_{n} - x_{n-1}|$ for speech under each interpretation). Test it by byte-swapping a real
recording. Report your accuracy on 100 ms segments and on 1 s segments.

**E0.3.2** Synthesise a 6 kHz sine at 16 kHz. Decimate to 8 kHz (a) by `x[::2]` and (b) with the
band-limited `resample` above. Predict the alias frequency from $|f - k f_s|$ *before*
running, then verify by locating the FFT peak. Then repeat with a 4 kHz sine and explain why
the result is ambiguous.

**E0.3.3** Take a recording of yourself saying "six sisters sell seashells". Lowpass it at 3400
Hz to simulate G.711's passband, and measure the ratio of energy in 3.5–8 kHz before and after
for the sibilant segments only (segment by hand or by a simple high-frequency-energy
threshold). Compare your measured ratio to the −11.1 dB the flat-noise model of §2.1 predicts
for a 4 kHz cutoff, and explain any discrepancy.

**E0.3.4** Implement A-law (`ITU-T G.711`, the European variant: 13-bit input, different bias
and segment table) and verify it bit-exactly against `audioop.lin2alaw` over all 65 536 int16
inputs. Then produce the A-law equivalent of the SNR-vs-level table in §3 and state, with
numbers, which of the two companding laws is better at −50 dBFS and which at −3 dBFS.

**E0.3.5** Write a WAV file with a 200-byte `LIST` chunk between `fmt ` and `data`, and an
odd-sized `cue ` chunk after `data`. Confirm that a parser hardcoding offset 44 produces
garbage, that one which forgets the `size & 1` pad byte desynchronises, and that the `wav_read`
above handles both.

**E0.3.6** Instrument the `Framer` to count `bytes` allocations per 640-byte frame emitted.
Then rewrite it to emit `memoryview` slices of a single pre-allocated backing buffer with zero
per-frame allocation, and measure the throughput difference in frames/second. State how many
concurrent 20 ms streams each version could sustain on one core.

**E0.3.7** Given a 20 ms frame grid and a Silero VAD requiring 512-sample windows, write the
adapter that produces VAD windows from the frame stream. Prove — by asserting on sample
indices, not frame counts — that no sample is dropped or duplicated over 10 seconds, and
report the worst-case additional latency the adapter introduces.

---

## 7. Interview drill

> *"We're building a voice agent that takes calls from both a web widget and a phone number.
> A designer asks why the phone calls sound worse and transcribe worse. Give me the technical
> answer, with numbers, and then tell me what you'd actually do about it."*

What a staff-level answer contains:

1. **Two independent losses, named separately.** Bandwidth: the PSTN passband is 300–3400 Hz,
   so all sibilant frication (primary peak 4–5 kHz for `/s, z/`) is *absent*, not attenuated.
   Quantisation: G.711 µ-law holds ~37 dB SNR over a 30 dB input range and degrades to ~20 dB
   at −60 dBFS, so quiet callers are hit twice.
2. **The linguistic consequence, specifically.** Sibilant confusions: plurals, third-person
   `-s`, `/f/`–`/θ/`–`/s/` in spelled-out names and codes. This is why "F as in Frank" exists.
3. **What is *not* the cause,** to show you have debugged this before: it is not the codec
   bitrate (G.711 is 64 kbit/s, higher than the Opus you use on the web path), and it is not
   packet loss unless RTCP says so.
4. **Mitigations, ranked by cost-effectiveness.**
   - Use a model that was trained or fine-tuned on 8 kHz telephone speech, rather than
     upsampling to 16 kHz and hoping. Upsampling adds no information.
   - Contextual biasing / keyword boosting on your domain vocabulary — this recovers exactly
     the entity errors narrowband causes. `../02-asr/06-decoding-and-biasing.md`.
   - Design the *dialogue* for it: confirm digits and names by readback, use alphanumeric
     alphabets, never ask an open question whose answer is a proper noun.
   - Negotiate a wideband codec (Opus or G.722 over SIP) where the carrier supports it. Often
     they do not.
   - Do *not* propose "add a denoiser": the information is not noisy, it is missing.
5. **Measurement.** Report WER split by ingress path as a first-class dashboard cut, and track
   entity WER separately from overall WER, because overall WER will move by 2 points while
   entity WER moves by 15. `../02-asr/07-evaluation.md`.

The trap in this question is answering "8 kHz versus 16 kHz" and stopping. The interviewer
wants to know whether you understand *which phonemes* and *therefore which product failures*.

---

## Sources

- Valin, Vos & Terriberry, **RFC 6716: Definition of the Opus Audio Codec** (IETF, September
  2012). §2.1.3 Table 1 (bandwidth/effective-rate table: NB 4 kHz/8 kHz … FB 20 kHz/48 kHz);
  §2.1.4 frame durations 2.5–60 ms, packets to 120 ms, and the "20 ms is a good choice"
  recommendation. <https://www.rfc-editor.org/rfc/rfc6716.txt>
- Schulzrinne & Casner, **RFC 3551: RTP Profile for Audio and Video Conferences with Minimal
  Control**, §4.5.11 `L16` — 16-bit samples "transmitted in network byte order (most
  significant byte first)". <https://www.rfc-editor.org/rfc/rfc3551.txt>
- **ITU-T Recommendation G.711**, Pulse Code Modulation (PCM) of voice frequencies. The
  reference implementation used here is the Sun Microsystems `g711.c` code carried into CPython
  as `Modules/audioop.c` (checked against branch `3.12`): `BIAS = 0x84`,
  `seg_uend = {0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF}`, and
  `st_14linear2ulaw()` operating on the input right-shifted to 14 bits.
  <https://github.com/python/cpython/blob/3.12/Modules/audioop.c>
- Jongman, A., Wayland, R. & Wong, S. (2000). *Acoustic characteristics of English fricatives.*
  **J. Acoust. Soc. Am.** 108(3), 1252–1263. Source of the "`/s, z/` primary spectral peak
  around 4–5 kHz" figure. <https://pubs.aip.org/asa/jasa/article/108/3/1252/551143>
- Li, F., Edwards, J. & Beckman, M. (2007). *Spectral measures for sibilant fricatives of
  English, Japanese, and Mandarin Chinese.* **ICPhS XVI.** Source of the ≈6.1 kHz centre-of-
  gravity figure for English `/s/`. <https://www.ling.ohio-state.edu/pdlg/LiICPhS2007.pdf>
- `livekit/agents` — `livekit-agents/livekit/agents/utils/audio.py`: `AudioByteStream`
  (default `samples_per_channel = sample_rate // 10`; `_MIN_PROGRESSIVE_MS = 20`),
  `silence_frame`, `calculate_audio_duration`. Branch `main`, framework release 1.7.0.
  <https://github.com/livekit/agents>
- `SYSTRAN/faster-whisper` — `faster_whisper/audio.py:decode_audio` (`sampling_rate=16000`,
  `av.audio.resampler.AudioResampler`). <https://github.com/SYSTRAN/faster-whisper>
- `ggml-org/whisper.cpp` — `include/whisper.h`: `WHISPER_SAMPLE_RATE 16000`,
  `WHISPER_N_FFT 400`, `WHISPER_HOP_LENGTH 160`, `WHISPER_CHUNK_SIZE 30`.
  <https://github.com/ggml-org/whisper.cpp>
- `snakers4/silero-vad` — `src/silero_vad/utils_vad.py`: 512-sample windows at 16 kHz,
  256 at 8 kHz, enforced by `ValueError`. <https://github.com/snakers4/silero-vad>
- **PEP 594 — Removing dead batteries from the standard library.** `audioop` is removed in
  Python 3.13; it exists, deprecated, in 3.12. <https://peps.python.org/pep-0594/>
- Microsoft/IBM **Multimedia Programming Interface and Data Specifications 1.0** (the RIFF/WAVE
  specification); cross-checked byte-for-byte against CPython's `wave` module output on this
  machine.

All `[MEASURED]` figures were produced on the bench described in `01-environment.md`
(Apple M5, macOS 26.5.2) under `uv run --python 3.12 --with numpy`, `numpy 2.5.2`,
CPython 3.12.13.
