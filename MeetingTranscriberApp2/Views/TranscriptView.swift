import SwiftUI

struct TranscriptView: View {
    @Bindable var transcriber: LiveTranscriber
    let pastSession: PastTranscript?

    @State private var editingTurnID: Int? = nil
    @State private var editBuffer: String = ""
    @State private var hoveredTurnID: Int? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Unified, junk-filtered line list rendered as turns. Source priority:
    /// 1. live transcriber.cleanedLines (post-stop polish, or pre-loaded past .cleaned.json)
    /// 2. live transcriber.lines (raw VAD chunks during/after recording)
    /// 3. pastSession.lines (raw .md parse when no cleaned sidecar exists)
    /// What kind of underlying data we're rendering — affects whether edits can persist.
    private enum SourceKind { case cleaned, past, live }

    private var currentSourceKind: SourceKind {
        if let cleaned = transcriber.cleanedLines, !cleaned.isEmpty { return .cleaned }
        if pastSession != nil { return .past }
        return .live
    }

    private var turns: [Turn] {
        switch currentSourceKind {
        case .cleaned:
            let cleaned = transcriber.cleanedLines ?? []
            return Self.group(cleaned.enumerated().map { i, l in
                Source(speaker: l.speaker, text: l.text,
                       timestamp: Self.timeFormatter.string(from: l.timestamp),
                       originalIndex: i, originalDate: l.timestamp)
            })
        case .past:
            let past = pastSession!
            return Self.group(past.lines.enumerated().map { i, l in
                Source(speaker: l.speaker, text: l.text,
                       timestamp: l.timestamp,
                       originalIndex: i,
                       originalDate: Self.timeFormatter.date(from: l.timestamp))
            })
        case .live:
            return Self.group(transcriber.lines.enumerated().map { i, l in
                Source(speaker: l.speaker, text: l.text,
                       timestamp: Self.timeFormatter.string(from: l.timestamp),
                       originalIndex: i, originalDate: l.timestamp)
            })
        }
    }

    private var showingCleaned: Bool {
        transcriber.cleanedLines != nil && !((transcriber.cleanedLines ?? []).isEmpty)
    }

    /// Cleaning hasn't run on this past session — surface a "Polish" CTA.
    private var canOfferPolish: Bool {
        guard pastSession != nil else { return false }
        return !showingCleaned && transcriber.cleaningState != .loading
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    headerBanner
                    if turns.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    } else {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { idx, turn in
                            turnBlock(turn,
                                      isLatestAndLive: idx == turns.count - 1
                                        && transcriber.state == .running
                                        && !showingCleaned)
                                .id(turn.id)
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 28)
                .padding(.bottom, 48)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Theme.paper)
            .onChange(of: transcriber.lines.count) { _, _ in
                if pastSession == nil, let last = turns.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Header banner (polish state)

    @ViewBuilder
    private var headerBanner: some View {
        if transcriber.cleaningState == .loading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Marty is polishing the transcript…")
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        } else if showingCleaned {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentDeep)
                Text("Polished by Marty — merged split utterances, fixed mishearings")
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Button(action: { transcriber.cleanedLines = nil }) {
                    Text("show raw").font(.mono(10)).foregroundStyle(Theme.inkSoft)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        } else if canOfferPolish {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentDeep)
                Text("This transcript hasn't been polished yet.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button(action: triggerPolish) {
                    Text("Polish with Marty →")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.paper))
                        .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        }
    }

    private func triggerPolish() {
        guard let past = pastSession else { return }
        // Hydrate transcriber.lines from past so cleanTranscript has something to work on.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines: [TranscriptLine] = past.lines.map { line in
            let ts = formatter.date(from: line.timestamp) ?? past.summary.date
            return TranscriptLine(timestamp: ts, speaker: line.speaker, text: line.text)
        }
        transcriber.lines = lines
        transcriber.transcriptFileURL = past.summary.id
        Task { await transcriber.cleanTranscript() }
    }

    // MARK: - Turn block

    @ViewBuilder
    private func turnBlock(_ turn: Turn, isLatestAndLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(speakerDisplayName(turn.speakerKey))
                    .font(.serif(17, italic: true))
                    .foregroundStyle(turn.speakerKey == "You" ? Theme.accentDeep : Theme.amber)
                Text("·")
                    .font(.mono(10))
                    .foregroundStyle(Theme.inkMuted)
                Text(turn.firstTimestamp)
                    .font(.mono(10))
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                if editingTurnID == nil && !isLatestAndLive {
                    Button(action: { startEditing(turn) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                            Text("Edit")
                                .font(.mono(10, weight: .medium))
                        }
                        .foregroundStyle(hoveredTurnID == turn.id ? Theme.ink : Theme.inkMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(hoveredTurnID == turn.id ? Theme.sidebar : Theme.paper))
                        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            if editingTurnID == turn.id {
                editor(for: turn)
            } else if isLatestAndLive {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(turn.paragraph)
                        .font(.bodySerif(16))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    BlinkingCaret()
                }
            } else {
                Text(turn.paragraph)
                    .font(.bodySerif(16))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredTurnID = inside ? turn.id : (hoveredTurnID == turn.id ? nil : hoveredTurnID)
        }
    }

    @ViewBuilder
    private func editor(for turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editBuffer)
                .font(.bodySerif(16))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.paper)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accentDeep, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 80)

            HStack(spacing: 10) {
                Button(action: { saveEdit(for: turn) }) {
                    Text("Save")
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)

                Button(action: cancelEdit) {
                    Text("Cancel")
                        .font(.ui(12))
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Text("⌘↩ to save · esc to cancel")
                    .font(.mono(10))
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
            }
        }
    }

    private func startEditing(_ turn: Turn) {
        editBuffer = turn.paragraph
        editingTurnID = turn.id
    }

    private func cancelEdit() {
        editingTurnID = nil
        editBuffer = ""
    }

    /// Persist the edited paragraph into `transcriber.cleanedLines` + `.cleaned.json` sidecar.
    /// The edited turn's source range is collapsed into a single TranscriptLine.
    private func saveEdit(for turn: Turn) {
        let newText = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { cancelEdit(); return }

        // Materialize cleanedLines if we're editing a past-session or live raw source.
        var lines: [TranscriptLine] = transcriber.cleanedLines ?? materializedLinesFromCurrentSource()
        guard !lines.isEmpty else { cancelEdit(); return }

        let timestamp = turn.firstDate ?? lines[max(0, min(lines.count - 1, turn.sourceIndices.lowerBound))].timestamp
        let newLine = TranscriptLine(timestamp: timestamp, speaker: turn.speakerKey, text: newText)

        let range = turn.sourceIndices
        let safeRange = max(0, range.lowerBound)..<min(lines.count, range.upperBound)
        lines.replaceSubrange(safeRange, with: [newLine])

        transcriber.cleanedLines = lines
        transcriber.cleaningState = .ready

        if let url = transcriber.transcriptFileURL ?? pastSession?.summary.id {
            CleanedTranscriptSidecar.save(lines, for: url)
        }
        cancelEdit()
    }

    private func materializedLinesFromCurrentSource() -> [TranscriptLine] {
        switch currentSourceKind {
        case .cleaned:
            return transcriber.cleanedLines ?? []
        case .past:
            guard let past = pastSession else { return [] }
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return past.lines.map {
                TranscriptLine(timestamp: f.date(from: $0.timestamp) ?? past.summary.date,
                               speaker: $0.speaker, text: $0.text)
            }
        case .live:
            return transcriber.lines
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nothing recorded yet.")
                .font(.serif(28, italic: true))
                .foregroundStyle(Theme.inkSoft)
            Text("Begin a new recording from the sidebar.")
                .font(.bodySerif(16, italic: true))
                .foregroundStyle(Theme.inkMuted)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Helpers

    private func speakerDisplayName(_ key: String) -> String {
        switch key {
        case "You":
            let first = UserProfile.shared.name.split(separator: " ").first.map(String.init)
            return first ?? "You"
        case "Them": return "Other"
        default: return key
        }
    }

    // MARK: - Grouping

    private struct Source {
        let speaker: String
        let text: String
        let timestamp: String
        let originalIndex: Int       // index into the underlying [TranscriptLine] / past.lines source
        let originalDate: Date?      // present when source was a TranscriptLine (cleanedLines/live); nil for past.lines fallback
    }

    struct Turn: Identifiable {
        // Stable id derived from the underlying source range so SwiftUI state
        // (editingTurnID, hoveredTurnID) survives re-renders.
        var id: Int { sourceIndices.lowerBound }
        let speakerKey: String
        let firstTimestamp: String
        let firstDate: Date?
        let paragraph: String
        let sourceIndices: Range<Int>
    }

    /// Filters junk lines and merges consecutive same-speaker utterances into
    /// editorial paragraphs.
    private static func group(_ src: [Source]) -> [Turn] {
        var result: [Turn] = []
        var currentSpeaker: String? = nil
        var currentTs: String = ""
        var currentDate: Date? = nil
        var currentTexts: [String] = []
        var currentStart: Int = 0
        var currentEnd: Int = 0  // inclusive

        let alphanums = CharacterSet.letters.union(.decimalDigits)

        func flush() {
            guard let speaker = currentSpeaker, !currentTexts.isEmpty else { return }
            let paragraph = joinSentences(currentTexts)
            result.append(Turn(speakerKey: speaker,
                               firstTimestamp: currentTs,
                               firstDate: currentDate,
                               paragraph: paragraph,
                               sourceIndices: currentStart..<(currentEnd + 1)))
            currentSpeaker = nil
            currentTexts = []
        }

        for s in src {
            let raw = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop empties + ultra-short fragments + lines with no alphanumerics.
            if raw.count < 2 { continue }
            let hasContent = raw.unicodeScalars.contains { alphanums.contains($0) }
            if !hasContent { continue }

            if s.speaker != currentSpeaker {
                flush()
                currentSpeaker = s.speaker
                currentTs = s.timestamp
                currentDate = s.originalDate
                currentTexts = [raw]
                currentStart = s.originalIndex
                currentEnd = s.originalIndex
            } else {
                currentTexts.append(raw)
                currentEnd = s.originalIndex
            }
        }
        flush()
        return result
    }

    /// Joins utterances into one paragraph. If the previous fragment ends mid-clause
    /// (no terminal punctuation), join with a space; otherwise join with a space too —
    /// but capitalize sentence starts. Light-touch: this is just visual stitching, not
    /// editorial cleanup (that's what cleanTranscript does via Claude).
    private static func joinSentences(_ parts: [String]) -> String {
        var out = ""
        for (i, p) in parts.enumerated() {
            if i == 0 {
                out = p
            } else {
                let prev = out.last
                let needsSpace = !(prev == " " || prev == nil)
                let joiner = needsSpace ? " " : ""
                out += joiner + p
            }
        }
        return out
    }
}

struct BlinkingCaret: View {
    @State private var on = true
    var body: some View {
        Text("▊")
            .font(.bodySerif(14))
            .foregroundStyle(Theme.accent)
            .opacity(on ? 1 : 0)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    on.toggle()
                }
            }
    }
}
