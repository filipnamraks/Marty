import Foundation

/// A meeting the user explicitly saved to the library. A single bundle holding
/// whichever parts they chose to keep — the agenda document, the transcript,
/// and/or the summary — under one file so they travel together.
struct SavedMeeting: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var date: Date

    var includesAgenda: Bool
    var includesTranscript: Bool
    var includesSummary: Bool

    var agenda: Agenda?
    var transcript: [Line]?
    var summary: MeetingSummary?

    struct Line: Codable, Hashable {
        var timestamp: Date
        var speaker: String
        var text: String
    }

    /// One-line description of what's inside, for the card footer.
    var partsLabel: String {
        var parts: [String] = []
        if includesAgenda { parts.append("Agenda") }
        if includesTranscript { parts.append("Transcript") }
        if includesSummary { parts.append("Summary") }
        return parts.joined(separator: " · ")
    }
}
