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
    /// Utterances flushed by the VAD but not yet transcribed. AgendaFiller only
    /// fires an LLM fill when this is 0, so Ollama never grabs the GPU while
    /// WhisperKit has work queued. Best-effort (incremented via a MainActor hop
    /// from the VAD queue), which is fine — the gate is an optimization.
    var pendingTranscriptions: Int = 0

    // Agenda-first flow (Phase 2). When non-nil, the UI renders AgendaDocumentView
    // and AgendaFiller drives periodic LLM fills against `lines`.
    var agenda: Agenda?
    var agendaFillState: SummaryState = .idle
    private var agendaFiller: AgendaFiller?

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
    /// Agenda/context terms that anchor the rolling Whisper prompt all session.
    private var agendaTerms: String?
    /// Where this session's utterance audio is kept (transcriptsDir/{stamp}/audio).
    private var sessionAudioDir: URL?

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
        pendingTranscriptions = 0

        state = .loading
        statusMessage = "Loading WhisperKit…"
        appendEvent(.info, detail: "loading model")

        Task {
            do {
                // Build the initial prompt: prefer agenda headings (live agenda-first flow),
                // fall back to sessionContext (legacy / past sessions).
                let prompt: String? = {
                    if let agenda = self.agenda {
                        let parts = ([agenda.title] + agenda.sections.map { $0.heading })
                            .filter { !$0.isEmpty }
                        return parts.isEmpty ? nil : parts.joined(separator: ", ")
                    }
                    let trimmed = self.sessionContext.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()
                self.agendaTerms = prompt
                let loadedEngine = try await WhisperKitEngine(model: WhisperConfig.model,
                                                              initialPrompt: prompt,
                                                              language: WhisperConfig.languageCode)
                self.engine = loadedEngine

                // Pre-warm the live draft model so its multi-second cold load
                // happens now — not minutes in, on the first fill, where it
                // visibly stuttered the machine. Fire-and-forget.
                if self.agenda != nil {
                    Task.detached { await OllamaEngine.fromStorage().prewarm() }
                }

                let transcriptsDir = SessionsScanner.transcriptsDir
                try? FileManager.default.createDirectory(at: transcriptsDir,
                                                         withIntermediateDirectories: true)
                let ts = DateFormatter()
                ts.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let stamp = ts.string(from: Date())
                let url = transcriptsDir.appendingPathComponent("\(stamp).md")

                // Keep this session's utterance audio next to the transcript so a
                // higher-quality re-transcription pass stays possible. Deleted with
                // the session (SessionsScanner.delete trashes the {stamp} folder).
                let audioDir = transcriptsDir.appendingPathComponent(stamp)
                    .appendingPathComponent("audio")
                try? FileManager.default.createDirectory(at: audioDir,
                                                         withIntermediateDirectories: true)
                self.sessionAudioDir = audioDir
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                let header = DateFormatter()
                header.dateFormat = "yyyy-MM-dd HH:mm"
                try handle.write(contentsOf: Data("# Meeting transcript — \(header.string(from: Date()))\n\n".utf8))
                self.mdHandle = handle
                self.transcriptFileURL = url

                let (stream, continuation) = AsyncStream.makeStream(of: (String, URL, Date).self)
                self.continuation = continuation

                let micChunker = VADChunker(label: "You") { [weak self] label, fileURL in
                    Task { @MainActor in self?.pendingTranscriptions += 1 }
                    continuation.yield((label, fileURL, Date()))
                }
                let sysChunker = VADChunker(label: "Them") { [weak self] label, fileURL in
                    Task { @MainActor in self?.pendingTranscriptions += 1 }
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
                                    self.updateRollingPrompt()
                                }
                            }
                        } catch {
                            // ignore individual errors
                        }
                        // Decrement once per dequeued chunk — success or failure —
                        // so the idle gate can't wedge shut.
                        self.pendingTranscriptions = max(0, self.pendingTranscriptions - 1)
                        // Keep the source audio (it's the only copy of what was
                        // actually said) — kept even when transcription failed,
                        // since that's exactly the clip worth re-running later.
                        if let audioDir = self.sessionAudioDir {
                            try? FileManager.default.moveItem(
                                at: fileURL,
                                to: audioDir.appendingPathComponent(fileURL.lastPathComponent)
                            )
                        } else {
                            try? FileManager.default.removeItem(at: fileURL)
                        }
                    }
                }

                self.state = .running
                self.statusMessage = "Listening"
                self.appendEvent(.sessionStarted)

                // Kick off live agenda fill loop if an agenda is loaded.
                if self.agenda != nil {
                    let filler = AgendaFiller(transcriber: self)
                    self.agendaFiller = filler
                    filler.start()
                }
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
            self.sessionAudioDir = nil
            self.agendaTerms = nil
            self.state = .idle
            self.statusMessage = "Ready when you are"

            // If running the agenda-first flow, run the final polish pass.
            // Otherwise fall back to the legacy summary + cleanTranscript pipeline.
            if self.agenda != nil, let filler = self.agendaFiller {
                self.agendaFillState = .loading
                Task {
                    filler.stop()
                    await filler.finalize()
                    await MainActor.run { self.agendaFillState = .ready }
                }
            } else {
                Task { await self.generateSummary() }
                Task { await self.cleanTranscript() }
            }
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
            let engine = OllamaEngine.fromStorage()
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
        appendEvent(.summaryUpdated, detail: "calling local model")
        do {
            let engine = OllamaEngine.fromStorage()
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

    /// Whisper uses its prompt as previous-utterance context. Re-derive it after
    /// every line: agenda terms keep proper nouns biased all session, the tail of
    /// the recent transcript gives cross-utterance continuity (the engine re-reads
    /// it per utterance). Capped ~600 chars, well under Whisper's 224-token budget.
    private func updateRollingPrompt() {
        var tailParts: [String] = []
        var chars = 0
        for line in lines.reversed() {
            chars += line.text.count + 1
            if chars > 600 { break }
            tailParts.append(line.text)
        }
        let recent = tailParts.reversed().joined(separator: " ")
        let parts = [agendaTerms, recent.isEmpty ? nil : recent].compactMap { $0 }
        engine?.initialPrompt = parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private func appendEvent(_ kind: ActivityEvent.Kind, detail: String? = nil) {
        activityEvents.append(ActivityEvent(kind, detail: detail))
        if activityEvents.count > 50 {
            activityEvents.removeFirst(activityEvents.count - 50)
        }
    }
}
