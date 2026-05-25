import AVFoundation
import Foundation

final class MicCapture {
    private let engine = AVAudioEngine()
    private var tapped = false

    // Existing file-based recording (kept for record command)
    func record(to outputURL: URL, durationSeconds: Double) async throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: inputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            try? file.write(from: buffer)
        }
        tapped = true

        try engine.start()
        try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
        engine.stop()
        if tapped {
            inputNode.removeTap(onBus: 0)
            tapped = false
        }
    }

    // Streaming mode for live transcription
    func startStreaming(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            onBuffer(buffer)
        }
        tapped = true
        try engine.start()
    }

    func stop() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        engine.stop()
    }
}
