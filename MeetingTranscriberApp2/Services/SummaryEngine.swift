import Foundation

protocol SummaryEngine {
    func summarize(transcript: [TranscriptLine]) async throws -> MeetingSummary
    func cleanTranscript(transcript: [TranscriptLine]) async throws -> [TranscriptLine]
}

enum SummaryEngineError: LocalizedError {
    case missingAPIKey
    case emptyTranscript
    case http(status: Int, message: String)
    case decoding(String)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Anthropic API key set. Add one in Settings."
        case .emptyTranscript: return "Transcript is empty — nothing to summarize."
        case .http(let status, let msg):
            return "API error \(status): \(msg)"
        case .decoding(let msg):
            return "Couldn't decode response: \(msg)"
        case .transport(let error):
            return "Network: \(error.localizedDescription)"
        }
    }
}

enum SummaryModel: String, CaseIterable, Identifiable {
    case haiku45 = "claude-haiku-4-5"
    case sonnet46 = "claude-sonnet-4-6"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .haiku45: return "Claude Haiku 4.5 (fast, cheap)"
        case .sonnet46: return "Claude Sonnet 4.6 (better, pricier)"
        }
    }
    var defaultMaxTokens: Int { 1024 }
}
