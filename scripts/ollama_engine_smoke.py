#!/usr/bin/env python3
"""
Engine-level smoke test for Marty's local agenda fill.

Hits a running Ollama exactly the way Swift's `OllamaEngine.fillAgenda` does
(POST /api/chat, stream=false, format="json", temperature 0.2, num_ctx 8192)
and validates the JSON contract the app depends on:

  - response content is valid JSON
  - "sections" maps EVERY agenda section id -> a STRING (not a nested object)
  - an undiscussed section is "" (draft) / "Not covered in this meeting." (refined)
  - off-agenda discussion lands in "offAgenda"
  - refined output uses bold sub-labels (**Decision:** etc.)

This is a manual harness (the app has no XCTest target). Run it after:
    ollama serve
    ollama pull gemma4:e2b
    ollama pull gemma4:e4b
    python3 scripts/ollama_engine_smoke.py
"""
import json, sys, time, urllib.request, urllib.error

BASE = "http://localhost:11434"

SECTIONS = [
    ("11111111-1111-1111-1111-111111111111", "Last week's metrics", "Activation, retention, and the funnel"),
    ("22222222-2222-2222-2222-222222222222", "Onboarding redesign", "Where the v2 flow stands"),
    ("33333333-3333-3333-3333-333333333333", "Pricing experiment", "Annual-plan discount test"),
    ("44444444-4444-4444-4444-444444444444", "Support backlog", "Ticket volume & staffing"),   # left UNCOVERED on purpose
    ("55555555-5555-5555-5555-555555555555", "Next steps & owners", "Action items for the week"),
]
TITLE = "Weekly Product Sync"
BACKLOG_ID = "44444444-4444-4444-4444-444444444444"

# A realistic multi-turn transcript. (A heavily condensed transcript makes small
# models like e2b under-fill — not representative of a real meeting.)
TRANSCRIPT = """[10:00:04] [You] Let's start with last week's metrics. Activation is up 4.2 points week over week to 38 percent, driven by the new onboarding checklist.
[10:00:22] [Them] Nice. What about retention?
[10:00:25] [You] D7 retention is flat at 22 percent. I suspect the email cadence, not the product itself. The signup to paid funnel still drops hardest at the workspace-invite step.
[10:01:10] [Them] Okay. Onboarding redesign — where's v2?
[10:01:15] [You] Design is locked. Engineering estimates two sprints to ship it behind a flag.
[10:01:30] [Them] Let's gate v2 to ten percent of new signups first and read activation before a full rollout.
[10:01:42] [You] Agreed. Next, the pricing experiment.
[10:01:50] [You] We want to test a 20 percent annual discount to lift conversion on the paid tier.
[10:02:05] [Them] Finance flagged margin risk if the discount applies to existing renewals.
[10:02:14] [You] Right. Decision: we run it for new annual signups only, a four-week test. Priya owns it, with finance review before launch.
[10:03:00] [You] Oh, unrelated — the office move to the new floor is happening the week of the 23rd, so plan to work from home that week.
[10:03:20] [Them] Good to know. Let's also lock next steps and owners.
[10:03:28] [You] Marcus sends the metrics deck Friday, Priya kicks off the pricing test Monday, and I'll write the v2 rollout plan."""

DRAFT_STYLE = ('Write SHORT, factual bullets that capture only what was actually said. '
    'Each section value is a markdown bullet list using "- " markers. '
    'If a section was not discussed yet, return "" (empty string). '
    'Be honest — do not invent.')

REFINED_STYLE = ('Polish each section into a clean, readable summary. Use markdown bullets ("- "). '
    'Where the discussion produced concrete elements (proposal, risk, decision, owner, next step, '
    'deadline), label the bullet with a bold prefix like "- **Decision:** …" / "- **Owner:** …". '
    'If a section was not discussed, return the exact string "Not covered in this meeting." '
    'Do not invent — only include what\'s in the transcript.')

# Mirrors OllamaEngine.fillAgenda's system prompt verbatim. Two details are
# load-bearing (see the Swift comment): a SINGLE generic key + "..." repeat-cue
# (so e2b fills every id instead of mirroring a finite example's key count), and
# a plain-string value description (so e4b doesn't nest the value in an object).
SYSTEM = """You are Marty, an editorial meeting analyst. The user has an agenda; you are filling \
in each section based on what was actually discussed in the transcript.

Respond ONLY with a JSON object, no prose around it:
{
  "sections": { "the-section-id": "markdown text for that section, as a plain string", ... },
  "offAgenda": ["short bullet of a substantive discussion that didn't map to any heading", ...]
}

The "..." means: repeat for EVERY section id in the input. Each value in "sections" is a plain \
JSON string (markdown bullet lines separated by newlines) — never a nested object or array.

Rules:
- The keys in "sections" MUST exactly match the section ids provided in the input, and you MUST include EVERY id (even if the value is "").
- %STYLE%
- "offAgenda" captures topics that consumed real meeting time but don't belong under any heading. Empty array if everything mapped.
- Never invent facts, decisions, or quotes not in the transcript."""

def payload():
    return json.dumps({"title": TITLE, "sections": [
        {"id": i, "heading": h, "subheading": s, "originalBullets": []} for (i, h, s) in SECTIONS]},
        sort_keys=True)

def call(model, style):
    system = SYSTEM.replace("%STYLE%", style)
    user = f"AGENDA:\n{payload()}\n\nTRANSCRIPT:\n{TRANSCRIPT}"
    body = {"model": model, "stream": False, "format": "json",
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "options": {"temperature": 0.2, "num_ctx": 8192}}
    req = urllib.request.Request(BASE + "/api/chat", data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=400) as r:
        content = json.loads(r.read())["message"]["content"]
    return content, time.time() - t0

def check(model, mode, style):
    issues = []
    try:
        content, dt = call(model, style)
    except urllib.error.URLError as e:
        return [f"request failed (is `ollama serve` running, and `{model}` pulled?): {e}"], 0.0
    try:
        parsed = json.loads(content)
    except Exception as e:
        return [f"content not valid JSON: {e}"], dt
    secs = parsed.get("sections", {})
    nonstr = {k: type(v).__name__ for k, v in secs.items() if not isinstance(v, str)}
    if nonstr:
        issues.append(f"non-string section values (breaks Swift [String:String]): {nonstr}")
    ids = {i for (i, _, _) in SECTIONS}
    if not ids.issubset(secs.keys()):
        issues.append(f"missing ids: {ids - set(secs.keys())}")
    if set(secs.keys()) - ids:
        issues.append(f"hallucinated ids: {set(secs.keys()) - ids}")
    backlog = secs.get(BACKLOG_ID)
    if mode == "draft" and backlog not in ("", None):
        issues.append(f"undiscussed section should be empty in draft, got {backlog!r}")
    if mode == "refined" and backlog != "Not covered in this meeting.":
        issues.append(f"undiscussed section should be 'Not covered…' in refined, got {backlog!r}")
    oa = " ".join(parsed.get("offAgenda", [])).lower()
    if not any(w in oa for w in ("office", "floor", "move")):
        issues.append("offAgenda did not capture the office-move tangent")
    if mode == "refined" and "**" not in " ".join(str(v) for v in secs.values()):
        issues.append("refined output missing bold sub-labels (**Decision:** etc.)")
    print(f"  {mode:8} {model:14} {dt:6.1f}s  {'PASS' if not issues else 'FAIL'}")
    for i in issues:
        print(f"      - {i}")
    return issues, dt

if __name__ == "__main__":
    print("Marty · Ollama agenda-fill smoke test")
    failures = 0
    failures += 1 if check("gemma4:e2b", "draft", DRAFT_STYLE)[0] else 0
    failures += 1 if check("gemma4:e4b", "refined", REFINED_STYLE)[0] else 0
    sys.exit(1 if failures else 0)
