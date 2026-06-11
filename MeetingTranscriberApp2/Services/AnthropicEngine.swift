import Foundation

/// Cloud LLM engine backed by the Anthropic API. Resurrected (and slimmed) from
/// the original cloud engine this app shipped with before the all-local Ollama
/// era — brought back because live agenda fills through a resident 7 GB local
/// model starve a 16 GB machine that is simultaneously running WhisperKit and a
/// video call. Cloud fills cost zero local GPU/RAM, so transcription and fills
/// can't collide no matter how busy the meeting is.
///
/// Same prompts and JSON contract as OllamaEngine (shared via AgendaFillPrompts);
/// only the transport differs. Non-streaming on purpose: fills are applied
/// atomically after a full JSON parse, so streaming buys nothing.
///
/// Two-tier models, mirroring the local engine: live fills use a fast model
/// (Claude Haiku), the final refine pass uses a stronger one (Claude Sonnet).
final class AnthropicEngine: SummaryEngine, AgendaFillEngine {
    private let apiKey: String
    let liveModel: String
    let refineModel: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String,
         liveModel: String = CloudLLM.liveModel,
         refineModel: String = CloudLLM.refineModel) {
        self.apiKey = apiKey
        self.liveModel = liveModel
        self.refineModel = refineModel
    }

    static func fromStorage() throws -> AnthropicEngine {
        guard let key = SecureStorage.read(SecureStorage.anthropicAPIKey), !key.isEmpty else {
            throw SummaryEngineError.missingAPIKey
        }
        return AnthropicEngine(apiKey: key)
    }

    // MARK: - Key check (Settings "Test key" button)

    enum KeyStatus {
        case valid
        case invalid
        case offline
    }

    /// Cheap validity probe: GET /v1/models authenticates the key without
    /// spending tokens. 200 → valid, 401 → invalid, transport error → offline.
    static func checkKey(_ key: String) async -> KeyStatus {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .offline }
            return http.statusCode == 200 ? .valid : .invalid
        } catch {
            return .offline
        }
    }

    // MARK: - Agenda fill (priority path)

    func fillAgenda(agenda: Agenda, transcript: [TranscriptLine], mode: AgendaFillMode) async throws -> AgendaFillResult {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }
        let model = (mode == .draft) ? liveModel : refineModel
        let text = try await chat(model: model,
                                  system: AgendaFillPrompts.fullSystem(mode: mode),
                                  user: AgendaFillPrompts.fullUser(agenda: agenda, transcript: transcript),
                                  maxTokens: 8192, timeout: 120)
        return try AgendaFillPrompts.parseFillResponse(text, dropEmpty: false, context: "agenda fill")
    }

    func fillAgendaIncremental(agenda: Agenda, newTranscript: [TranscriptLine]) async throws -> AgendaFillResult {
        guard !newTranscript.isEmpty else { return AgendaFillResult(sections: [:], offAgenda: []) }
        // max_tokens 1024 is the cloud analog of the local path's num_predict 256
        // — generous headroom, because a mid-JSON truncation fails the decode.
        // 30s timeout: a live fill that takes longer than the fill interval is
        // better retried with a bigger delta than waited on.
        let text = try await chat(model: liveModel,
                                  system: AgendaFillPrompts.incrementalSystem,
                                  user: AgendaFillPrompts.incrementalUser(agenda: agenda, newTranscript: newTranscript),
                                  maxTokens: 1024, timeout: 30)
        return try AgendaFillPrompts.parseFillResponse(text, dropEmpty: true, context: "incremental fill")
    }

    // MARK: - Summary / cleanup (SummaryEngine conformance, post-meeting paths)

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

        let text = try await chat(model: refineModel, system: system,
                                  user: AgendaFillPrompts.serialize(transcript),
                                  maxTokens: 4096, timeout: 120)
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

        let text = try await chat(model: refineModel, system: system, user: inputJSON,
                                  maxTokens: 8192, timeout: 180)

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

    // MARK: - Core HTTP

    /// POST /v1/messages (non-streaming), returns the first text block with any
    /// markdown fences stripped. Unlike Ollama there is no `format: "json"`
    /// constraint, so stripFences + the tolerant SectionValue decode in
    /// AgendaFillPrompts carry the JSON contract.
    private func chat(model: String, system: String, user: String,
                      maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SummaryEngineError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SummaryEngineError.http(status: -1, message: "no http response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            // Surface 401/429/529 verbatim — the UI shows this in agendaFillState.
            throw SummaryEngineError.http(status: http.statusCode, message: String(msg.prefix(300)))
        }

        struct APIContent: Decodable { let type: String; let text: String? }
        struct APIEnvelope: Decodable { let content: [APIContent] }
        let envelope: APIEnvelope
        do {
            envelope = try JSONDecoder().decode(APIEnvelope.self, from: data)
        } catch {
            throw SummaryEngineError.decoding("anthropic envelope: \(error.localizedDescription)")
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw SummaryEngineError.decoding("no text content in response")
        }
        return stripFences(text)
    }

    /// The model may wrap the JSON in markdown fences; strip them defensively.
    private func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // remove opening fence (optionally with "json")
            if let nl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: nl)...])
            }
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}
