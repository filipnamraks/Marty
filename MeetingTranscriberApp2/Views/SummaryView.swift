import SwiftUI
import AppKit

struct SummaryView: View {
    @Bindable var transcriber: LiveTranscriber

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch transcriber.summaryState {
                case .loading: loadingState
                case .error(let msg): errorState(msg: msg)
                case .idle: idleState
                case .ready:
                    if let s = transcriber.summary {
                        readyContent(s)
                    } else {
                        idleState
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
    }

    // MARK: Loading
    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Marty is reading the transcript…")
                .font(.bodySerif(16, italic: true))
                .foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 120)
    }

    // MARK: Error
    private func errorState(msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(msg)
                .font(.bodySerif(15, italic: true))
                .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
            Button("Retry") { Task { await transcriber.generateSummary() } }
                .buttonStyle(.plain)
                .font(.mono(12, weight: .medium))
                .foregroundStyle(Theme.accentDeep)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
    }

    // MARK: Idle
    private var idleState: some View {
        VStack(alignment: .leading, spacing: 16) {
            (Text("No summary ").font(.serif(28)) +
             Text("yet").font(.serif(28, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(".").font(.serif(28)))
                .foregroundStyle(Theme.ink)

            Text(idleCopy)
                .font(.bodySerif(15, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)

            if hasAPIKey && !transcriber.lines.isEmpty {
                Button(action: { Task { await transcriber.generateSummary() } }) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").font(.system(size: 11))
                        Text("Generate summary").font(.ui(13, weight: .medium))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.ink)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
    }

    private var idleCopy: String {
        if !hasAPIKey {
            return "Set up a local model in Settings to enable summaries."
        }
        if transcriber.lines.isEmpty {
            return "Record a session and Marty will write a summary when you stop."
        }
        return "Click Generate to have Marty read this session and write it up."
    }

    // Local model is always available (Ollama); kept for call-site compatibility.
    private var hasAPIKey: Bool { true }

    // MARK: Ready
    @ViewBuilder
    private func readyContent(_ s: MeetingSummary) -> some View {
        masthead(s)
        if let narrative = s.narrative, !narrative.isEmpty {
            narrativeSection(narrative)
        } else if !s.summary.isEmpty {
            narrativeSection(s.summary)
        }
        if let topics = s.topics, !topics.isEmpty {
            topicsSection(topics)
        }
        if !s.keyPoints.isEmpty {
            sectionTitle("Key points")
            ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in
                bulletRow(p)
            }
        }
        if let quotes = s.keyQuotes, !quotes.isEmpty {
            sectionTitle("Notable quotes")
            VStack(spacing: 12) {
                ForEach(quotes) { q in
                    quoteCard(q)
                }
            }
        }
        if let decisions = s.decisions, !decisions.isEmpty {
            sectionTitle("Decisions")
            ForEach(Array(decisions.enumerated()), id: \.offset) { _, d in
                bulletRow(d)
            }
        }
        if !s.actionItems.isEmpty {
            sectionTitle("Action items")
            ForEach(Array(s.actionItems.enumerated()), id: \.offset) { _, a in
                actionRow(a)
            }
        }
        if let qs = s.openQuestions, !qs.isEmpty {
            sectionTitle("Open questions")
            ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                bulletRow(q)
            }
        }
        toolbar(s)
            .padding(.top, 16)
    }

    // MARK: Masthead
    private func masthead(_ s: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("BY MARTY · \(eyebrowDate)")
                    .font(.mono(10.5))
                    .tracking(1.8)
                    .foregroundStyle(Theme.inkMuted)
                Rectangle().fill(Theme.strokeBold).frame(height: 1)
            }
            Text(s.title ?? "Untitled session")
                .font(.serif(40))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !s.summary.isEmpty {
                Text(s.summary)
                    .font(.bodySerif(17, italic: true))
                    .foregroundStyle(Theme.inkSoft)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 700, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var eyebrowDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: Date()).uppercased()
    }

    // MARK: Narrative
    private func narrativeSection(_ text: String) -> some View {
        Text(text)
            .font(.bodySerif(17))
            .foregroundStyle(Theme.ink)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 700, alignment: .leading)
            .textSelection(.enabled)
            .padding(.top, 4)
    }

    // MARK: Topics
    private func topicsSection(_ topics: [String]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(topics.enumerated()), id: \.offset) { _, t in
                Text(t)
                    .font(.mono(10.5))
                    .tracking(0.4)
                    .foregroundStyle(Theme.accentDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.sidebar))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
        }
    }

    // MARK: Section title
    private func sectionTitle(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.mono(10.5))
                .tracking(1.8)
                .foregroundStyle(Theme.inkMuted)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    // MARK: Rows
    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            Text(text)
                .font(.bodySerif(15))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private func actionRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Theme.strokeBold, lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            Text(text)
                .font(.bodySerif(15))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private func quoteCard(_ q: KeyQuote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\u{201C}")
                    .font(.serif(28, italic: true))
                    .foregroundStyle(Theme.accent)
                    .offset(y: 4)
                Text(q.quote)
                    .font(.bodySerif(16, italic: true))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text("—")
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkMuted)
                Text(q.speaker.uppercased())
                    .font(.mono(10.5, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(Theme.accentDeep)
                if let ts = q.timestamp {
                    Text("·").font(.mono(11)).foregroundStyle(Theme.inkMuted)
                    Text(ts).font(.mono(10.5)).foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(.leading, 26)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
    }

    // MARK: Toolbar
    private func toolbar(_ s: MeetingSummary) -> some View {
        HStack(spacing: 10) {
            Button(action: { copyMarkdown(s) }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                    Text("Copy as Markdown").font(.ui(12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.sidebar)
                .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                .clipShape(Capsule())
                .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)

            Button(action: { Task { await transcriber.generateSummary() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    Text("Regenerate").font(.ui(12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.paper)
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1.5))
                .clipShape(Capsule())
                .foregroundStyle(Theme.inkSoft)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func copyMarkdown(_ s: MeetingSummary) {
        var lines: [String] = []
        lines.append("# \(s.title ?? "Meeting summary")\n")
        if !s.summary.isEmpty { lines.append("_\(s.summary)_\n") }
        if let n = s.narrative, !n.isEmpty { lines.append("\(n)\n") }
        if let topics = s.topics, !topics.isEmpty {
            lines.append("**Topics:** " + topics.joined(separator: " · ") + "\n")
        }
        if !s.keyPoints.isEmpty {
            lines.append("\n## Key points\n")
            for p in s.keyPoints { lines.append("- \(p)") }
        }
        if let quotes = s.keyQuotes, !quotes.isEmpty {
            lines.append("\n## Notable quotes\n")
            for q in quotes {
                let ts = q.timestamp.map { " · \($0)" } ?? ""
                lines.append("> \(q.quote)  \n> — \(q.speaker)\(ts)\n")
            }
        }
        if let d = s.decisions, !d.isEmpty {
            lines.append("\n## Decisions\n")
            for x in d { lines.append("- \(x)") }
        }
        if !s.actionItems.isEmpty {
            lines.append("\n## Action items\n")
            for a in s.actionItems { lines.append("- [ ] \(a)") }
        }
        if let q = s.openQuestions, !q.isEmpty {
            lines.append("\n## Open questions\n")
            for x in q { lines.append("- \(x)") }
        }
        let md = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}

// Simple flow layout for the topic pills.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
