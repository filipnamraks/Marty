import AVFoundation
import Foundation

// Energy-based VAD that accumulates speech into utterances.
// When 800ms of silence follows speech (>=300ms long), flushes the utterance
// as a .caf file and invokes the callback with (label, file URL).
final class VADChunker {
    private let label: String
    private let onUtterance: (String, URL) -> Void

    private let speechThresholdRMS: Float = 0.01
    private let silenceTimeoutMs: Double = 800
    private let minSpeechMs: Double = 300
    private let maxUtteranceMs: Double = 25000

    private var samples: [Float] = []
    private var inSpeech = false
    private var speechMs: Double = 0
    private var silenceMs: Double = 0
    private var bufferedMs: Double = 0
    private var sampleRate: Double = 16000

    private let tmpDir: URL
    private var utteranceCounter = 0
    private let serialQueue = DispatchQueue(label: "vad-chunker")

    init(label: String, onUtterance: @escaping (String, URL) -> Void) {
        self.label = label
        self.onUtterance = onUtterance
        self.tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-transcriber")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func feed(_ pcm: AVAudioPCMBuffer) {
        serialQueue.sync {
            self.process(pcm)
        }
    }

    private func process(_ pcm: AVAudioPCMBuffer) {
        guard let channelData = pcm.floatChannelData else { return }
        let frameLength = Int(pcm.frameLength)
        guard frameLength > 0 else { return }

        sampleRate = pcm.format.sampleRate

        // Mix down to mono
        var mono = [Float](repeating: 0, count: frameLength)
        let channelCount = Int(pcm.format.channelCount)
        if channelCount >= 2 {
            let left = channelData[0]
            let right = channelData[1]
            for i in 0..<frameLength {
                mono[i] = (left[i] + right[i]) * 0.5
            }
        } else {
            let src = channelData[0]
            for i in 0..<frameLength {
                mono[i] = src[i]
            }
        }

        // RMS
        var sumSquares: Float = 0
        for s in mono { sumSquares += s * s }
        let rms = sqrt(sumSquares / Float(frameLength))

        let durMs = Double(frameLength) / sampleRate * 1000

        if rms > speechThresholdRMS {
            samples.append(contentsOf: mono)
            bufferedMs += durMs
            speechMs += durMs
            silenceMs = 0
            if !inSpeech && speechMs >= minSpeechMs {
                inSpeech = true
            }
            if inSpeech && bufferedMs >= maxUtteranceMs {
                flush()
            }
        } else {
            if inSpeech {
                samples.append(contentsOf: mono)
                bufferedMs += durMs
                silenceMs += durMs
                if silenceMs >= silenceTimeoutMs {
                    flush()
                }
            } else {
                samples.removeAll(keepingCapacity: true)
                bufferedMs = 0
                speechMs = 0
            }
        }
    }

    private func flush() {
        defer {
            samples.removeAll(keepingCapacity: true)
            bufferedMs = 0
            speechMs = 0
            silenceMs = 0
            inSpeech = false
        }
        guard !samples.isEmpty else { return }

        utteranceCounter += 1
        let url = tmpDir.appendingPathComponent("\(label)-\(utteranceCounter).caf")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else { return }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        let dst = pcm.floatChannelData![0]
        for i in 0..<samples.count {
            dst[i] = samples[i]
        }

        do {
            let file = try AVAudioFile(forWriting: url,
                                       settings: format.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: pcm)
            onUtterance(label, url)
        } catch {
            // ignore
        }
    }
}
