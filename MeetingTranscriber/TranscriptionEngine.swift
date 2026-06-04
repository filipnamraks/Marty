import Foundation

protocol TranscriptionEngine: AnyObject {
    /// Context the engine feeds the model as a decoding prompt. Re-read on every
    /// utterance, so callers can roll it forward as the session evolves (recent
    /// transcript tail + agenda terms) for cross-utterance continuity.
    var initialPrompt: String? { get set }

    func transcribe(audioPath: String) async throws -> String
}
