import SwiftUI

/// The document flow — a white page on the dark desk with three Chrome-style
/// tabs (Meeting Agenda / Transcript / Summary). The agenda fills as you talk,
/// and every piece is click-to-edit. When refined you can add it to the library.
struct AgendaDocumentView: View {
    @Bindable var transcriber: LiveTranscriber
    var onFinish: () -> Void
    var onExport: () -> Void = {}
    var onAddToLibrary: () -> Void = {}

    @State private var tab: DocTab = .agenda

    enum DocTab: String, CaseIterable, Identifiable {
        case agenda = "Meeting Agenda"
        case transcript = "Transcript"
        case summary = "Summary"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .agenda: return "doc.text"
            case .transcript: return "text.quote"
            case .summary: return "sparkles"
            }
        }
    }

    private var isRecording: Bool { transcriber.state == .running || transcriber.state == .loading }
    private var isRefined: Bool { transcriber.state == .idle && transcriber.agendaFillState == .ready }
    /// Once a meeting is done (refined / saved), the agenda reads like a plain
    /// document — no status chips, meter, or colored accents.
    private var plain: Bool { !isRecording }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                Theme.D.deskGlow
                page
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, isRecording && tab == .agenda ? 0 : 24)
            }
            .contentShape(Rectangle())
            .onTapGesture { endEditing() }   // click anywhere off a field to stop editing
            if isRecording && tab == .agenda {
                TranscriptDock(line: transcriber.lines.last, feedingSection: writingNumber)
            }
        }
    }

    /// Resign first responder so any in-progress inline edit commits.
    private func endEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - Top bar (Chrome tabs + actions)

    private var topBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(DocTab.allCases) { t in
                    chromeTab(t)
                }
            }
            Spacer(minLength: 12)
            actions.padding(.bottom, 7)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .frame(height: 50)
        .background(Theme.D.panel)
        .overlay(Rectangle().fill(Theme.D.line).frame(height: 1), alignment: .bottom)
    }

    private func chromeTab(_ t: DocTab) -> some View {
        let on = tab == t
        return Button(action: { tab = t }) {
            HStack(spacing: 7) {
                Image(systemName: t.icon).font(.system(size: 11))
                Text(t.rawValue).font(.ui(12.5, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Theme.ink : Theme.D.sub)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                    .fill(on ? Theme.paper : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var actions: some View {
        if isRecording {
            HStack(spacing: 10) {
                RecordingPill(elapsed: formatElapsed(transcriber.elapsedSeconds))
                barButton("Finish & refine", filled: false, action: onFinish)
            }
        } else if isRefined {
            HStack(spacing: 8) {
                barButton("Copy", filled: false, action: copyCurrent)
                barButton("Save as PDF", filled: false, action: savePDFCurrent)
                barButton("Add to library", filled: true, action: onAddToLibrary)
                barButton("Export", filled: false, action: onExport)
            }
        } else {
            Text("Refining…").font(.mono(11)).foregroundStyle(Theme.D.sub)
        }
    }

    private func barButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(13, weight: .semibold))
                .foregroundStyle(filled ? Color.white : Theme.D.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? Theme.D.accentDeep : Color(hex: 0x15171B)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(filled ? Color.clear : Theme.D.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page content per tab

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .agenda:
            PageSurface {
                ScrollView {
                    document
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 56)
                        .padding(.vertical, 44)
                }
            }
        case .transcript:
            PageSurface { TranscriptView(transcriber: transcriber, pastSession: nil) }
        case .summary:
            PageSurface { SummaryView(transcriber: transcriber) }
        }
    }

    // MARK: - Editable agenda document

    private var document: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditableText(
                text: agendaTitle,
                placeholder: "Untitled meeting",
                font: .serif(29).weight(.bold),
                color: Theme.ink,
                onCommit: { transcriber.agenda?.title = $0 }
            )
            Text(metaLine)
                .font(.mono(12.5)).foregroundStyle(Theme.inkMuted)
                .padding(.top, 7)

            if !plain {
                SectionMeter(segments: meterSegments, label: meterLabel)
                    .padding(.top, 16)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.top, 16)

            if let agenda = transcriber.agenda {
                ForEach(Array(agenda.sections.enumerated()), id: \.element.id) { idx, section in
                    SectionRow(
                        section: section,
                        number: idx + 1,
                        plain: plain,
                        onEditHeading: updateSection(section.id) { $0.heading = $1; $0.userEdited = true },
                        onEditSubheading: updateSection(section.id) { $0.subheading = $1.isEmpty ? nil : $1; $0.userEdited = true },
                        onEditBody: updateSection(section.id) { sec, text in
                            sec.filledContent = text
                            sec.userEdited = true
                            if !text.isEmpty, sec.status == .upcoming || sec.status == .notCovered {
                                sec.status = isRefined ? .refined : .filled
                            }
                        }
                    )
                }
            }
        }
    }

    /// Mutate one section by id and write the agenda back (triggers a refresh).
    private func updateSection(_ id: UUID, _ mutate: (inout AgendaSection, String) -> Void, value: String) {
        guard var agenda = transcriber.agenda,
              let idx = agenda.sections.firstIndex(where: { $0.id == id }) else { return }
        mutate(&agenda.sections[idx], value)
        transcriber.agenda = agenda
    }

    /// Curried helper so call sites read `updateSection(id) { section, newText in … }`.
    private func updateSection(_ id: UUID, _ mutate: @escaping (inout AgendaSection, String) -> Void) -> (String) -> Void {
        { value in self.updateSection(id, mutate, value: value) }
    }

    // MARK: - Derived

    private var agendaTitle: String { transcriber.agenda?.title ?? "Untitled meeting" }

    private var meterSegments: [MeterSegment] {
        (transcriber.agenda?.sections ?? []).map { s in
            switch s.status {
            case .filled, .refined: return .done
            case .writing:          return .writing
            default:                return .empty
            }
        }
    }

    private var meterLabel: String {
        guard let agenda = transcriber.agenda else { return "" }
        let total = agenda.sectionCount
        if isRefined { return "\(total) of \(total) refined" }
        return "\(agenda.filledCount) of \(total) filled"
    }

    private var writingNumber: Int? {
        guard let agenda = transcriber.agenda,
              let idx = agenda.sections.firstIndex(where: { $0.status == .writing }) else { return nil }
        return idx + 1
    }

    private var metaLine: String {
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM yyyy"
        let date = df.string(from: Date())
        if isRefined {
            let mins = max(1, transcriber.elapsedSeconds / 60)
            return "Refined from \(mins) minute\(mins == 1 ? "" : "s") of conversation"
        }
        let count = transcriber.agenda?.sectionCount ?? 0
        return "\(date) · \(count) section\(count == 1 ? "" : "s")"
    }

    /// The current tab rendered as a plain Word-style document (no app UI).
    private func currentDocument() -> NSAttributedString? {
        switch tab {
        case .agenda:
            guard let agenda = transcriber.agenda else { return nil }
            return DocumentExport.agenda(agenda)
        case .summary:
            guard let summary = transcriber.summary else { return nil }
            return DocumentExport.summary(summary)
        case .transcript:
            let lines = transcriber.cleanedLines ?? transcriber.lines
            guard !lines.isEmpty else { return nil }
            return DocumentExport.transcript(lines)
        }
    }

    private var documentName: String {
        let base = transcriber.agenda?.title ?? transcriber.summary?.title ?? "Meeting"
        return "\(base) — \(tab.rawValue)"
    }

    private func copyCurrent() {
        guard let doc = currentDocument() else { return }
        DocumentExport.copy(doc)
    }

    private func savePDFCurrent() {
        guard let doc = currentDocument() else { return }
        DocumentExport.savePDF(doc, suggestedName: documentName)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Agenda markdown rendering (shared by Copy + library save)

enum AgendaMarkdown {
    static func render(_ agenda: Agenda) -> String {
        var out = "# \(agenda.title)\n\n"
        for s in agenda.sections {
            out += "## \(s.heading)\n"
            if let sub = s.subheading, !sub.isEmpty { out += "*\(sub)*\n\n" }
            if !s.filledContent.isEmpty { out += s.filledContent + "\n\n" }
        }
        return out
    }
}

// MARK: - Recording pill

private struct RecordingPill: View {
    let elapsed: String
    var body: some View {
        HStack(spacing: 9) {
            EqualizerView(barCount: 4, color: Theme.D.accent, maxHeight: 11)
            Text("Recording \(elapsed)")
                .font(.ui(12, weight: .semibold))
                .foregroundStyle(Theme.D.accent)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.D.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.D.accent.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Transcript dock

private struct TranscriptDock: View {
    let line: TranscriptLine?
    let feedingSection: Int?

    var body: some View {
        HStack(spacing: 13) {
            EqualizerView(barCount: 5, color: Theme.D.accent, maxHeight: 14, barWidth: 2.5)
            Group {
                if let line {
                    (Text(line.speaker + " — ").foregroundStyle(Theme.D.sub)
                     + Text("“\(line.text)”").italic().foregroundStyle(Color(hex: 0xCFD2D8)))
                } else {
                    Text("Listening…").foregroundStyle(Theme.D.mut)
                }
            }
            .font(.ui(12.5))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let feedingSection {
                Text("● feeding §\(feedingSection)")
                    .font(.mono(10.5)).foregroundStyle(Theme.D.accent)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(Theme.D.dockBg)
        .overlay(Rectangle().fill(Theme.D.line).frame(height: 1), alignment: .top)
    }
}

// MARK: - Section row (editable)

private struct SectionRow: View {
    let section: AgendaSection
    let number: Int
    var plain: Bool = false
    var onEditHeading: (String) -> Void
    var onEditSubheading: (String) -> Void
    var onEditBody: (String) -> Void

    private var isWriting: Bool { section.status == .writing && !plain }
    private var isUpcoming: Bool { !plain && (section.status == .upcoming || section.status == .notCovered) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if section.status != .offAgenda {
                    Text("\(number) ·")
                        .font(.serif(18.5).weight(.semibold))
                        .foregroundStyle(isUpcoming ? Color(hex: 0xB9BCC4) : Theme.ink)
                }
                EditableText(
                    text: section.heading,
                    placeholder: "Section title",
                    font: .serif(18.5).weight(.semibold),
                    color: isUpcoming ? Color(hex: 0xB9BCC4) : Theme.ink,
                    onCommit: onEditHeading
                )
                Spacer(minLength: 8)
                if !plain {
                    StatusChip(status: section.status)
                }
            }

            EditableText(
                text: section.subheading ?? "",
                placeholder: "Add a subheading…",
                font: .bodySerif(13.5),
                color: isUpcoming ? Color(hex: 0xC9CCD3) : Theme.inkSoft,
                onCommit: onEditSubheading
            )

            EditableSectionBody(
                content: section.filledContent,
                isWriting: isWriting,
                plain: plain,
                onCommit: onEditBody
            )
        }
        .padding(.vertical, plain ? 14 : 20)
        .padding(.horizontal, isWriting ? 28 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if isWriting {
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                    Theme.liveBg
                }
            }
        }
        .overlay(Rectangle().fill(Color(hex: 0xF1F2F4)).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - Editable section body (formatted bullets ↔ raw editor)

private struct EditableSectionBody: View {
    let content: String
    let isWriting: Bool
    var plain: Bool = false
    var onCommit: (String) -> Void

    @State private var editing = false
    @State private var buffer = ""
    @FocusState private var focused: Bool

    private var dashColor: Color { plain ? Color(hex: 0x33353C) : Theme.accent }

    var body: some View {
        if editing {
            // Seamless — no box, no outline. Click elsewhere to stop editing.
            TextEditor(text: $buffer)
                .font(.bodySerif(14.5))
                .foregroundStyle(Color(hex: 0x33353C))
                .scrollContentBackground(.hidden)
                .tint(Theme.ink)
                .focused($focused)
                .frame(minHeight: 54)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: focused) { _, f in if !f { commit() } }
                .padding(.top, 5)
        } else if content.isEmpty {
            Text("Click to add notes…")
                .font(.bodySerif(14.5)).foregroundStyle(Theme.inkMuted.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { begin() }
                .padding(.top, 5)
        } else {
            bullets
                .contentShape(Rectangle())
                .onTapGesture { begin() }
                .help("Click to edit")
                .padding(.top, 5)
        }
    }

    private var bullets: some View {
        let lines = parsedBullets(content)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("—").font(.bodySerif(14.5)).foregroundStyle(dashColor)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        formattedLine(line)
                            .font(.bodySerif(14.5))
                            .foregroundStyle(Color(hex: 0x33353C))
                            .fixedSize(horizontal: false, vertical: true)
                        if isWriting && i == lines.count - 1 {
                            SheetCaret(height: 14)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func begin() {
        buffer = content
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onCommit(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parsedBullets(_ raw: String) -> [String] {
        let split = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
        var result: [String] = []
        for line in split {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("- ") { result.append(String(t.dropFirst(2))); continue }
            if t.hasPrefix("* ") { result.append(String(t.dropFirst(2))); continue }
            result.append(t)
        }
        return result
    }

    @ViewBuilder
    private func formattedLine(_ raw: String) -> some View {
        if let attr = try? AttributedString(markdown: raw) {
            Text(attr)
        } else {
            Text(raw)
        }
    }
}

// MARK: - Status chip

private struct StatusChip: View {
    let status: AgendaSection.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(fg).frame(width: 6, height: 6)
            Text(label)
                .font(.ui(11, weight: .semibold))
                .foregroundStyle(fg)
        }
    }

    private var label: String {
        switch status {
        case .upcoming:   return "Upcoming"
        case .writing:    return "Writing"
        case .filled:     return "Filled"
        case .refined:    return "Refined"
        case .notCovered: return "Not covered"
        case .offAgenda:  return "Off-agenda"
        }
    }

    private var fg: Color {
        switch status {
        case .filled, .refined: return Theme.chipDoneFg
        case .writing:          return Theme.chipLiveFg
        case .upcoming, .notCovered, .offAgenda: return Theme.inkMuted
        }
    }
}
