import AVFoundation
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

    /// DISABLED: prompt conditioning breaks turbo on a reused engine.
    /// Verified with `transcribe-batch` over a kept session's 20 clips:
    /// any promptTokens (rolling OR static, with or without special-token
    /// filtering) → first transcribe fine, every later one returns EMPTY;
    /// same clips with no prompt → 17/20 correct. Until the upstream
    /// WhisperKit issue is resolved, decode options carry only the language.
    /// `initialPrompt` stays settable (protocol contract) but is not consumed.
    private static let promptConditioningEnabled = false

    private func decodeOptions() -> DecodingOptions? {
        var options: DecodingOptions?
        if Self.promptConditioningEnabled,
           let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty,
           let tokenizer = pipe.tokenizer {
            // Convention: leading space helps tokenizer treat it as continuation.
            // Strip special tokens — encode() includes them, WhisperKit adds its own.
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                .map { Int($0) }
            options = DecodingOptions(promptTokens: tokens)
        }
        if let language {
            var withLanguage = options ?? DecodingOptions()
            withLanguage.language = language
            options = withLanguage
        }
        return options
    }

    /// Run one throwaway transcription of generated silence so the one-time
    /// CoreML/ANE attach cost is paid during the visible "loading" phase, not
    /// silently on the user's first real utterance (which looked like a hang).
    func warmup() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-warmup-\(ProcessInfo.processInfo.processIdentifier).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000) else { return }
        pcm.frameLength = 8000   // 0.5s of silence
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: pcm)
            _ = try await transcribe(audioPath: url.path)
        } catch {
            // Best-effort: a failed warmup just means the first utterance pays it.
        }
    }
}
