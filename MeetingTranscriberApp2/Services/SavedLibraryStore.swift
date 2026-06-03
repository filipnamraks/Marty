import Foundation

/// Persists user-saved meetings as one JSON file each under
/// ~/Documents/MeetingTranscripts/Library/. The library UI reads from here.
enum SavedLibraryStore {
    static var dir: URL {
        SessionsScanner.transcriptsDir.appendingPathComponent("Library", isDirectory: true)
    }

    private static func fileURL(for id: String) -> URL {
        dir.appendingPathComponent("\(id).json")
    }

    /// All saved meetings, newest first.
    static func all() -> [SavedMeeting] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SavedMeeting? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SavedMeeting.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    static func save(_ meeting: SavedMeeting) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(meeting) else { return false }
        do {
            try data.write(to: fileURL(for: meeting.id), options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func load(id: String) -> SavedMeeting? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? decoder.decode(SavedMeeting.self, from: data)
    }

    @discardableResult
    static func delete(_ id: String) -> Bool {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return true
        } catch {
            return false
        }
    }
}
