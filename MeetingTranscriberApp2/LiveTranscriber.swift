import Foundation
import SwiftUI

struct TranscriptLine: Identifiable {
    let id = UUID()
    let timestamp: Date
    let speaker: String
    let text: String

    var wordCount: Int {
        text.split { $0.isWhitespace }.count
    }
}

@MainActor
@Observable
final class LiveTranscriber {
    enum State {
        case idle
        case loading
        case running
        case stopping
    }

    enum SummaryState: Equatable {
        case idle
        case loading
        case ready
        case error(String)
    }

    var state: State = .idle
    var statusMessage: String = "Ready when you are"
    var lines: [TranscriptLine] = []
    var transcriptFileURL: URL?
    var activityEvents: [ActivityEvent] = []
    var elapsedSeconds: Int = 0
    var summary: MeetingSummary?
    var summaryState: SummaryState = .idle
    var cleanedLines: [TranscriptLine]?
    var cleaningState: SummaryState = .idle
    var sessionContext: String = ""

    /// Fired once when a recording begins (state transitions idle → loading).
    /// Used by LiveAssistant to clear its per-meeting conversation memory.
    var onRecordingStart: (() -> Void)?

    var speakerCount: Int {
        Set(lines.map(\.speaker)).count
    }
    var wordCount: Int {
        lines.reduce(0) { $0 + $1.wordCount }
    }
    var wordsPerMinute: Int {
        guard elapsedSeconds > 0 else { return 0 }
        let minutes = Double(elapsedSeconds) / 60.0
        guard minutes > 0 else { return 0 }
        return Int(Double(wordCount) / minutes)
    }

    private var engine: TranscriptionEngine?
    private var mic: MicCapture?
    private var sys: SystemCapture?
    private var workerTask: Task<Void, Never>?
    private var continuation: AsyncStream<(String, URL, Date)>.Continuation?
    private var mdHandle: FileHandle?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var seenSpeakers: Set<String> = []

    func start() {
        guard state == .idle else { return }
        // Wipe any leftover data from a past session the user might have opened.
        // Without this, `cleanedLines` from a previously-viewed session masks
        // the new live transcript (displayLines reads cleanedLines first).
        lines = []
        activityEvents = []
        elapsedSeconds = 0
        seenSpeakers = []
        transcriptFileURL = nil
        summary = nil
        summaryState = .idle
        cleanedLines = nil
        cleaningState = .idle

        state = .loading
        statusMessage = "Loading WhisperKit…"
        appendEvent(.info, detail: "loading model")
        onRecordingStart?()

        Task {
            do {
                let trimmed = self.sessionContext.trimmingCharacters(in: .whitespacesAndNewlines)
                let loadedEngine = try await WhisperKitEngine(initialPrompt: trimmed.isEmpty ? nil : trimmed)
                self.engine = loadedEngine

                let transcriptsDir = SessionsScanner.transcriptsDir
                try? FileManager.default.createDirectory(at: transcriptsDir,
                                                         withIntermediateDirectories: true)
                let ts = DateFormatter()
                ts.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let url = transcriptsDir.appendingPathComponent("\(ts.string(from: Date())).md")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                let header = DateFormatter()
                header.dateFormat = "yyyy-MM-dd HH:mm"
                try handle.write(contentsOf: Data("# Meeting transcript — \(header.string(from: Date()))\n\n".utf8))
                self.mdHandle = handle
                self.transcriptFileURL = url

                let (stream, continuation) = AsyncStream.makeStream(of: (String, URL, Date).self)
                self.continuation = continuation

                let micChunker = VADChunker(label: "You") { label, fileURL in
                    continuation.yield((label, fileURL, Date()))
                }
                let sysChunker = VADChunker(label: "Them") { label, fileURL in
                    continuation.yield((label, fileURL, Date()))
                }

                let micCapture = MicCapture()
                try micCapture.startStreaming { buf in micChunker.feed(buf) }
                self.mic = micCapture

                let sysCapture = SystemCapture()
                try await sysCapture.startStreaming { buf in sysChunker.feed(buf) }
                self.sys = sysCapture

                self.startedAt = Date()
                self.elapsedSeconds = 0
                self.seenSpeakers = []
                self.elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    Task { @MainActor in
                        if let started = self.startedAt {
                            self.elapsedSeconds = Int(Date().timeIntervalSince(started))
                        }
                    }
                }

                self.workerTask = Task { [weak self] in
                    guard let self else { return }
                    for await (label, fileURL, timestamp) in stream {
                        guard let engine = self.engine else { break }
                        do {
                            // Force transcription off MainActor. NonisolatedNonsendingByDefault
                            // would otherwise run it on main since we're @MainActor-isolated,
                            // freezing the UI during inference.
                            let text = try await Task.detached {
                                try await engine.transcribe(audioPath: fileURL.path)
                            }.value
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && trimmed != "[BLANK_AUDIO]" {
                                await MainActor.run {
                                    let isNewSpeaker = !self.seenSpeakers.contains(label)
                                    self.seenSpeakers.insert(label)
                                    if isNewSpeaker {
                                        self.appendEvent(.newSpeaker, detail: label)
                                    }
                                    self.lines.append(TranscriptLine(timestamp: timestamp,
                                                                     speaker: label,
                                                                     text: trimmed))
                                    self.appendEvent(.utteranceSaved, detail: label)
                                    let formatter = DateFormatter()
                                    formatter.dateFormat = "HH:mm:ss"
                                    let line = "[\(formatter.string(from: timestamp))] [\(label)] \(trimmed)\n"
                                    try? self.mdHandle?.write(contentsOf: Data(line.utf8))
                                }
                            }
                        } catch {
                            // ignore individual errors
                        }
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }

                self.state = .running
                self.statusMessage = "Listening"
                self.appendEvent(.sessionStarted)
            } catch {
                self.state = .idle
                self.statusMessage = "Failed to start: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        guard state == .running else { return }
        state = .stopping
        statusMessage = "Stopping…"

        Task {
            self.elapsedTimer?.invalidate()
            self.elapsedTimer = nil
            self.mic?.stop()
            try? await self.sys?.stop()
            self.continuation?.finish()
            await self.workerTask?.value
            try? self.mdHandle?.close()
            self.appendEvent(.sessionEnded)
            self.mic = nil
            self.sys = nil
            self.workerTask = nil
            self.continuation = nil
            self.mdHandle = nil
            self.engine = nil
            self.startedAt = nil
            self.state = .idle
            self.statusMessage = "Ready when you are"

            // Kick off the LLM summary AND transcript cleaning in parallel.
            // UI flips both to loading; each finishes independently.
            Task { await self.generateSummary() }
            Task { await self.cleanTranscript() }
        }
    }

    func reset() {
        guard state == .idle else { return }
        lines = []
        activityEvents = []
        elapsedSeconds = 0
        seenSpeakers = []
        transcriptFileURL = nil
        summary = nil
        summaryState = .idle
        cleanedLines = nil
        cleaningState = .idle
    }

    func cleanTranscript() async {
        guard !lines.isEmpty else { return }
        cleaningState = .loading
        appendEvent(.info, detail: "cleaning transcript")
        do {
            let engine = try AnthropicEngine.fromStorage()
            let cleaned = try await engine.cleanTranscript(transcript: lines)
            cleanedLines = cleaned
            cleaningState = .ready
            appendEvent(.info, detail: "transcript cleaned")
            if let url = transcriptFileURL {
                CleanedTranscriptSidecar.save(cleaned, for: url)
            }
        } catch let error as SummaryEngineError {
            cleaningState = .error(error.localizedDescription)
        } catch {
            cleaningState = .error(error.localizedDescription)
        }
    }

    func generateSummary() async {
        guard !lines.isEmpty else { return }
        summaryState = .loading
        appendEvent(.summaryUpdated, detail: "calling Anthropic")
        do {
            let engine = try AnthropicEngine.fromStorage()
            let result = try await engine.summarize(transcript: lines)
            summary = result
            summaryState = .ready
            appendEvent(.summaryUpdated, detail: "ready")
            if let url = transcriptFileURL {
                SummarySidecar.save(result, for: url)
            }
        } catch let error as SummaryEngineError {
            summaryState = .error(error.localizedDescription)
            appendEvent(.info, detail: "summary error")
        } catch {
            summaryState = .error(error.localizedDescription)
            appendEvent(.info, detail: "summary error")
        }
    }

    private func appendEvent(_ kind: ActivityEvent.Kind, detail: String? = nil) {
        activityEvents.append(ActivityEvent(kind, detail: detail))
        if activityEvents.count > 50 {
            activityEvents.removeFirst(activityEvents.count - 50)
        }
    }
}
