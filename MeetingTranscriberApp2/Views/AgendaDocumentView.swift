import SwiftUI

/// The Ledger document — single scrolling artifact. Renders the agenda title,
/// meta line, then each section with its status chip. The "writing now" section
/// gets a cream background + amber left border. The raw transcript lives in a
/// collapsible peek at the bottom.
struct AgendaDocumentView: View {
    @Bindable var transcriber: LiveTranscriber
    var onFinish: () -> Void

    @State private var transcriptPeekOpen: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                document
                    .padding(.horizontal, 56)
                    .padding(.vertical, 30)
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.paper)
            TranscriptDrawer(
                lines: transcriber.lines,
                isOpen: $transcriptPeekOpen,
                hidden: transcriber.state == .idle
            )
        }
        .background(Theme.paper)
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        if transcriber.state == .running || transcriber.state == .loading {
            recordingTopBar
        } else {
            refinedTopBar
        }
    }

    private var recordingTopBar: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.recordRed)
                    .frame(width: 8, height: 8)
                Text("RECORDING · \(formatElapsed(transcriber.elapsedSeconds))")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Theme.recordText)
            }
            Spacer()
            HStack(spacing: 12) {
                Text(progressLabel)
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkMuted)
                Button(action: onFinish) {
                    Text("Finish & refine →")
                        .font(.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.white)
                                .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.paper)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }

    private var refinedTopBar: some View {
        HStack {
            let isReady = transcriber.agendaFillState == .ready
            let label = isReady
                ? "✓ REFINED · \(formatElapsedLong(transcriber.elapsedSeconds)) · \(filledCount) sections filled"
                : "REFINING…"
            Text(label)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            if isReady {
                Button(action: copyAgenda) {
                    Text("Copy")
                        .font(.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.white)
                                .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.paper)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }

    // MARK: - Document body

    private var document: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transcriber.agenda?.title ?? "Untitled meeting")
                    .font(.serif(36))
                    .foregroundStyle(Theme.ink)
                Text(metaLine)
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkMuted)
            }
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1.5)
                .padding(.vertical, 2)

            if let agenda = transcriber.agenda {
                ForEach(Array(agenda.sections.enumerated()), id: \.element.id) { idx, section in
                    SectionRow(section: section, number: idx + 1)
                }
            }
        }
    }

    private var metaLine: String {
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM yyyy"
        let dateText = df.string(from: Date()).uppercased()
        let count = transcriber.agenda?.sectionCount ?? 0
        return "\(dateText) · \(count) section\(count == 1 ? "" : "s")"
    }

    private var progressLabel: String {
        guard let agenda = transcriber.agenda else { return "" }
        let total = agenda.sections.count
        let writingIdx = agenda.sections.firstIndex(where: { $0.status == .writing })
        if let idx = writingIdx {
            return "filling section \(idx + 1) of \(total)"
        }
        return "\(agenda.filledCount) of \(total) filled"
    }

    private var filledCount: String {
        guard let agenda = transcriber.agenda else { return "0/0" }
        return "\(agenda.filledCount)/\(agenda.sectionCount)"
    }

    private func copyAgenda() {
        guard let agenda = transcriber.agenda else { return }
        var out = "# \(agenda.title)\n\n"
        for s in agenda.sections {
            out += "## \(s.heading)\n"
            if let sub = s.subheading { out += "*\(sub)*\n\n" }
            if !s.filledContent.isEmpty { out += s.filledContent + "\n\n" }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func formatElapsedLong(_ seconds: Int) -> String {
        let m = seconds / 60
        return "\(m) min"
    }
}

// MARK: - Section row

private struct SectionRow: View {
    let section: AgendaSection
    let number: Int

    var body: some View {
        let isLive = section.status == .writing
        let content =
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(headingText)
                        .font(.serif(24))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    StatusChip(status: section.status)
                }
                if let sub = section.subheading {
                    Text(sub)
                        .font(.bodySerif(16, italic: true))
                        .foregroundStyle(Theme.inkSoft)
                }
                if section.filledContent.isEmpty {
                    EmptyView()
                } else {
                    bullets
                }
            }
            .padding(.horizontal, isLive ? 16 : 0)
            .padding(.vertical, isLive ? 14 : 0)
            .background(
                Group {
                    if isLive {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.liveBg)
                    }
                }
            )
            .overlay(
                Group {
                    if isLive {
                        Rectangle()
                            .fill(Theme.amberBright)
                            .frame(width: 2)
                    }
                },
                alignment: .leading
            )

        content
            .padding(.bottom, 4)
    }

    private var headingText: String {
        section.status == .offAgenda ? section.heading : "\(number) · \(section.heading)"
    }

    private var bullets: some View {
        let lines = parsedBullets(section.filledContent)
        return VStack(alignment: .leading, spacing: 7) {
            if lines.isEmpty {
                Text(section.filledContent)
                    .font(.bodySerif(15.5))
                    .foregroundStyle(Color(red: 0x2B/255, green: 0x2B/255, blue: 0x28/255))
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("—")
                            .font(.bodySerif(15.5))
                            .foregroundStyle(Theme.amber)
                        formattedLine(line)
                            .font(.bodySerif(15.5))
                            .foregroundStyle(Color(red: 0x2B/255, green: 0x2B/255, blue: 0x28/255))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    /// Turns "- foo" / "* foo" markdown bullets into plain strings; lines without
    /// a bullet marker pass through verbatim.
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
            if status == .writing {
                Circle()
                    .fill(Theme.amberBright)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.mono(9.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(fg)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(bg))
        .overlay(Capsule().stroke(border, lineWidth: 1))
    }

    private var label: String {
        switch status {
        case .upcoming:   return "UPCOMING"
        case .writing:    return "WRITING NOW"
        case .filled:     return "✓ FILLED"
        case .refined:    return "✓ REFINED"
        case .notCovered: return "NOT COVERED"
        case .offAgenda:  return "OFF-AGENDA"
        }
    }

    private var fg: Color {
        switch status {
        case .filled, .refined: return Theme.chipDoneFg
        case .writing:          return Theme.chipLiveFg
        case .notCovered, .offAgenda, .upcoming: return Theme.inkMuted
        }
    }
    private var bg: Color {
        switch status {
        case .filled, .refined: return Theme.chipDoneBg
        case .writing:          return Theme.chipLiveBg
        default:                return .white
        }
    }
    private var border: Color {
        switch status {
        case .filled, .refined: return Theme.chipDoneBorder
        case .writing:          return Theme.chipLiveBorder
        default:                return Theme.stroke
        }
    }
}
