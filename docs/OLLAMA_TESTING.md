# Local engine (Ollama) — testing notes

Marty's agenda fill, summary, transcript clean-up and NL picker all run locally
through Ollama. There's no XCTest target, so the engine contract is covered by a
manual smoke test that hits a running Ollama exactly the way `OllamaEngine` does.

## Live fills are incremental (and why)

The naive approach — re-send the whole transcript and rewrite every section on
each tick — gets heavier as the meeting grows and pins the GPU, which on a 16 GB
Mac **starves WhisperKit** (transcription stalls mid-meeting). So live updates are
incremental: `OllamaEngine.fillAgendaIncremental` sends each section's *current
notes* plus only the *new transcript since the last update*, and the model merges
the new info in, returning only the sections that changed. Each pass is small and
roughly constant in cost regardless of meeting length, so the GPU frees quickly.
`AgendaFiller` fires this once ~6 new transcript lines have arrived (content-
triggered, not a timer). The one full re-read is `fillAgenda(mode:.refined)` on
stop, when WhisperKit has released the GPU — that pass is authoritative; live
drafts are best-effort previews.

`scripts/ollama_incremental_smoke.py` checks that a new snippet about one topic
updates only that section (merging into its notes), not the whole agenda.

## Run it

```bash
ollama serve                 # or: brew services start ollama
ollama pull gemma4:e2b       # live-draft model (~7.2 GB)
ollama pull gemma4:e4b       # final-polish model (~9.6 GB)
python3 scripts/ollama_engine_smoke.py
```

Exit code 0 = pass. It runs a realistic agenda + transcript through both
models/modes and asserts the JSON contract the app relies on:

- response content is valid JSON,
- `sections` maps **every** agenda id → a **string** (not a nested object),
- an undiscussed section is `""` (draft) / `"Not covered in this meeting."` (refined),
- the off-agenda tangent lands in `offAgenda`,
- refined output uses bold sub-labels (`**Decision:**`, …).

## Findings from the first local run (gemma4:e2b / e4b, 16 GB Mac)

**Content quality is strong on both models** — accurate, faithful bullets;
correct "Decision/Risk/Owner/Next step" labelling on the refined pass; undiscussed
sections handled correctly; off-agenda tangents captured.

Two prompt details turned out to be load-bearing and are now baked into
`OllamaEngine.fillAgenda` (and mirrored in the smoke test):

1. **e4b nested the value.** With an angle-bracket placeholder
   (`"<markdown content for that section>"`), `gemma4:e4b` emitted
   `"id": { "markdown content for that section": "…" }` — a nested object that
   breaks the `[String: String]` decode. Fix: describe the value as a plain
   string ("never a nested object"). A defensive `SectionValue` decoder also
   unwraps a single-key object as a fallback.

2. **e2b mirrored the example's key count.** A finite multi-key example made the
   small `gemma4:e2b` emit only that many sections. Fix: a single generic key +
   `"..."` repeat-cue, plus "include EVERY id". With a realistic multi-turn
   transcript this is reliable (5/5 sections, repeated runs).

> Heavily condensed transcripts make small models under-fill — not representative
> of real meetings, so the smoke test uses a realistic multi-turn transcript.

## Latency (rough, on a loaded 16 GB Mac)

Per full 5-section fill: `gemma4:e2b` ≈ 25–45 s, `gemma4:e4b` ≈ 55–105 s. Numbers
inflate under memory pressure. The live draft cadence (`AgendaFiller.draftInterval`)
self-throttles via the in-flight guard, so fills land when they finish rather than
queueing — expect live sections to update roughly every ~30–60 s, faster on an
unloaded machine.
