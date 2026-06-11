#!/usr/bin/env python3
"""Validate AnthropicEngine's agenda-fill contract against the real API —
the cloud mirror of ollama_incremental_smoke.py, same SYSTEM prompts, same
fixtures, same assertions.

Case 1 (incremental, claude-haiku-4-5): a new snippet about ONE topic should
update only that section, append-only, values plain strings.
Case 2 (refined full fill, claude-sonnet-4-6): every section id present,
undiscussed sections get the exact "Not covered in this meeting." string.

Usage: ANTHROPIC_API_KEY=sk-ant-... python3 scripts/anthropic_incremental_smoke.py
"""
import json, os, sys, time, urllib.request

API = "https://api.anthropic.com/v1/messages"
KEY = os.environ.get("ANTHROPIC_API_KEY", "")
LIVE_MODEL = "claude-haiku-4-5"
REFINE_MODEL = "claude-sonnet-4-6"

# Section ids (same fixtures as the Ollama smoke).
M = "11111111-1111-1111-1111-111111111111"  # metrics (already has notes)
O = "22222222-2222-2222-2222-222222222222"  # onboarding (empty; the snippet is about this)
P = "33333333-3333-3333-3333-333333333333"  # pricing (empty / never discussed)

SECTIONS = [
    {"id": M, "heading": "Last week's metrics", "subheading": "Activation, retention",
     "currentNotes": "- Activation up 4.2 pts WoW to 38%, from the new onboarding checklist."},
    {"id": O, "heading": "Onboarding redesign", "subheading": "Where v2 stands", "currentNotes": ""},
    {"id": P, "heading": "Pricing experiment", "subheading": "Annual discount", "currentNotes": ""},
]
NEW_SNIPPET = """[10:01:15] [Them] On the onboarding redesign — v2 design is locked.
[10:01:20] [You] Engineering says two sprints to ship behind a flag.
[10:01:30] [Them] Let's gate it to ten percent of new signups first and read activation."""

# Mirrors AgendaFillPrompts.incrementalSystem verbatim.
INCREMENTAL_SYSTEM = """You are Marty, an editorial meeting analyst updating a meeting agenda LIVE as new \
transcript arrives. You are given each agenda section with its CURRENT notes, and a NEW \
snippet of transcript since the last update. Extract what the snippet ADDS.

Respond ONLY with a JSON object, no prose around it:
{
  "sections": { "the-section-id": "- first new point\\n- second new point\\n- third new point", ... },
  "offAgenda": ["a new tangent from the snippet that fit no heading", ...]
}

Rules:
- Return ONLY the sections the new snippet adds something to. OMIT every section the snippet \
doesn't change. (Most snippets touch one or two sections.)
- For a changed section, capture EVERY new fact, decision or next step from the snippet as \
its own "- " line — one bullet per spoken point, as many as the snippet contains. Do NOT \
repeat any point already in its currentNotes; the app appends what you return to the \
existing notes.
- Each value is a plain JSON string — never a nested object or array. The "..." means \
repeat for each CHANGED section only.
- Short, factual, only what was actually said. Never invent.
- "offAgenda" holds only NEW tangents from this snippet; empty array if none."""

# Mirrors AgendaFillPrompts.fullSystem(mode: .refined) verbatim.
REFINED_STYLE = """Polish each section into a clean, readable summary. Use markdown bullets ("- "). \
Where the discussion produced concrete elements (proposal, risk, decision, owner, \
next step, deadline), label the bullet with a bold prefix like \
"- **Decision:** …" / "- **Owner:** …" / "- **Risk:** …" / "- **Next step:** …". \
If a section was not discussed, return the exact string "Not covered in this meeting." \
Do not invent — only include what's in the transcript."""

FULL_SYSTEM = f"""You are Marty, an editorial meeting analyst. The user has an agenda; you are filling \
in each section based on what was actually discussed in the transcript.

Respond ONLY with a JSON object, no prose around it:
{{
  "sections": {{ "the-section-id": "markdown text for that section, as a plain string", ... }},
  "offAgenda": ["short bullet of a substantive discussion that didn't map to any heading", ...]
}}

The "..." means: repeat for EVERY section id in the input. Each value in "sections" is a plain \
JSON string (markdown bullet lines separated by newlines) — never a nested object or array.

Rules:
- The keys in "sections" MUST exactly match the section ids provided in the input, and you \
MUST include EVERY id (even if the value is "").
- {REFINED_STYLE}
- "offAgenda" captures topics that consumed real meeting time but don't belong under \
any heading. Empty array if everything mapped.
- Never invent facts, decisions, or quotes not in the transcript."""

FULL_TRANSCRIPT = """[10:00:05] [You] Quick status on last week's numbers first.
[10:00:12] [Them] Activation is up four point two points week over week, to thirty-eight percent. The new onboarding checklist is doing the work.
""" + NEW_SNIPPET


def strip_fences(t):
    t = t.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t
    if t.endswith("```"):
        t = t[:-3].strip()
    return t


def call(model, system, user, max_tokens):
    body = {"model": model, "max_tokens": max_tokens, "system": system,
            "messages": [{"role": "user", "content": user}]}
    req = urllib.request.Request(API, data=json.dumps(body).encode(), headers={
        "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=120) as r:
        env = json.loads(r.read())
    text = next(c["text"] for c in env["content"] if c["type"] == "text")
    return strip_fences(text), time.time() - t0


def case_incremental():
    payload = json.dumps({"sections": SECTIONS}, sort_keys=True)
    user = f"AGENDA SECTIONS (id, heading, current notes):\n{payload}\n\nNEW TRANSCRIPT SNIPPET (integrate only this):\n{NEW_SNIPPET}"
    text, dt = call(LIVE_MODEL, INCREMENTAL_SYSTEM, user, 1024)
    p = json.loads(text)
    secs = p.get("sections", {})
    changed = set(secs.keys())
    nonstr = [k for k, v in secs.items() if not isinstance(v, str)]
    no_echo = "Activation up 4.2" not in str(secs.get(O, ""))
    print(f"[incremental/{LIVE_MODEL}] latency {dt:.1f}s, returned ids: {len(changed)}")
    print(f"  touched onboarding (expected): {O in changed}")
    print(f"  left metrics untouched (expected): {M not in changed}")
    print(f"  left pricing untouched (expected): {P not in changed}")
    print(f"  all values strings: {not nonstr}")
    print(f"  no echo of existing notes (append-only): {no_echo}")
    for k, v in secs.items():
        name = {M: "metrics", O: "onboarding", P: "pricing"}.get(k, k)
        print(f"  [{name}] {str(v)[:160]}")
    return O in changed and M not in changed and not nonstr and no_echo


def case_refined():
    payload = json.dumps({"title": "Weekly product sync", "sections": [
        {"id": s["id"], "heading": s["heading"], "subheading": s["subheading"], "originalBullets": []}
        for s in SECTIONS]}, sort_keys=True)
    user = f"AGENDA:\n{payload}\n\nTRANSCRIPT:\n{FULL_TRANSCRIPT}"
    text, dt = call(REFINE_MODEL, FULL_SYSTEM, user, 8192)
    p = json.loads(text)
    secs = p.get("sections", {})
    all_ids = {M, O, P} <= set(secs.keys())
    nonstr = [k for k, v in secs.items() if not isinstance(v, str)]
    pricing_not_covered = secs.get(P, "") == "Not covered in this meeting."
    onboarding_filled = bool(secs.get(O, "").strip()) and secs.get(O) != "Not covered in this meeting."
    print(f"[refined/{REFINE_MODEL}] latency {dt:.1f}s, returned ids: {len(secs)}")
    print(f"  every id present: {all_ids}")
    print(f"  all values strings: {not nonstr}")
    print(f"  pricing marked not covered (exact string): {pricing_not_covered}")
    print(f"  onboarding filled: {onboarding_filled}")
    return all_ids and not nonstr and pricing_not_covered and onboarding_filled


def main():
    if not KEY:
        print("Set ANTHROPIC_API_KEY first."); sys.exit(2)
    ok1 = case_incremental()
    ok2 = case_refined()
    print("RESULT:", "PASS" if (ok1 and ok2) else "CHECK")
    sys.exit(0 if (ok1 and ok2) else 1)


main()
