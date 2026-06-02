import Foundation

/// Turns a one-line natural-language meeting hint ("the budget review at 3pm")
/// into an Agenda. Gathers candidates from every available AgendaSource, asks
/// Claude to pick the best match, fetches that candidate's content, and parses
/// it into the same Agenda shape AgendaParser produces from pasted markdown.
@MainActor
final class AgendaResolver {
    enum ResolverError: Error, LocalizedError {
        case noSourcesAvailable
        case noCandidates
        case pickerFailed(String)
        case fetchFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSourcesAvailable:
                return "No source is connected. Add a Notion integration or connect your calendar in Settings."
            case .noCandidates:
                return "No matching events or pages were found. Try a more specific phrase."
            case .pickerFailed(let m): return "Picker failed: \(m)"
            case .fetchFailed(let m):  return "Fetch failed: \(m)"
            }
        }
    }

    private let sources: [AgendaSource]

    init(sources: [AgendaSource]) {
        self.sources = sources
    }

    /// Default wiring — calendar + notion + drive stub, pulling stores from
    /// the environment. Pass an explicit array in tests / previews.
    static func standard(calendar: CalendarStore) -> AgendaResolver {
        AgendaResolver(sources: [
            CalendarAgendaSource(store: calendar),
            NotionAgendaSource(),
            DriveAgendaSource(),
        ])
    }

    func resolve(intent: String) async throws -> Agenda {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ResolverError.noCandidates }

        let available = sources.filter { $0.isAvailable }
        guard !available.isEmpty else { throw ResolverError.noSourcesAvailable }

        // Gather candidates from each source in parallel.
        var allCandidates: [AgendaCandidate] = []
        await withTaskGroup(of: [AgendaCandidate].self) { group in
            for source in available {
                group.addTask { await source.candidates(for: trimmed) }
            }
            for await batch in group { allCandidates.append(contentsOf: batch) }
        }

        guard !allCandidates.isEmpty else { throw ResolverError.noCandidates }

        let chosenId = try await pickCandidate(intent: trimmed, candidates: allCandidates)
        guard let chosen = allCandidates.first(where: { $0.compositeId == chosenId }) else {
            // Claude returned an unknown id; fall back to the top-scored candidate.
            return try await fetchAndParse(allCandidates[0])
        }
        return try await fetchAndParse(chosen)
    }

    // MARK: - Picker

    private func pickCandidate(intent: String, candidates: [AgendaCandidate]) async throws -> String {
        // Single-candidate shortcut — no need to spend a Claude call.
        if candidates.count == 1 { return candidates[0].compositeId }

        let engine: AnthropicEngine
        do { engine = try AnthropicEngine.fromStorage() }
        catch { return candidates[0].compositeId }  // no key → take the top score

        let payload: [String: Any] = [
            "intent": intent,
            "candidates": candidates.map { c in
                [
                    "id": c.compositeId,
                    "source": c.source,
                    "title": c.title,
                    "snippet": c.snippet ?? "",
                    "when": c.when.map { ISO8601DateFormatter().string(from: $0) } as Any,
                ] as [String: Any]
            }
        ]
        let payloadJSON = String(
            data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8
        ) ?? "{}"

        let system = """
        You are an agenda picker. The user typed a one-line instruction describing the meeting they're \
        about to have. You're given a list of candidate items (calendar events or Notion pages). \
        Pick the single best match.

        Respond ONLY with a JSON object — no prose:
        { "id": "<the chosen candidate id, exactly as given>" }

        Rules:
        - Prefer candidates whose title closely matches the user's intent.
        - When the intent mentions a time ("at 3pm", "today", "tomorrow morning"), prefer the calendar \
          event closest to that time. Use the candidate "when" field.
        - If nothing matches well, return the closest title match anyway. Always return something.
        - The id MUST be one of the provided ids verbatim, including the source prefix (e.g. "calendar:abc123").
        """

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 200,
            "system": system,
            "messages": [["role": "user", "content": payloadJSON]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(try engineAPIKey(), forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<no body>"
            throw ResolverError.pickerFailed(msg)
        }

        struct APIContent: Decodable { let type: String; let text: String }
        struct APIEnvelope: Decodable { let content: [APIContent] }
        let envelope = try JSONDecoder().decode(APIEnvelope.self, from: data)
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw ResolverError.pickerFailed("no text content")
        }
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jd = cleaned.data(using: .utf8) else {
            throw ResolverError.pickerFailed("not utf8")
        }
        struct Pick: Decodable { let id: String }
        let pick = try JSONDecoder().decode(Pick.self, from: jd)
        return pick.id
    }

    private func engineAPIKey() throws -> String {
        guard let key = SecureStorage.read(SecureStorage.anthropicAPIKey), !key.isEmpty else {
            throw ResolverError.pickerFailed("no API key")
        }
        return key
    }

    // MARK: - Fetch + parse

    private func fetchAndParse(_ candidate: AgendaCandidate) async throws -> Agenda {
        guard let source = sources.first(where: { $0.sourceName == candidate.source }) else {
            throw ResolverError.fetchFailed("unknown source \(candidate.source)")
        }
        do {
            let markdown = try await source.fetchMarkdown(id: candidate.id)
            var agenda = AgendaParser.parse(markdown: markdown)
            // Preserve the candidate title if the parsed markdown lacks one.
            if agenda.title == "Untitled meeting" || agenda.title.isEmpty {
                agenda.title = candidate.title
            }
            return agenda
        } catch {
            throw ResolverError.fetchFailed(error.localizedDescription)
        }
    }
}
