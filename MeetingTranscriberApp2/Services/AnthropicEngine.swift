import Foundation

final class AnthropicEngine: SummaryEngine {
    private let apiKey: String
    private let model: SummaryModel
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: SummaryModel = .haiku45) {
        self.apiKey = apiKey
        self.model = model
    }

    static func fromStorage(model: SummaryModel? = nil) throws -> AnthropicEngine {
        guard let key = SecureStorage.read(SecureStorage.anthropicAPIKey), !key.isEmpty else {
            throw SummaryEngineError.missingAPIKey
        }
        let chosen = model ?? SummaryModel(rawValue: SecureStorage.read(SecureStorage.preferredModel) ?? "") ?? .haiku45
        return AnthropicEngine(apiKey: key, model: chosen)
    }

    func summarize(transcript: [TranscriptLine]) async throws -> MeetingSummary {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        let serialized = transcript.map { line in
            "[\(timeFormatter.string(from: line.timestamp))] [\(line.speaker)] \(line.text)"
        }.joined(separator: "\n")

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

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 2048,
            "system": system,
            "messages": [
                ["role": "user", "content": serialized]
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
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
            throw SummaryEngineError.http(status: http.statusCode, message: msg)
        }

        struct APIContent: Decodable { let type: String; let text: String }
        struct APIEnvelope: Decodable { let content: [APIContent] }
        let envelope: APIEnvelope
        do {
            envelope = try JSONDecoder().decode(APIEnvelope.self, from: data)
        } catch {
            throw SummaryEngineError.decoding("envelope: \(error.localizedDescription)")
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw SummaryEngineError.decoding("no text content in response")
        }

        // The model may wrap the JSON in markdown fences; strip them defensively.
        let jsonText = stripFences(text)
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw SummaryEngineError.decoding("text not utf8")
        }
        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: jsonData)
        } catch {
            throw SummaryEngineError.decoding("summary JSON: \(error.localizedDescription) — raw: \(jsonText.prefix(200))")
        }
    }

    func cleanTranscript(transcript: [TranscriptLine]) async throws -> [TranscriptLine] {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        // Serialize as a JSON array so the model returns the same shape back.
        struct InputLine: Encodable {
            let speaker: String
            let timestamp: String
            let text: String
        }
        let input = transcript.map {
            InputLine(speaker: $0.speaker,
                      timestamp: timeFormatter.string(from: $0.timestamp),
                      text: $0.text)
        }
        let inputJSON = String(data: try JSONEncoder().encode(input), encoding: .utf8) ?? "[]"

        let system = """
        You are Marty, an editor that cleans up live speech-to-text transcripts so they read \
        like a manuscript by a professional, while preserving exactly what each speaker actually said.

        You receive an array of utterances. Apply these rules:

        1. MERGE consecutive utterances by the same speaker when they are clearly one continuous \
           thought split by a VAD pause (e.g. one ends mid-clause and the next begins mid-clause). \
           Keep the timestamp of the FIRST utterance in any merged group.
        2. FIX obvious speech-to-text errors: misheard homophones, mangled proper nouns, mis-segmented \
           words, missing or wrong punctuation, capitalization, broken contractions. Use context to \
           infer the most likely intended word.
        3. PRESERVE the speaker's voice. Do NOT paraphrase, summarise, or rewrite. Filler words and \
           stylistic quirks stay if they were intentional; only drop them if they are clearly \
           transcription noise (e.g. duplicated "you you you you").
        4. Do NOT add or remove information. Do NOT add content not present in the original.
        5. Maintain speaker attribution exactly.
        6. Keep timestamps in "HH:mm:ss" format.

        Respond ONLY with a JSON array, no prose around it:
        [
          {"speaker": "You" | "Them" | <other>, "timestamp": "HH:mm:ss", "text": "cleaned text"}
        ]
        """

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": inputJSON]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
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
            throw SummaryEngineError.http(status: http.statusCode, message: msg)
        }

        struct APIContent: Decodable { let type: String; let text: String }
        struct APIEnvelope: Decodable { let content: [APIContent] }
        let envelope: APIEnvelope
        do {
            envelope = try JSONDecoder().decode(APIEnvelope.self, from: data)
        } catch {
            throw SummaryEngineError.decoding("envelope: \(error.localizedDescription)")
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw SummaryEngineError.decoding("no text content in response")
        }

        let jsonText = stripFences(text)
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw SummaryEngineError.decoding("text not utf8")
        }

        struct CleanedLine: Decodable {
            let speaker: String
            let timestamp: String
            let text: String
        }
        let cleaned: [CleanedLine]
        do {
            cleaned = try JSONDecoder().decode([CleanedLine].self, from: jsonData)
        } catch {
            throw SummaryEngineError.decoding("cleaned JSON: \(error.localizedDescription) — raw: \(jsonText.prefix(200))")
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

    // MARK: - Agenda fill

    enum FillMode: String {
        case draft
        case refined
    }

    struct AgendaFillResult {
        var sections: [UUID: String]
        var offAgenda: [String]
    }

    /// Asks Claude to write, per agenda section, what the meeting has covered under
    /// that heading so far. Returns updated text keyed by section id, plus any
    /// substantive off-agenda discussion as a "parking lot" list.
    /// - mode .draft: terse, written for live updating. Empty string if not covered yet.
    /// - mode .refined: polished prose / bullets, suitable as final deliverable.
    func fillAgenda(agenda: Agenda, transcript: [TranscriptLine], mode: FillMode) async throws -> AgendaFillResult {
        guard !transcript.isEmpty else { throw SummaryEngineError.emptyTranscript }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let serialized = transcript.map { line in
            "[\(timeFormatter.string(from: line.timestamp))] [\(line.speaker)] \(line.text)"
        }.joined(separator: "\n")

        struct AgendaSectionPayload: Encodable {
            let id: String
            let heading: String
            let subheading: String?
            let originalBullets: [String]
        }
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
            data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
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

        let system = """
        You are Marty, an editorial meeting analyst. The user has an agenda; you are filling \
        in each section based on what was actually discussed in the transcript.

        Respond ONLY with a JSON object, no prose around it:
        {
          "sections": { "<section_id>": "<markdown content for that section>", ... },
          "offAgenda": ["short bullet of a substantive discussion that didn't map to any heading", ...]
        }

        Rules:
        - The keys in "sections" MUST exactly match the section ids provided in the input.
        - Include EVERY section id, even if the value is "".
        - \(styleNote)
        - "offAgenda" captures topics that consumed real meeting time but don't belong under \
          any heading. Empty array if everything mapped. 3-line max per item.
        - Never invent facts, decisions, or quotes not in the transcript.
        """

        let userMessage = """
        AGENDA:
        \(payloadJSON)

        TRANSCRIPT:
        \(serialized)
        """

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": userMessage]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
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
            throw SummaryEngineError.http(status: http.statusCode, message: msg)
        }

        struct APIContent: Decodable { let type: String; let text: String }
        struct APIEnvelope: Decodable { let content: [APIContent] }
        let envelope: APIEnvelope
        do {
            envelope = try JSONDecoder().decode(APIEnvelope.self, from: data)
        } catch {
            throw SummaryEngineError.decoding("envelope: \(error.localizedDescription)")
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw SummaryEngineError.decoding("no text content in response")
        }

        let jsonText = stripFences(text)
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw SummaryEngineError.decoding("text not utf8")
        }

        struct Response: Decodable {
            let sections: [String: String]
            let offAgenda: [String]?
        }
        let parsed: Response
        do {
            parsed = try JSONDecoder().decode(Response.self, from: jsonData)
        } catch {
            throw SummaryEngineError.decoding("agenda fill JSON: \(error.localizedDescription) — raw: \(jsonText.prefix(200))")
        }

        var byId: [UUID: String] = [:]
        for (key, value) in parsed.sections {
            if let uuid = UUID(uuidString: key) { byId[uuid] = value }
        }
        return AgendaFillResult(sections: byId, offAgenda: parsed.offAgenda ?? [])
    }

    // Interpret a user's free-text instruction into structured export routing.
    struct ExportRouting: Decodable {
        let folder: String?
        let filename: String?
    }

    func routeExport(
        instruction: String,
        defaultFolder: String,
        defaultFilename: String
    ) async throws -> ExportRouting {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ExportRouting(folder: defaultFolder, filename: defaultFilename)
        }

        let system = """
        You are a routing helper. The user is exporting a meeting transcript and has given a \
        natural-language instruction about where it should go. Read the instruction and respond \
        ONLY with a JSON object, no prose:

        {
          "folder": "the folder name they implied, or the default if not specified",
          "filename": "the filename (no extension) they implied, or the default if not specified"
        }

        Rules:
        - Single folder name, no slashes, no leading/trailing whitespace.
        - Filename: human-readable, no .md extension, no slashes, no quotes.
        - If the instruction doesn't mention a folder or filename, return the default for that field.
        """

        let userPayload: [String: String] = [
            "instruction": trimmed,
            "default_folder": defaultFolder,
            "default_filename": defaultFilename,
        ]
        let payloadJSON = String(data: try JSONEncoder().encode(userPayload), encoding: .utf8) ?? "{}"

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 256,
            "system": system,
            "messages": [["role": "user", "content": payloadJSON]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
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
            throw SummaryEngineError.http(status: http.statusCode, message: msg)
        }

        struct APIContent: Decodable { let type: String; let text: String }
        struct APIEnvelope: Decodable { let content: [APIContent] }
        let envelope = try JSONDecoder().decode(APIEnvelope.self, from: data)
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw SummaryEngineError.decoding("no text content")
        }
        let cleanText = stripFences(text)
        guard let jsonData = cleanText.data(using: .utf8) else {
            throw SummaryEngineError.decoding("not utf8")
        }
        return try JSONDecoder().decode(ExportRouting.self, from: jsonData)
    }

    struct LiveContext {
        let recentTranscript: String?
        static let none = LiveContext(recentTranscript: nil)
    }

    /// Single-turn convenience wrapper.
    func quickAnswer(question: String) -> AsyncThrowingStream<String, Error> {
        quickAnswer(turns: [AssistantTurn(role: .user, content: question)], context: .none)
    }

    /// Live in-meeting assistant: streams a short answer (1–3 sentences), with
    /// Anthropic's web_search tool enabled so real-time questions work.
    /// `turns` should end with the new user question; prior turns provide follow-up context.
    func quickAnswer(turns: [AssistantTurn], context: LiveContext) -> AsyncThrowingStream<String, Error> {
        let webSearchTool: [String: Any] = [
            "type": "web_search_20250305",
            "name": "web_search",
            "max_uses": 3
        ]
        var systemPrompt = """
        You are Marty, a live in-meeting assistant. The user holds a hotkey to ask quick \
        questions, sometimes during a meeting, sometimes not. You are having an ongoing \
        conversation with the user: prior messages in this thread are real follow-ups from \
        the SAME user — use them as context. If they say "it", "that", "those", or "and X", \
        resolve the reference from earlier turns and answer directly. Never ask for context \
        that's already in the thread.

        ANSWER STYLE — optimized for scanning during a live meeting:

        - Single-fact questions → just the fact. No sentence wrapper.
            "Marcus Chen." not "The CEO is Marcus Chen."
            "$4.2M." not "The MRR is $4.2M."
        - List/multi-item questions → short header line, then a bullet list. \
          **Bold** only the key name or number on each line — never bold whole sentences.
        - NEVER include URLs, hyperlinks, or markdown links. No [text](url). Strip them.
        - NEVER include source citations. No "Based on…", "According to…", "See the document…", \
          "Your Notion workspace shows…". The user knows where the info came from.
        - NO bonus context the user didn't ask for. No "Note:", "Also worth noting:", \
          "Additionally:". They'll ask a follow-up if they want more.
        - NO hedging language ("approximately", "around", "roughly") unless the source is genuinely fuzzy.
        - Use tools (web_search, search_notion) silently — never narrate using them.
        - Length budget: single-fact ≤15 words. List ≤60 words total.

        Allowed markdown (rendered in the UI): **bold**, *italic*, line breaks. \
        Use **bold** sparingly — only for the most important token per line.

        Examples:

        Q: "Who's the CEO of Helix Robotics?"
        A: **Marcus Chen**.

        Q: "MRR for Q1?"
        A: **$4.2M**.

        Q: "When does the contract expire?"
        A: **March 14, 2027**.

        Q: "Any new hires?"
        A: Three Q1 hires:
        • **Priya Anand** — VP Engineering
        • **Tomás Reyes** — Senior AE
        • **Aisha Okonkwo** — Head of People

        Q: "Capital of Sweden?"
        A: **Stockholm**.
        """
        if let tail = context.recentTranscript, !tail.isEmpty {
            systemPrompt += """


            Live meeting transcript (last ~90s, may contain ASR errors):
            ---
            \(tail)
            ---
            Use this only if the user's question is about what was just said in the meeting. \
            Don't quote it verbatim unless asked. The user asking you is "You"; other speakers \
            are participants in the meeting — don't confuse them.
            """
        }
        let messages: [[String: Any]] = turns.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 1024,
            "stream": true,
            "tools": [webSearchTool],
            "system": systemPrompt,
            "messages": messages
        ]

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    request.setValue("web-search-2025-03-05", forHTTPHeaderField: "anthropic-beta")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: SummaryEngineError.http(status: -1, message: "no http response"))
                        return
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 500 { break } }
                        continuation.finish(throwing: SummaryEngineError.http(status: http.statusCode, message: body))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        guard let jd = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any] else {
                            continue
                        }
                        let type = obj["type"] as? String
                        if type == "content_block_delta",
                           let delta = obj["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }
                        if type == "message_stop" { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Agentic loop (client-side tool use)

    /// Events the agentic loop yields. The HUD interprets these to show status
    /// during tool execution and stream the final answer text.
    enum AgenticEvent {
        case textDelta(String)
        case toolStart(name: String)
        case toolEnd(name: String, ok: Bool)
        case citations([AnthropicCitation])
    }

    struct AnthropicCitation: Equatable {
        let title: String
        let url: String
    }

    /// Multi-turn streaming with client-side tool execution. If `registry` is
    /// empty this behaves like `quickAnswer(turns:context:)` but yields the
    /// richer event stream so the HUD can show "Looking in your Notion…".
    func quickAnswerWithTools(
        turns: [AssistantTurn],
        context: LiveContext,
        registry: ToolRegistry
    ) -> AsyncThrowingStream<AgenticEvent, Error> {
        var systemPrompt = """
        You are Marty, a live in-meeting assistant. The user holds a hotkey to ask quick \
        questions during meetings. You're having an ongoing conversation: prior messages \
        in this thread are real follow-ups from the SAME user — use them as context.

        ANSWER STYLE — optimized for scanning during a live meeting.

        FORMAT RULES (apply every time):

        1. Bold every key noun: every person name, every company name, every number, \
           every date. Wrap them in **double asterisks**. This is not optional — bold the \
           names so the user can scan the bubble at a glance.
        2. Single-fact questions → just the bolded fact. No sentence wrapper.
            "**Marcus Chen**, co-founder." not "The CEO is Marcus Chen."
            "**$4.2M**, up 18% QoQ." not "The MRR is $4.2M…"
        3. List/multi-item questions → one short header line, then a bullet list. Each \
           bullet starts with "• " (the bullet glyph, not a hyphen). Pattern:
              • **Person Name** — Role *(prior company / prior role)*
           Include the most useful supporting detail in italics inside parentheses.
        4. If the answer came from a Notion document (you used `search_notion`), end with \
           one line linking the source page in markdown: `→ [Page Title](url)`. Exactly \
           one link, on its own line, at the end. No "see the document" prose around it.
        5. NEVER narrate tool calls. NEVER write "I'll search…", "Let me look up…", \
           "Based on your Notion workspace…". Just answer.
        6. NEVER add bonus info the user didn't ask for. No "Note:", "Also worth noting:".
        7. NO hedging ("approximately", "around") unless the source is genuinely fuzzy.
        8. Length budget: single-fact ≤25 words. List ≤90 words total (excluding the link).

        Allowed markdown (rendered live): **bold**, *italic*, [text](url), line breaks, "• " bullets.

        Tool selection (silently):
        - `search_notion` → anything that might be in the user's workspace.
        - `exa_search` → public real-time / web data: weather, news, recent events, prices, sports.
        - Static knowledge (math, definitions, code) → no tool.

        Examples:

        Q: "Who's the CEO of Helix Robotics?"
        A: **Marcus Chen**, co-founder.
        → [Helix Robotics — Q1 2026 Investor Update](https://notion.so/…)

        Q: "MRR for Q1?"
        A: **$4.2M**, up 18% QoQ.
        → [Helix Robotics — Q1 2026 Investor Update](https://notion.so/…)

        Q: "Any new hires?"
        A: Three Q1 hires:
        • **Priya Anand** — VP Engineering *(ex-Stripe, ex-Boston Dynamics)*
        • **Tomás Reyes** — Senior AE *(ex-Samsara)*
        • **Aisha Okonkwo** — Head of People
        → [Helix Robotics — Q1 2026 Investor Update](https://notion.so/…)

        Q: "Capital of Sweden?"
        A: **Stockholm**.
        (No link line — answered from general knowledge, not from a Notion document.)
        """
        if let tail = context.recentTranscript, !tail.isEmpty {
            systemPrompt += """


            Live meeting transcript (last ~90s, may contain ASR errors):
            ---
            \(tail)
            ---
            """
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Build initial messages from the turns array.
                    var messages: [[String: Any]] = turns.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }

                    // Tools come entirely from the registry now (no server-side web_search).
                    let tools: [[String: Any]] = registry.tools.map { $0.apiSpec() }

                    // Up to 5 agentic turns (safety bound).
                    for _ in 0..<5 {
                        let body: [String: Any] = [
                            "model": "claude-haiku-4-5",
                            "max_tokens": 1024,
                            "stream": true,
                            "tools": tools,
                            "system": systemPrompt,
                            "messages": messages
                        ]
                        var request = URLRequest(url: self.endpoint)
                        request.httpMethod = "POST"
                        request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                        request.setValue("application/json", forHTTPHeaderField: "content-type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                        request.httpBody = try JSONSerialization.data(withJSONObject: body)

                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            continuation.finish(throwing: SummaryEngineError.http(status: -1, message: "no http response"))
                            return
                        }
                        guard http.statusCode == 200 else {
                            var bodyStr = ""
                            for try await line in bytes.lines { bodyStr += line; if bodyStr.count > 500 { break } }
                            continuation.finish(throwing: SummaryEngineError.http(status: http.statusCode, message: bodyStr))
                            return
                        }

                        // Per-turn parse state.
                        var assistantText = ""
                        var pendingToolUses: [(index: Int, id: String, name: String, partialJSON: String)] = []
                        var contentBlocks: [[String: Any]] = []   // for the assistant message we'll append
                        var stopReason: String?

                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            if payload.isEmpty || payload == "[DONE]" { continue }
                            guard let jd = payload.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any] else {
                                continue
                            }
                            let type = obj["type"] as? String

                            if type == "content_block_start",
                               let cb = obj["content_block"] as? [String: Any],
                               let blockType = cb["type"] as? String,
                               let index = obj["index"] as? Int {
                                if blockType == "tool_use" {
                                    let id = (cb["id"] as? String) ?? ""
                                    let name = (cb["name"] as? String) ?? ""
                                    pendingToolUses.append((index, id, name, ""))
                                    continuation.yield(.toolStart(name: name))
                                }
                            }

                            if type == "content_block_delta",
                               let delta = obj["delta"] as? [String: Any] {
                                let deltaType = delta["type"] as? String
                                if deltaType == "text_delta", let text = delta["text"] as? String {
                                    assistantText += text
                                    continuation.yield(.textDelta(text))
                                } else if deltaType == "input_json_delta",
                                          let partial = delta["partial_json"] as? String,
                                          let index = obj["index"] as? Int,
                                          let i = pendingToolUses.firstIndex(where: { $0.index == index }) {
                                    pendingToolUses[i].partialJSON += partial
                                }
                            }

                            if type == "message_delta",
                               let delta = obj["delta"] as? [String: Any],
                               let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                            }

                            if type == "message_stop" { break }
                        }

                        // Build the assistant message content blocks in order.
                        if !assistantText.isEmpty {
                            contentBlocks.append(["type": "text", "text": assistantText])
                        }
                        for use in pendingToolUses {
                            let input: [String: Any]
                            if let data = use.partialJSON.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                input = obj
                            } else {
                                input = [:]
                            }
                            contentBlocks.append([
                                "type": "tool_use",
                                "id": use.id,
                                "name": use.name,
                                "input": input
                            ])
                        }

                        // If no tool calls — we're done.
                        let clientToolUses = pendingToolUses.filter { use in
                            registry.tools.contains(where: { $0.name == use.name })
                        }
                        if clientToolUses.isEmpty || stopReason != "tool_use" {
                            continuation.finish()
                            return
                        }

                        // Append assistant message to history.
                        messages.append(["role": "assistant", "content": contentBlocks])

                        // Execute client tools and build tool_result blocks.
                        var toolResults: [[String: Any]] = []
                        for use in clientToolUses {
                            let input: [String: Any]
                            if let data = use.partialJSON.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                input = obj
                            } else {
                                input = [:]
                            }
                            do {
                                let result = try await registry.execute(name: use.name, input: input)
                                toolResults.append([
                                    "type": "tool_result",
                                    "tool_use_id": use.id,
                                    "content": result
                                ])
                                continuation.yield(.toolEnd(name: use.name, ok: true))
                            } catch {
                                toolResults.append([
                                    "type": "tool_result",
                                    "tool_use_id": use.id,
                                    "content": "Error: \(error.localizedDescription)",
                                    "is_error": true
                                ])
                                continuation.yield(.toolEnd(name: use.name, ok: false))
                            }
                        }
                        messages.append(["role": "user", "content": toolResults])
                        // Loop again — Haiku now has tool results and will produce the final answer.
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

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
