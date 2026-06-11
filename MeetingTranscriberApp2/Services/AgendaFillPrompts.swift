import Foundation

/// The agenda-fill prompts and response parsing, shared verbatim by both fill
/// engines (OllamaEngine and AnthropicEngine). The wording here is load-bearing
/// and was tuned against the small local models (see the comments inline and
/// scripts/ollama_*_smoke.py) — the cloud models tolerate it fine, so both
/// engines speak the exact same contract and AgendaFiller can't tell them apart.
enum AgendaFillPrompts {

    // MARK: - Full fill (draft / refined)

    static func fullSystem(mode: AgendaFillMode) -> String {
        let styleNote: String
        switch mode {
        case .draft:
            styleNote = """
            Write SHORT, factual bullets that capture only what was actually said. \
            Each section's "content" is a markdown bullet list using "- " markers. \
            If a section was not discussed yet, return "" (empty string). \
            Be honest — do not invent. Match the user's voice (their originalBullets show their preferred style).
            """
        case .refined:
            styleNote = """
            Polish each section into a clean, readable summary. Use markdown bullets ("- "). \
            Where the discussion produced concrete elements (proposal, risk, decision, owner, \
            next step, deadline), label the bullet with a bold prefix like \
            "- **Decision:** …" / "- **Owner:** …" / "- **Risk:** …" / "- **Next step:** …". \
            If a section was not discussed, return the exact string "Not covered in this meeting." \
            Do not invent — only include what's in the transcript.
            """
        }

        // Two prompt details are load-bearing (verified against both local models
        // via scripts/ollama_engine_smoke.py):
        //  1) a SINGLE generic key + "..." repeat-cue — a finite multi-key example
        //     makes the small e2b model mirror the example's key count and drop
        //     sections; the "..." makes it fill every id.
        //  2) the value is described as a plain string ("never a nested object")
        //     instead of an angle-bracket placeholder — e4b otherwise turned the
        //     placeholder into a nested object key, breaking [String: String].
        // SectionValue decoding in parseFillResponse is the belt-and-suspenders for (2).
        return """
        You are Marty, an editorial meeting analyst. The user has an agenda; you are filling \
        in each section based on what was actually discussed in the transcript.

        Respond ONLY with a JSON object, no prose around it:
        {
          "sections": { "the-section-id": "markdown text for that section, as a plain string", ... },
          "offAgenda": ["short bullet of a substantive discussion that didn't map to any heading", ...]
        }

        The "..." means: repeat for EVERY section id in the input. Each value in "sections" is a plain \
        JSON string (markdown bullet lines separated by newlines) — never a nested object or array.

        Rules:
        - The keys in "sections" MUST exactly match the section ids provided in the input, and you \
          MUST include EVERY id (even if the value is "").
        - \(styleNote)
        - "offAgenda" captures topics that consumed real meeting time but don't belong under \
          any heading. Empty array if everything mapped.
        - Never invent facts, decisions, or quotes not in the transcript.
        """
    }

    static func fullUser(agenda: Agenda, transcript: [TranscriptLine]) -> String {
        let payload: [String: Any] = [
            "title": agenda.title,
            "sections": agenda.sections.map { s in
                [
                    "id": s.id.uuidString,
                    "heading": s.heading,
                    "subheading": s.subheading as Any,
                    "originalBullets": s.originalBullets,
                ] as [String: Any]
            },
        ]
        let payloadJSON = String(
            data: (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        return """
        AGENDA:
        \(payloadJSON)

        TRANSCRIPT:
        \(serialize(transcript))
        """
    }

    // MARK: - Incremental fill (append-only live updates)

    // Load-bearing prompt detail (verified via scripts/ollama_incremental_smoke.py,
    // 3/3 runs): the example value MUST show multiple "- " bullets joined by \n.
    // With a prose placeholder ("the NEW bullet lines…"), e2b reproducibly
    // returned only the snippet's LAST point; the multi-bullet shape makes it
    // capture every point. Same lesson as the full fill: e2b mirrors example
    // shapes far more reliably than it follows written rules.
    static let incrementalSystem = """
    You are Marty, an editorial meeting analyst updating a meeting agenda LIVE as new \
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
    - "offAgenda" holds only NEW tangents from this snippet; empty array if none.
    """

    static func incrementalUser(agenda: Agenda, newTranscript: [TranscriptLine]) -> String {
        let sectionsPayload = agenda.sections.map { s -> [String: Any] in
            [
                "id": s.id.uuidString,
                "heading": s.heading,
                "subheading": s.subheading as Any,
                "currentNotes": s.filledContent,   // what we've captured so far
            ]
        }
        let payloadJSON = String(
            data: (try? JSONSerialization.data(withJSONObject: ["sections": sectionsPayload], options: [.sortedKeys])) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        // Each section's current notes ride along in payloadJSON only — an earlier
        // version repeated them in a separate "NOTES SO FAR" block, doubling the
        // (growing) prefill on every call for no benefit.
        return """
        AGENDA SECTIONS (id, heading, current notes):
        \(payloadJSON)

        NEW TRANSCRIPT SNIPPET (integrate only this):
        \(serialize(newTranscript))
        """
    }

    // MARK: - Response parsing

    /// A section's filled content. Normally a plain string, but defensively
    /// tolerates a model that wraps it in a single-key object (observed with
    /// gemma4:e4b) — we unwrap to the inner string so a quirk never throws.
    struct SectionValue: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                text = s
            } else if let obj = try? c.decode([String: String].self), let first = obj.values.first {
                text = first
            } else {
                text = ""
            }
        }
    }

    /// Decode a fill response (full or incremental — same envelope).
    /// - dropEmpty: incremental fills treat "" as "no change" and skip it;
    ///   full fills keep "" (it means "section not discussed → upcoming").
    static func parseFillResponse(_ text: String, dropEmpty: Bool, context: String) throws -> AgendaFillResult {
        struct Response: Decodable {
            let sections: [String: SectionValue]
            let offAgenda: [String]?
        }
        let parsed: Response
        do {
            parsed = try JSONDecoder().decode(Response.self, from: Data(text.utf8))
        } catch {
            throw SummaryEngineError.decoding("\(context) JSON: \(error.localizedDescription) — raw: \(text.prefix(200))")
        }

        var byId: [UUID: String] = [:]
        for (key, value) in parsed.sections {
            guard let uuid = UUID(uuidString: key) else { continue }
            if dropEmpty && value.text.isEmpty { continue }
            byId[uuid] = value.text
        }
        return AgendaFillResult(sections: byId, offAgenda: parsed.offAgenda ?? [])
    }

    // MARK: - Helpers

    static func serialize(_ transcript: [TranscriptLine]) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return transcript.map { "[\(f.string(from: $0.timestamp))] [\($0.speaker)] \($0.text)" }
            .joined(separator: "\n")
    }
}
