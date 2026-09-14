# LiveKit in Plain Words

**What you'll be able to do after this:** draw LiveKit's four moving parts from memory, say which
process owns each one, trace a call from "user taps Call" to "agent hears the first word", and
answer the ten questions that confuse everyone in their first week.

---

## 1. The one-sentence version

**LiveKit is a phone exchange for software: it moves audio between participants in a room, and
your voice agent is just another participant in that room.**

Everything else — telephony, recording, your Python code, a browser tab — is a participant. That
single idea is the whole design, and it is why the same agent code can serve a web widget and a
phone call without knowing which one it is talking to.

---

## 2. The four parts, and who runs them

People say "LiveKit" and mean one of four different things. Separate them now and most confusion
disappears.

| # | Part | What it actually is | Runs where | Your agent's relationship to it |
|---|---|---|---|---|
| 1 | **Media server** (`livekit-server`) | A Go binary. Receives audio packets and forwards them. Does *not* decode, understand, or transcribe anything | One process per node; a cluster is many of them plus Redis | It connects *to* this and gets audio from it |
| 2 | **Data model** | Rooms → participants → tracks. A vocabulary, not a program | Enforced by the media server | Your agent joins a room and subscribes to tracks |
| 3 | **Auth model** | A signed JWT that carries identity + permissions. There is no session table | Minted by **your backend**, verified by the media server | Your agent gets a token too |
| 4 | **Agents framework** (`livekit-agents`) | A Python worker pool. Registers with the server, is handed jobs, runs one call per subprocess | Your own containers, separate fleet from #1 | This *is* your agent |

The boundary that matters most: **#1 is packet plumbing and #4 is your application.** They scale
differently, fail differently, and cost differently. A media node dies of packet rate; an agent
worker dies of CPU and memory. Conflating them is how deployments get sized wrong
([`../04-self-hosting-and-scale.md`](../04-self-hosting-and-scale.md)).

### The analogy that holds up

A **conference centre**:

- The **room** is a meeting room, created the instant someone wants it and swept clean shortly
  after the last person leaves.
- A **participant** is a badge-holder in that room. The badge (**token**) says who you are and
  what you may do — talk, listen, kick people out.
- A **track** is one microphone being broadcast. **Publishing** is switching your mic on;
  **subscribing** is choosing whose mic you want in your earpiece. You subscribe per person,
  which is why one person joining doesn't cost everyone bandwidth.
- The **media server** is the AV desk: it patches mic feeds to earpieces and never listens to the
  content.
- Your **agent** is a staff member who walks into the room when the meeting starts, with their
  own badge, wearing an earpiece and holding a mic.

The analogy fails in exactly one useful place: the AV desk does not mix. Everyone's audio stays a
separate stream end to end (that is what the "F" in SFU — Selective Forwarding Unit — means). No
mixing is why LiveKit is cheap per participant and why your agent gets clean, per-speaker audio.

---

## 3. One call, traced

```mermaid
sequenceDiagram
    participant U as Browser (user)
    participant BE as Your backend
    participant LK as livekit-server<br/>:7880 signal, :7881 TCP, :7882+ UDP
    participant W as Agent worker (long-lived)
    participant J as Job process (one call)

    Note over W,LK: at boot: worker registers, reports load twice a second
    U->>BE: "start call" (your auth: cookie/session)
    BE->>BE: mint JWT with API secret (identity + roomJoin + room name)
    BE-->>U: { url, token }
    U->>LK: WebSocket connect to :7880 with token
    LK->>LK: verify signature, read grants, create room on demand
    LK-->>U: join response; SDP offer/answer; trickle ICE
    U->>LK: SRTP audio (Opus 48 kHz) over UDP
    LK->>W: job assignment (a new room exists)
    W->>J: fork a job process (or take a warm one)
    J->>LK: join the room as a participant, kind=AGENT
    LK->>J: forward the user's RTP (no transcode)
    J->>J: Opus → PCM → 16 kHz → VAD → STT → LLM → TTS
    J->>LK: publish an audio track (PCM → Opus)
    LK->>U: forward the agent's audio
```

Read three things off that diagram, because they are the three things beginners get wrong:

1. **Your backend mints the token, never the client.** The API secret is the whole security
   model; a client that can sign tokens can grant itself room-admin
   ([`../01-architecture.md`](../01-architecture.md) §2.2).
2. **The agent is dispatched after the room exists**, not before. Its job process joins as a
   second participant. That's why "why is there silence for two seconds before the greeting?" is
   a *worker* question (cold start), not a media question
   ([`../02-agents-framework.md`](../02-agents-framework.md) §2.5).
3. **Decoding happens in your process, not the server's.** The SFU forwards Opus; your job
   process turns it into PCM. That is why agent workers are CPU-hungry and media nodes are not.

---

## 4. The vocabulary, in plain language

| Term | Plain meaning | Why you care |
|---|---|---|
| **Room** | A named routing domain, created on demand | Named in the *token*, not in the connect call (§5.1) |
| **Participant** | One connected thing with an `identity` you choose | Joining twice with the same identity **displaces** the first connection |
| **Identity vs name** | `identity` = stable key; `name` = display label | Your logs, recordings and metrics should key on `identity` |
| **Attributes** | A string→string map on a participant, visible to the room | The right place for per-call state ("language=hi", "verified=true") |
| **Kind** | `STANDARD`, `AGENT`, `SIP`, `INGRESS`, `EGRESS` | Filter on kind, never on name patterns, or two agents will talk to each other |
| **Track** | One media stream (a mic, a camera) | Audio tracks carry a `source`: `microphone`, `screen_share_audio`, … |
| **Publication** | The room-level handle to someone's track | You subscribe to a publication, and subscription is per-subscriber |
| **Data channel** | Non-audio messages in the room, reliable or lossy | Live transcripts, "agent is thinking", UI state |
| **Worker / AgentServer** | The long-lived process that registers and receives jobs | Lives for days; a deploy kills it |
| **Job** | One call, in its own subprocess | A crash kills one conversation, not fifty |
| **`AgentSession`** | The voice state machine inside a job: VAD → STT → LLM → TTS + turn-taking | Where endpointing and barge-in policy live |
| **Dispatch** | How a job gets attached to a room: automatic, or explicit by `agent_name` | Two kinds of agent ⇒ you need explicit dispatch |
| **Prewarm** | Loading models in an idle process before a call arrives | Removes seconds of silence in front of the greeting |
| **Egress / Ingress** | Media out (recording, RTMP/HLS) / media in (RTMP, WHIP, URL) | Separate services; egress *does* transcode, so it is its own fleet |
| **SIP service** | The bridge that makes a phone call a participant of kind `SIP` | 8 kHz G.711 in, and that costs you WER ([`../05-telephony-sip.md`](../05-telephony-sip.md)) |
| **TURN** | A relay for users whose network blocks direct media | Without it you lose a chunk of corporate users |
| **Redis** | The room→node map and signalling bus for a multi-node cluster | A room lives on exactly one node; Redis is how any node finds it |

---

## 5. Ten facts that remove 90% of the confusion

Each one is either measured here or cited to the chapter that measures it.

### 5.1 The token decides which room you join — not your code

`room.connect(url, token)` takes no room name. The room comes from the `room` claim inside the
token. Proof: connecting with a token whose grant said `room="some-other-room"` created and
joined *that* room `[MEASURED]`:

```
grant for another room   CONNECTED  (11 ms)

$ lk --dev room list
│ RM_NZr32mijA3JY │ auth-probe      │ 0 │ 0 │
│ RM_5zSBEVGymXAJ │ some-other-room │ 0 │ 0 │
```

Consequence: a token-minting endpoint that takes the room name from the client request body is an
authorisation bug — the client can join any room it can name.

### 5.2 In grants, *absent* is not *false*

`canPublish`, `canSubscribe` and `canPublishData` are pointers in the Go source, and the comment
above them says: if none of the permissions are set explicitly, **all** publish and subscribe
permissions are granted. So a "listen-only" token that simply omits `canPublish` grants
publishing ([`../01-architecture.md`](../01-architecture.md) §2.2). Write the `false` down.

### 5.3 Your agent is a participant, so the room does not care what it is

A phone caller (`kind=SIP`), a browser (`kind=STANDARD`) and your agent (`kind=AGENT`) are the
same shape of object. Measured from a real dispatch in the lab `[MEASURED]`:

```
[sub] subscribed: tone-bot            kind=0  source=2  codec=audio/red
[sub] subscribed: agent-AJ_WpwAUWVVA6ve kind=4 source=2 codec=audio/red
```

`kind=0` is `STANDARD`, `kind=4` is `AGENT`. Two useful details fall out: the agent's default
identity is `agent-` + job id, and the negotiated codec is `audio/red` — Opus wrapped in RFC 2198
redundancy, which is LiveKit protecting speech against packet loss by sending each payload twice.

### 5.4 You choose the sample rate and frame size you receive

The SDK resamples for you. Asking for 16 kHz gives you exactly this curriculum's contract, and
`frame_size_ms` decides the frame length — the default is **10 ms**, not 20 `[MEASURED]`:

| `AudioStream(...)` | `sample_rate` | `samples_per_channel` | bytes/frame | `duration` |
|---|---|---|---|---|
| `sample_rate=16000` (default frame size) | 16000 | 160 | 320 | 10.0 ms |
| `sample_rate=16000, frame_size_ms=20` | 16000 | 320 | 640 | 20.0 ms |

640 bytes per 20 ms frame is the number every other module in this curriculum assumes
([`../../00-setup/03-canonical-formats.md`](../../00-setup/03-canonical-formats.md)). Also:
`AudioFrame.data` is **already** a `memoryview` of int16 — casting it again raises
`TypeError: memoryview: cannot cast between two non-byte formats`.

### 5.5 Rooms outlive their participants, deliberately

A room is created on demand and swept later: `departure_timeout` (20 s in the shipped config)
after the last participant leaves, or `empty_timeout` (300 s) if nobody ever joined. In the lab,
rooms from a finished test were still listed a minute later, then vanished on their own
`[MEASURED]`. So "the room still exists" is not a leak, and "my room disappeared" after five
minutes of nobody joining is not a bug.

### 5.6 Signalling is a WebSocket; media is not

Port 7880 carries the signalling WebSocket and the HTTP API. Media rides UDP (and TCP 7881 as a
fallback). From the dev server's own boot log `[MEASURED]`:

```
starting LiveKit server {"portHttp": 7880, "nodeID": "ND_5x2apdAGqYtj", "version": "1.13.7",
                         "rtc.portTCP": 7881, "rtc.portUDP": {"Start":7882,"End":0}}
```

**You can load-balance the WebSocket. You cannot load-balance the media.** The shipped config says
the ICE-over-TCP port "*cannot* be behind load balancer or TLS, and must be exposed on the node".
Putting LiveKit behind a normal HTTPS ingress is the single most common self-hosting failure
([`../04-self-hosting-and-scale.md`](../04-self-hosting-and-scale.md) §2.2).

### 5.7 There are two peer connections, not one

One for what you publish, one for what you subscribe to. That is what lets the server push a new
subscribed track by making an offer, without renegotiating your uplink. It is also why you see
two PeerConnections in `chrome://webrtc-internals` and should not panic
([`../01-architecture.md`](../01-architecture.md) §2.3).

### 5.8 Jobs are processes, and that is a feature

One call per subprocess. A native audio library that segfaults kills one conversation; a model
that blocks the GIL stalls one conversation; `job_memory_limit_mb` can cap one conversation.
`multiprocessing_context` is `spawn` (`forkserver` on Linux)
([`../02-agents-framework.md`](../02-agents-framework.md) §2.1).

### 5.9 Dev-mode defaults are wrong for production, on purpose

`load_threshold` is `inf` in dev and **0.7** in production; `num_idle_processes` is **0** in dev
and `min(ceil(cpu_count), 4)` in production. In the lab, dev mode logged exactly what that costs
`[MEASURED]`:

```
WARNING livekit.agents - no warmed process available for job, waiting for one to be created
```

Those seconds land in front of the caller's greeting. Copying a dev config into a deployment is
how you ship both a cold-start problem and no admission control
([`../02-agents-framework.md`](../02-agents-framework.md) §2.2–2.5).

### 5.10 The framework has opinions about turn-taking, and they are configurable

`AgentSession` ships with an endpointing delay (`min_delay` 0.5 s, `max_delay` 3.0 s), barge-in on
*audio* rather than words (`min_words: 0`, so a cough interrupts), and false-interruption recovery
(resume after 2.0 s with no transcript). All of it lives under `turn_handling=TurnHandlingOptions(…)`
in 1.7.0+, and every value is a product decision you should make on measured data
([`../02-agents-framework.md`](../02-agents-framework.md) §2.7,
[`../../03-turn-taking/02-endpointing.md`](../../03-turn-taking/02-endpointing.md)).

---

## 6. What LiveKit gives you, and what is still your job

| You get | You still build |
|---|---|
| Transport: WebRTC, SRTP, jitter buffers, TURN, reconnection | A token endpoint wired to *your* auth, with short TTLs |
| A room/participant/track model and a data channel | The agent's behaviour: prompts, tools, memory, escalation |
| A worker pool with dispatch, load reporting, prewarm, drain | Your own `load_fnc` if your bottleneck isn't CPU (it usually isn't) |
| A voice state machine with VAD/STT/LLM/TTS wiring and barge-in | Provider choice, and the eval harness that proves the choice |
| Telephony, egress, ingress as separate services | Consent, recording policy, PII redaction, retention |
| Metrics per turn (`transcription_delay`, `llm_node_ttft`, `tts_node_ttfb`, `e2e_latency`) | The dashboards, SLOs and alerts on top of them |

The honest summary: LiveKit removes the transport problem and gives you a sane place to put your
agent. It does not remove the product problem, the latency budget, or the operations. Those are
[`../../06-realtime-systems/`](../../06-realtime-systems/) and
[`../../08-eval-safety/`](../../08-eval-safety/).

---

## 7. Check yourself

If you can answer these without scrolling up, move to [`02-run-it-locally.md`](02-run-it-locally.md).

1. Where does the room name come from when a client connects?
2. A token omits `canPublish`. Can the holder publish?
3. Which process decodes Opus into PCM?
4. You ask for `sample_rate=16000, frame_size_ms=20`. How many bytes is a frame?
5. Your ops team wants to put the whole thing behind the standard HTTPS load balancer. What breaks?
6. Every tenth call has two seconds of silence before the greeting. Which of the four parts do you look at?
7. Two agents join the same room and start talking to each other. What did the code filter on, and what should it have filtered on?

Answers: §5.1, §5.2, §3 (the job process), §5.4 (640), §5.6, §5.9 (the worker's warm pool), §4/§5.3 (name patterns; `kind`).
