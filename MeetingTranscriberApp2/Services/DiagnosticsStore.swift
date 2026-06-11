import Foundation

/// Opt-in, metadata-only usage diagnostics — a flight recorder, not a microphone.
///
/// When (and only when) the user enables "Collect diagnostics" in Settings,
/// Marty records HOW it behaved during agenda meetings: fill counts, latencies,
/// failures, refine timing, utterance statistics. Never a word of content — no
/// transcript text, no headlines, no titles, no names.
///
/// The data stays in a local JSON file and never travels on its own. The user
/// exports it manually from Settings (it's human-readable, so they can verify
/// what's in it first) and shares it however they choose. A delete button
/// removes everything collected.
@MainActor
final class DiagnosticsStore {
    static let shared = DiagnosticsStore()

    private static let enabledKey = "Marty.diagnosticsEnabled"
    /// Off by default — recording starts only after the user opts in.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Record shape (everything here is a number or a date — by design)

    struct MeetingRecord: Codable {
        var startedAt: Date
        var sectionsInAgenda: Int
        var durationMin: Double?
        // Live fills
        var fillsAttempted = 0
        var fillsSucceeded = 0
        var fillsFailed = 0
        var chunksSkipped = 0
        var skippedLines = 0
        var fillLatenciesS: [Double] = []
        var maxBacklogLines = 0
        // Refine pass
        var refineLatencyS: Double?
        var sectionsNotCovered: Int?
        // Transcription quality proxies (counts only, never text)
        var utterances = 0
        var totalWords = 0
        /// Utterances under 3 words — a proxy for the VAD clipping speech starts.
        var shortUtterances = 0
    }

    private struct Archive: Codable {
        var meetings: [MeetingRecord] = []
    }

    private var current: MeetingRecord?
    private var archive: Archive

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Marty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let loaded = try? JSONDecoder().decode(Archive.self, from: data) {
            archive = loaded
        } else {
            archive = Archive()
        }
    }

    // MARK: - Recording hooks (each is a no-op unless enabled AND a meeting is open)

    func beginMeeting(sections: Int) {
        guard Self.enabled else { return }
        current = MeetingRecord(startedAt: Date(), sectionsInAgenda: sections)
    }

    func recordUtterance(words: Int) {
        guard current != nil else { return }
        current?.utterances += 1
        current?.totalWords += words
        if words < 3 { current?.shortUtterances += 1 }
    }

    func recordFillAttempt(backlogLines: Int) {
        guard var record = current else { return }
        record.fillsAttempted += 1
        record.maxBacklogLines = max(record.maxBacklogLines, backlogLines)
        current = record
    }

    func recordFillSuccess(latencyS: Double) {
        guard current != nil else { return }
        current?.fillsSucceeded += 1
        current?.fillLatenciesS.append((latencyS * 10).rounded() / 10)
    }

    func recordFillFailure() {
        current?.fillsFailed += 1
    }

    func recordChunkSkipped(lines: Int) {
        guard current != nil else { return }
        current?.chunksSkipped += 1
        current?.skippedLines += lines
    }

    func recordRefine(latencyS: Double, sectionsNotCovered: Int) {
        guard current != nil else { return }
        current?.refineLatencyS = (latencyS * 10).rounded() / 10
        current?.sectionsNotCovered = sectionsNotCovered
    }

    /// Close the open meeting record and persist it.
    func endMeeting() {
        guard var record = current else { return }
        record.durationMin = (Date().timeIntervalSince(record.startedAt) / 6).rounded() / 10
        archive.meetings.append(record)
        current = nil
        save()
    }

    // MARK: - Export / delete

    var collectedMeetingCount: Int { archive.meetings.count }

    /// The human-readable export — computed summaries, pretty-printed so the
    /// user can read every byte before deciding to share it.
    func exportJSON() -> Data? {
        struct FillsOut: Codable {
            let attempted: Int, succeeded: Int, failed: Int
            let chunksSkipped: Int, skippedLines: Int
            let avgLatencyS: Double?, maxLatencyS: Double?, maxBacklogLines: Int
        }
        struct RefineOut: Codable { let latencyS: Double?; let sectionsNotCovered: Int? }
        struct SpeechOut: Codable {
            let utterances: Int, avgWordsPerUtterance: Double, pctUnder3Words: Double
        }
        struct MeetingOut: Codable {
            let startedAt: Date, durationMin: Double?, sectionsInAgenda: Int
            let liveFills: FillsOut, refinePass: RefineOut, transcription: SpeechOut
        }
        struct Payload: Codable {
            let note: String
            let martyVersion: String
            let generatedAt: Date
            let meetings: [MeetingOut]
        }

        let meetings = archive.meetings.map { m -> MeetingOut in
            let lat = m.fillLatenciesS
            return MeetingOut(
                startedAt: m.startedAt,
                durationMin: m.durationMin,
                sectionsInAgenda: m.sectionsInAgenda,
                liveFills: FillsOut(
                    attempted: m.fillsAttempted, succeeded: m.fillsSucceeded, failed: m.fillsFailed,
                    chunksSkipped: m.chunksSkipped, skippedLines: m.skippedLines,
                    avgLatencyS: lat.isEmpty ? nil : ((lat.reduce(0, +) / Double(lat.count)) * 10).rounded() / 10,
                    maxLatencyS: lat.max(),
                    maxBacklogLines: m.maxBacklogLines
                ),
                refinePass: RefineOut(latencyS: m.refineLatencyS, sectionsNotCovered: m.sectionsNotCovered),
                transcription: SpeechOut(
                    utterances: m.utterances,
                    avgWordsPerUtterance: m.utterances == 0 ? 0 :
                        (Double(m.totalWords) / Double(m.utterances) * 10).rounded() / 10,
                    pctUnder3Words: m.utterances == 0 ? 0 :
                        (Double(m.shortUtterances) / Double(m.utterances) * 1000).rounded() / 10
                )
            )
        }
        let payload = Payload(
            note: "Metadata-only Marty diagnostics: timings and counts. Contains no transcript text, headlines, titles or names.",
            martyVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            generatedAt: Date(),
            meetings: meetings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(payload)
    }

    /// Remove everything collected so far (and any open record).
    func deleteAll() {
        archive = Archive()
        current = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic])
    }
}
