import Foundation
import SwiftUI
import AppKit
import Combine

/// Live in-meeting assistant. Press-and-hold ⇧⌘M to ask Marty a quick question
/// without breaking the meeting recording. Whisper transcribes the question,
/// Claude Haiku 4.5 (with web search) answers, the answer streams into a
/// floating HUD that sits over Zoom/Meet/anything.
@MainActor
final class LiveAssistant: ObservableObject {

    enum State: Equatable {
        case idle
        case permissionNeeded
        case listening
        case transcribing
        case thinking(question: String)
        case toolRunning(question: String, toolName: String, partialAnswer: String)
        case answering(question: String, answer: String)
        case done(question: String, answer: String)
        case error(message: String, question: String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var beepSuppressed: Bool = false
    @Published private(set) var conversationTurnCount: Int = 0
    /// Bumped each time ⌥⌘M is pressed — the HUD watches this and focuses
    /// the text field. (Counter pattern so SwiftUI sees a change every press.)
    @Published private(set) var focusTextRequest: Int = 0
    @Published private(set) var hudVisible: Bool = false

    private let hotkey = GlobalHotkeyMonitor()
    /// ⌥⌘M — opens the HUD in text-input mode (no recording).
    private let textHotkey = GlobalHotkeyMonitor(modifiers: CGEventFlags([.maskCommand, .maskAlternate]))
    private let recorder = QueryRecorder()
    private var whisper: WhisperKitEngine?
    private var hud: HUDWindowController?
    private var notch: NotchWindowController?
    private var dismissTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private let conversation = AssistantConversation()
    private weak var transcriber: LiveTranscriber?
    private var idleResetTask: Task<Void, Never>?
    private let idleTimeoutSeconds: UInt64 = 60 * 60

    /// Called once at app launch. Installs the global hotkey if Input Monitoring
    /// permission is granted; otherwise flags `.permissionNeeded` so the UI can
    /// surface the system-settings deeplink on first hotkey attempt.
    func start() {
        hotkey.onEvent = { [weak self] event in
            guard let self = self else { return }
            switch event {
            case .pressed:  self.handlePressed()
            case .released: self.handleReleased()
            }
        }
        textHotkey.onEvent = { [weak self] event in
            guard let self = self else { return }
            if case .pressed = event { self.openForText() }
        }
        do {
            try hotkey.start()
            beepSuppressed = hotkey.isConsuming
        } catch {
            state = .permissionNeeded
        }
        try? textHotkey.start()

        if notch == nil { notch = NotchWindowController(assistant: self) }
        notch?.show()
    }

    /// Open the HUD without recording, and ask the HUD to focus its text field.
    /// Triggered by ⌥⌘M or by the UI directly.
    func openForText() {
        switch state {
        case .listening, .transcribing, .thinking, .answering:
            return // don't interrupt an in-flight ask
        default: break
        }
        dismissTask?.cancel()
        ensureHUD()
        if case .idle = state {
            // Surface the HUD even when there's nothing to show yet.
            // Keep state .idle so the content area renders the idle/listening
            // body; the text field at the bottom is always available.
        }
        focusTextRequest &+= 1
    }

    /// Click-to-toggle the microphone. First press starts recording, second
    /// press stops it and runs the transcribe + ask pipeline. Mirrors the
    /// hold-to-speak hotkey but is a one-tap-twice click.
    func toggleRecording() {
        switch state {
        case .listening:
            handleReleased()
        case .idle, .done, .error:
            dismissTask?.cancel()
            ensureHUD()
            do {
                try recorder.start()
                state = .listening
            } catch {
                state = .error(message: error.localizedDescription, question: nil)
                scheduleAutoDismiss(after: 6)
            }
        case .permissionNeeded, .transcribing, .thinking, .toolRunning, .answering:
            return // ignore mid-flight
        }
    }

    /// Send a typed question through the same ask() pipeline as voice.
    func submitText(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        switch state {
        case .listening, .transcribing, .thinking, .answering:
            return
        default: break
        }
        dismissTask?.cancel()
        ensureHUD()
        state = .thinking(question: q)
        Task { await ask(q) }
    }

    /// Wire up the live transcriber so the assistant can (a) clear conversation
    /// memory when a new recording starts, and (b) feed Claude the recent
    /// transcript tail as system context for in-meeting follow-ups.
    func attach(transcriber: LiveTranscriber) {
        self.transcriber = transcriber
        transcriber.onRecordingStart = { [weak self] in
            Task { @MainActor in self?.resetConversation() }
        }
    }

    /// Read-only view of the chat thread. Kept current via the @Published
    /// `conversationTurnCount` which bumps whenever turns change.
    var conversationTurns: [AssistantTurn] {
        conversation.turns
    }

    func resetConversation() {
        print("[Marty] resetConversation called (had \(conversation.count) turns)")
        conversation.reset()
        conversationTurnCount = 0
        idleResetTask?.cancel()
        idleResetTask = nil
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Called by the HUD's text field on focus; keeps the panel alive
    /// while the user is composing a typed question.
    func suspendAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Explicit "clear the chat" — the X button. Wipes state so the next
    /// open starts fresh. Does NOT clear conversation memory (that's a
    /// separate "New thread" action).
    func dismissHUD() {
        dismissTask?.cancel()
        streamTask?.cancel()
        recorder.cancel()
        hud?.hide()
        hudVisible = false
        state = .idle
    }

    /// Soft hide — just removes the panel from the screen but leaves the
    /// last Q&A in `state` so it's visible again next time the HUD opens.
    /// Used by the notch toggle and the (now-removed) auto-dismiss.
    func hidePanelKeepState() {
        dismissTask?.cancel()
        hud?.hide()
        hudVisible = false
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Press / release handlers

    private func handlePressed() {
        // Only arm from idle / done / error. Ignore re-press during an in-flight ask.
        switch state {
        case .idle, .done, .error: break
        case .permissionNeeded: return
        default: return
        }

        dismissTask?.cancel()
        streamTask?.cancel()

        do {
            try recorder.start()
            state = .listening
            ensureHUD()
        } catch {
            state = .error(message: error.localizedDescription, question: nil)
            ensureHUD()
            scheduleAutoDismiss(after: 6)
        }
    }

    private func handleReleased() {
        guard case .listening = state else { return }
        state = .transcribing

        Task {
            do {
                let url = try recorder.stop()
                let engine = try await whisperEngine()
                // Detach: same reason as in LiveTranscriber — NonisolatedNonsendingByDefault
                // would run Whisper inference on MainActor and freeze the HUD.
                let raw = try await Task.detached {
                    try await engine.transcribe(audioPath: url.path)
                }.value
                try? FileManager.default.removeItem(at: url)

                let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty else {
                    state = .error(message: "Didn't catch that — try again.", question: nil)
                    scheduleAutoDismiss(after: 5)
                    return
                }
                state = .thinking(question: question)
                await ask(question)
            } catch {
                state = .error(message: error.localizedDescription, question: nil)
                scheduleAutoDismiss(after: 6)
            }
        }
    }

    // MARK: - Ask Haiku

    private func ask(_ question: String) async {
        let engine: AnthropicEngine
        do {
            engine = try AnthropicEngine.fromStorage(model: .haiku45)
        } catch {
            state = .error(message: "Add your Anthropic API key in Settings to use Marty's live assistant.",
                           question: question)
            scheduleAutoDismiss(after: 6)
            return
        }

        let turns = conversation.turns + [AssistantTurn(role: .user, content: question)]
        let context = AnthropicEngine.LiveContext(recentTranscript: recentTranscriptTail())
        print("[Marty] ask — prior turns: \(conversation.turns.count), sending \(turns.count) messages")
        for (i, t) in turns.enumerated() {
            let preview = t.content.prefix(80)
            print("[Marty]   [\(i)] \(t.role.rawValue): \(preview)")
        }

        let registry = ToolRegistry()
        registry.registerNotionIfAvailable()
        registry.registerExaIfAvailable()
        print("[Marty] tool registry has tools: \(registry.names)")

        var accumulated = ""
        state = .answering(question: question, answer: "")
        streamTask = Task { [weak self] in
            // Safety timeout: if the stream produces nothing for 30s, bail.
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self else { return }
                    if case .answering(_, let a) = self.state, a.isEmpty {
                        self.streamTask?.cancel()
                        self.state = .error(message: "Claude didn't respond in 30s. Try a simpler question.",
                                            question: question)
                        self.scheduleAutoDismiss(after: 8)
                    }
                }
            }
            do {
                let stream = engine.quickAnswerWithTools(turns: turns, context: context, registry: registry)
                for try await event in stream {
                    timeoutTask.cancel()
                    switch event {
                    case .textDelta(let text):
                        accumulated += text
                        await MainActor.run {
                            guard let self = self else { return }
                            self.state = .answering(question: question, answer: accumulated)
                        }
                    case .toolStart(let name):
                        // Pre-tool narration ("I'll search your Notion…") is noise —
                        // drop it so only the post-tool answer is shown.
                        accumulated = ""
                        await MainActor.run {
                            guard let self = self else { return }
                            self.state = .toolRunning(question: question,
                                                      toolName: name,
                                                      partialAnswer: "")
                        }
                    case .toolEnd:
                        await MainActor.run {
                            guard let self = self else { return }
                            self.state = .answering(question: question, answer: accumulated)
                        }
                    case .citations:
                        break // not used yet
                    }
                }
                timeoutTask.cancel()
                await MainActor.run {
                    guard let self = self else { return }
                    let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                    let answer = final.isEmpty ? "(no answer)" : final
                    self.state = .done(question: question, answer: answer)
                    self.conversation.append(AssistantTurn(role: .user, content: question))
                    self.conversation.append(AssistantTurn(role: .assistant, content: answer))
                    self.conversationTurnCount = self.conversation.count
                    print("[Marty] done — appended turn. Conversation now has \(self.conversation.count) entries.")
                    self.scheduleIdleReset()
                    // No auto-dismiss after a successful answer — the HUD
                    // stays so the user can re-read the chat. They close it
                    // with the X, the notch, or by starting a new question.
                }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    self.state = .error(message: error.localizedDescription, question: question)
                    self.scheduleAutoDismiss(after: 8)
                }
            }
        }
    }

    // MARK: - Context helpers

    /// Returns the tail of the live transcript (last ~90s, capped at ~1500 chars)
    /// or nil if there's no active recording / nothing to show.
    private func recentTranscriptTail() -> String? {
        guard let transcriber, transcriber.state == .running else { return nil }
        let lines = transcriber.lines
        guard !lines.isEmpty else { return nil }

        let cutoff = Date().addingTimeInterval(-90)
        let recent = lines.filter { $0.timestamp >= cutoff }
        let pool = recent.isEmpty ? Array(lines.suffix(8)) : recent

        let formatted = pool.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let limit = 1500
        if formatted.count <= limit { return formatted }
        let tail = formatted.suffix(limit)
        if let firstNewline = tail.firstIndex(of: "\n") {
            return String(tail[tail.index(after: firstNewline)...])
        }
        return String(tail)
    }

    /// 15-minute idle timer — clears conversation memory if the user doesn't
    /// press the hotkey again and isn't recording.
    private func scheduleIdleReset() {
        idleResetTask?.cancel()
        idleResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.idleTimeoutSeconds ?? 900) * 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self else { return }
                if self.transcriber?.state == .running { return } // active meeting holds memory
                self.resetConversation()
            }
        }
    }

    // MARK: - Lazy loading

    private func whisperEngine() async throws -> WhisperKitEngine {
        if let w = whisper { return w }
        let w = try await WhisperKitEngine()
        whisper = w
        return w
    }

    // MARK: - HUD lifecycle

    private func ensureHUD() {
        if hud == nil {
            hud = HUDWindowController(assistant: self)
        }
        hud?.show()
        hudVisible = true
    }

    /// Toggle the HUD from the persistent edge tab.
    /// If the HUD is showing → slide it away (chat is preserved). Otherwise open.
    func toggleFromNotch() {
        if hudVisible {
            hidePanelKeepState()
        } else {
            openForText()
        }
    }

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.dismissHUD() }
        }
    }
}
