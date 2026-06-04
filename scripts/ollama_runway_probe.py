#!/usr/bin/env python3
"""Measure the per-fill "runway" of OllamaEngine.fillAgendaIncremental.

Replicates the exact prompt the app builds (system + AGENDA SECTIONS payload +
NOTES SO FAR + 6-line delta) at three meeting stages — early (empty notes),
mid (~10 min of notes), late (~30 min of notes) — and reports Ollama's own
metrics per request:

  prompt_eval_count / duration  -> prefill (how much is read, how long)
  eval_count / duration         -> decode  (how much is generated, how long)
  load_duration                 -> model load spike (the "video stutter")

Run:  python3 scripts/ollama_runway_probe.py [model]   (default gemma4:e2b)
"""

import json
import sys
import time
import urllib.request
import uuid

BASE = "http://localhost:11434"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "gemma4:e2b"

HEADINGS = [
    ("Q3 roadmap priorities", "What ships, what slips"),
    ("Hiring plan", "Backend + design headcount"),
    ("Budget review", "Burn vs plan"),
    ("Customer feedback themes", "Top issues from support"),
    ("Launch comms", "Timeline and owners"),
]

# A realistic spoken bullet, ~15 words.
BULLET = "- {topic}: team agreed the {n} option needs another pass before we commit to it"

DELTA_LINES = [
    "[14:1{i}:0{i}] [Them] So on the budget side we are tracking about twelve percent over on cloud spend this quarter.",
    "[14:1{i}:1{i}] [You] Right, and most of that is the new inference cluster we spun up in April.",
    "[14:1{i}:2{i}] [Them] Exactly, so the proposal is to reserve instances for the baseline and keep spot for bursts.",
    "[14:1{i}:3{i}] [You] That should claw back maybe seven percent if the usage pattern holds.",
    "[14:1{i}:4{i}] [Them] Finance wants a decision by Friday so it lands in the Q3 forecast.",
    "[14:1{i}:5{i}] [You] Okay, let's take reserving the baseline as the working decision and flag it to Priya.",
]


def make_sections(bullets_per_section: int):
    sections = []
    for heading, sub in HEADINGS:
        notes = "\n".join(
            BULLET.format(topic=heading.split()[0], n=i + 1) for i in range(bullets_per_section)
        )
        sections.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "heading": heading,
                "subheading": sub,
                "currentNotes": notes,
            }
        )
    return sections


def build_prompt(sections):
    """Mirror fillAgendaIncremental exactly: payload JSON + NOTES SO FAR + delta."""
    payload_json = json.dumps({"sections": sections}, sort_keys=True)

    system = """You are Marty, an editorial meeting analyst updating a meeting agenda LIVE as new \
transcript arrives. You are given each agenda section with its CURRENT notes, and a NEW \
snippet of transcript since the last update. Integrate ONLY the new snippet.

Respond ONLY with a JSON object, no prose around it:
{
  "sections": { "the-section-id": "the FULL updated notes for that section, as a plain string", ... },
  "offAgenda": ["a new tangent from the snippet that fit no heading", ...]
}

Rules:
- Return ONLY the sections the new snippet actually adds to. OMIT every section the snippet \
doesn't change. (Most snippets touch one or two sections.)
- For a changed section, return its FULL updated notes: keep the existing points and merge \
the new info in. Do not duplicate points already present. Do not drop existing points.
- Each value is a plain JSON string of markdown bullet lines ("- " markers) — never a nested \
object or array. The "..." means repeat for each CHANGED section only.
- Short, factual, only what was actually said. Never invent.
- "offAgenda" holds only NEW tangents from this snippet; empty array if none."""

    # Mirrors the current fillAgendaIncremental: notes ride in the payload JSON
    # only (the duplicate "NOTES SO FAR" block was removed after this probe
    # flagged it).
    delta = "\n".join(line.format(i=k) for k, line in enumerate(DELTA_LINES))

    user = f"""AGENDA SECTIONS (id, heading, current notes):
{payload_json}

NEW TRANSCRIPT SNIPPET (integrate only this):
{delta}"""
    return system, user


def chat(system, user):
    body = {
        "model": MODEL,
        "stream": False,
        "format": "json",
        "think": False,  # matches the app's live path (gemma4 is a thinking model)
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "options": {"temperature": 0.2, "num_ctx": 8192},
    }
    req = urllib.request.Request(
        BASE + "/api/chat",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    wall = time.time() - t0
    return data, wall


def ns(x):
    return (x or 0) / 1e9


def main():
    stages = [
        ("minute-2 (empty notes)", 0),
        ("minute-10 (~8 bullets/section)", 8),
        ("minute-30 (~20 bullets/section)", 20),
    ]
    print(f"model={MODEL}  ctx=8192  delta=6 lines (fixed)\n")
    header = f"{'stage':<34} {'in-tok':>7} {'out-tok':>8} {'load s':>7} {'prefill s':>10} {'decode s':>9} {'wall s':>7} {'#sects':>7}"
    print(header)
    print("-" * len(header))

    for label, bullets in stages:
        sections = make_sections(bullets)
        system, user = build_prompt(sections)
        data, wall = chat(system, user)

        in_tok = data.get("prompt_eval_count", -1)
        out_tok = data.get("eval_count", -1)
        load_s = ns(data.get("load_duration"))
        prefill_s = ns(data.get("prompt_eval_duration"))
        decode_s = ns(data.get("eval_duration"))

        try:
            content = json.loads(data["message"]["content"])
            n_sections = len(content.get("sections", {}))
        except Exception:
            n_sections = -1

        print(
            f"{label:<34} {in_tok:>7} {out_tok:>8} {load_s:>7.1f} {prefill_s:>10.1f} {decode_s:>9.1f} {wall:>7.1f} {n_sections:>7}"
        )

    print(
        "\nin-tok = prompt tokens read (prefill: system + sections payload + delta)"
        "\nout-tok = tokens generated (full rewrite of changed sections + any echoes)"
        "\nload s = one-time model load (pre-warmed at record-start in the app); ~0 when warm"
        "\n#sects = sections the model returned (should be 1-2; more = echoing)"
    )


if __name__ == "__main__":
    main()
