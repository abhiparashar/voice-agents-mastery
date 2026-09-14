# Production: Low Latency, Logging, Tracing, Langfuse

**What you'll be able to do after this:** name every place a voice agent spends time and the lever
that shortens it; wire your agent's traces into Langfuse (or Jaeger, Grafana, LiveKit Cloud — same
protocol) in about fifteen lines; and know what production teams actually watch, alert on, and
argue about.

Measured on this machine 2026-09-14 with `livekit-agents` **1.8.1** unless marked otherwise.

---

## 1. Where the time goes

One turn, from "the caller stops talking" to "the caller hears a word", broken into the pieces you
can actually change:

| # | Piece | Typical | Who decides it |
|---|---|---|---|
| 1 | Caller's network + jitter buffer | 20–60 ms | Their Wi-Fi, your TURN placement |
| 2 | **Silence wait (endpointing)** | 300–700 ms | **You.** `turn_handling.endpointing.min_delay` |
| 3 | STT final transcript lag | 50–300 ms | Vendor + how you segment |
| 4 | LLM time-to-first-token | 200–800 ms | Model size, region, prompt length, caching |
| 5 | Text→first speakable clause | 0–100 ms | The framework's sentence splitter |
| 6 | TTS time-to-first-byte | 80–400 ms | Vendor, streaming or not, first-sentence length |
| 7 | Playout + network back | 40–120 ms | Physics |
| 8 | **Cold start, on some calls** | 0 or 700–3000 ms | **You.** Warm pool size |

Two of the eight are *entirely your choice* (2 and 8) and they are usually the biggest. That is
the whole reason beginners chase model benchmarks and get nowhere: **the silence you wait and the
process you didn't warm up dominate the model you argued about.**

From the lab, with deliberately trivial models so only the framework's own overhead shows
`[MEASURED]`:

```
eou_metrics  end_of_utterance_delay=0.3000  transcription_delay=0.0
llm_metrics  ttft=0.00010   duration=0.0740
tts_metrics  ttfb=0.0068    audio_duration=2.59
cold start   job request 20:20:30.022 -> session started 20:20:30.691   (669 ms, no warm pool)
```

`end_of_utterance_delay` came out at exactly the 0.3 s configured. The framework adds almost
nothing; everything else is your providers and your config.

---

## 2. The twelve levers production teams actually pull

Ordered by how much they buy, per unit of work.

1. **Put the models in the region the audio is in.** A cross-ocean round trip is ~250 ms, paid
   twice per turn (request and response). Your Azure `centralindia` + Vertex `asia-south1`
   choice already does this; forgetting `location=` undoes it silently
   ([`06-your-stack-india.md`](06-your-stack-india.md) §2).
2. **Warm processes.** `num_idle_processes` ≥ 1 plus a `prewarm_fnc` that loads models into
   `proc.userdata`. Dev mode's default is 0 — the 669 ms above, or seconds with a real model.
3. **Tune the silence wait on your own recordings**, don't inherit 500 ms. Then add a **turn
   detector** (`livekit-plugins-turn-detector`) so you can be *fast* on clearly-finished
   sentences and *patient* on "my number is… uh…". 1.8.1 already tightens the defaults to
   `min_delay 0.3 / max_delay 2.5` when a streaming turn detector is configured `[MEASURED from
   source]`.
4. **Start generating before the turn is confirmed.** 1.8.1 ships
   `preemptive_generation` **enabled** with `preemptive_tts=False`, `max_speech_duration=10.0`,
   `max_retries=3` `[MEASURED from source]`. Tokens are cheap to throw away; audio is not — which
   is exactly why audio is off by default.
5. **Keep the first sentence short.** With a non-streaming TTS (Azure's plugin is
   `TTSCapabilities(streaming=False)` `[MEASURED]`) your first audio waits for the first sentence
   to synthesise. "Sure, one moment." then the detail. This is free latency.
6. **Stable system prompt = prefix caching.** Put everything fixed at the top and never
   interpolate a timestamp into it, or you invalidate the cache on every call and pay full prefill
   ([`../../05-llm-layer/04-serving-llms-fast.md`](../../05-llm-layer/04-serving-llms-fast.md)).
7. **Turn thinking off for live calls.** `thinking_config={"thinking_budget": 0}` on Gemini. The
   caller cannot hear reasoning; they can hear the delay.
8. **Prewarm connections, not just processes.** 1.8.1's `LLM.prewarm()` exists to do DNS + TLS
   before the first token: "Establishes DNS resolution and the TLS connection to the provider
   before the first inference request" — called automatically when an `AgentSession` is built
   `[MEASURED from source]`.
9. **No retries inside a live call.** `APIConnectOptions` defaults to 3 retries, 2 s apart, 10 s
   timeout. Pass your own turn-sized budget and accept a graceful "sorry, say that again" instead
   of 30 s of dead air.
10. **Speak while you work.** Filler speech before a slow tool, and start the retrieval during the
    user's turn rather than after it
    ([`../../05-llm-layer/03-tools-and-agentic.md`](../../05-llm-layer/03-tools-and-agentic.md),
    [`../../05-llm-layer/02-context-and-memory.md`](../../05-llm-layer/02-context-and-memory.md)).
11. **Cache fixed audio.** Greetings, hold messages, disclosures, IVR menus — synthesise once,
    replay bytes. On a phone-heavy product this is both latency and a visible chunk of the TTS
    bill.
12. **Run at under ~70% utilisation.** Queueing theory, not opinion: past that, p95 explodes while
    the mean still looks fine ([`../../01-foundations/04-latency-budget.md`](../../01-foundations/04-latency-budget.md)).
    Also why `load_threshold` defaults to 0.7 in production mode, not 0.95.

**And the one anti-lever:** don't chase the mean. Callers experience p95. A 600 ms mean with a
2.5 s p95 feels broken, because the caller remembers the two seconds of nothing.

---

## 3. Observability, three planes

You need all three, and they answer different questions:

| Plane | Question it answers | Where it comes from |
|---|---|---|
| **Metrics** | "Is the fleet healthy right now?" | Prometheus on `livekit-server` and on the worker |
| **Traces** | "What happened in *that* call, turn by turn?" | OpenTelemetry out of `livekit-agents` → Langfuse / Jaeger / Tempo / LiveKit Cloud |
| **Logs** | "What exactly did the code do and which line failed?" | Structured JSON logs, correlated by `job_id` and `room` |

### 3.1 Metrics

The media server exposes Prometheus when you set `prometheus_port`. Verified on the self-hosted
config from [`06-your-stack-india.md`](06-your-stack-india.md) §6 `[MEASURED]`:

```bash
$ curl -s http://127.0.0.1:6789/metrics | grep -c '^livekit_'
270
$ curl -s http://127.0.0.1:6789/metrics | grep '^livekit_forward_latency'
livekit_forward_latency{node_id="ND_JSxa5cpTpLf9",node_type="SERVER"} 0
```

The worker has its own: set `prometheus_port` in `WorkerOptions`/`ServerOptions` and it serves
`/metrics`; the health endpoint is `port` (8081 in production mode).

Per-turn model metrics arrive in your process as events — these four names are what you graph,
and all four were observed in the lab `[MEASURED]`:

| Event `type` | Fields you will actually use |
|---|---|
| `eou_metrics` | `end_of_utterance_delay`, `transcription_delay`, `on_user_turn_completed_delay` |
| `llm_metrics` | `ttft`, `duration`, `completion_tokens`, `prompt_tokens`, `prompt_cached_tokens`, `tokens_per_second` |
| `tts_metrics` | `ttfb`, `duration`, `audio_duration`, `characters_count`, `cancelled` |
| `vad_metrics` | `inference_count`, `inference_duration_total`, `idle_time` |

`prompt_cached_tokens` is the one nobody watches and everybody should: it tells you whether your
prefix cache is working, i.e. whether lever #6 is real or imaginary.

### 3.2 Traces — and this is the good part

`livekit-agents` 1.8.1 is instrumented with **OpenTelemetry** end to end: `telemetry/traces.py`
imports the OTLP HTTP exporters for **traces, logs and metrics**, and span attributes follow the
**GenAI semantic conventions** (`gen_ai.*`) plus LiveKit's own `lk.*`
`[MEASURED from the published wheel]`.

Which means: **any OTLP-compatible backend works, and LiveKit Cloud is simply one of them** — its
own endpoints in the source are `…/observability/traces/otlp/v0`, `…/logs/otlp/v0`,
`…/metrics/otlp/v0`.

Fifteen lines is the entire integration:

```python
from livekit.agents.telemetry import set_tracer_provider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def setup_tracing() -> None:
    provider = TracerProvider()
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint="http://127.0.0.1:4318/v1/traces"))
    )
    set_tracer_provider(
        provider,
        metadata={"lk.deployment": "lab"},   # stamped on every span
        allow_pii=True,                      # see §3.4 before you ship this
    )


async def entrypoint(ctx: JobContext) -> None:
    setup_tracing()
    await ctx.connect()
    ...
```

Before paying for a backend, look at what you are about to send. This receiver is the whole
debugging tool — it speaks the same protocol Langfuse does:

```python
"""A 40-line OTLP/HTTP trace receiver, so you can see exactly what your agent exports."""

from http.server import BaseHTTPRequestHandler, HTTPServer

from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        req = ExportTraceServiceRequest()
        req.ParseFromString(body)
        for rs in req.resource_spans:
            for ss in rs.scope_spans:
                for span in ss.spans:
                    attrs = {kv.key: str(kv.value)[:60].strip() for kv in span.attributes}
                    keep = {k: v for k, v in attrs.items()
                            if k.startswith(("gen_ai", "lk.response", "lk.eou",
                                             "lk.function_tool.name", "lk.agent_label"))}
                    print(f"SPAN {span.name:34s} {keep}", flush=True)
        self.send_response(200)
        self.send_header("content-type", "application/x-protobuf")
        self.end_headers()
        self.wfile.write(b"")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print("otlp sink on :4318", flush=True)
    HTTPServer(("127.0.0.1", 4318), Handler).serve_forever()
```

I ran exactly that, with exactly the `setup_tracing()` above, and drove one call. This is the
**real** span tree, verbatim `[MEASURED]`:

```
SPAN agent_session          gen_ai.operation.name=invoke_workflow  gen_ai.workflow.name=agent_session
SPAN start_agent_activity   gen_ai.operation.name=create_agent  gen_ai.agent.name=default_agent
                            gen_ai.request.model=echo-v0  gen_ai.conversation.id=RM_VBmEbH2kfNkj
SPAN on_enter               lk.agent_label=default_agent
SPAN tts_request / tts_request_run / tts_stream_adapter
SPAN tts_node               gen_ai.request.model=tone-v0  lk.response.ttfb=0.00524
SPAN agent_speaking
SPAN agent_turn             gen_ai.operation.name=invoke_agent
SPAN user_speaking
SPAN user_turn              gen_ai.request.model=energy-v0  gen_ai.provider.name=local
SPAN llm_request            gen_ai.operation.name=chat  gen_ai.request.stream=true
                            gen_ai.usage.input_tokens=0  gen_ai.usage.output_tokens=0
                            gen_ai.response.id=13b4d33c75ed  gen_ai.response.finish_reasons=[stop]
                            gen_ai.response.time_to_first_chunk=0.00119
                            gen_ai.system_instructions="[{\"type\": \"text\", \"content\": \"You are…
                            gen_ai.input.messages=…  gen_ai.output.messages=…
SPAN llm_node               lk.response.ttft=0.00178
SPAN on_exit / drain_agent_activity
```

Read that tree once and you understand why tracing beats logging for this problem: **one call is
one trace, one turn is one `agent_turn` span, and the four latencies hang off it as attributes.**
"Why was that call slow?" stops being an archaeology project.

### 3.3 Langfuse specifically

Langfuse ingests OTLP over HTTP, so it needs no special SDK — you point the same exporter at it.
Verified from Langfuse's own docs (retrieved 2026-09-14):

- Endpoint: `https://cloud.langfuse.com/api/public/otel` (EU), `https://us.cloud.langfuse.com/…`
  (US), `https://jp.cloud.langfuse.com/…` (Japan). Signal-specific traces path is
  `/api/public/otel/v1/traces`.
- Auth is **HTTP Basic** with your project keys: `echo -n "pk-lf-…:sk-lf-…" | base64`.
- OTLP **HTTP only** — no gRPC.

```bash
AUTH=$(echo -n "pk-lf-PUBLIC:sk-lf-SECRET" | base64)
export OTEL_EXPORTER_OTLP_ENDPOINT="https://cloud.langfuse.com/api/public/otel"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic ${AUTH},x-langfuse-ingestion-version=4"
```

```python
# in code, if you prefer explicit over environment
OTLPSpanExporter(
    endpoint="https://cloud.langfuse.com/api/public/otel/v1/traces",
    headers={"Authorization": f"Basic {AUTH}"},
)
```

**For your India constraint: Langfuse is open source — self-host it in your own VPC** and the
transcripts in those `gen_ai.input.messages` attributes never leave your infrastructure. That is
the version to propose internally, because §3.4 explains what is in those attributes.

Why teams like it for voice agents: each call becomes a trace with the prompt, the reply, the tool
calls, token counts and latency on every span; you can score sessions, and you can point a
non-engineer at a URL instead of a log query. What it does *not* replace: the fleet metrics in
§3.1 (that stays Prometheus/Grafana) and audio (Langfuse holds text, not waveforms — keep
recordings in object storage and put the URL in a span attribute or a tag).

Alternatives with the same wiring, since it is all OTLP: **Jaeger** or **Grafana Tempo** for pure
tracing, **Grafana/Prometheus** for metrics, **LiveKit Cloud observability** if you ever move off
self-hosting, and the LLM-observability crowd (Arize Phoenix, Braintrust, W&B Weave, Helicone,
LangSmith) which mostly accept OTLP too `[INFERENCE — verify the endpoint for whichever you pick]`.

### 3.4 The privacy switch you must not skip

Those spans carry the conversation: `gen_ai.system_instructions`, `gen_ai.input.messages`,
`gen_ai.output.messages`, and LiveKit's own `lk.pii.*` attributes (`lk.pii.user_input`,
`lk.pii.room_name`, `lk.pii.function_tool.arguments`, …). If your backend is outside your
compliance boundary, that is a data export nobody approved.

`set_tracer_provider(..., allow_pii=False)` strips content in-process before every exporter.
Verified by running the same call twice `[MEASURED]`:

| Attribute | `allow_pii=True` | `allow_pii=False` |
|---|---|---|
| `gen_ai.system_instructions` | present | **absent** |
| `gen_ai.input.messages` | present | **absent** |
| `gen_ai.output.messages` | present | **absent** |
| `gen_ai.response.time_to_first_chunk` | 0.00119 | 0.00053 (still there) |
| `gen_ai.request.model`, token counts, `finish_reasons` | present | present |

So you keep every number you need for latency and cost work, and lose only the words. Default it
to `False`, and switch it on deliberately — per environment, ideally only in staging, or in
production only with the retention and access rules written down
([`../../08-eval-safety/03-safety-and-privacy.md`](../../08-eval-safety/03-safety-and-privacy.md)).

### 3.5 Logs

Rules that survive contact with a real incident:

- **JSON in production** (`logging: {json: true}` on the server; the worker's logger already
  attaches `pid`, `job_id` and `room` to every line — that is your correlation key).
- **Log the config at session start**, especially regions and provider names. The silent
  residency bug in [`06-your-stack-india.md`](06-your-stack-india.md) §8 is only catchable this way.
- **One line per turn** with the four latencies, even if you also have traces. Log queries survive
  when your tracing backend is the thing that is down.
- **Never log raw transcripts by default.** Hash or truncate; gate full text behind the same flag
  as `allow_pii`.
- **Keep the stack traces.** `SESSION ERROR` events with vendor error objects (see the Azure 401
  examples) are worth more than any dashboard on day one.

### 3.6 Outcomes, not just latency

1.8.1 has a first-class place to record what *happened* in a call — `ctx.tagger`
`[MEASURED from source]`:

```python
ctx.tagger.success(reason="appointment booked")
ctx.tagger.fail(reason="user hung up before confirming")
ctx.tagger.add("language:hi")
ctx.tagger.add("appointment:booked", metadata={"slot_id": "abc123"})
```

Latency is a proxy; **task success is the product**. If you only build one dashboard, build
"percentage of calls that achieved the caller's goal, by day, by language, by cohort" — and put
`tagger` calls at every decisive branch so that dashboard is free.

---

## 4. What to graph and what to page on

| Dashboard | Panels that earn their space |
|---|---|
| **Caller experience** | p50/p95 of the four turn latencies; barge-in rate; false-interruption rate; calls with any silence > 3 s |
| **Fleet** | Active sessions per worker; worker load vs `load_threshold`; cold-start fraction; job rejections; media-node packet loss and jitter |
| **Providers** | Error rate and p95 per provider; retry counts; `prompt_cached_tokens` ratio |
| **Business** | Calls, containment/success rate from `tagger`, escalation rate, ₹ per successful call |

Page a human for: job rejection rate up (capacity), provider error rate up (vendor), p95
end-to-end past SLO for N minutes (quality), Redis unavailable (the cluster cannot route), calls
with zero audio (the ICE/TURN failure nobody notices because the calls *connect*).

Do **not** page on: single-call latency spikes, a cold start, one 500 from a vendor with a
successful retry. Alert fatigue kills on-call faster than outages.

---

## 5. Testing and evals, briefly

- **Regression suite on recorded audio.** WAV in, transcript + metrics out, thresholds from
  distributions rather than feelings ([`../../08-eval-safety/01-testing.md`](../../08-eval-safety/01-testing.md)).
- **Simulated callers** for load and for adversarial behaviour — interrupting, silent, angry,
  code-switching ([`../../08-eval-safety/02-simulation-and-load.md`](../../08-eval-safety/02-simulation-and-load.md)).
- **1.8.1 ships an `evals` module and a `testing` module**; there is a home for this inside the
  framework rather than beside it.
- **Score sessions in your tracing backend** (Langfuse supports scores) so quality trends live
  next to latency trends.

---

## 6. How production teams actually run this

Patterns you will recognise in any mature deployment, and the reason for each:

1. **Two fleets, scaled separately.** Media nodes scale on packet rate, agent workers on CPU and
   memory. Same autoscaler for both is the classic sizing mistake.
2. **Workers in the region of the models, media where the callers are.** The media path and the
   model path have different geographies, and LiveKit lets you split them.
3. **Explicit dispatch from day one.** `agent_name` set, routing chosen in the token or via the
   dispatch API — because the second kind of agent always arrives, and migrating later is worse.
4. **Deploys drain, never cut.** `SIGTERM` → stop accepting, finish live calls, exit. Blue/green
   with a drain window sized to p99 call length.
5. **A second provider behind the same interface, config-switchable.** When a vendor has a bad
   hour you flip an environment variable. Teams that hard-code one provider take the outage.
6. **Per-tenant keys, per-tenant cost attribution.** Room `attributes` and span metadata carry the
   tenant so the bill and the SLO can be sliced.
7. **Phrase caches and pre-rendered audio** for everything scripted.
8. **A recorded-call review ritual.** Five random calls a week, listened to by a human, with the
   trace open beside the audio. Every team that does this finds bugs no metric showed.
9. **Runbooks per failure mode**, written before the incident: agent not dispatching, one-way
   audio, provider 401/429, Redis down, cost spike.
10. **Cost per successful call on the same dashboard as latency**, because every latency
    improvement has a price and somebody will eventually ask what it was.

---

## 7. Your next three concrete steps

1. Add the fifteen lines in §3.2 to your agent, point them at a **self-hosted Langfuse** in your
   VPC, and start with `allow_pii=False`.
2. Add `prometheus_port` to both `livekit.yaml` and your `WorkerOptions`, and build the
   *caller-experience* panel first — the four latencies at p95, nothing else.
3. Put `ctx.tagger.success()` / `.fail()` at the two places your call can end well or badly, so
   that in a month you can answer "is it working?" with a number instead of an opinion.

Deeper treatments: [`../../06-realtime-systems/06-observability.md`](../../06-realtime-systems/06-observability.md)
(metric taxonomy, SLOs, OTel GenAI conventions),
[`../../06-realtime-systems/07-reliability.md`](../../06-realtime-systems/07-reliability.md)
(failure modes and drills),
[`../../06-realtime-systems/08-deployment.md`](../../06-realtime-systems/08-deployment.md)
(containers, regions, blue/green with live calls).
