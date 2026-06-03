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

        let allCandidates = await candidates(for: trimmed)
        guard !allCandidates.isEmpty else { throw ResolverError.noCandidates }

        let chosenId = try await pickCandidate(intent: trimmed, candidates: allCandidates)
        guard let chosen = allCandidates.first(where: { $0.compositeId == chosenId }) else {
            // Claude returned an unknown id; fall back to the top-scored candidate.
            return try await fetchAgenda(for: allCandidates[0])
        }
        return try await fetchAgenda(for: chosen)
    }

    /// Gather candidates from every available source in parallel. Backs the ⌘K
    /// command palette's live result list. Returns [] when nothing is connected.
    func candidates(for intent: String) async -> [AgendaCandidate] {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let available = sources.filter { $0.isAvailable }
        guard !available.isEmpty else { return [] }

        var all: [AgendaCandidate] = []
        await withTaskGroup(of: [AgendaCandidate].self) { group in
            for source in available {
                group.addTask { await source.candidates(for: trimmed) }
            }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return all
    }

    /// Fetch + parse a single candidate the user picked in the palette.
    func fetchAgenda(for candidate: AgendaCandidate) async throws -> Agenda {
        try await fetchAndParse(candidate)
    }

    // MARK: - Picker

    private func pickCandidate(intent: String, candidates: [AgendaCandidate]) async throws -> String {
        // Single-candidate shortcut — no need to spend an LLM call.
        if candidates.count == 1 { return candidates[0].compositeId }

        let payload: [String: Any] = [
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
        let candidatesJSON = String(
            data: (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        do {
            let id = try await OllamaEngine.fromStorage()
                .pickAgendaCandidate(intent: intent, candidatesJSON: candidatesJSON)
            // Guard against a hallucinated id — fall back to the top-scored candidate.
            return candidates.contains { $0.compositeId == id } ? id : candidates[0].compositeId
        } catch {
            // Local model unavailable → don't fail intake; take the best fuzzy match.
            return candidates[0].compositeId
        }
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
