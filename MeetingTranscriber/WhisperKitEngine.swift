import Foundation
import WhisperKit

final class WhisperKitEngine: TranscriptionEngine {
    private let pipe: WhisperKit
    var initialPrompt: String?

    init(model: String = "openai_whisper-large-v3-v20240930", initialPrompt: String? = nil) async throws {
        let config = WhisperKitConfig(model: model)
        self.pipe = try await WhisperKit(config)
        self.initialPrompt = initialPrompt
    }

    func transcribe(audioPath: String) async throws -> String {
        let results = try await pipe.transcribe(
            audioPath: audioPath,
            decodeOptions: decodeOptions()
        )
        return results.map { $0.text }.joined(separator: " ")
    }

    // Build DecodingOptions with the user's session context tokenized as a Whisper "prompt".
    // Whisper uses this as previous-utterance context, biasing its vocabulary toward
    // names and terms the user mentioned.
    private func decodeOptions() -> DecodingOptions? {
        guard let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty,
              let tokenizer = pipe.tokenizer else {
            return nil
        }
        // Convention: leading space helps tokenizer treat it as continuation.
        let tokens = tokenizer.encode(text: " " + prompt).map { Int($0) }
        return DecodingOptions(promptTokens: tokens)
    }
}
