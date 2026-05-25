import SwiftUI

struct RightSidebarView: View {
    @Bindable var transcriber: LiveTranscriber
    var onCollapse: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                collapseHeader
                summarySection
                keyPointsSection
                actionItemsSection
                activityFeedSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(width: 290)
        .background(Theme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.strokeBold).frame(width: 1.5)
        }
    }

    private var collapseHeader: some View {
        HStack {
            Button(action: onCollapse) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide right sidebar")
            Spacer()
        }
    }

    // MARK: Summary
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Summary",
                trailing: summaryTrailing,
                withDot: transcriber.summaryState == .loading
            )
            summaryCard
        }
    }

    private var summaryTrailing: String? {
        switch transcriber.summaryState {
        case .loading: return "thinking"
        case .ready: return "by Marty"
        case .error: return "error"
        case .idle: return nil
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        switch transcriber.summaryState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Marty is thinking…")
                    .font(.bodySerif(14, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))

        case .ready:
            Text(transcriber.summary?.summary ?? "")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
                .textSelection(.enabled)

        case .error(let msg):
            errorCard(msg: msg)

        case .idle:
            idleCard
        }
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(idleCopy)
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)
            if !hasAPIKey {
                Button(action: onOpenSettings) {
                    Text("Open Settings →")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Theme.accentDeep)
                }
                .buttonStyle(.plain)
            } else if transcriber.lines.isEmpty {
                Text("Start a recording — Marty will summarize it when you stop.")
                    .font(.mono(10))
                    .foregroundStyle(Theme.inkMuted)
            } else {
                Button(action: { Task { await transcriber.generateSummary() } }) {
                    Text("Generate now →")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Theme.accentDeep)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
    }

    private func errorCard(msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(msg)
                .font(.bodySerif(13, italic: true))
                .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                .lineSpacing(2)
            HStack(spacing: 12) {
                Button(action: { Task { await transcriber.generateSummary() } }) {
                    Text("Retry").font(.mono(11, weight: .medium)).foregroundStyle(Theme.accentDeep)
                }
                .buttonStyle(.plain)
                Button(action: onOpenSettings) {
                    Text("Settings").font(.mono(11, weight: .medium)).foregroundStyle(Theme.inkSoft)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
    }

    private var hasAPIKey: Bool {
        (SecureStorage.read(SecureStorage.anthropicAPIKey) ?? "").isEmpty == false
    }

    private var idleCopy: String {
        if !hasAPIKey {
            return "Add your Anthropic API key in Settings to enable summaries."
        }
        if transcriber.lines.isEmpty {
            return "Marty's summary lands here after each session."
        }
        return "Ready to summarize this session."
    }

    // MARK: Key points
    private var keyPointsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Key points")
            VStack(alignment: .leading, spacing: 0) {
                let points = transcriber.summary?.keyPoints ?? []
                if points.isEmpty {
                    placeholderText("Key points appear after Marty processes the session.")
                } else {
                    ForEach(Array(points.enumerated()), id: \.offset) { idx, point in
                        keyPoint(point, isLast: idx == points.count - 1)
                    }
                }
            }
        }
    }

    private func placeholderText(_ s: String) -> some View {
        Text(s)
            .font(.ui(12.5))
            .foregroundStyle(Theme.inkMuted)
            .padding(.vertical, 8)
    }

    private func keyPoint(_ text: String, isLast: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            Text(text)
                .font(.ui(12.5))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.stroke).frame(height: 1) }
        }
    }

    // MARK: Action items
    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Action items")
            VStack(alignment: .leading, spacing: 0) {
                let items = transcriber.summary?.actionItems ?? []
                if items.isEmpty {
                    placeholderText("Action items detected during the session appear here.")
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        actionItem(item, isLast: idx == items.count - 1)
                    }
                }
            }
        }
    }

    private func actionItem(_ text: String, isLast: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Theme.strokeBold, lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            Text(text)
                .font(.ui(12.5))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.stroke).frame(height: 1) }
        }
    }

    // MARK: Activity feed
    private var activityFeedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Activity feed", trailing: "live")
            VStack(alignment: .leading, spacing: 5) {
                if transcriber.activityEvents.isEmpty {
                    Text("no events yet")
                        .font(.mono(10))
                        .foregroundStyle(Color(white: 0.45))
                } else {
                    ForEach(transcriber.activityEvents.suffix(8).reversed()) { event in
                        activityRow(event)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.terminalBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(f.string(from: event.timestamp))
                .font(.mono(10))
                .foregroundStyle(Color(white: 0.53))
            (Text(event.kind.label).foregroundStyle(Color(white: 0.92)) +
             Text(event.detail.map { " \($0)" } ?? "").foregroundStyle(Color(white: 0.58)))
                .font(.mono(10))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    // MARK: Section header
    private func sectionHeader(_ text: String, trailing: String? = nil, withDot: Bool = false) -> some View {
        HStack(spacing: 6) {
            if withDot { PulsingMiniDot() }
            Text(text.uppercased())
                .font(.mono(10))
                .tracking(1.8)
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

private struct PulsingMiniDot: View {
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
