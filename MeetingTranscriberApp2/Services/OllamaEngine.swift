import Foundation

/// Local LLM engine backed by Ollama (a server on the user's machine, default
/// http://localhost:11434). Replaces the cloud AnthropicEngine — same prompts,
/// local inference, no API key. Uses Ollama's `/api/chat` with `format: "json"`
/// so the model is constrained to valid JSON (no markdown-fence stripping).
///
/// Two-tier models: live drafts use a fast model (gemma4:e2b), the final polish
/// and one-shot calls use a stronger one (gemma4:e4b).
final class OllamaEngine: SummaryEngine {
    let baseURL: URL
    let draftModel: String
    let refineModel: String

    init(baseURL: URL, draftModel: String, refineModel: String) {
        self.baseURL = baseURL
        self.draftModel = draftModel
        self.refineModel = refineModel
    }

    static func fromStorage() -> OllamaEngine {
        OllamaEngine(
            baseURL: LocalLLM.baseURL,
            draftModel: LocalLLM.draftModel,
            refineModel: LocalLLM.refineModel
        )
    }

    // MARK: - Health

    /// Result of probing the Ollama server and the configured models.
    struct Health {
        var reachable: Bool
        var version: String?
        var installedModels: [String]
        func hasModel(_ tag: String) -> Bool {
            // Ollama reports tags like "gemma4:e2b"; match exact or base name.
            installedModels.contains(tag) ||
            installedModels.contains { $0.hasPrefix(tag.split(separator: ":").first.map(String.init) ?? tag) && $0 == tag }
        }
    }

    func checkHealth() async -> Health {
        guard let version = try? await getVersion() else {
            return Health(reachable: false, version: nil, installedModels: [])
        }
        let models = (try? await listModels()) ?? []
        return Health(reachable: true, version: version, installedModels: models)
    }

    private func getVersion() async throws -> String {
        let url = baseURL.appendingPathComponent("api/version")
        let (data, response) = try await dataMappingErrors(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SummaryEngineError.ollamaUnreachable
        }
        struct V: Decodable { let version: String }
        return (try? JSONDecoder().decode(V.self, from: data).version) ?? "unknown"
    }

    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, response) = try await dataMappingErrors(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SummaryEngineError.ollamaUnreachable
        }
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.map(\.name)
    }

    // MARK: - Agenda fill (priority path)

    enum FillMode: String { case draft, refined }

    struct AgendaFillResult {
        var sections: [UUID: String]
        var offAgenda: [String]
    }

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

    func fillAgenda(agenda: Agenda, transcript: [TranscriptLine], mode: FillMode) async throws -> AgendaFillResult {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }

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

        // Two prompt details are load-bearing (verified against both models via
        // scripts/ollama_engine_smoke.py):
        //  1) a SINGLE generic key + "..." repeat-cue — a finite multi-key example
        //     makes the small e2b model mirror the example's key count and drop
        //     sections; the "..." makes it fill every id.
        //  2) the value is described as a plain string ("never a nested object")
        //     instead of an angle-bracket placeholder — e4b otherwise turned the
        //     placeholder into a nested object key, breaking [String: String].
        // SectionValue decoding below is the belt-and-suspenders for (2).
        let system = """
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

        let userMessage = """
        AGENDA:
        \(payloadJSON)

        TRANSCRIPT:
        \(Self.serialize(transcript))
        """

        let model = (mode == .draft) ? draftModel : refineModel
        let text = try await chat(model: model, system: system, user: userMessage)

        struct Response: Decodable {
            let sections: [String: SectionValue]
            let offAgenda: [String]?
        }
        let parsed: Response
        do {
            parsed = try JSONDecoder().decode(Response.self, from: Data(text.utf8))
        } catch {
            throw SummaryEngineError.decoding("agenda fill JSON: \(error.localizedDescription) — raw: \(text.prefix(200))")
        }

        var byId: [UUID: String] = [:]
        for (key, value) in parsed.sections {
            if let uuid = UUID(uuidString: key) { byId[uuid] = value.text }
        }
        return AgendaFillResult(sections: byId, offAgenda: parsed.offAgenda ?? [])
    }

    // MARK: - Summary (legacy / past-session path)

    func summarize(transcript: [TranscriptLine]) async throws -> MeetingSummary {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }

        let system = """
        You are Marty, an editorial meeting analyst. The user provides a transcript with speakers \
        labeled "You" (the user) and "Them" (everyone else). Respond ONLY with a JSON object \
        matching this schema, no prose around it:
        {
          "title": "3-7 word descriptive headline naming what the meeting was about (no quotes, no period)",
          "summary": "1-3 sentences, editorial tone, for a glance card",
          "narrative": "1-2 short paragraphs of editorial prose summarising the conversation — \
            written like a magazine recap, not bullet points. Concrete, specific. Avoid AI clichés.",
          "keyPoints": ["3 to 5 short sentences, the gist of the conversation"],
          "actionItems": ["concrete next-step TODOs detected in the conversation, may be empty"],
          "topics": ["3 to 6 short topic labels, single words or noun phrases, no sentences"],
          "keyQuotes": [
            {"quote": "exact verbatim quote from the transcript (no paraphrasing)", \
             "speaker": "You" or "Them" or other label as used in the transcript, \
             "timestamp": "HH:mm:ss if available, otherwise null"}
          ],
          "decisions": ["concrete decisions reached during the conversation, may be empty"],
          "openQuestions": ["unresolved questions or unfinished threads, may be empty"]
        }

        Notes:
        - keyQuotes should be 2-4 of the most striking, idea-bearing, or representative lines. \
          Quote verbatim from the transcript — do not paraphrase.
        - All array fields may be empty if not applicable.
        - Never invent facts, decisions, or quotes not in the transcript.
        """

        let text = try await chat(model: refineModel, system: system, user: Self.serialize(transcript))
        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: Data(text.utf8))
        } catch {
            throw SummaryEngineError.decoding("summary JSON: \(error.localizedDescription) — raw: \(text.prefix(200))")
        }
    }

    func cleanTranscript(transcript: [TranscriptLine]) async throws -> [TranscriptLine] {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        struct InputLine: Encodable { let speaker: String; let timestamp: String; let text: String }
        let input = transcript.map {
            InputLine(speaker: $0.speaker, timestamp: timeFormatter.string(from: $0.timestamp), text: $0.text)
        }
        let inputJSON = String(data: (try? JSONEncoder().encode(input)) ?? Data(), encoding: .utf8) ?? "[]"

        let system = """
        You are Marty, an editor that cleans up live speech-to-text transcripts so they read \
        like a manuscript by a professional, while preserving exactly what each speaker actually said.

        You receive an array of utterances. Apply these rules:

        1. MERGE consecutive utterances by the same speaker when they are clearly one continuous \
           thought split by a VAD pause. Keep the timestamp of the FIRST utterance in any merged group.
        2. FIX obvious speech-to-text errors: misheard homophones, mangled proper nouns, mis-segmented \
           words, missing or wrong punctuation, capitalization, broken contractions.
        3. PRESERVE the speaker's voice. Do NOT paraphrase, summarise, or rewrite.
        4. Do NOT add or remove information.
        5. Maintain speaker attribution exactly.
        6. Keep timestamps in "HH:mm:ss" format.

        Respond ONLY with a JSON object, no prose: { "lines": [ {"speaker": "...", "timestamp": "HH:mm:ss", "text": "..."} ] }
        """

        let text = try await chat(model: refineModel, system: system, user: inputJSON)

        struct CleanedLine: Decodable { let speaker: String; let timestamp: String; let text: String }
        struct Wrapper: Decodable { let lines: [CleanedLine] }
        let cleaned: [CleanedLine]
        do {
            cleaned = try JSONDecoder().decode(Wrapper.self, from: Data(text.utf8)).lines
        } catch {
            throw SummaryEngineError.decoding("cleaned JSON: \(error.localizedDescription) — raw: \(text.prefix(200))")
        }

        let today = Calendar.current.startOfDay(for: Date())
        return cleaned.map { c in
            let ts: Date
            if let parsed = timeFormatter.date(from: c.timestamp) {
                let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: parsed)
                ts = Calendar.current.date(byAdding: comps, to: today) ?? Date()
            } else {
                ts = Date()
            }
            return TranscriptLine(timestamp: ts, speaker: c.speaker, text: c.text)
        }
    }

    // MARK: - Export routing

    struct ExportRouting: Decodable { let folder: String?; let filename: String? }

    func routeExport(instruction: String, defaultFolder: String, defaultFilename: String) async throws -> ExportRouting {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ExportRouting(folder: defaultFolder, filename: defaultFilename)
        }
        let system = """
        You are a routing helper. The user is exporting a meeting transcript and gave a \
        natural-language instruction about where it should go. Respond ONLY with a JSON object:
        { "folder": "folder name they implied, or the default", "filename": "filename (no extension) they implied, or the default" }
        Rules: single folder name, no slashes; filename human-readable, no .md, no slashes, no quotes; \
        return the default for any field they didn't mention.
        """
        let payload: [String: String] = [
            "instruction": trimmed, "default_folder": defaultFolder, "default_filename": defaultFilename,
        ]
        let payloadJSON = String(data: (try? JSONEncoder().encode(payload)) ?? Data(), encoding: .utf8) ?? "{}"
        let text = try await chat(model: refineModel, system: system, user: payloadJSON)
        do {
            return try JSONDecoder().decode(ExportRouting.self, from: Data(text.utf8))
        } catch {
            return ExportRouting(folder: defaultFolder, filename: defaultFilename)
        }
    }

    // MARK: - Agenda candidate picker (NL intake)

    func pickAgendaCandidate(intent: String, candidatesJSON: String) async throws -> String {
        let system = """
        You are an agenda picker. The user typed a one-line instruction describing the meeting they're \
        about to have. You're given candidate items (calendar events or Notion pages). Pick the single \
        best match. Respond ONLY with a JSON object: { "id": "<the chosen candidate id, exactly as given>" }
        Rules:
        - Prefer candidates whose title closely matches the user's intent.
        - When the intent mentions a time, prefer the calendar event closest to that time (use "when").
        - Always return one of the provided ids verbatim, including the source prefix (e.g. "calendar:abc123").
        """
        let user = "intent: \(intent)\ncandidates: \(candidatesJSON)"
        let text = try await chat(model: refineModel, system: system, user: user)
        struct Pick: Decodable { let id: String }
        return try JSONDecoder().decode(Pick.self, from: Data(text.utf8)).id
    }

    // MARK: - Core HTTP

    /// POST /api/chat with format:"json", returns the assistant message content (a JSON string).
    private func chat(model: String, system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0.2, "num_ctx": 8192],
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataMappingErrors(request)
        guard let http = response as? HTTPURLResponse else {
            throw SummaryEngineError.http(status: -1, message: "no http response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            // Ollama returns 404 with "model not found" when the tag isn't pulled.
            if http.statusCode == 404 || msg.lowercased().contains("not found") {
                throw SummaryEngineError.modelMissing(model)
            }
            throw SummaryEngineError.http(status: http.statusCode, message: msg)
        }

        struct ChatResponse: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        do {
            return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        } catch {
            throw SummaryEngineError.decoding("ollama envelope: \(error.localizedDescription)")
        }
    }

    /// URLSession.data that maps connection failures to a friendly "Ollama isn't running".
    private func dataMappingErrors(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let err as URLError {
            switch err.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet:
                throw SummaryEngineError.ollamaUnreachable
            default:
                throw SummaryEngineError.transport(err)
            }
        }
    }

    // MARK: - Helpers

    private static func serialize(_ transcript: [TranscriptLine]) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return transcript.map { "[\(f.string(from: $0.timestamp))] [\($0.speaker)] \($0.text)" }
            .joined(separator: "\n")
    }
}
