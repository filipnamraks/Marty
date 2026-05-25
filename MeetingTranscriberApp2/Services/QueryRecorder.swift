import Foundation
import AVFoundation

/// Short-burst mic recorder for the hotkey query. Independent of the meeting's
/// MicCapture so triggering Marty mid-call doesn't interrupt the transcript.
final class QueryRecorder {

    enum RecorderError: Error, LocalizedError {
        case engineFailed(String)
        case noAudioCaptured
        case fileWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .engineFailed(let m): return "Mic failed: \(m)"
            case .noAudioCaptured:     return "Didn't hear anything — hold ⇧⌘M and speak."
            case .fileWriteFailed(let m): return "Couldn't write audio: \(m)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var bufferCount = 0
    private var tapped = false

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.engineFailed("input format has zero sample rate (mic disconnected?)")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marty-query-\(UUID().uuidString).caf")
        let f: AVAudioFile
        do {
            f = try AVAudioFile(
                forWriting: url,
                settings: inputFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw RecorderError.fileWriteFailed(error.localizedDescription)
        }
        self.file = f
        self.fileURL = url
        self.bufferCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let file = self.file else { return }
            do {
                try file.write(from: buffer)
                self.bufferCount += 1
            } catch {
                // Drop quietly — partial file is still usable.
            }
        }
        tapped = true

        do {
            try engine.start()
        } catch {
            cancel()
            throw RecorderError.engineFailed(error.localizedDescription)
        }
    }

    /// Stops the engine, flushes the file, returns the URL of the recorded clip.
    /// Throws `.noAudioCaptured` if too few samples were captured to bother transcribing.
    @discardableResult
    func stop() throws -> URL {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        engine.stop()
        file = nil // flush

        guard let url = fileURL else {
            throw RecorderError.noAudioCaptured
        }
        // Heuristic: under ~200ms (very short hotkey tap) means probably nothing useful.
        if bufferCount < 5 {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
            throw RecorderError.noAudioCaptured
        }
        fileURL = nil
        return url
    }

    func cancel() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        engine.stop()
        file = nil
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }

    deinit { cancel() }
}
