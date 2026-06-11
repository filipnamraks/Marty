import Foundation

// Reads and writes <transcript>.agenda.json sidecar files next to the .md
// transcripts. The filled agenda document is the product's whole point — it
// must survive the app closing without the user remembering to export or
// add to library. Saved after every live fill, the refine pass, and every
// hand-edit; loaded back when a past session is opened.
enum AgendaSidecar {
    static func url(for transcriptURL: URL) -> URL {
        transcriptURL.deletingPathExtension().appendingPathExtension("agenda.json")
    }

    static func load(for transcriptURL: URL) -> Agenda? {
        let url = self.url(for: transcriptURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Agenda.self, from: data)
    }

    @discardableResult
    static func save(_ agenda: Agenda, for transcriptURL: URL) -> Bool {
        let url = self.url(for: transcriptURL)
        guard let data = try? JSONEncoder().encode(agenda) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
