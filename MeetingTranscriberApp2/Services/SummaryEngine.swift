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

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "Transcript is empty — nothing to summarize."
        case .http(let status, let msg):
            return "Local model error \(status): \(msg)"
        case .decoding(let msg):
            return "Couldn't decode the model's response: \(msg)"
        case .transport(let error):
            return "Network: \(error.localizedDescription)"
        case .ollamaUnreachable:
            return "Ollama isn't running. Start it (`ollama serve`) and pull a model, then try again."
        case .modelMissing(let tag):
            return "Model not installed. Run: ollama pull \(tag)"
        }
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
