# Status: complete

The curriculum described in `README.md` is finished. All **57 files** in the README manifest
exist — 55 chapters, one mini-projects list, plus `00-setup/bootstrap.sh` — totalling roughly
**271,000 words**, with **377 exercises** and a worked answer for every one.

There is no remaining work queued. This file is now a record of what was built and how, for
whoever picks it up next.

---

## What exists

| Module | Files | State |
|---|---|---|
| `README.md` | 1 | authoritative map; chapter count and answer count verified against the tree |
| `00-setup/` | 5 + `bootstrap.sh` | complete |
| `01-foundations/` | 5 | complete |
| `02-asr/` | 9 | complete |
| `03-turn-taking/` | 5 | complete |
| `04-tts/` | 5 | complete |
| `05-llm-layer/` | 5 | complete |
| `06-realtime-systems/` | 8 | complete |
| `07-livekit/` | 6 | complete |
| `08-eval-safety/` | 3 | complete |
| `09-mastery/` | 5 | complete |

Verified mechanically at the end of the final session: every file in the README manifest
exists; **zero broken relative links** across all 58 markdown files; every `## 3. From scratch`
listing runs; and the 377 exercise IDs in the chapters match the 377 answer IDs in
`09-mastery/03-answers.md` exactly, with no gaps and no orphans.

---

## The process that produced it

Worth preserving, because it is what made the material trustworthy.

- **One file at a time, written directly, no subagents.** Parallel authoring lost work and hit
  rate limits; sequential single-threaded writing did not.
- **Measure before writing.** Each chapter began as a throwaway script in `/tmp/vam`, run to
  produce real numbers, and the prose was written around those numbers rather than the reverse.
- **Verify every published listing after writing.** Extract the ```python block from the
  finished markdown, run it, diff against the documented output. This caught real errors,
  including a misaligned output column and two wrong conclusions.
- **Verify API and spec facts from primary source** — raw GitHub files, PyPI JSON, RFC text,
  the arXiv API — before asserting them.

### Four corrections the process forced

These are recorded because each was a plausible, widely-repeated claim that measurement
falsified. They are listed in `09-mastery/03-answers.md` too.

1. **"Terminate media at the edge, run models centrally" is wrong.** With central inference the
   media edge lies on the geodesic to the model region, so by the triangle inequality it cannot
   reduce mouth-to-ear latency, and with sparse edges it *increases* it — 756 ms mean against
   730 ms for a single central region. This had been asserted in two earlier chapters
   (`06-realtime-systems/02` §5 and `06-realtime-systems/05` §5) before being measured in
   `06-realtime-systems/08`; both were corrected.
2. **Golden audio cannot be gated on a waveform or per-bin spectral metric.** The first version
   of that measurement ranked a benign TTS re-run as *more* changed than a real formant
   regression. The mel-band formulation replaced it, and an inaudible 62 µs shift is now shown
   scoring worse on RMS (0.05298) than a genuine 2% formant shift (0.04586).
3. **Python 3.12 is pinned because of `audioop`, not kokoro.** Kokoro 0.9.4 declares
   `Requires-Python: <3.13`, and `uv run --with` installs and imports it on 3.13.13 anyway — the
   declared bound does not protect you. What actually breaks is `audioop`, removed in 3.13 under
   PEP 594.
4. **`sounddevice` bundles PortAudio.** Verified `PortAudio V19.7.0-devel` from the wheel, so
   `brew install portaudio` is unnecessary despite near-universal advice to the contrary.

### One deliberate deviation from the original spec

Five files are reference artefacts rather than chapters and do not carry the seven-part
format: `00-setup/05-bootcamp-coverage.md` (a syllabus mapping table, pre-existing),
`00-setup/04-reading-list.md` (books, 40 papers, 15 repositories),
`09-mastery/02-mastery-checklist.md` (138 scored capability statements),
`09-mastery/04-glossary.md` (237 terms), and `09-mastery/05-mini-projects.md` (added
2026-09-13: 33 single-concept, 30 min–2 hr projects mapped to specific chapters, distinct
from the five multi-week capstones in `00-setup/05-bootcamp-coverage.md` §12).
`09-mastery/03-answers.md` is likewise exempt from the
1800–4500 word guidance, since it answers 377 exercises. Several chapters also run above 4500
words; density was preferred over the cap where the extra words were verified facts, tables or
source citations.

---

## Environment the measurements were taken on

Apple M5, 10 cores (4P + 6E), 16 GiB unified memory, macOS 26.5.2 (build 25F84), `arm64`,
MPS available and **no CUDA**. `uv` 0.11.19; system Python is 3.9.6 so every listing runs under
`uv run --python 3.12 ...`. CPython 3.12.13, `numpy` 2.5.2, `torch` 2.13.0, `torchaudio` 2.11.0,
`scipy` 1.18.1, `soxr` 1.1.0, PortAudio V19.7.0-devel via `sounddevice` 0.5.6. No paid API keys
were used for any measurement.

Reproduce the bench with `00-setup/bootstrap.sh`, which extracts the doctor script from
`00-setup/01-environment.md` so there is exactly one copy of it.

---

## If you extend it

- **Keep the contracts.** Audio is 16 kHz mono s16le, 20 ms = 320 samples = 640 bytes; metric
  names are fixed (`t_eou`, `stt_final`, `ttft_llm`, `first_clause`, `ttfb_tts`, `ttfa`,
  `eou_to_ttfa`, `wer`, `endpoint_f1`, `interruption_rate`, `barge_in_latency`). Both are
  asserted by the doctor and used by every chapter.
- **Exercise IDs are `E<module>.<chapter>.<n>`.** Two chapters violated this and were
  normalised (`00-setup/03` used `E0.n`, `02-asr/02` had trailing periods). Any new exercise
  needs an answer in `09-mastery/03-answers.md`; the one-to-one check is a three-line script and
  worth keeping in CI.
- **Prices are stamped.** Everything published was retrieved 2026-08-22 and is marked
  `[UNVERIFIED PRICE]` where it could not be re-confirmed. Re-date them before quoting.
- **Version-pinned facts will drift.** `livekit-agents` 1.7.0, `pipecat-ai` 1.7.0,
  `moshi` 0.2.13 and the OTel GenAI conventions (which moved repositories mid-project and are
  still marked Development) are the most likely to move. Read the published wheel, never `main`.
