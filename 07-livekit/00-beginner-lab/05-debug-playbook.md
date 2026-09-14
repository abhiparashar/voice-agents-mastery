# Debug Playbook

Symptom → cause → command. Every error string here was produced on this machine on 2026-09-14
against `livekit-server` 1.13.7 / `lk` 2.18.6 / `livekit-agents` 1.8.1 `[MEASURED]`, except where
marked `[INFERENCE]`.

---

## 1. Connection and auth

The server returns 401 with a *specific* message for every auth failure. Learn these four:

| Server says | Cause | Fix |
|---|---|---|
| `invalid authorization token: token signature is invalid` | The secret used to sign ≠ the secret the server has | Compare the exact strings; a trailing newline in a `.env` counts |
| `invalid API key` | The `iss` claim names a key the server does not know | Check `keys:` in `config.yaml`; in dev the pair is `devkey`/`secret` |
| `invalid authorization token: token has invalid claims: token is expired` | TTL elapsed, or client/server clock skew | Shorten mint-to-use time; check NTP on both ends |
| `permissions denied` | Token is valid but lacks the grant for this action (e.g. no `roomJoin`) | Print the decoded grants; remember absent ≠ false for publish/subscribe |

**First three commands, in order:**

```bash
curl -s http://127.0.0.1:7880/                                     # → OK   (server alive)
curl -s -o /dev/null -w '%{http_code}\n' \
  "http://127.0.0.1:7880/rtc/validate?room=$ROOM&access_token=$TOKEN"   # → 200 or 401
lk --dev room list                                                 # → does the room exist?
```

`/rtc/validate` separates "my token is wrong" from "my media is wrong" in one request, without a
browser.

**Client connects but joins the wrong room.** Expected: the room comes from the token's `room`
claim, not from your code. A token grant for `some-other-room` connected in 11 ms and created
that room `[MEASURED]`.

**Warning `InsecureKeyLengthWarning: The HMAC key is 6 bytes long`** — PyJWT complaining about the
dev secret `secret`. Harmless locally; if you see it in production your API secret is too short.

---

## 2. No audio (the classic)

Work outward from the agent:

1. **Is a track published at all?** `lk --dev room participants list --room <room>` and check the
   publisher count in `lk --dev room list`. Zero publishers ⇒ the problem is upstream of LiveKit.
2. **Is your side subscribed?** Log `track_subscribed`. A participant with `canSubscribe` omitted
   *can* subscribe; one with it explicitly `false` cannot, and gets no error, just silence.
3. **Are frames arriving?** Count them (L2 in [`03-small-projects.md`](03-small-projects.md)).
   Frames arriving but RMS ≈ 0 means a muted mic or a client-side gain problem, not transport.
4. **One-way audio, remote users only, works on your laptop.** This is ICE. UDP is blocked
   somewhere; you need TURN, and the ICE-over-TCP port must be exposed on the node and not behind
   TLS termination or an HTTP load balancer
   ([`../04-self-hosting-and-scale.md`](../04-self-hosting-and-scale.md) §2.2).
5. **Audio works, then dies after ~30 s.** Look for a proxy or LB idle timeout on the signalling
   WebSocket `[INFERENCE]` — the media may survive while signalling dies, which breaks
   renegotiation and reconnect.
6. **Agent hears the caller but the caller hears nothing.** The agent published no track, or
   published it before joining. Check for `publish_track` errors and for a `TTS` that never
   flushed.

Useful: `codec=audio/red` in `track_subscribed` is normal — Opus wrapped in RFC 2198 redundancy,
i.e. each payload sent twice for loss resilience.

---

## 3. The agent never joins

```
# Worker healthy?
… registered worker {"agent_name": "", "id": "AW_…", "url": "ws://…", "protocol": 17}
```

| Observation | Cause |
|---|---|
| No `registered worker` line at all | Wrong `LIVEKIT_URL`/key/secret in the worker env, or no `agent: true` in its token path. The worker connects **outbound**; no inbound port is needed |
| `registered worker` but no `received job request` when a room appears | `agent_name` is set ⇒ **explicit dispatch**. Name the agent in the user's token or call `AgentDispatch.createDispatch` |
| `received job request` then nothing | Your `request_fnc` rejected it, or the entrypoint raised before `ctx.connect()`. `reject(terminate=True)` is final: no other worker is offered the job |
| Job assigned to nobody under load | Every worker reported load above `load_threshold` (prod default 0.7), or none accepted inside `ASSIGNMENT_TIMEOUT = 7.5 s` |
| Two agents answer one room | Two workers with automatic dispatch (empty `agent_name`) both registered |
| Agents talk to each other | You filtered participants by name instead of `kind`. `DEFAULT_PARTICIPANT_KINDS = [CONNECTOR, SIP, STANDARD]` exists for this |

**Silence before the greeting.** Look for this line `[MEASURED]`:

```
WARNING livekit.agents - no warmed process available for job, waiting for one to be created
```

In the lab that cost 669 ms between `received job request` and `session started` with a trivial
agent; with a real model load it is seconds. Fix: `num_idle_processes` ≥ 1 plus a `prewarm_fnc`
that loads models into `proc.userdata` ([`../02-agents-framework.md`](../02-agents-framework.md)
§2.5).

**The no-code dispatch test.** You do not need a browser or a script to prove dispatch works —
`lk` can be the participant `[MEASURED]`:

```
$ lk --dev room join --identity probe lab-3
INFO  lk  connected to room  {"room": "lab-3"}
INFO  lk  participant connected  {"kind": 4, "participant": "agent-AJ_KYyWhZ6BzmLX"}
```

`kind: 4` is your agent arriving. If `lk` connects and no agent shows up, the fault is in the
worker or the dispatch configuration, never in your client code.

---

## 4. `livekit-agents` 1.7.0 → 1.8.1 deltas

The parent chapters are written against **1.7.0**. Verified differences in **1.8.1**, from the
published wheel and the lab run:

| Thing | State in 1.8.1 |
|---|---|
| `WorkerOptions` / `Worker` | Still work: `WorkerOptions = ServerOptions`, `WorkerType = ServerType` aliases in `worker.py`. `AgentServer` is the current name |
| `turn_detection=` kwarg | **Deprecated.** Logs `turn_detection is deprecated and will be removed in v2.0. Use turn_handling=TurnHandlingOptions(...) instead` `[MEASURED]`. Keys: `turn_detection`, `endpointing`, `interruption`, `preemptive_generation`, `user_turn_limit` |
| Endpointing defaults | Unchanged: `min_delay` 0.5, `max_delay` 3.0, `alpha` 0.9; tighter (0.3 / 2.5) when a streaming turn detector is used |
| Default VAD | `AgentSession` now defaults to `inference.VAD(model="silero")` — a **local** Silero via `livekit-local-inference`, no key, ~4.4 ms CPU per second of audio at 32 inferences/s `[MEASURED]`. Pass `vad=None` to opt out |
| Adaptive interruption | New, and **on by default in dev/hosted mode**, off in production mode. It calls LiveKit **Cloud** (`wss://agent-gateway.livekit.cloud/v1/bargein`) |
| `conversation_item_added` | `ev.item` may be an `AgentHandoff`, not only a `ChatMessage`. `ev.item.role` then raises `AttributeError: 'AgentHandoff' object has no attribute 'role'` `[MEASURED]` — `isinstance` first |
| CLI | `console`, `dev`, `start`, `download-files`. `console` is marked deprecated in favour of `lk agent console` |
| `console` mode | Runs with **no server and no credentials**: logs `{"id": "unregistered"}`, uses `job_id: mock-job-…` in room `console-room` `[MEASURED]` |

### The adaptive-interruption trap, in full

Running `python agent.py dev` against a **self-hosted** server produces this, three times, ~4.5 s
of retries `[MEASURED]`:

```
WARNING livekit.agents - failed to detect interruption, retrying in 2.0s: failed to connect to
  LiveKit Adaptive Interruption (caused by WSServerHandshakeError: 401, message='Invalid response
  status', url='wss://agent-gateway.livekit.cloud/v1/bargein')
INFO    livekit.agents - adaptive interruption disabled due to unrecoverable error, falling back
  to VAD-based interruption
```

Nothing is broken — the framework tried a Cloud service your dev keys cannot authenticate to and
fell back. To silence it and keep barge-in local:

```python
AgentSession(..., turn_handling={"interruption": {"mode": "vad"}})
```

Verified: with that set, the lab run shows no gateway warnings at all `[MEASURED]`.

---

## 5. Turn-taking symptoms

| Symptom | Where to look |
|---|---|
| Agent cuts the user off | `endpointing.min_delay` too low for your traffic; measure the frontier ([`../../03-turn-taking/02-endpointing.md`](../../03-turn-taking/02-endpointing.md)) |
| Long dead air before replies | `min_delay`/`max_delay` too high, or your STT commits late. `eou_metrics.transcription_delay` tells you which |
| A cough stops the agent | `interruption.min_words` is 0 by default: barge-in fires on audio, not words. Raise to 1–2 |
| Agent interrupts itself | Echo. AEC belongs on the client; the framework's 3 s `aec warmup active, disabling interruptions` at session start exists for this ([`../../03-turn-taking/05-echo-and-aec.md`](../../03-turn-taking/05-echo-and-aec.md)) |
| Agent resumes a sentence oddly | `resume_false_interruption` (default true, 2 s): VAD fired, no transcript followed, so it carried on |
| Two deployments endpoint differently on identical code | `turn_detection` auto-selects `realtime_llm → vad → stt → manual` based on what you configured; adding a VAD changes the strategy |

---

## 6. Rooms and lifecycle

| Question | Answer |
|---|---|
| "My room still exists after everyone left" | `departure_timeout` (20 s in the shipped config) |
| "My room vanished and nobody joined" | `empty_timeout` (300 s) |
| "A second connection with the same identity killed the first" | By design: identity is unique per room |
| "`lk room list` shows rooms I never created" | Rooms are created on demand by the first join — including a join with a token naming a room you did not intend |

---

## 7. When it is not LiveKit

Before blaming the transport, check the three things that produce LiveKit-shaped symptoms:

1. **Provider latency.** `llm_metrics.ttft` and `tts_metrics.ttfb` are per-turn. A p95 spike there
   looks exactly like "the agent is laggy".
2. **Event-loop starvation.** A blocking model call in the job process stalls the audio reader and
   drops frames. Anything CPU-bound goes in an executor
   ([`../03-writing-plugins.md`](../03-writing-plugins.md) §2.6).
3. **Your own retries.** `APIConnectOptions` defaults (3 retries, 2 s apart, 10 s timeout) can add
   tens of seconds inside a live call.

---

## 8. Commands worth memorising

```bash
livekit-server --dev --bind 127.0.0.1                 # dev server: devkey/secret, :7880
lk --dev token create --join --room r --identity u --valid-for 10m --token-only
lk --dev room list
lk --dev room participants list --room r
lk --dev room join --identity probe lab-3              # a real participant, no code at all
lk --dev room send-data --room r --topic t '{"hello":1}'   # DATA is positional
python agent.py console                               # mic + speakers, no server
python agent.py dev                                   # dev worker: no warm pool, no admission control
python agent.py start                                 # production: thr 0.7, warm pool, health :8081
```
