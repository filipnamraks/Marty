import CoreML
import Foundation
import WhisperKit

final class WhisperKitEngine: TranscriptionEngine {
    private let pipe: WhisperKit
    var initialPrompt: String?
    /// ISO language code ("en", "sv"). nil = auto-detect per utterance —
    /// pinning skips detection, which misfires on short clips.
    var language: String?

    init(model: String = "openai_whisper-large-v3-v20240930",
         initialPrompt: String? = nil,
         language: String? = nil) async throws {
        // Pin inference to ANE+CPU, off the Metal GPU. The live Ollama fills
        // monopolize the GPU in bursts; on the default ("prefer ANE") options
        // some configs still put the encoder on .cpuAndGPU, which made
        // transcription queue behind LLM jobs and drop sentences. Explicit
        // pinning guarantees the two engines run on different silicon.
        let config = WhisperKitConfig(
            model: model,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )
        self.pipe = try await WhisperKit(config)
        self.initialPrompt = initialPrompt
        self.language = language
    }

    func transcribe(audioPath: String) async throws -> String {
        let results = try await pipe.transcribe(
            audioPath: audioPath,
            decodeOptions: decodeOptions()
        )
        return results.map { $0.text }.joined(separator: " ")
    }

    // Build DecodingOptions from the rolling prompt and pinned language.
    // The prompt is tokenized as Whisper's previous-utterance context, biasing
    // its vocabulary toward names and terms the speakers actually used.
    private func decodeOptions() -> DecodingOptions? {
        var options: DecodingOptions?
        if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty,
           let tokenizer = pipe.tokenizer {
            // Convention: leading space helps tokenizer treat it as continuation.
            let tokens = tokenizer.encode(text: " " + prompt).map { Int($0) }
            options = DecodingOptions(promptTokens: tokens)
        }
        if let language {
            var withLanguage = options ?? DecodingOptions()
            withLanguage.language = language
            options = withLanguage
        }
        return options
    }
}
