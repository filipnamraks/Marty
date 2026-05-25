import Foundation

struct KeyQuote: Codable, Hashable, Identifiable {
    var id: String { "\(timestamp ?? "--")|\(speaker)|\(quote.prefix(40))" }
    var quote: String
    var speaker: String
    var timestamp: String?
}

struct MeetingSummary: Codable, Hashable {
    var title: String?
    var summary: String
    var narrative: String?
    var keyPoints: [String]
    var actionItems: [String]
    var topics: [String]?
    var keyQuotes: [KeyQuote]?
    var decisions: [String]?
    var openQuestions: [String]?

    static let empty = MeetingSummary(
        title: nil, summary: "", narrative: nil,
        keyPoints: [], actionItems: [],
        topics: nil, keyQuotes: nil, decisions: nil, openQuestions: nil
    )
}
