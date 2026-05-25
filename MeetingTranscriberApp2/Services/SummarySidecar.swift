import Foundation

// Reads and writes <transcript>.summary.json sidecar files next to the .md transcripts
// so past sessions don't need to re-call the LLM every time they're opened.
enum SummarySidecar {
    static func url(for transcriptURL: URL) -> URL {
        let base = transcriptURL.deletingPathExtension()
        return base.appendingPathExtension("summary.json")
    }

    static func load(for transcriptURL: URL) -> MeetingSummary? {
        let url = self.url(for: transcriptURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    @discardableResult
    static func save(_ summary: MeetingSummary, for transcriptURL: URL) -> Bool {
        let url = self.url(for: transcriptURL)
        guard let data = try? JSONEncoder().encode(summary) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
