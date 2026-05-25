import SwiftUI

/// The Marty live-assistant panel. Shows a ChatGPT-style scrolling chat log of
/// the current thread (user bubbles right-aligned, assistant bubbles left), plus
/// the in-flight question at the bottom. The chat persists across collapse/reopen;
/// only the "↺ New thread" pill wipes it.
struct QueryHUD: View {
    @ObservedObject var assistant: LiveAssistant
    @State private var typedQuestion: String = ""
    @FocusState private var inputFocused: Bool

    private let bottomAnchorID = "marty.chat.bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.stroke)
            chatLog
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().background(Theme.stroke)
            textInputRow
            Divider().background(Theme.stroke)
            footer
        }
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(8)
        .onChange(of: assistant.focusTextRequest) { _, _ in
            inputFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: { assistant.hidePanelKeepState() }) {
                (Text("M").font(.serif(22)) +
                 Text(".").font(.serif(22, italic: true)).foregroundStyle(Theme.accent))
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .help("Collapse Marty")

            Text("Marty")
                .font(.mono(10))
                .tracking(1.2)
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            if assistant.conversationTurnCount > 0 {
                Button(action: { assistant.resetConversation() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .medium))
                        Text("New thread")
                            .font(.mono(9, weight: .medium))
                    }
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.sidebar))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Forget this conversation and start fresh")
            }

            Button(action: { assistant.hidePanelKeepState() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Collapse Marty")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Chat log

    @ViewBuilder
    private var chatLog: some View {
        switch assistant.state {
        case .permissionNeeded:
            permissionBody
        default:
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.conversationTurns.isEmpty && !hasInFlightContent {
                            emptyHint
                        }
                        ForEach(Array(assistant.conversationTurns.enumerated()), id: \.offset) { _, turn in
                            switch turn.role {
                            case .user:      userBubble(turn.content)
                            case .assistant: assistantBubble(turn.content, isStreaming: false)
                            }
                        }
                        inFlightBubble()
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.conversationTurnCount) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: assistant.state) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyHint: some View {
        HStack {
            Spacer()
            Text("Ask anything. Hold ⇧⌘M to speak, ⌥⌘M to type.")
                .font(.bodySerif(13, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.vertical, 20)
    }

    private var hasInFlightContent: Bool {
        switch assistant.state {
        case .idle, .done: return false
        default: return true
        }
    }

    /// The bottom-most "currently happening" bubble, derived from `state`.
    /// Returns nil when the state's content is already represented in `conversationTurns`
    /// (i.e. `.idle` and `.done`).
    @ViewBuilder
    private func inFlightBubble() -> some View {
        switch assistant.state {
        case .idle, .done:
            EmptyView()
        case .listening:
            statusBubble(text: "Listening…", systemImage: "mic.fill")
        case .transcribing:
            statusBubble(text: "Reading your words…", systemImage: "waveform")
        case .thinking(let q):
            VStack(alignment: .trailing, spacing: 10) {
                userBubble(q)
                statusBubble(text: "Thinking…", systemImage: "sparkles")
            }
        case .toolRunning(let q, let toolName, let partial):
            VStack(alignment: .leading, spacing: 10) {
                userBubble(q)
                toolBubble(toolName: toolName, partial: partial)
            }
        case .answering(let q, let a):
            VStack(alignment: .leading, spacing: 10) {
                userBubble(q)
                assistantBubble(a, isStreaming: true)
            }
        case .error(let msg, let q):
            VStack(alignment: .leading, spacing: 10) {
                if let q { userBubble(q) }
                errorBubble(msg)
            }
        case .permissionNeeded:
            EmptyView()
        }
    }

    // MARK: - Bubbles

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.ui(12))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.93, green: 0.89, blue: 0.80))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.stroke.opacity(0.5), lineWidth: 1)
                )
                .textSelection(.enabled)
        }
    }

    private func assistantBubble(_ text: String, isStreaming: Bool) -> some View {
        HStack {
            (renderMarkdown(text) +
             (isStreaming ? Text("▍").foregroundStyle(Theme.accentDeep) : Text("")))
                .font(.ui(13))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.sidebar)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.stroke.opacity(0.5), lineWidth: 1)
                )
                .textSelection(.enabled)
            Spacer(minLength: 40)
        }
    }

    /// Parses inline markdown (**bold**, *italic*) and preserves newlines so bullet
    /// lists rendered with "• " or "- " prefixes display as the model typed them.
    /// Falls back to plain text if markdown parsing fails (e.g. mid-stream chunks).
    private func renderMarkdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: text, options: options) {
            return Text(attr)
        }
        return Text(text)
    }

    private func statusBubble(text: String, systemImage: String) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentDeep)
                    .symbolEffect(.pulse, options: .repeating)
                Text(text)
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.sidebar)
            )
            Spacer(minLength: 40)
        }
    }

    private func toolBubble(toolName: String, partial: String) -> some View {
        let label: String = {
            switch toolName {
            case "search_notion": return "Looking in your Notion…"
            case "exa_search":    return "Searching the web…"
            case "web_search":    return "Searching the web…"
            default:              return "Calling \(toolName)…"
            }
        }()
        return HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accentDeep)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(label)
                        .font(.bodySerif(13, italic: true))
                        .foregroundStyle(Theme.inkSoft)
                }
                if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(partial)
                        .font(.ui(11))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.sidebar)
            )
            Spacer(minLength: 40)
        }
    }

    private func errorBubble(_ msg: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(msg)
                    .font(.bodySerif(12, italic: true))
                    .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                    .lineLimit(4)
                Text("Hold ⇧⌘M to try again.")
                    .font(.mono(9))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.98, green: 0.92, blue: 0.88))
            )
            Spacer(minLength: 40)
        }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Marty needs Input Monitoring.")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Open System Settings → Privacy & Security → Input Monitoring and turn Marty on, then relaunch.")
                .font(.bodySerif(12, italic: true))
                .foregroundStyle(Theme.inkSoft)
            Button(action: { assistant.openInputMonitoringSettings() }) {
                Text("Open System Settings →")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.paper))
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Text input

    private var textInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accentDeep)
            TextField("ask in writing…", text: $typedQuestion)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .foregroundStyle(Theme.ink)
                .focused($inputFocused)
                .onSubmit(submitTyped)
                .onChange(of: inputFocused) { _, focused in
                    if focused { assistant.suspendAutoDismiss() }
                }
            if !typedQuestion.isEmpty {
                Button(action: submitTyped) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accentDeep)
                }
                .buttonStyle(.plain)
            }
            micButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Color(red: 0.95, green: 0.92, blue: 0.85))
    }

    @ViewBuilder
    private var micButton: some View {
        let recording = (assistant.state == .listening)
        Button(action: { assistant.toggleRecording() }) {
            Image(systemName: recording ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 14))
                .foregroundStyle(recording ? Color(red: 0.78, green: 0.30, blue: 0.25) : Theme.accentDeep)
                .symbolEffect(.pulse, options: recording ? .repeating : .nonRepeating, value: recording)
        }
        .buttonStyle(.plain)
        .help(recording ? "Stop recording" : "Click to speak (click again to stop)")
    }

    private func submitTyped() {
        let q = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        typedQuestion = ""
        assistant.submitText(q)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("⇧⌘M")
                .font(.mono(10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.sidebar))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .foregroundStyle(Theme.inkMuted)
            Text("hold to speak · ⌥⌘M to type")
                .font(.mono(10))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
