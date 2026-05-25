import Foundation

enum CleanedTranscriptSidecar {
    private struct Persistable: Codable {
        let speaker: String
        let timestamp: Date
        let text: String
    }

    static func url(for transcriptURL: URL) -> URL {
        transcriptURL.deletingPathExtension().appendingPathExtension("cleaned.json")
    }

    static func load(for transcriptURL: URL) -> [TranscriptLine]? {
        let url = self.url(for: transcriptURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let rows = try? JSONDecoder().decode([Persistable].self, from: data) else { return nil }
        return rows.map { TranscriptLine(timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text) }
    }

    @discardableResult
    static func save(_ lines: [TranscriptLine], for transcriptURL: URL) -> Bool {
        let rows = lines.map { Persistable(speaker: $0.speaker, timestamp: $0.timestamp, text: $0.text) }
        guard let data = try? JSONEncoder().encode(rows) else { return false }
        let url = self.url(for: transcriptURL)
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
