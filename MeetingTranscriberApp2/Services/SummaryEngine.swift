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
    case ollamaUnreachable
    case modelMissing(String)
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
        case .ollamaUnreachable:
            return "Ollama isn't running. Start it (`ollama serve`) and pull a model, then try again."
        case .modelMissing(let tag):
            return "Model not installed. Run: ollama pull \(tag)"
        case .missingAPIKey:
            return "No Anthropic API key set. Add one in Settings, or switch agenda fills to Local."
        }
    }
}

// MARK: - Agenda fill engine abstraction

enum AgendaFillMode: String { case draft, refined }

struct AgendaFillResult {
    var sections: [UUID: String]
    var offAgenda: [String]
}

/// Anything that can fill an agenda from transcript text — the cloud
/// AnthropicEngine or the local OllamaEngine. AgendaFiller talks to this,
/// FillConfig decides which one it gets.
protocol AgendaFillEngine {
    func fillAgenda(agenda: Agenda, transcript: [TranscriptLine], mode: AgendaFillMode) async throws -> AgendaFillResult
    func fillAgendaIncremental(agenda: Agenda, newTranscript: [TranscriptLine]) async throws -> AgendaFillResult
}

/// Which engine runs the live agenda fills, plus per-engine scheduling tuning.
/// Cloud (Claude Haiku) is the default: it uses zero local GPU/RAM, so it never
/// competes with WhisperKit on a 16 GB machine the way a resident 7 GB local
/// model does. Local (Ollama) remains a fully offline option.
enum FillEngineKind: String { case cloud, local }

enum FillConfig {
    private static let d = UserDefaults.standard
    private static let engineKey = "Marty.fillEngine"

    static var engine: FillEngineKind {
        get { FillEngineKind(rawValue: d.string(forKey: engineKey) ?? "") ?? .cloud }
        set { d.set(newValue.rawValue, forKey: engineKey) }
    }

    static func makeFillEngine() throws -> AgendaFillEngine {
        switch engine {
        case .cloud: return try AnthropicEngine.fromStorage()
        case .local: return OllamaEngine.fromStorage()
        }
    }

    /// Scheduling knobs for AgendaFiller, per engine.
    struct Tuning {
        let engine: FillEngineKind
        /// Don't bother the model for fewer new lines than this.
        let minNewLines: Int
        /// Aim for one fill per this many seconds.
        let targetInterval: TimeInterval
        /// Cloud only: with WhisperKit busy, defer at most this long past the
        /// target before firing anyway. nil = strict idle gate (local — firing
        /// Ollama mid-Whisper-burst is the GPU collision this app fixed once).
        let maxWait: TimeInterval?
    }

    static var tuning: Tuning {
        switch engine {
        case .cloud:
            return Tuning(engine: .cloud, minNewLines: 2, targetInterval: 30, maxWait: 45)
        case .local:
            return Tuning(engine: .local, minNewLines: 6, targetInterval: 30, maxWait: nil)
        }
    }
}

/// Cloud (Anthropic) model configuration, stored in UserDefaults — the API key
/// itself lives in the Keychain (SecureStorage.anthropicAPIKey).
enum CloudLLM {
    private static let d = UserDefaults.standard
    private static let liveKey   = "Marty.cloudLiveModel"
    private static let refineKey = "Marty.cloudRefineModel"

    /// Live incremental fills: latency- and cost-sensitive, ~2 calls/minute.
    static let defaultLiveModel = "claude-haiku-4-5"
    /// Final refine pass: one quality-sensitive call per meeting.
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

/// Local LLM configuration, stored in UserDefaults (no secrets — just an Ollama
/// base URL and the two model tags). Defaults target a 16 GB Mac.
enum LocalLLM {
    private static let d = UserDefaults.standard
    private static let baseURLKey = "Marty.ollamaBaseURL"
    private static let draftKey   = "Marty.draftModel"
    private static let refineKey  = "Marty.refineModel"

    static let defaultBaseURL = "http://localhost:11434"
    static let defaultDraftModel = "gemma4:e2b"
    static let defaultRefineModel = "gemma4:e4b"

    static var baseURLString: String {
        get { d.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { d.set(newValue, forKey: baseURLKey) }
    }
    static var baseURL: URL {
        URL(string: baseURLString) ?? URL(string: defaultBaseURL)!
    }
    static var draftModel: String {
        get { d.string(forKey: draftKey) ?? defaultDraftModel }
        set { d.set(newValue, forKey: draftKey) }
    }
    static var refineModel: String {
        get { d.string(forKey: refineKey) ?? defaultRefineModel }
        set { d.set(newValue, forKey: refineKey) }
    }

    /// Curated suggestions shown in Settings pickers. Users can type any tag.
    static let suggestions: [LocalModelOption] = [
        .init(tag: "gemma4:e2b", label: "Gemma 4 e2b — fastest (7 GB)"),
        .init(tag: "gemma4:e4b", label: "Gemma 4 e4b — balanced (10 GB)"),
        .init(tag: "gemma4:26b", label: "Gemma 4 26b — best, 32 GB+ Macs (18 GB)"),
        .init(tag: "gemma4:31b", label: "Gemma 4 31b — largest, 32 GB+ Macs (20 GB)"),
    ]
}

struct LocalModelOption: Identifiable, Hashable {
    let tag: String
    let label: String
    var id: String { tag }
}

/// Speech-to-text (WhisperKit) configuration, stored in UserDefaults. The
/// default is the large-v3 *turbo* build: near large-v3 accuracy at a fraction
/// of the decode cost — which matters because transcription shares the machine
/// with the live Ollama fills.
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
