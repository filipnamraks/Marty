import Foundation

protocol SummaryEngine {
    func summarize(transcript: [TranscriptLine]) async throws -> MeetingSummary
    func cleanTranscript(transcript: [TranscriptLine]) async throws -> [TranscriptLine]
}

enum SummaryEngineError: LocalizedError {
    case emptyTranscript
    case http(status: Int, message: String)
    case decoding(String)
    case transport(Error)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "Transcript is empty — nothing to summarize."
        case .http(let status, let msg):
            return "Model error \(status): \(msg)"
        case .decoding(let msg):
            return "Couldn't decode the model's response: \(msg)"
        case .transport(let error):
            return "Network: \(error.localizedDescription)"
        case .missingAPIKey:
            return "No Anthropic API key set. Add one in Settings."
        }
    }
}

// MARK: - Agenda fill types

enum AgendaFillMode: String { case draft, refined }

struct AgendaFillResult {
    var sections: [UUID: String]
    var offAgenda: [String]
}

/// Cloud (Anthropic) model configuration, stored in UserDefaults — the API key
/// itself lives in the Keychain (SecureStorage.anthropicAPIKey).
enum CloudLLM {
    private static let d = UserDefaults.standard
    private static let liveKey   = "Marty.cloudLiveModel"
    private static let refineKey = "Marty.cloudRefineModel"

    /// Live incremental fills: latency- and cost-sensitive, ~2 calls/minute.
    static let defaultLiveModel = "claude-haiku-4-5"
    /// Final refine pass + post-meeting summary/cleanup: one quality-sensitive
    /// call per meeting each.
    static let defaultRefineModel = "claude-sonnet-4-6"

    static var liveModel: String {
        get { d.string(forKey: liveKey) ?? defaultLiveModel }
        set { d.set(newValue, forKey: liveKey) }
    }
    static var refineModel: String {
        get { d.string(forKey: refineKey) ?? defaultRefineModel }
        set { d.set(newValue, forKey: refineKey) }
    }
}

struct LocalModelOption: Identifiable, Hashable {
    let tag: String
    let label: String
    var id: String { tag }
}

/// Speech-to-text (WhisperKit) configuration, stored in UserDefaults. The
/// default is the large-v3 *turbo* build: near large-v3 accuracy at a fraction
/// of the decode cost.
enum WhisperConfig {
    private static let d = UserDefaults.standard
    private static let modelKey = "Marty.whisperModel"
    private static let languageKey = "Marty.whisperLanguage"

    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo"

    static var model: String {
        get { d.string(forKey: modelKey) ?? defaultModel }
        set { d.set(newValue, forKey: modelKey) }
    }

    /// "auto" (detect per utterance) or an ISO code like "en" / "sv".
    static var languageSetting: String {
        get { d.string(forKey: languageKey) ?? "auto" }
        set { d.set(newValue, forKey: languageKey) }
    }
    /// The code passed to Whisper; nil means auto-detect.
    static var languageCode: String? {
        let v = languageSetting
        return v == "auto" ? nil : v
    }

    /// Curated suggestions shown in Settings. Users can type any WhisperKit tag.
    static let modelSuggestions: [LocalModelOption] = [
        .init(tag: "openai_whisper-large-v3-v20240930_turbo", label: "Large v3 Turbo — fast, recommended"),
        .init(tag: "openai_whisper-large-v3-v20240930", label: "Large v3 — most accurate, slowest"),
        .init(tag: "distil-whisper_distil-large-v3", label: "Distil Large v3 — fastest, English-leaning"),
    ]

    static let languageOptions: [(code: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("sv", "Svenska"),
    ]
}
