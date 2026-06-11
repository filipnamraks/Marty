#!/usr/bin/env python3
"""Validate AnthropicEngine's agenda-fill contract against the real API.
Mirrors the SYSTEM prompts in AgendaFillPrompts.swift verbatim.

Case 1 (incremental, claude-haiku-4-5): a new snippet about ONE topic should
update only that section, append-only, values plain strings, and every bullet
must be a standalone point (no 4-word fragments).
Case 2 (incremental straddle, claude-haiku-4-5): a snippet that finishes one
topic and starts the next must SPLIT across both sections.
Case 3 (big chunk, claude-haiku-4-5): a dense 12-line snippet — the
AgendaFiller.maxLinesPerFill worst case — must come back as valid JSON well
inside the 2048-token cap (stop_reason must not be max_tokens).
Case 4 (refined full fill, claude-sonnet-4-6): every section id present,
undiscussed sections get the exact "Not covered in this meeting." string.

Usage: ANTHROPIC_API_KEY=sk-ant-... python3 scripts/anthropic_incremental_smoke.py
"""
import json, os, sys, time, urllib.request

API = "https://api.anthropic.com/v1/messages"
KEY = os.environ.get("ANTHROPIC_API_KEY", "")
LIVE_MODEL = "claude-haiku-4-5"
REFINE_MODEL = "claude-sonnet-4-6"

# Section ids
M = "11111111-1111-1111-1111-111111111111"  # metrics (already has notes)
O = "22222222-2222-2222-2222-222222222222"  # onboarding (empty)
P = "33333333-3333-3333-3333-333333333333"  # pricing (empty / never discussed)

SECTIONS = [
    {"id": M, "heading": "Last week's metrics", "subheading": "Activation, retention",
     "originalBullets": ["How did activation move after the checklist?", "Retention cohorts"],
     "currentNotes": "- Activation up 4.2 pts WoW to 38%, driven by the new onboarding checklist."},
    {"id": O, "heading": "Onboarding redesign", "subheading": "Where v2 stands",
     "originalBullets": ["Design status", "Engineering estimate", "Rollout plan"],
     "currentNotes": ""},
    {"id": P, "heading": "Pricing experiment", "subheading": "Annual discount",
     "originalBullets": ["Annual discount test results"],
     "currentNotes": ""},
]

CONTEXT_LINES = """[10:00:55] [You] So the checklist is clearly working for activation.
[10:01:02] [Them] Agreed, let's keep it as the default flow.
[10:01:08] [You] Okay, next up."""

NEW_SNIPPET = """[10:01:15] [Them] On the onboarding redesign — v2 design is locked.
[10:01:20] [You] Engineering says two sprints to ship behind a flag.
[10:01:30] [Them] Let's gate it to ten percent of new signups first and read activation."""

# Straddle: first line closes out metrics, rest opens onboarding.
STRADDLE_CONTEXT = """[10:00:40] [You] Retention is the other number I wanted to flag.
[10:00:48] [Them] Go on."""
STRADDLE_SNIPPET = """[10:00:55] [You] Week-four retention slipped two points to 61 percent, mostly in the free tier.
[10:01:05] [You] Anyway, onboarding redesign. The v2 design is locked as of yesterday.
[10:01:12] [Them] And engineering thinks two sprints to ship it behind a flag."""

# Mirrors AgendaFillPrompts.incrementalSystem verbatim.
INCREMENTAL_SYSTEM = """You are Marty, an editorial meeting analyst updating a meeting agenda LIVE as new \
transcript arrives. You are given the agenda sections (each with the user's prepared \
bullets and its CURRENT notes), a few lines of RECENT CONTEXT that have already been \
processed, and a NEW snippet of transcript. Extract what the NEW snippet adds.

Respond ONLY with a JSON object, no prose around it:
{
  "sections": { "the-section-id": "- first new point\\n- second new point\\n- third new point", ... },
  "offAgenda": ["a new tangent from the snippet that fit no heading", ...]
}

Routing rules:
- Return ONLY the sections the new snippet adds something to. OMIT every section the \
snippet doesn't change. (Most snippets touch one or two sections.)
- Meetings usually move through the agenda roughly in order, and a speaker usually \
continues the most recently updated section until they clearly shift. Use the RECENT \
CONTEXT to tell whether the snippet continues the previous thought or starts a new one. \
A snippet CAN split across two sections when the speaker moves on mid-snippet.
- When content could fit more than one section, the user's prepared bullets \
("originalBullets") define each section's intended angle — file it under the section \
whose prepared bullets it speaks to.
- "offAgenda" holds only NEW tangents from this snippet that genuinely fit no section; \
empty array if none.
- Do NOT extract anything from the RECENT CONTEXT lines — they are already filed; they \
exist only to show what the speaker was mid-way through.

Writing rules:
- Each bullet must STAND ALONE: someone who missed the meeting should fully understand \
the point from the bullet alone. Capture the what AND the why/outcome — names, numbers, \
reasons — in roughly 10–25 words. Never a bare fragment like "- used local models".
- Live speech arrives fragmented across lines; merge the fragments into complete points \
rather than echoing them line by line.
- One distinct spoken point per "- " line, as many lines as the snippet contains. Do NOT \
repeat any point already in a section's currentNotes; the app appends what you return \
to the existing notes.
- Each value is a plain JSON string — never a nested object or array. The "..." means \
repeat for each CHANGED section only.
- Only what was actually said. Never invent."""

# Mirrors AgendaFillPrompts.fullSystem(mode: .refined) verbatim.
REFINED_STYLE = """Polish each section into a clean, readable record of that part of the meeting. \
Use markdown bullets ("- "). Each bullet must STAND ALONE: someone who missed the \
meeting should fully understand the point from the bullet alone — capture the what \
AND the why/outcome, with names, numbers and reasons, in roughly 10–25 words. Never \
a bare fragment. \
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
- When content could fit more than one section, the user's prepared bullets \
("originalBullets") define each section's intended angle — file it under the section \
whose prepared bullets it speaks to.
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
    return strip_fences(text), time.time() - t0, env.get("stop_reason")


def incremental_user(context, snippet):
    payload = json.dumps({"sections": SECTIONS}, sort_keys=True)
    return (f"AGENDA SECTIONS (id, heading, prepared bullets, current notes):\n{payload}\n"
            f"\nRECENT CONTEXT (already filed — do not extract from this):\n{context}\n"
            f"\nNEW TRANSCRIPT SNIPPET (integrate only this):\n{snippet}")


def bullets_of(text):
    return [l.strip()[2:].strip() for l in str(text).split("\n") if l.strip().startswith("- ")]


def depth_ok(secs):
    """Every returned bullet must be a standalone point, not a fragment."""
    all_bullets = [b for v in secs.values() for b in bullets_of(v)]
    short = [b for b in all_bullets if len(b.split()) < 6]
    return not short, short


def case_single_topic():
    text, dt, _ = call(LIVE_MODEL, INCREMENTAL_SYSTEM, incremental_user(CONTEXT_LINES, NEW_SNIPPET), 2048)
    secs = json.loads(text).get("sections", {})
    changed = set(secs.keys())
    nonstr = [k for k, v in secs.items() if not isinstance(v, str)]
    no_echo = "4.2" not in str(secs.get(O, ""))
    deep, short = depth_ok(secs)
    print(f"[single-topic/{LIVE_MODEL}] latency {dt:.1f}s, returned ids: {len(changed)}")
    print(f"  touched onboarding only: {changed == {O}}")
    print(f"  all values strings: {not nonstr}")
    print(f"  no echo of existing notes: {no_echo}")
    print(f"  every bullet standalone (>=6 words): {deep}" + (f" — short: {short}" if short else ""))
    for k, v in secs.items():
        print(f"  [{ {M:'metrics',O:'onboarding',P:'pricing'}.get(k,k) }] {str(v)[:200]}")
    return changed == {O} and not nonstr and no_echo and deep


def case_straddle():
    text, dt, _ = call(LIVE_MODEL, INCREMENTAL_SYSTEM, incremental_user(STRADDLE_CONTEXT, STRADDLE_SNIPPET), 2048)
    secs = json.loads(text).get("sections", {})
    changed = set(secs.keys())
    deep, short = depth_ok(secs)
    retention_in_metrics = "61" in str(secs.get(M, ""))
    design_in_onboarding = "v2" in str(secs.get(O, "")).lower() or "design" in str(secs.get(O, "")).lower()
    print(f"[straddle/{LIVE_MODEL}] latency {dt:.1f}s, returned ids: {len(changed)}")
    print(f"  split across metrics + onboarding: {changed == {M, O}}")
    print(f"  retention point filed under metrics: {retention_in_metrics}")
    print(f"  design status filed under onboarding: {design_in_onboarding}")
    print(f"  every bullet standalone: {deep}" + (f" — short: {short}" if short else ""))
    for k, v in secs.items():
        print(f"  [{ {M:'metrics',O:'onboarding',P:'pricing'}.get(k,k) }] {str(v)[:200]}")
    return changed == {M, O} and retention_in_metrics and design_in_onboarding and deep



# Worst case AgendaFiller can send: maxLinesPerFill dense lines spanning topics.
BIG_CONTEXT = """[10:02:00] [You] Let me run through everything quickly.
[10:02:04] [Them] Go ahead."""
BIG_SNIPPET = "\n".join([
    "[10:02:10] [You] Activation held at thirty-eight percent this week, so the checklist gains are sticking.",
    "[10:02:16] [Them] Week-four retention recovered one point to sixty-two percent after the email nudges.",
    "[10:02:22] [You] Free-tier churn is still our biggest leak, about nine percent monthly.",
    "[10:02:28] [Them] On onboarding v2, the design team locked the final flows yesterday afternoon.",
    "[10:02:34] [You] Engineering committed to two sprints, shipping behind a feature flag.",
    "[10:02:40] [Them] We will gate it to ten percent of new signups and compare activation curves.",
    "[10:02:46] [You] If the gated cohort beats control by two points we roll out to everyone.",
    "[10:02:52] [Them] Support volume should drop too since v2 removes the manual import step.",
    "[10:02:58] [You] On pricing, the annual discount test finally has enough volume to read.",
    "[10:03:04] [Them] Annual plans took eighteen percent of new purchases at the twenty percent discount.",
    "[10:03:10] [You] Margin impact is acceptable, finance signed off this morning.",
    "[10:03:16] [Them] So the proposal is to make the annual toggle default-on next month.",
])


def case_big_chunk():
    text, dt, stop = call(LIVE_MODEL, INCREMENTAL_SYSTEM, incremental_user(BIG_CONTEXT, BIG_SNIPPET), 2048)
    secs = json.loads(text).get("sections", {})
    deep, short = depth_ok(secs)
    not_truncated = stop != "max_tokens"
    covers_all = {M, O, P} <= set(secs.keys())
    print(f"[big-chunk/{LIVE_MODEL}] latency {dt:.1f}s, returned ids: {len(secs)}, stop_reason: {stop}")
    print(f"  not truncated at 2048: {not_truncated}")
    print(f"  all three sections updated: {covers_all}")
    print(f"  every bullet standalone: {deep}" + (f" — short: {short}" if short else ""))
    return not_truncated and covers_all and deep


def case_refined():
    payload = json.dumps({"title": "Weekly product sync", "sections": [
        {"id": s["id"], "heading": s["heading"], "subheading": s["subheading"],
         "originalBullets": s["originalBullets"]} for s in SECTIONS]}, sort_keys=True)
    user = f"AGENDA:\n{payload}\n\nTRANSCRIPT:\n{FULL_TRANSCRIPT}"
    text, dt, _ = call(REFINE_MODEL, FULL_SYSTEM, user, 8192)
    secs = json.loads(text).get("sections", {})
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
    ok = [case_single_topic(), case_straddle(), case_big_chunk(), case_refined()]
    print("RESULT:", "PASS" if all(ok) else "CHECK", ok)
    sys.exit(0 if all(ok) else 1)


main()
