# Eight Small Projects

Confidence comes from having debugged something, not from having read about it. These are ordered
so each one fails in a *new* way, and every one runs against `livekit-server --dev` on your
laptop. Six of the eight need **no vendor keys**.

How to use them: build L0–L3 in your first week, L4–L7 in your second. Do not skip L0 — almost
every production LiveKit incident is a token or dispatch problem, and those are L0 and L5.

| | Project | Time | Keys? | The one thing it teaches |
|---|---|---|---|---|
| **L0** | Token service + verifier | 2–3 h | no | Auth is your problem, not LiveKit's |
| **L1** | Room inspector CLI | 3–4 h | no | The server API, and rooms as a lifecycle |
| **L2** | Audio meter bot | 3–4 h | no | The PCM contract and frame accounting |
| **L3** | Two-provider voice agent | 1 day | yes | Where your latency actually goes |
| **L4** | Transcript sidecar | 1 day | yes/no | The data plane, and per-turn metrics |
| **L5** | Dispatch lab | half day | no | Explicit dispatch, `request_fnc`, job metadata |
| **L6** | Cold-start measurement | half day | no | Prewarm, warm pools, and perceived latency |
| **L7** | Drain drill | half day | no | Deploys with live calls, and `SIGTERM` |

---

## L0 — Token service, and a verifier that says why

**Build.** An HTTP endpoint `POST /token` that returns `{ url, token }` for the *authenticated*
caller, plus a CLI `verify <token>` that decodes it, checks the signature, and prints every grant
in English ("may join room `clinic-4821`; may publish microphone only; expires in 4m59s").

**Rules that make it real.**
- The room name is derived **server-side** from the caller's session — never taken from the
  request body. You reproduced why in [`02-run-it-locally.md`](02-run-it-locally.md) §3.
- TTL in minutes, not the 6-hour default.
- `canPublishSources=["microphone"]`, and `canPublish=False` written **explicitly** wherever you
  mean listen-only, because absent ≠ false.

**Accept.**
1. A token minted by your service joins a dev server; `/rtc/validate` returns 200 for it and 401
   after its TTL passes.
2. Your verifier prints, for a "listen-only" token with `canPublish` *omitted*, that publishing
   **is** allowed — and your service never mints one.
3. A caller who asks for someone else's room gets their own room, proven by `lk --dev room list`.

**Trap.** Base64url in JWTs carries no padding; a hand-rolled decoder must add it back. See the
stdlib implementation in [`../01-architecture.md`](../01-architecture.md) §3 — write yours, then
diff.

---

## L1 — Room inspector CLI

**Build.** `rooms ls`, `rooms show <room>`, `rooms kick <room> <identity>`,
`rooms mute <room> <identity>` against the server API (`livekit.api.LiveKitAPI`), plus a
`--watch` mode that prints participant join/leave as it happens.

**Accept.**
1. `rooms show` prints every participant's `identity`, `kind`, `attributes` and published tracks.
2. `kick` removes a participant and your own connected test client observes the disconnect reason.
3. Your `--watch` output shows a room being **created on demand** and disappearing ~20 s after
   the last participant leaves (`departure_timeout`), and a room created but never joined
   disappearing after `empty_timeout`.
4. You can state, from your own output, which operations need `roomAdmin` versus `roomList`.

**Trap.** The API client needs a token with server-wide grants, not a join token. If `rooms ls`
returns "permissions denied", that is the lesson, not a bug.

---

## L2 — Audio meter bot

**Build.** A participant (no agent framework) that subscribes to every `STANDARD` participant's
microphone and prints, once per second: frames received, expected frames, dropped/late frames,
peak dBFS, and running duration. Then publish a 1 kHz tone back so you can hear yourself.

**Accept.**
1. With `sample_rate=16000, frame_size_ms=20` you assert `samples_per_channel == 320` and
   `len(bytes(frame.data)) == 640` on every frame, and the assertion never fires over 60 s.
2. Frames received over 60 s is within 1% of 3000, and you explain any gap (it is jitter buffer
   and RED, not lost audio).
3. Your dBFS reading matches an independently computed value for a synthetic tone of known
   amplitude (amplitude 12000 ⇒ RMS ≈ 8485 ⇒ ≈ −11.7 dBFS).
4. It filters on `participant.kind`, so pointing two meter bots at one room does not make them
   measure each other.

**Trap.** `AudioFrame.data` is already an int16 `memoryview`; `memoryview(frame.data).cast("h")`
raises `TypeError: memoryview: cannot cast between two non-byte formats`.

---

## L3 — Two-provider voice agent, measured

**Build.** Take `keyless_agent.py` from the lab and replace the fakes with real providers — but
build **two** configurations (e.g. Deepgram + GPT-4o-mini + Cartesia, and a second stack swapping
any one layer). Same prompt, same turn-handling config.

**Accept.**
1. A table over ≥ 30 turns per stack: `end_of_utterance_delay`, `transcription_delay`,
   `llm_metrics.ttft`, `tts_metrics.ttfb`, and their sum, p50 and p95, taken from
   `metrics_collected` — not from a stopwatch.
2. You state which stack wins, by how much, and which *layer* the difference came from.
3. Swapping a provider touches exactly one line of your code.
4. Cost per 1000 minutes for each stack, from published prices, with the date you retrieved them.

**Trap.** `APIConnectOptions` defaults to 3 retries × 2 s against a 10 s timeout — sane for a
chat backend, absurd inside a live call. Set your own, sized to your turn budget
([`../03-writing-plugins.md`](../03-writing-plugins.md) §2.5).

---

## L4 — Transcript sidecar

**Build.** Stream live transcripts and agent state to the client over the room's **data plane**,
and write a per-call JSONL: one record per turn with the transcript, the metrics report, and the
tool calls. A ten-line HTML page that shows the running transcript is the client.

**Accept.**
1. Interim and final transcripts render differently in the page, and finals never arrive out of
   order.
2. Transcripts are sent **lossy** and agent-state pings lossy; only the end-of-call summary is
   reliable — and you can explain why in one sentence (head-of-line blocking under congestion,
   [`../../06-realtime-systems/01-transports.md`](../../06-realtime-systems/01-transports.md)).
3. The JSONL for a 2-minute call reconstructs the whole conversation, with `e2e_latency` per turn.
4. A redaction rule (say, digit strings) is applied in **both** `transcription_node` and
   `tts_node`, and you show a test that fails when only one is patched.

**Trap.** `conversation_item_added` can carry an `AgentHandoff`, not only a `ChatMessage`;
`ev.item.role` raises `AttributeError` on it. Measured in the lab — see
[`05-debug-playbook.md`](05-debug-playbook.md) §4.

---

## L5 — Dispatch lab

**Build.** Two workers with different `agent_name` values ("greeter" and "specialist"). Route by
naming the agent in the end-user's token *and* by `AgentDispatch.createDispatch`. Implement
`request_fnc` to reject jobs whose `job.metadata` fails validation, and to set a stable
participant identity.

**Accept.**
1. With `agent_name` set, no automatic dispatch happens: a room created without naming an agent
   gets **no** agent, proven by the worker log staying silent.
2. A token naming `greeter` brings exactly one greeter; `lk token create --agent` and
   `--job-metadata` both work against your worker.
3. `reject(terminate=True)` is shown to be final — the job is not offered to your second worker.
4. Your agent's participant identity is your own value, not `agent-<job id>`, and it shows up in
   `lk --dev room participants list --room <room>`.

**Trap.** Setting `agent_name` silently switches off automatic dispatch. Every "my agent stopped
joining rooms" report starts here ([`../02-agents-framework.md`](../02-agents-framework.md) §2.4).

---

## L6 — Cold-start measurement

**Build.** Run the keyless agent with `num_idle_processes` ∈ {0, 1, 2} and a `prewarm_fnc` that
sleeps a configurable 0.5–3 s (standing in for a model load). Drive 30 calls per configuration
with a script, and extract *job request → session started* from the logs.

**Accept.**
1. A table of p50/p95 job-start latency per configuration, and the fraction of calls that paid a
   cold start.
2. You state the memory cost per idle process, measured with `ps`, and the resulting
   memory-versus-latency tradeoff at your target concurrency.
3. You show the `no warmed process available for job` warning disappearing as the warm pool grows.
4. You state what happens when `prewarm_fnc` exceeds `initialize_process_timeout` (10 s) — and
   you demonstrate it.

**Trap.** In dev mode `num_idle_processes` defaults to 0 and `load_threshold` to `inf`, so the
laptop measurement of "how many calls can one worker take" is meaningless without setting both.
The simulation in [`../02-agents-framework.md`](../02-agents-framework.md) §3 gives the shape to
expect: no warm pool ⇒ 100% of jobs pay ~2.5 s; two idle processes ⇒ 1%.

---

## L7 — Drain drill

**Build.** Start a call, then `SIGTERM` the worker mid-conversation. Add an
`add_shutdown_callback` that writes the call summary, and make the agent say a closing line if it
is being drained.

**Accept.**
1. The in-flight call **keeps audio to the end** — no truncation — and no *new* jobs are accepted
   after the signal.
2. `drain_timeout` is set to something sane for your call-length distribution (the default is
   3600 s), and you justify the number from your own p99 call duration.
3. Your shutdown callback's write is present for every drained call, including one where you
   deliberately make it slow, and you state what `shutdown_process_timeout` (10 s) does to it.
4. A second `SIGTERM` during drain is handled the way you intend, and you show the log.

**Trap.** Post-call work belongs in `add_shutdown_callback`, not at the end of your entrypoint;
if a caller hangs up first, code after `await session.start(...)` may never run.

---

## When these feel easy

Move to [`04-large-project.md`](04-large-project.md), then the tiered ladder in
[`../../PROJECTS.md`](../../PROJECTS.md): **C4** turns L2+L3 into real local plugins, **S1** is a
production-grade agent, **S6** is telephony, **F1** is the platform. The chapters those projects
draw on are listed in each entry.
