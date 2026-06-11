import Foundation

enum SessionsScanner {
    static var transcriptsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingTranscripts")
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func scan() -> [SessionSummary] {
        let dir = transcriptsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }

        let summaries: [SessionSummary] = files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                let date = filenameFormatter.date(from: name)
                    ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date.distantPast

                var headerTitle = name
                var lineCount = 0
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    let allLines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    var found = false
                    for line in allLines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("# ") {
                            if !found {
                                headerTitle = String(trimmed.dropFirst(2))
                                found = true
                            }
                        } else if trimmed.hasPrefix("[") {
                            lineCount += 1
                        }
                    }
                }
                let title = SessionTitleStore.resolvedTitle(for: url, fallback: headerTitle)
                return SessionSummary(id: url, title: title, date: date, lineCount: lineCount)
            }
            .sorted { $0.date > $1.date }

        return summaries
    }

    // Move a session and all its sidecars to the Trash. Returns true on success.
    @discardableResult
    static func delete(_ session: SessionSummary) -> Bool {
        let candidates: [URL] = [
            session.id,
            SummarySidecar.url(for: session.id),
            CleanedTranscriptSidecar.url(for: session.id),
            AgendaSidecar.url(for: session.id),
            // Per-session folder holding the kept utterance audio ({stamp}/audio).
            session.id.deletingPathExtension(),
        ]
        var ok = true
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            } catch {
                ok = false
            }
        }
        SessionTitleStore.remove(for: session.id)
        return ok
    }

    // Parse a saved .md file into structured PastTranscript.Line entries.
    // Expected line format: [HH:mm:ss] [Speaker] text...
    static func load(_ summary: SessionSummary) -> PastTranscript {
        guard let contents = try? String(contentsOf: summary.id, encoding: .utf8) else {
            return PastTranscript(summary: summary, lines: [])
        }
        var result: [PastTranscript.Line] = []
        let lineRegex = #/^\[(?<ts>\d{2}:\d{2}:\d{2})\] \[(?<who>[^\]]+)\] (?<text>.+)$/#
        for line in contents.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = try? lineRegex.wholeMatch(in: trimmed) {
                result.append(PastTranscript.Line(
                    timestamp: String(match.output.ts),
                    speaker: String(match.output.who),
                    text: String(match.output.text)
                ))
            }
        }
        return PastTranscript(summary: summary, lines: result)
    }
}
