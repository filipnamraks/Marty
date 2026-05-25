import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 13.0, *)
final class SystemCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var streamingCallback: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "system-capture-queue")

    // File-based recording (kept for record-system command)
    func record(to url: URL, durationSeconds: Double) async throws {
        self.outputURL = url
        try await startCapture()
        try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
        try await stop()
    }

    // Streaming mode for live transcription
    func startStreaming(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        self.streamingCallback = onBuffer
        try await startCapture()
    }

    private func startCapture() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = s
        try await s.startCapture()
    }

    func stop() async throws {
        if let s = stream {
            try await s.stopCapture()
        }
        queue.sync {}
        self.file = nil
        self.stream = nil
        self.outputURL = nil
        self.streamingCallback = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                             channels: asbd.mChannelsPerFrame) else { return }
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                   bufferListNoCopy: audioBufferList.unsafePointer) else { return }

            // File mode
            if let url = self.outputURL {
                if self.file == nil {
                    self.file = try? AVAudioFile(forWriting: url,
                                                 settings: format.settings,
                                                 commonFormat: .pcmFormatFloat32,
                                                 interleaved: false)
                }
                try? self.file?.write(from: pcmBuffer)
            }

            // Streaming mode
            self.streamingCallback?(pcmBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // delegate requirement; no-op
    }
}
