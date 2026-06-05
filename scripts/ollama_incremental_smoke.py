#!/usr/bin/env python3
"""Validate OllamaEngine.fillAgendaIncremental behavior against real Ollama:
a new snippet about ONE topic should update only that section (merging into its
existing notes), not rewrite the whole agenda."""
import json, time, urllib.request
BASE="http://localhost:11434"
# Section ids
M="11111111-1111-1111-1111-111111111111"  # metrics (already has notes)
O="22222222-2222-2222-2222-222222222222"  # onboarding (empty; the snippet is about this)
P="33333333-3333-3333-3333-333333333333"  # pricing (empty)

SECTIONS=[
 {"id":M,"heading":"Last week's metrics","subheading":"Activation, retention","currentNotes":"- Activation up 4.2 pts WoW to 38%, from the new onboarding checklist."},
 {"id":O,"heading":"Onboarding redesign","subheading":"Where v2 stands","currentNotes":""},
 {"id":P,"heading":"Pricing experiment","subheading":"Annual discount","currentNotes":""},
]
NEW_SNIPPET="""[10:01:15] [Them] On the onboarding redesign — v2 design is locked.
[10:01:20] [You] Engineering says two sprints to ship behind a flag.
[10:01:30] [Them] Let's gate it to ten percent of new signups first and read activation."""

SYSTEM="""You are Marty, an editorial meeting analyst updating a meeting agenda LIVE as new \
transcript arrives. You are given each agenda section with its CURRENT notes, and a NEW \
snippet of transcript since the last update. Integrate ONLY the new snippet.

Respond ONLY with a JSON object, no prose around it:
{
  "sections": { "the-section-id": "the FULL updated notes for that section, as a plain string", ... },
  "offAgenda": ["a new tangent from the snippet that fit no heading", ...]
}

Rules:
- Return ONLY the sections the new snippet actually adds to. OMIT every section the snippet doesn't change. (Most snippets touch one or two sections.)
- For a changed section, return its FULL updated notes: keep the existing points and merge the new info in. Do not duplicate points already present. Do not drop existing points.
- Each value is a plain JSON string of markdown bullet lines ("- " markers) — never a nested object or array. The "..." means repeat for each CHANGED section only.
- Short, factual, only what was actually said. Never invent.
- "offAgenda" holds only NEW tangents from this snippet; empty array if none."""

def main():
    # Mirrors fillAgendaIncremental: notes ride in the payload JSON only (the old
    # duplicate "NOTES SO FAR" block was removed) and think=false skips gemma4's
    # hidden chain-of-thought on the latency-critical live path.
    payload=json.dumps({"sections":SECTIONS},sort_keys=True)
    user=f"AGENDA SECTIONS (id, heading, current notes):\n{payload}\n\nNEW TRANSCRIPT SNIPPET (integrate only this):\n{NEW_SNIPPET}"
    body={"model":"gemma4:e2b","stream":False,"format":"json","think":False,"messages":[{"role":"system","content":SYSTEM},{"role":"user","content":user}],"options":{"temperature":0.2,"num_ctx":8192}}
    req=urllib.request.Request(BASE+"/api/chat",data=json.dumps(body).encode(),headers={"content-type":"application/json"})
    t0=time.time()
    with urllib.request.urlopen(req,timeout=200) as r: content=json.loads(r.read())["message"]["content"]
    dt=time.time()-t0
    p=json.loads(content); secs=p.get("sections",{})
    changed=set(secs.keys())
    print(f"latency {dt:.1f}s   returned section ids: {len(changed)}")
    print(f"  touched onboarding (expected): {O in changed}")
    print(f"  left metrics untouched (expected, not returned): {M not in changed}")
    print(f"  left pricing untouched (expected): {P not in changed}")
    nonstr=[k for k,v in secs.items() if not isinstance(v,str)]
    print(f"  all values strings: {not nonstr}")
    for k,v in secs.items():
        name={M:'metrics',O:'onboarding',P:'pricing'}.get(k,k)
        print(f"  [{name}] {str(v)[:160]}")
    ok = O in changed and M not in changed and not nonstr
    print("RESULT:", "PASS" if ok else "CHECK")
main()
