# Run It Locally

**What you'll be able to do after this:** run a LiveKit server, mint and break tokens, move real
audio between two participants of your own making, and run a **complete `AgentSession` — VAD, STT,
LLM, TTS, turn-taking, metrics — with no API keys at all**, then read the worker log well enough
to explain every line.

Every command and every output below was run in this order on 2026-09-14 `[MEASURED]`. Versions:
`livekit-server` 1.13.7, `lk` 2.18.6, `livekit-agents` 1.8.1, `livekit` (realtime SDK) 1.1.18,
CPython 3.12.13, macOS `arm64`.

---

## Step 1 — Install the two binaries

```bash
brew install livekit livekit-cli      # macOS; installs livekit-server and `lk`
```

```
🍺  /opt/homebrew/Cellar/livekit/1.13.7: 8 files, 52MB
🍺  /opt/homebrew/Cellar/livekit-cli/2.18.6: 11 files, 89.0MB
```

Not on macOS, or you want the exact production image:

```bash
docker run --rm -p 7880:7880 -p 7881:7881 -p 7882:7882/udp \
  livekit/livekit-server --dev --bind 0.0.0.0
```

`livekit-server` is the media server (part 1 of
[`01-livekit-in-plain-words.md`](01-livekit-in-plain-words.md) §2). `lk` is the admin CLI: it
mints tokens, lists rooms, joins rooms, and drives the server API. You will use it constantly.

---

## Step 2 — Start the server in dev mode, and read its first four lines

```bash
livekit-server --dev --bind 127.0.0.1
```

```
INFO   livekit   starting in development mode
INFO   livekit   no keys provided, using placeholder keys   {"API Key": "devkey", "API Secret": "secret"}
INFO   livekit   using single-node routing
INFO   livekit   starting LiveKit server   {"portHttp": 7880, "nodeID": "ND_5x2apdAGqYtj",
                                            "version": "1.13.7", "bindAddresses": ["127.0.0.1"],
                                            "rtc.portTCP": 7881, "rtc.portUDP": {"Start":7882,"End":0}}
```

Four facts, and you now know them from the source rather than a blog post:

- **`devkey` / `secret`** are the dev credentials. They are placeholders and they are public;
  nothing signed with them should ever reach a real deployment.
- **`single-node routing`** means no Redis, so exactly one process holds every room. Add Redis
  and the same binary becomes a cluster node
  ([`../04-self-hosting-and-scale.md`](../04-self-hosting-and-scale.md) §2.1).
- **7880 is HTTP + WebSocket**; 7881 is ICE-over-TCP; UDP starts at 7882. In production the UDP
  range is 50000–60000 by default and must be reachable *directly*.
- `--bind 127.0.0.1` keeps this off your LAN. Drop it and your laptop is a public SFU.

Two health checks worth memorising `[MEASURED]`:

```bash
$ curl -s http://127.0.0.1:7880/ ; echo
OK
$ curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:7880/rtc/validate?room=x'
401
```

`GET /` is the liveness probe. `/rtc/validate` is the *token* check: give it a token and it tells
you whether the server would accept a join, without opening a WebSocket. That makes it the first
thing to try when a client cannot connect.

---

## Step 3 — Mint a token, then break it on purpose

```bash
$ lk --dev token create --join --room demo --identity me --valid-for 10m --token-only
# 276 bytes of JWT

$ curl -s -o /dev/null -w '%{http_code}\n' \
    "http://127.0.0.1:7880/rtc/validate?room=demo&access_token=$TOKEN"
200
```

`--dev` is the CLI's shortcut for `devkey`/`secret` against `http://localhost:7880`. Now the part
that actually teaches you something: connect six times with six different tokens and read what
the server says `[MEASURED]`.

```python
"""What the server says when the token is wrong. Each row is one real connect attempt."""

import asyncio
import datetime
import time

from livekit import api, rtc

URL, KEY, SECRET = "ws://127.0.0.1:7880", "devkey", "secret"
ROOM = "auth-probe"


def tok(*, secret=SECRET, key=KEY, identity="probe", ttl=600, join=True, room=ROOM):
    at = api.AccessToken(key, secret).with_identity(identity).with_ttl(
        datetime.timedelta(seconds=ttl)
    )
    return at.with_grants(
        api.VideoGrants(room_join=join, room=room, can_publish=True, can_subscribe=True)
    ).to_jwt()


CASES = {
    "valid": tok(),
    "wrong secret": tok(secret="not-the-secret"),
    "unknown api key": tok(key="APInope"),
    "expired (ttl=-60s)": tok(ttl=-60),
    "no roomJoin grant": tok(join=False),
    "grant for another room": tok(room="some-other-room"),
}


async def main() -> None:
    for label, t in CASES.items():
        room = rtc.Room()
        t0 = time.perf_counter()
        try:
            await asyncio.wait_for(room.connect(URL, t), timeout=10)
            print(f"{label:24s} CONNECTED  ({(time.perf_counter()-t0)*1000:.0f} ms)")
            await room.disconnect()
        except Exception as e:
            print(f"{label:24s} {type(e).__name__}: {str(e).splitlines()[0][:80]}")


asyncio.run(main())
```

Output `[MEASURED]`:

```
valid                    CONNECTED  (178 ms)
wrong secret             ConnectError: engine: signal failure: client error: 401 Unauthorized -
                         invalid authorization token: token signature is invalid
unknown api key          ConnectError: engine: signal failure: client error: 401 Unauthorized -
                         invalid API key
expired (ttl=-60s)       ConnectError: engine: signal failure: client error: 401 Unauthorized -
                         invalid authorization token: token has invalid claims: token is expired
no roomJoin grant        ConnectError: engine: signal failure: client error: 401 Unauthorized -
                         permissions denied
grant for another room   CONNECTED  (11 ms)
```

**Learn the four error strings** — they are the entire auth surface, and
[`05-debug-playbook.md`](05-debug-playbook.md) §1 keys off them.

**Then stare at the last row.** A token for `some-other-room` connected happily, because the room
comes from the token, not from your code. `lk --dev room list` confirms the room was created on
demand `[MEASURED]`:

```
│ RM_NZr32mijA3JY │ auth-probe      │ 0 │ 0 │
│ RM_5zSBEVGymXAJ │ some-other-room │ 0 │ 0 │
```

If your token endpoint reads the room name out of the client's request, any client can join any
room whose name it can guess. That is the most common LiveKit security bug, and you just
reproduced it in eleven milliseconds.

> Aside: PyJWT warns `InsecureKeyLengthWarning: The HMAC key is 6 bytes long` when signing with
> the dev secret. Correct and harmless here — real secrets are 32+ bytes.

---

## Step 4 — Move real audio between two participants you wrote

Install the SDK (no keys, no account):

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv livekit livekit-api
```

`meter.py` — one participant publishes a 440 Hz tone, the other subscribes and measures what
arrives:

```python
"""Two participants in one room: one publishes a tone, the other measures the PCM it gets.

Verifies the whole local loop with no agent framework involved:
token mint -> signalling -> SFU -> Opus/RED -> PCM at the rate you asked for.

Usage: python meter.py [room-name]
"""

import asyncio
import math
import os
import struct
import sys
import time

from livekit import api, rtc

URL = os.environ.get("LIVEKIT_URL", "ws://127.0.0.1:7880")
KEY = os.environ.get("LIVEKIT_API_KEY", "devkey")
SECRET = os.environ.get("LIVEKIT_API_SECRET", "secret")
ROOM = sys.argv[1] if len(sys.argv) > 1 else "lab-1"

SR_PUB = 48000        # publish rate; WebRTC's native audio rate
SR_SUB = 16000        # what we ask the SDK for: this curriculum's contract
FRAME_MS = 20
TONE_HZ = 440.0


def token(identity: str) -> str:
    return (
        api.AccessToken(KEY, SECRET)
        .with_identity(identity)
        .with_grants(api.VideoGrants(room_join=True, room=ROOM))
        .to_jwt()
    )


async def publisher(stop: asyncio.Event) -> None:
    room = rtc.Room()
    await room.connect(URL, token("tone-bot"))
    source = rtc.AudioSource(SR_PUB, 1)
    track = rtc.LocalAudioTrack.create_audio_track("tone", source)
    await room.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    )
    n = SR_PUB * FRAME_MS // 1000
    phase, step = 0.0, 2 * math.pi * TONE_HZ / SR_PUB
    while not stop.is_set():
        frame = rtc.AudioFrame.create(SR_PUB, 1, n)
        buf = frame.data                     # ALREADY a memoryview of int16
        for i in range(n):
            buf[i] = int(12000 * math.sin(phase))
            phase += step
        await source.capture_frame(frame)    # paces itself to real time
    await room.disconnect()


async def subscriber(stop: asyncio.Event) -> dict:
    room = rtc.Room()
    subscribed: asyncio.Queue = asyncio.Queue()

    @room.on("track_subscribed")
    def _on_track(track, publication, participant):
        print(f"[sub] subscribed: {participant.identity} kind={participant.kind} "
              f"source={publication.source} codec={publication.mime_type}")
        subscribed.put_nowait(track)

    await room.connect(URL, token("listener"), rtc.RoomOptions(auto_subscribe=True))
    print(f"[sub] connected to {ROOM!r}; already present: {list(room.remote_participants)}")

    t0 = time.perf_counter()
    track = await asyncio.wait_for(subscribed.get(), timeout=15)
    t_sub = time.perf_counter() - t0

    stream = rtc.AudioStream(track, sample_rate=SR_SUB, num_channels=1, frame_size_ms=FRAME_MS)
    stats = {"t_subscribe_s": round(t_sub, 3), "frames": 0, "bytes": 0, "peak_rms": 0.0}
    async for event in stream:
        f = event.frame
        pcm = bytes(f.data)
        if stats["frames"] == 0:
            stats |= {
                "sample_rate": f.sample_rate,
                "samples_per_channel": f.samples_per_channel,
                "bytes_per_frame": len(pcm),
                "duration_ms": round(f.duration * 1000, 3),
            }
        stats["frames"] += 1
        stats["bytes"] += len(pcm)
        s = struct.unpack(f"<{len(pcm) // 2}h", pcm)
        stats["peak_rms"] = max(stats["peak_rms"], math.sqrt(sum(x * x for x in s) / len(s)))
        if stats["frames"] >= 100:           # 100 x 20 ms = 2 s of audio
            break

    await stream.aclose()
    await room.disconnect()
    stop.set()
    return stats


async def main() -> None:
    stop = asyncio.Event()
    pub = asyncio.create_task(publisher(stop))
    stats = await subscriber(stop)
    await pub
    print("[result]", stats)


asyncio.run(main())
```

Output `[MEASURED]`:

```
[sub] connected to 'lab-1'; already present: ['tone-bot']
[sub] subscribed: tone-bot kind=0 source=2 codec=audio/red
[result] {'t_subscribe_s': 0.174, 'frames': 100, 'bytes': 64000, 'peak_rms': 8605.48,
          'sample_rate': 16000, 'samples_per_channel': 320, 'bytes_per_frame': 640,
          'duration_ms': 20.0}
```

Five things you just proved, not read:

1. **You publish at 48 kHz and receive at 16 kHz** because you asked; the SDK resampled.
2. **`frame_size_ms=20` ⇒ 320 samples ⇒ 640 bytes.** Drop that argument and you get 10 ms /
   160 samples / 320 bytes. Everything else in this curriculum assumes 640
   ([`../../00-setup/03-canonical-formats.md`](../../00-setup/03-canonical-formats.md)).
3. **`codec=audio/red`**: Opus inside RFC 2198 redundancy. LiveKit sends each speech payload
   twice by default so one lost packet is not a glitch.
4. **`kind=0`** is `STANDARD` — a plain participant. Remember this number; in step 6 you will see
   `kind=4`.
5. **Subscribe took 174 ms** on loopback, and a tone of amplitude 12000 arrived with peak RMS
   8605 ≈ 12000/√2. The audio path is lossless-ish and the arithmetic checks out, which is how
   you know you are measuring the pipeline and not a bug.

---

## Step 5 — Install the agents framework

```bash
uv pip install --python .venv 'livekit-agents==1.8.1'
```

Pin the version. This is a fast-moving framework, the parent chapters are written against 1.7.0,
and [`05-debug-playbook.md`](05-debug-playbook.md) §4 lists what moved.

---

## Step 6 — A full `AgentSession` with zero API keys

The blocker for most beginners is that every tutorial wants a Deepgram key, an OpenAI key and a
Cartesia key before anything runs, which means you cannot tell a *framework* problem from a
*vendor* problem. So write the three plugins yourself, deliberately stupid:

- **`EnergySTT`** — a streaming STT that ignores language entirely. Loud for ~100 ms ⇒
  `START_OF_SPEECH`; quiet for ~500 ms ⇒ `FINAL_TRANSCRIPT` saying how long you made noise.
- **`EchoLLM`** — emits `"Understood: <your text>."` word by word, like a real token stream.
- **`ToneTTS`** — 60 ms of 330 Hz beep per character of text, pushed in 100 ms chunks.

`keyless_agent.py`:

```python
"""A real AgentSession with zero API keys: energy STT, echo LLM, tone TTS.

Proves the framework end to end -- registration, dispatch, job process, session,
turn loop, metrics -- without any vendor account. The three plugins are deliberately
stupid: swapping in deepgram/openai/cartesia later is a one-line change each.

Run:  LIVEKIT_URL=ws://127.0.0.1:7880 LIVEKIT_API_KEY=devkey LIVEKIT_API_SECRET=secret \
      python keyless_agent.py dev
"""

import asyncio
import logging
import math
import struct

from livekit import agents
from livekit.agents import (
    NOT_GIVEN,
    Agent,
    AgentSession,
    APIConnectOptions,
    JobContext,
    NotGivenOr,
    WorkerOptions,
    cli,
    utils,
)
from livekit.agents.llm import LLM, ChatChunk, ChatMessage, ChoiceDelta, LLMStream
from livekit.agents.stt import (
    STT,
    RecognizeStream,
    SpeechData,
    SpeechEvent,
    SpeechEventType,
    STTCapabilities,
)
from livekit.agents.tts import TTS, AudioEmitter, ChunkedStream, TTSCapabilities

log = logging.getLogger("keyless")
SR = 16000
FAST = APIConnectOptions(max_retry=0, timeout=5.0)   # never retry inside a live call


# ------------------------------------------------------- STT: energy, not speech
class EnergySTT(STT):
    """Emits a fake transcript describing how long you made noise for."""

    def __init__(self, *, threshold: float = 500.0) -> None:
        super().__init__(capabilities=STTCapabilities(streaming=True, interim_results=False))
        self.threshold = threshold

    @property
    def model(self) -> str:
        return "energy-v0"

    @property
    def provider(self) -> str:
        return "local"

    async def _recognize_impl(self, buffer, *, language=NOT_GIVEN, conn_options=None):
        raise NotImplementedError("this STT is streaming-only")

    def stream(self, *, language: NotGivenOr[str] = NOT_GIVEN, conn_options=None):
        return _EnergyStream(stt=self, conn_options=conn_options or FAST)


class _EnergyStream(RecognizeStream):
    def __init__(self, *, stt: EnergySTT, conn_options: APIConnectOptions) -> None:
        # sample_rate= makes the base class resample everything to 16 kHz for us
        super().__init__(stt=stt, conn_options=conn_options, sample_rate=SR)
        self._impl = stt

    async def _run(self) -> None:
        speaking, loud, quiet, samples = False, 0, 0, 0
        async for item in self._input_ch:
            if isinstance(item, self._FlushSentinel):
                continue
            pcm = bytes(item.data)
            s = struct.unpack(f"<{len(pcm) // 2}h", pcm)
            rms = math.sqrt(sum(x * x for x in s) / len(s))
            loud, quiet = (loud + 1, 0) if rms > self._impl.threshold else (0, quiet + 1)

            if not speaking and loud >= 5:              # ~100 ms of sound: onset
                speaking, samples = True, 0
                self._event_ch.send_nowait(SpeechEvent(type=SpeechEventType.START_OF_SPEECH))
            if speaking:
                samples += item.samples_per_channel
            if speaking and quiet >= 25:                # ~500 ms of silence: commit
                speaking = False
                self._event_ch.send_nowait(
                    SpeechEvent(
                        type=SpeechEventType.FINAL_TRANSCRIPT,
                        alternatives=[
                            SpeechData(
                                language="en",
                                text=f"you made noise for {samples / SR:.1f} seconds",
                                confidence=1.0,
                            )
                        ],
                    )
                )
                self._event_ch.send_nowait(SpeechEvent(type=SpeechEventType.END_OF_SPEECH))


# ---------------------------------------------------------------- LLM: echo only
class EchoLLM(LLM):
    @property
    def model(self) -> str:
        return "echo-v0"

    def chat(self, *, chat_ctx, tools=None, conn_options=None, **kwargs) -> LLMStream:
        return _EchoStream(
            self, chat_ctx=chat_ctx, tools=tools or [], conn_options=conn_options or FAST
        )


class _EchoStream(LLMStream):
    async def _run(self) -> None:
        last = ""
        for item in reversed(self._chat_ctx.items):
            if isinstance(item, ChatMessage) and item.role == "user":
                last = item.text_content or ""
                break
        reply = f"Understood: {last}." if last else "I am listening."
        for word in reply.split():                      # token-by-token, like a real LLM
            self._event_ch.send_nowait(
                ChatChunk(id=utils.shortuuid(),
                          delta=ChoiceDelta(role="assistant", content=word + " "))
            )
            await asyncio.sleep(0.01)


# --------------------------------------------------------------- TTS: a beep, 1:1
class ToneTTS(TTS):
    def __init__(self) -> None:
        super().__init__(
            capabilities=TTSCapabilities(streaming=False), sample_rate=SR, num_channels=1
        )

    @property
    def model(self) -> str:
        return "tone-v0"

    def synthesize(self, text: str, *, conn_options=None) -> ChunkedStream:
        return _ToneStream(tts=self, input_text=text, conn_options=conn_options or FAST)


class _ToneStream(ChunkedStream):
    async def _run(self, output_emitter: AudioEmitter) -> None:
        output_emitter.initialize(
            request_id=utils.shortuuid(),
            sample_rate=SR,
            num_channels=1,
            mime_type="audio/pcm",          # raw PCM: the emitter skips container decoding
        )
        total = int(SR * 0.06 * max(1, len(self._input_text)))   # 60 ms of beep per character
        phase, step = 0.0, 2 * math.pi * 330.0 / SR
        chunk = bytearray()
        for _ in range(total):
            chunk += struct.pack("<h", int(9000 * math.sin(phase)))
            phase += step
            if len(chunk) >= 3200:          # push every 100 ms: TTFB, not total synthesis time
                output_emitter.push(bytes(chunk))
                chunk.clear()
        if chunk:
            output_emitter.push(bytes(chunk))
        output_emitter.flush()


# ------------------------------------------------------------------- the job code
async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect(auto_subscribe=agents.AutoSubscribe.AUDIO_ONLY)

    session = AgentSession(
        stt=EnergySTT(),
        llm=EchoLLM(),
        tts=ToneTTS(),
        turn_handling={
            "turn_detection": "stt",
            "endpointing": {"min_delay": 0.3},
            "interruption": {"mode": "vad"},   # "adaptive" needs LiveKit Cloud; see playbook §4
        },
    )

    @session.on("user_input_transcribed")
    def _on_transcript(ev):
        log.info("TRANSCRIBED %r final=%s", ev.transcript, ev.is_final)

    @session.on("conversation_item_added")
    def _on_item(ev):
        if isinstance(ev.item, ChatMessage):   # items can also be AgentHandoff: check first
            log.info("ITEM %s: %r", ev.item.role, ev.item.text_content)

    @session.on("metrics_collected")
    def _on_metrics(ev):
        log.info("METRICS %s", ev.metrics)

    await session.start(agent=Agent(instructions="You are a test harness."), room=ctx.room)
    log.info("session started in room %s", ctx.room.name)
    await session.say("Hello, this is the keyless echo bot.")


if __name__ == "__main__":
    cli.run_app(WorkerOptions(entrypoint_fnc=entrypoint))
```

Run the worker in one terminal:

```bash
LIVEKIT_URL=ws://127.0.0.1:7880 LIVEKIT_API_KEY=devkey LIVEKIT_API_SECRET=secret \
  .venv/bin/python keyless_agent.py dev
```

and in another, a "caller" that publishes 2 s of tone, 2 s of silence, 2 s of tone, then hangs up:

```python
"""Join a room and publish 2 s of tone, 2 s of silence, 2 s of tone, then hang up."""

import asyncio
import math
import os
import sys

from livekit import api, rtc

URL = os.environ.get("LIVEKIT_URL", "ws://127.0.0.1:7880")
KEY = os.environ.get("LIVEKIT_API_KEY", "devkey")
SECRET = os.environ.get("LIVEKIT_API_SECRET", "secret")
ROOM = sys.argv[1] if len(sys.argv) > 1 else "lab-2"
SR, FRAME_MS = 48000, 20


async def main() -> None:
    tok = (
        api.AccessToken(KEY, SECRET)
        .with_identity("caller")
        .with_grants(api.VideoGrants(room_join=True, room=ROOM))
        .to_jwt()
    )
    room = rtc.Room()
    await room.connect(URL, tok)
    src = rtc.AudioSource(SR, 1)
    track = rtc.LocalAudioTrack.create_audio_track("mic", src)
    await room.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    )
    n = SR * FRAME_MS // 1000
    phase, step = 0.0, 2 * math.pi * 440.0 / SR
    for kind, secs in [("tone", 2.0), ("silence", 2.0), ("tone", 2.0), ("silence", 3.0)]:
        print(f"[caller] {kind} {secs}s", flush=True)
        for _ in range(int(secs * 1000 / FRAME_MS)):
            f = rtc.AudioFrame.create(SR, 1, n)
            buf = f.data
            for i in range(n):
                buf[i] = int(12000 * math.sin(phase)) if kind == "tone" else 0
                phase += step
            await src.capture_frame(f)
    await room.disconnect()
    print("[caller] hung up", flush=True)


asyncio.run(main())
```

### Read the worker log line by line

This is the payoff. Timestamps are from the real run `[MEASURED]`, trimmed to the lines that
teach something:

```
20:20:24.520  registered worker {"agent_name": "", "id": "AW_tYPALJiM4nsD",
                                 "url": "ws://127.0.0.1:7880", "protocol": 17}
20:20:30.022  received job request {"job_id": "AJ_tMfhFUci7D4y", "dispatch_id": "AD_XtfQxuRuAgnd",
                                   "room": "lab-2", "agent_name": "", "resuming": false}
20:20:30.022  WARNING no warmed process available for job, waiting for one to be created
20:20:30.691  keyless - session started in room lab-2                       (pid 15643)
20:20:30.704  METRICS tts_metrics  label=ToneTTS  ttfb=0.0046  audio_duration=2.17  characters_count=36
20:20:30.740  aec warmup active, disabling interruptions for 3.00s
20:20:31.743  METRICS vad_metrics  label=livekit.agents.inference.vad.VAD  inference_count=32
                                   inference_duration_total=0.0044  model=silero
20:20:32.911  keyless - ITEM assistant: 'Hello, this is the keyless echo bot.'
20:20:37.194  keyless - TRANSCRIBED 'you made noise for 3.1 seconds' final=True
20:20:37.194  received user transcript {"transcript_delay": 3.0509}
20:20:37.494  user turn committed {"delay_completed": true, "source": "stt"}
20:20:37.495  METRICS eou_metrics  end_of_utterance_delay=0.3000  transcription_delay=0.0
20:20:37.571  METRICS llm_metrics  label=EchoLLM  ttft=0.00010  duration=0.0740
20:20:37.594  METRICS tts_metrics  label=ToneTTS  ttfb=0.0068  audio_duration=2.59
```

| Line | What it tells you |
|---|---|
| `registered worker … protocol 17` | The worker connected **outbound** to the server. Nothing needs to reach *into* your agent fleet — no inbound ports, no ingress |
| `received job request` 5.5 s later | The job arrived only when a room appeared. `agent_name: ""` ⇒ **automatic dispatch**; the job id `AJ_…` becomes the agent's identity (`agent-AJ_…`) |
| `no warmed process available` | Dev mode's `num_idle_processes = 0`. The 669 ms between request and `session started` is pure cold start, and it lands in front of the caller's greeting. Production default is `min(ceil(cpu_count), 4)` ([`../02-agents-framework.md`](../02-agents-framework.md) §2.5) |
| `pid 15643` on session lines | The session runs in a **subprocess**, not the worker process |
| first `tts_metrics` at +13 ms | The greeting was synthesised before a word of user audio arrived. `ttfb` 4.6 ms, 2.17 s of audio for 36 characters — your 60 ms/char rule, verified |
| `aec warmup … 3.00s` | The framework suppresses barge-in for 3 s at session start, so the agent's own greeting cannot interrupt it through an unconverged echo canceller ([`../../03-turn-taking/05-echo-and-aec.md`](../../03-turn-taking/05-echo-and-aec.md)) |
| `vad_metrics … model=silero` | 1.8.1 loads a **local** Silero VAD by default (`livekit-local-inference`), 32 inferences/s costing ~4.4 ms of CPU per second of audio. No key, no download at call time |
| `transcript_delay: 3.05` | Our STT only commits after 500 ms of silence, so the final lands 3.05 s after speech onset. That is *by construction*, and it is exactly the latency tax a VAD-segmented batch STT pays ([`../03-writing-plugins.md`](../03-writing-plugins.md) §2.2) |
| `end_of_utterance_delay = 0.3000` | Our `endpointing.min_delay` of 0.3 s, honoured to the millisecond. Change the config, watch this number move |
| `llm_metrics ttft=0.0001` → `tts_metrics ttfb=0.0068` | The whole reply path took ~100 ms after turn commit. With real providers this is where 500–1500 ms goes; the *shape* of the trace is identical ([`../../01-foundations/04-latency-budget.md`](../../01-foundations/04-latency-budget.md)) |

And from the caller's side, `meter.py` pointed at the same room shows the agent as a participant
`[MEASURED]`:

```
[sub] subscribed: tone-bot              kind=0  source=2  codec=audio/red
[sub] subscribed: agent-AJ_WpwAUWVVA6ve kind=4  source=2  codec=audio/red
```

`kind=4` is `AGENT`. Your agent is a participant. That is the whole design, and you have now seen
it in a log.

---

## Step 7 — Swap the fakes for real providers, one at a time

When you have a vendor key (your company almost certainly does), change one line at a time and
watch the metrics move:

```bash
uv pip install --python .venv \
  'livekit-plugins-deepgram' 'livekit-plugins-openai' 'livekit-plugins-cartesia'
```

```python
from livekit.plugins import cartesia, deepgram, openai

session = AgentSession(
    stt=deepgram.STT(model="nova-3"),          # was EnergySTT()
    llm=openai.LLM(model="gpt-4o-mini"),       # was EchoLLM()
    tts=cartesia.TTS(),                        # was ToneTTS()
    turn_handling={"endpointing": {"min_delay": 0.5}},
)
```

Change **one** at a time, and after each change re-read `eou_metrics`, `llm_metrics.ttft` and
`tts_metrics.ttfb`. Two reasons this discipline matters: you learn which provider owns which part
of your latency budget, and when something breaks you know which line caused it. `[INFERENCE]`
— the plugin constructor signatures above are the documented shape, not something this lab ran;
verify against the version you install.

Also run `python keyless_agent.py console` once. It runs the same session against your **laptop
mic and speakers with no LiveKit server and no credentials at all** — verified `[MEASURED]`: with
`LIVEKIT_URL`/`LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` unset, the worker logs
`{"id": "unregistered"}`, fabricates `job_id: mock-job-df9dfa7ce50b` in room `console-room`, and
the session still greets you. `--text` gives a typed conversation instead of audio;
`--list-devices` prints your devices:

```
 ID   Type   Name                    Default
  0  Input   Rockerz 421               yes
  2  Input   MacBook Air Microphone
  3  Output  MacBook Air Speakers
```

That makes `console` the fastest loop for iterating on prompts and turn-taking, with the entire
transport layer removed from the picture. The four commands are `console`, `dev`, `start` and
`download-files`; `start` is the production one (prod defaults: load threshold 0.7, a warm
process pool, health endpoint on :8081). In 1.8.1 `console` is marked deprecated in favour of
`lk agent console`, so expect it to move.

---

## Clean up

```bash
pkill -f 'keyless_agent.py'     # the worker drains its jobs on SIGTERM
pkill -f livekit-server
lk --dev room list              # empty rooms vanish ~20 s after the last participant leaves
```

---

## Where to go next

- Confidence through repetition: [`03-small-projects.md`](03-small-projects.md).
- When something behaves oddly: [`05-debug-playbook.md`](05-debug-playbook.md).
- The framework in full: [`../02-agents-framework.md`](../02-agents-framework.md) — you have now
  seen every concept in its §2 at least once in a log line.
