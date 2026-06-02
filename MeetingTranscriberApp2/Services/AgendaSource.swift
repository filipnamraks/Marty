import Foundation

/// A "local MCP" — a source the resolver can ask for agenda candidates that
/// match a natural-language meeting hint. The protocol intentionally maps to
/// what a tiny MCP server would expose: search, then fetch one by id.
@MainActor
protocol AgendaSource {
    /// Stable identifier for the source ("calendar", "notion", "drive", …).
    var sourceName: String { get }

    /// Whether the source is configured / authed and worth querying.
    var isAvailable: Bool { get }

    /// Return up to a handful of candidates that plausibly match the query.
    /// Implementations should be fast; failures return [].
    func candidates(for query: String) async -> [AgendaCandidate]

    /// Fetch the full markdown body for a previously-returned candidate id.
    /// Throws if the id is unknown or the fetch fails.
    func fetchMarkdown(id: String) async throws -> String
}

struct AgendaCandidate: Identifiable, Hashable {
    let source: String   // "calendar" | "notion" | …
    let id: String       // source-specific identifier
    let title: String
    let snippet: String? // location/time/excerpt to help Claude pick
    let when: Date?      // event start (calendar only)

    var compositeId: String { "\(source):\(id)" }
}

extension AgendaCandidate {
    static func parse(compositeId: String) -> (source: String, id: String)? {
        guard let sep = compositeId.firstIndex(of: ":") else { return nil }
        let src = String(compositeId[..<sep])
        let id = String(compositeId[compositeId.index(after: sep)...])
        return (src, id)
    }
}

// MARK: - Calendar adapter

/// Wraps the existing CalendarStore. Calendar events don't currently carry
/// a description in our model, so fetch returns a template agenda built from
/// the event title. Extending GoogleCalendarProvider to fetch event
/// descriptions is a follow-up that would make this far more useful.
final class CalendarAgendaSource: AgendaSource {
    let sourceName = "calendar"
    private let store: CalendarStore

    init(store: CalendarStore) { self.store = store }

    var isAvailable: Bool { !store.events.isEmpty }

    func candidates(for query: String) async -> [AgendaCandidate] {
        let now = Date()
        let upcoming = store.events.filter { $0.end >= now }
        let scored = upcoming.map { event -> (CalendarEvent, Int) in
            (event, fuzzyScore(query: query, target: event.title))
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { event, _ in
                let df = DateFormatter()
                df.dateFormat = "EEE HH:mm"
                let snippet = "\(df.string(from: event.start))" +
                    (event.location.map { " · \($0)" } ?? "")
                return AgendaCandidate(
                    source: sourceName,
                    id: event.id,
                    title: event.title,
                    snippet: snippet,
                    when: event.start
                )
            }
    }

    func fetchMarkdown(id: String) async throws -> String {
        guard let event = store.events.first(where: { $0.id == id }) else {
            throw NSError(domain: "CalendarAgendaSource", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Calendar event not found"])
        }
        // Template — calendar events lack a body field in our model today.
        return """
            # \(event.title)

            ## Discussion

            ## Decisions

            ## Next steps & owners
            """
    }

    private func fuzzyScore(query: String, target: String) -> Int {
        let q = query.lowercased()
        let t = target.lowercased()
        if t.contains(q) { return 100 }
        let qWords = q.split { !$0.isLetter && !$0.isNumber }
        var score = 0
        for w in qWords where t.contains(w) { score += 10 }
        return score
    }
}

// MARK: - Notion adapter

final class NotionAgendaSource: AgendaSource {
    let sourceName = "notion"
    private let provider: NotionProvider?

    init(provider: NotionProvider? = NotionProvider.fromStorage()) {
        self.provider = provider
    }

    var isAvailable: Bool { provider != nil }

    func candidates(for query: String) async -> [AgendaCandidate] {
        guard let provider else { return [] }
        do {
            let hits = try await provider.search(query: query, pageSize: 5)
            return hits.map { hit in
                AgendaCandidate(
                    source: sourceName,
                    id: hit.id,
                    title: hit.title,
                    snippet: hit.snippet,
                    when: nil
                )
            }
        } catch {
            return []
        }
    }

    func fetchMarkdown(id: String) async throws -> String {
        guard let provider else {
            throw NSError(domain: "NotionAgendaSource", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Notion not configured"])
        }
        return try await provider.readPageContent(pageId: id, maxChars: 8000)
    }
}

// MARK: - Drive stub

/// Drive doesn't have a search/read API in the codebase yet; this is a
/// placeholder so the resolver shape stays uniform. Hooking up Google Drive
/// reading is a follow-up.
final class DriveAgendaSource: AgendaSource {
    let sourceName = "drive"
    var isAvailable: Bool { false }
    func candidates(for query: String) async -> [AgendaCandidate] { [] }
    func fetchMarkdown(id: String) async throws -> String {
        throw NSError(domain: "DriveAgendaSource", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Drive agenda fetch not implemented"])
    }
}
