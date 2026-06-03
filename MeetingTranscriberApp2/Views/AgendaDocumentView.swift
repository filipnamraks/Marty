import SwiftUI

/// The document flow — a white sheet on the dark desk that fills section by
/// section as you talk, then settles into refined notes. A dark context bar
/// carries the recording pill (or Copy/Export); a slim dock shows the live feed.
struct AgendaDocumentView: View {
    @Bindable var transcriber: LiveTranscriber
    var onFinish: () -> Void
    var onExport: () -> Void = {}

    private var isRecording: Bool { transcriber.state == .running || transcriber.state == .loading }
    private var isRefined: Bool { transcriber.state == .idle && transcriber.agendaFillState == .ready }

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            DeskBackground {
                Sheet { document }
            }
            if isRecording {
                TranscriptDock(line: transcriber.lines.last, feedingSection: writingNumber)
            }
        }
    }

    // MARK: - Context bar

    @ViewBuilder
    private var contextBar: some View {
        if isRecording {
            ContextBar(breadcrumb: ["Meetings", agendaTitle]) {
                HStack(spacing: 10) {
                    RecordingPill(elapsed: formatElapsed(transcriber.elapsedSeconds))
                    barButton("Finish & refine", filled: false, action: onFinish)
                }
            }
        } else if isRefined {
            ContextBar(breadcrumb: ["Library", "\(agendaTitle) — Notes"]) {
                HStack(spacing: 8) {
                    barButton("Copy", filled: false, action: copyAgenda)
                    barButton("Export", filled: true, action: onExport)
                }
            }
        } else {
            ContextBar(breadcrumb: ["Meetings", agendaTitle]) {
                Text("Refining…").font(.mono(11)).foregroundStyle(Theme.D.sub)
            }
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

    // MARK: - Document (sheet)

    private var document: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(agendaTitle)
                .font(.serif(29)).fontWeight(.bold)
                .foregroundStyle(Theme.ink)
            Text(metaLine)
                .font(.mono(12.5)).foregroundStyle(Theme.inkMuted)
                .padding(.top, 7)

            SectionMeter(segments: meterSegments, label: meterLabel)
                .padding(.top, 16)

            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.top, 16)

            if let agenda = transcriber.agenda {
                ForEach(Array(agenda.sections.enumerated()), id: \.element.id) { idx, section in
                    SectionRow(section: section, number: idx + 1)
                }
            }
        }
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

    private func copyAgenda() {
        guard let agenda = transcriber.agenda else { return }
        var out = "# \(agenda.title)\n\n"
        for s in agenda.sections {
            out += "## \(s.heading)\n"
            if let sub = s.subheading { out += "*\(sub)*\n\n" }
            if !s.filledContent.isEmpty { out += s.filledContent + "\n\n" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
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

/// The slim dark dock that gives the live feed a home below the page.
private struct TranscriptDock: View {
    let line: TranscriptLine?
    let feedingSection: Int?

    var body: some View {
        HStack(spacing: 13) {
            EqualizerView(barCount: 5, color: Theme.D.accent, maxHeight: 14, barWidth: 2.5)
            Group {
                if let line {
                    (Text(speaker(line.speaker) + " — ").foregroundStyle(Theme.D.sub)
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

    private func speaker(_ raw: String) -> String {
        if raw == "You" { return UserProfile.shared.displayName == "Add your name" ? "You" : "You" }
        if raw == "Them" { return "Them" }
        return raw
    }
}

// MARK: - Section row

private struct SectionRow: View {
    let section: AgendaSection
    let number: Int

    private var isWriting: Bool { section.status == .writing }
    private var isUpcoming: Bool {
        section.status == .upcoming || section.status == .notCovered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(headingText)
                    .font(.serif(18.5)).fontWeight(.semibold)
                    .foregroundStyle(isUpcoming ? Color(hex: 0xB9BCC4) : Theme.ink)
                Spacer(minLength: 8)
                StatusChip(status: section.status)
            }
            if let sub = section.subheading {
                Text(sub)
                    .font(.bodySerif(13.5))
                    .foregroundStyle(isUpcoming ? Color(hex: 0xC9CCD3) : Theme.inkSoft)
            }
            if !section.filledContent.isEmpty {
                bullets
            }
        }
        .padding(.vertical, 20)
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

    private var headingText: String {
        section.status == .offAgenda ? section.heading : "\(number) · \(section.heading)"
    }

    private var bullets: some View {
        let lines = parsedBullets(section.filledContent)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("—").font(.bodySerif(14.5)).foregroundStyle(Theme.accent)
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
        .padding(.top, 5)
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
