import Foundation

/// The agenda-fill prompts and response parsing for AnthropicEngine, kept in
/// one place so the live (incremental) and final (full) contracts stay visibly
/// in sync, and so scripts/anthropic_incremental_smoke.py can mirror them.
///
/// The JSON envelope (single generic example key + "..." repeat-cue, plain
/// string values) is inherited from the contract that survived two engine
/// generations — it parses reliably and there's no reason to churn it.
enum AgendaFillPrompts {

    // MARK: - Full fill (draft / refined)

    static func fullSystem(mode: AgendaFillMode) -> String {
        let styleNote: String
        switch mode {
        case .draft:
            styleNote = """
            Write factual bullets that capture what was actually said. \
            Each section's "content" is a markdown bullet list using "- " markers. \
            Each bullet must stand alone — capture the what AND the why/outcome, with names and \
            numbers, in roughly 10–25 words. \
            If a section was not discussed yet, return "" (empty string). \
            Be honest — do not invent. Match the user's voice (their originalBullets show their preferred style).
            """
        case .refined:
            styleNote = """
            Polish each section into a clean, readable record of that part of the meeting. \
            Use markdown bullets ("- "). Each bullet must STAND ALONE: someone who missed the \
            meeting should fully understand the point from the bullet alone — capture the what \
            AND the why/outcome, with names, numbers and reasons, in roughly 10–25 words. Never \
            a bare fragment. \
            Where the discussion produced concrete elements (proposal, risk, decision, owner, \
            next step, deadline), label the bullet with a bold prefix like \
            "- **Decision:** …" / "- **Owner:** …" / "- **Risk:** …" / "- **Next step:** …". \
            If a section was not discussed, return the exact string "Not covered in this meeting." \
            Do not invent — only include what's in the transcript.
            """
        }

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
        - When content could fit more than one section, the user's prepared bullets \
          ("originalBullets") define each section's intended angle — file it under the section \
          whose prepared bullets it speaks to.
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

    // The example value showing multiple "- " bullets joined by \n is kept on
    // purpose: models mirror example shapes more reliably than written rules,
    // and this shape is what makes multi-point snippets come back as multiple
    // bullets instead of one.
    static let incrementalSystem = """
    You are Marty, an editorial meeting analyst updating a meeting agenda LIVE as new \
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
    - Only what was actually said. Never invent.
    """

    static func incrementalUser(agenda: Agenda, newTranscript: [TranscriptLine],
                                contextLines: [TranscriptLine]) -> String {
        let sectionsPayload = agenda.sections.map { s -> [String: Any] in
            [
                "id": s.id.uuidString,
                "heading": s.heading,
                "subheading": s.subheading as Any,
                "originalBullets": s.originalBullets,  // the user's intended angle per section
                "currentNotes": s.filledContent,       // what we've captured so far
            ]
        }
        let payloadJSON = String(
            data: (try? JSONSerialization.data(withJSONObject: ["sections": sectionsPayload], options: [.sortedKeys])) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        // The context block lets a snippet that starts mid-thought ("…and that's
        // why it was slow") be routed by what preceded it, instead of cold.
        let contextBlock = contextLines.isEmpty ? "" : """

        RECENT CONTEXT (already filed — do not extract from this):
        \(serialize(contextLines))
        """

        return """
        AGENDA SECTIONS (id, heading, prepared bullets, current notes):
        \(payloadJSON)
        \(contextBlock)

        NEW TRANSCRIPT SNIPPET (integrate only this):
        \(serialize(newTranscript))
        """
    }

    // MARK: - Response parsing

    /// A section's filled content. Normally a plain string, but defensively
    /// tolerates a model that wraps it in a single-key object — we unwrap to
    /// the inner string so a quirk never throws.
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
