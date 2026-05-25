import SwiftUI

struct HomeRightSidebar: View {
    @Binding var sessions: [SessionSummary]
    @Bindable var transcriber: LiveTranscriber
    var onCollapse: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                collapseHeader
                archiveSection
                actionItemsSection
                weeklyRhythmSection
                recentActivitySection
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
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide right sidebar")
            Spacer()
        }
    }

    // MARK: From the archive
    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("From the archive")
                Spacer()
                if !sessions.isEmpty {
                    Text("№ \(sessions.count)")
                        .font(.mono(9.5))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("\u{201C}")
                    .font(.serif(36, italic: true))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 14, alignment: .top)
                Text("The thing about good meetings is they end before you realise they were good. Bad ones announce themselves immediately.")
                    .font(.bodySerif(14, italic: true))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                Text(sessions.first.map { "— from \($0.title)" } ?? "— quotes will appear once you have sessions")
                    .font(.mono(10))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
        }
    }

    // MARK: Action items (placeholder list)
    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Action items", withDot: true)
                Spacer()
                Text("placeholders")
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.inkMuted)
            }
            actionRow("Wire up the LLM for live summaries", due: "soon", urgent: true)
            actionRow("Add app icon", due: "this week", urgent: false)
            actionRow("Ship beta to a friend", due: "this week", urgent: false)
            actionRow("Code-sign for distribution", due: "later", urgent: false, isLast: true)
        }
    }

    private func actionRow(_ text: String, due: String, urgent: Bool, isLast: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(urgent ? Color(red: 0.69, green: 0.48, blue: 0.36) : Theme.strokeBold, lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                (Text("from ").foregroundStyle(Theme.inkMuted) +
                 Text(due).foregroundStyle(urgent ? Color(red: 0.54, green: 0.29, blue: 0.24) : Theme.accentDeep))
                    .font(.mono(9.5))
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.stroke).frame(height: 1) }
        }
    }

    // MARK: Weekly rhythm
    private var weeklyRhythmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Weekly rhythm")
                Spacer()
                Text("week \(currentWeekNumber)")
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.inkMuted)
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(weekDayCounts, id: \.label) { d in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(d.isToday ? Theme.accent : (d.isFuture ? Color(red: 0.93, green: 0.91, blue: 0.84) : Color(red: 0.85, green: 0.83, blue: 0.78)))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(6, CGFloat(d.height) * 56))
                            Text(d.label)
                                .font(.mono(9))
                                .foregroundStyle(d.isToday ? Theme.accentDeep : Theme.inkMuted)
                        }
                    }
                }
                HStack {
                    Text("Sessions").font(.mono(10)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Text("\(weekTotal) this week").font(.mono(10, weight: .medium)).foregroundStyle(Theme.ink)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
        }
    }

    private struct DayBar {
        let label: String
        let height: Double
        let isToday: Bool
        let isFuture: Bool
    }

    private var weekDayCounts: [DayBar] {
        let calendar = Calendar(identifier: .iso8601)
        let now = Date()
        guard let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: startOfWeek) }
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        let counts = days.map { day -> Int in
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            return sessions.filter { $0.date >= day && $0.date < next }.count
        }
        let maxCount = max(1, counts.max() ?? 1)
        return days.enumerated().map { i, day in
            DayBar(
                label: f.string(from: day),
                height: maxCount > 0 ? Double(counts[i]) / Double(maxCount) : 0,
                isToday: calendar.isDate(day, inSameDayAs: now),
                isFuture: day > now
            )
        }
    }

    private var weekTotal: Int {
        let calendar = Calendar(identifier: .iso8601)
        guard let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        return sessions.filter { $0.date >= startOfWeek }.count
    }
    private var currentWeekNumber: Int {
        Calendar(identifier: .iso8601).component(.weekOfYear, from: Date())
    }

    // MARK: Recent activity
    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Recent activity")
                Spacer()
                Text("live")
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.inkMuted)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(recentEvents, id: \.0) { (key, gray, white) in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(gray).font(.mono(10)).foregroundStyle(Color(white: 0.53))
                        Text(white).font(.mono(10)).foregroundStyle(Color(white: 0.92))
                        Spacer(minLength: 0)
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

    private var recentEvents: [(String, String, String)] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        let live = transcriber.activityEvents.suffix(5).reversed().enumerated().map { idx, event -> (String, String, String) in
            let detail = event.detail.map { " \($0)" } ?? ""
            return ("live-\(idx)-\(event.id)", dateFormatter.string(from: event.timestamp), "\(event.kind.label)\(detail)")
        }
        if !live.isEmpty { return Array(live) }
        let recent = sessions.prefix(5).enumerated().map { idx, s -> (String, String, String) in
            ("past-\(idx)-\(s.id)", dateFormatter.string(from: s.date), "session \u{2116} \(sessions.count - idx) saved")
        }
        if recent.isEmpty {
            return [("none", "—", "no activity yet")]
        }
        return Array(recent)
    }

    private func sectionLabel(_ text: String, withDot: Bool = false) -> some View {
        HStack(spacing: 6) {
            if withDot {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
            }
            Text(text.uppercased())
                .font(.mono(10))
                .tracking(1.8)
                .foregroundStyle(Theme.inkMuted)
        }
    }
}
