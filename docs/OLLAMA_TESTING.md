# Local engine (Ollama) — testing notes

Marty's agenda fill, summary, transcript clean-up and NL picker all run locally
through Ollama. There's no XCTest target, so the engine contract is covered by a
manual smoke test that hits a running Ollama exactly the way `OllamaEngine` does.

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
