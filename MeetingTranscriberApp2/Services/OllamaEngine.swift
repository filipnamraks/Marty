import Foundation

/// Local LLM engine backed by Ollama (a server on the user's machine, default
/// http://localhost:11434). Replaces the cloud AnthropicEngine — same prompts,
/// local inference, no API key. Uses Ollama's `/api/chat` with `format: "json"`
/// so the model is constrained to valid JSON (no markdown-fence stripping).
///
/// Two-tier models: live drafts use a fast model (gemma4:e2b), the final polish
/// and one-shot calls use a stronger one (gemma4:e4b).
final class OllamaEngine: SummaryEngine, AgendaFillEngine {
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

    /// Load the draft model into GPU memory ahead of the first live fill. The
    /// cold load measured ~7s and used to land minutes into a meeting (it
    /// visibly stuttered the whole machine); pre-warming moves that cost to
    /// record-start, before anyone is talking. An empty `messages` array makes
    /// Ollama load the model and return immediately. Best-effort by design:
    /// errors are swallowed — the first real fill loads the model anyway.
    func prewarm() async {
        // num_ctx must match chat()'s — Ollama re-allocates the runner when the
        // context size changes, which would re-trigger the load stall mid-meeting.
        let body: [String: Any] = [
            "model": draftModel,
            "messages": [[String: Any]](),
            "options": ["num_ctx": 8192],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
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

    func fillAgenda(agenda: Agenda, transcript: [TranscriptLine], mode: AgendaFillMode) async throws -> AgendaFillResult {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }

        // Prompts + parsing shared with AnthropicEngine — see AgendaFillPrompts
        // for the (load-bearing) wording and the SectionValue defensive decode.
        let model = (mode == .draft) ? draftModel : refineModel
        let text = try await chat(model: model,
                                  system: AgendaFillPrompts.fullSystem(mode: mode),
                                  user: AgendaFillPrompts.fullUser(agenda: agenda, transcript: transcript))
        return try AgendaFillPrompts.parseFillResponse(text, dropEmpty: false, context: "agenda fill")
    }

    /// Incremental live update, append-only. Sends each section's CURRENT notes
    /// plus ONLY the new transcript since the last update; the model returns just
    /// the NEW bullets per changed section (AgendaFiller appends them). With the
    /// output no longer a growing full-section rewrite, each call stays small for
    /// the whole meeting and `num_predict` caps a runaway generation safely —
    /// truncating a list of fresh bullets loses a bullet, not the JSON envelope's
    /// validity the way truncating a full rewrite did.
    /// The authoritative full pass is still `fillAgenda(mode:.refined)` on stop.
    func fillAgendaIncremental(agenda: Agenda, newTranscript: [TranscriptLine]) async throws -> AgendaFillResult {
        guard !newTranscript.isEmpty else { return AgendaFillResult(sections: [:], offAgenda: []) }

        // Prompts + parsing shared with AnthropicEngine (AgendaFillPrompts). The
        // multi-bullet example value in the system prompt is load-bearing for e2b.
        let text = try await chat(model: draftModel,
                                  system: AgendaFillPrompts.incrementalSystem,
                                  user: AgendaFillPrompts.incrementalUser(agenda: agenda, newTranscript: newTranscript),
                                  think: false, numPredict: 256)
        // dropEmpty: an empty value means "no change", not "clear the section".
        return try AgendaFillPrompts.parseFillResponse(text, dropEmpty: true, context: "incremental fill")
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
    ///
    /// `think` controls the model's hidden chain-of-thought (gemma4 is a thinking
    /// model). Measured on the live fill: ~19s of a ~25s call was invisible
    /// reasoning, so the latency-critical live path passes `false` (3× faster,
    /// JSON contract verified intact). `nil` leaves the model default — the final
    /// refine pass keeps thinking, since the GPU is free once recording stops.
    private func chat(model: String, system: String, user: String,
                      think: Bool? = nil, numPredict: Int? = nil) async throws -> String {
        var options: [String: Any] = ["temperature": 0.2, "num_ctx": 8192]
        // Only safe for bounded outputs (append-only fills) — capping a
        // full-document rewrite truncates mid-JSON and breaks the decode.
        if let numPredict { options["num_predict"] = numPredict }
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": options,
        ]
        if let think { body["think"] = think }

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
