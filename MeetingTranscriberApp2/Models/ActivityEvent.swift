import Foundation

struct ActivityEvent: Identifiable {
    enum Kind {
        case sessionStarted
        case sessionEnded
        case utteranceSaved
        case summaryUpdated
        case actionDetected
        case newSpeaker
        case info

        var label: String {
            switch self {
            case .sessionStarted: return "session started"
            case .sessionEnded: return "session ended"
            case .utteranceSaved: return "utterance saved"
            case .summaryUpdated: return "summary updated"
            case .actionDetected: return "action detected"
            case .newSpeaker: return "new speaker"
            case .info: return "info"
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let detail: String?

    init(_ kind: Kind, detail: String? = nil) {
        self.timestamp = Date()
        self.kind = kind
        self.detail = detail
    }
}
