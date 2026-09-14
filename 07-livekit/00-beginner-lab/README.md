# Beginner Lab: LiveKit from zero

The six chapters beside this folder are written for someone who already knows what an SFU is.
This folder is the on-ramp: **plain-language mental model first, then a local lab you actually
run, then a project ladder**. It teaches nothing the parent chapters contradict — it is the same
material at a lower slope, with every command verified on this machine.

> Everything marked `[MEASURED]` in these files was run on **2026-09-14**, macOS `arm64`
> (Apple M5), against `livekit-server` **1.13.7** (Homebrew `livekit`), `livekit-cli` (`lk`)
> **2.18.6**, `livekit-agents` **1.8.1**, the Python realtime SDK `livekit` **1.1.18**, and
> `livekit-plugins-azure` / `livekit-plugins-google` **1.8.1**, all under CPython 3.12.13.
> **No paid API keys were used.** The parent chapters are pinned to `livekit-agents` 1.7.0;
> [`05-debug-playbook.md`](05-debug-playbook.md) §4 lists every behaviour that changed between
> 1.7.0 and 1.8.1 so you never have to guess which is current.

## Read in this order

| File | What it gives you | Time |
|---|---|---|
| [`01-livekit-in-plain-words.md`](01-livekit-in-plain-words.md) | The mental model: four processes, one call traced end to end, the vocabulary, and the ten facts that remove 90% of beginner confusion | 45 min read |
| [`02-run-it-locally.md`](02-run-it-locally.md) | A seven-step lab: dev server, tokens, a participant that measures PCM, a **full `AgentSession` with zero API keys**, dispatch observed in the logs | 2–3 h hands-on |
| [`03-small-projects.md`](03-small-projects.md) | Eight small projects (2 h → 1 day each) with acceptance criteria, in confidence-building order | 2 weeks |
| [`04-large-project.md`](04-large-project.md) | One large project — a self-hosted appointment desk on web **and** phone — cut into eight milestones you can ship one at a time | 6–10 weeks |
| [`05-debug-playbook.md`](05-debug-playbook.md) | Symptom → cause → command. Real error strings, the 1.7.0→1.8.1 deltas, and the traps that cost a day each | reference |
| [`06-your-stack-india.md`](06-your-stack-india.md) | **Start here if you ship on self-hosted LiveKit + Azure Speech + Gemini in India.** The region facts checked, the full agent, your own `livekit.yaml`, and the exact failure logs of this stack | 1 h read, 2 weeks to work through |
| [`07-provider-landscape.md`](07-provider-landscape.md) | The whole field: cascade vs speech-to-speech, all 75 official plugins, hosted **and** open-source options per layer, who hosts in which region, and four worked "what would I choose" answers | 1 h read |
| [`08-production-and-observability.md`](08-production-and-observability.md) | The twelve levers production teams pull for latency, and the three observability planes — Prometheus, **OpenTelemetry traces into Langfuse** (verified span tree), structured logs, plus the PII switch | 1 h read, 1 day to wire |

## Then graduate

Each file ends with links into the deep chapters. The full sequence, once this folder feels easy:

1. [`../01-architecture.md`](../01-architecture.md) — the data model, every grant field, signalling
2. [`../02-agents-framework.md`](../02-agents-framework.md) — the three lifetimes, dispatch, load, prewarm
3. [`../03-writing-plugins.md`](../03-writing-plugins.md) — the STT/TTS/LLM/VAD contracts
4. [`../04-self-hosting-and-scale.md`](../04-self-hosting-and-scale.md) — topology, Redis, TURN, cost crossover
5. [`../05-telephony-sip.md`](../05-telephony-sip.md) — trunks, SIP, DTMF
6. [`../06-alternatives.md`](../06-alternatives.md) — when LiveKit is the wrong answer

And [`../../PROJECTS.md`](../../PROJECTS.md) for the 27-project ladder this folder feeds into:
project **C4** (`livekit-local-plugins`), **S1** (production voice agent), **S6** (telephony),
**F1** (the platform).

## What this folder is not

It is not a tutorial that ends at "hello world with an API key". Every listing here runs with
**no vendor account**, because the goal is that you understand the *transport and worker* layer
— which is the part your company runs and the part a tutorial cannot fake. Real STT/LLM/TTS
providers are a one-line swap once that layer is solid, and
[`03-small-projects.md`](03-small-projects.md) L3 is where you do it.
