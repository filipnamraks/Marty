import SwiftUI
import AppKit

struct HomeView: View {
    @Bindable var transcriber: LiveTranscriber
    @Binding var page: Page
    @Binding var sessions: [SessionSummary]
    var onRequestRecording: () -> Void
    var onConnectCalendar: () -> Void = {}
    @ObservedObject var calendar: CalendarStore
    @Bindable private var profile: UserProfile = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var firstName: String {
        profile.name.split(separator: " ").first.map(String.init) ?? profile.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                greetingMasthead
                heroCard
                statsRow
                todaysSchedule
                pickUpWhereYouLeftOff
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 36)
        }
        .background(Theme.paper)
    }

    // MARK: Today's schedule (placeholder — LLM/Calendar wires real data later)
    private struct ScheduleItem: Identifiable {
        let id = UUID()
        let time: String
        let relative: String
        let titleLead: String
        let titleItalic: String
        let titleTail: String
        let subtitle: String
        let action: String
        let isNow: Bool
        var conferenceURL: URL? = nil
    }

    private var scheduleItems: [ScheduleItem] {
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let relFmt = RelativeDateTimeFormatter()
        relFmt.unitsStyle = .short
        relFmt.dateTimeStyle = .numeric

        return calendar.events.compactMap { event in
            // Skip events that already ended.
            if event.end <= now { return nil }
            let isNow = event.start <= now && event.end > now
            let relative: String
            if isNow {
                relative = "now"
            } else {
                relative = relFmt.localizedString(for: event.start, relativeTo: now)
            }
            let durationMin = max(1, Int(event.end.timeIntervalSince(event.start) / 60))
            var subtitleParts: [String] = []
            if event.isRecurring { subtitleParts.append("Recurring") }
            subtitleParts.append("\(durationMin) min")
            if event.attendeeCount > 0 {
                subtitleParts.append("\(event.attendeeCount) attendees")
            }
            if let loc = event.location, !loc.isEmpty {
                subtitleParts.append(loc)
            } else if event.conferenceURL != nil {
                subtitleParts.append("Video call")
            }

            let action: String
            if isNow {
                action = "Start recording"
            } else if event.conferenceURL != nil {
                action = "Join"
            } else {
                action = "Pre-arm"
            }

            return ScheduleItem(time: timeFmt.string(from: event.start),
                                relative: relative,
                                titleLead: "",
                                titleItalic: event.title,
                                titleTail: "",
                                subtitle: subtitleParts.joined(separator: " · "),
                                action: action,
                                isNow: isNow,
                                conferenceURL: event.conferenceURL)
        }
    }

    private var todaysSchedule: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                (Text("Today's ").font(.serif(24)) +
                 Text("schedule").font(.serif(24, italic: true)))
                    .foregroundStyle(Theme.ink)
                Spacer()
                refreshButton
                viewCalendarLink
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.stroke).frame(height: 1.5)
            }
            .padding(.bottom, 4)

            scheduleBody
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        switch calendar.state {
        case .loaded, .error, .loading:
            Button(action: { Task { await calendar.refresh() } }) {
                Image(systemName: calendar.state == .loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.paper))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(calendar.state == .loading)
            .help(refreshTooltip)
        default:
            EmptyView()
        }
    }

    private var refreshTooltip: String {
        guard let last = calendar.lastRefreshed else { return "Refresh" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Refresh — last updated \(f.localizedString(for: last, relativeTo: Date()))"
    }

    @ViewBuilder
    private var viewCalendarLink: some View {
        switch calendar.state {
        case .loaded, .loading:
            Button(action: {
                if let url = URL(string: "https://calendar.google.com/calendar/u/0/r/day") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text("view calendar →")
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var scheduleBody: some View {
        switch calendar.state {
        case .disconnected:
            schedulePlaceholder(
                title: "Connect your calendar to see today's meetings.",
                action: "Connect",
                onTap: onConnectCalendar)
        case .loading where calendar.events.isEmpty:
            scheduleStatusRow("Loading today's events…")
        case .error(let msg):
            schedulePlaceholder(
                title: "Couldn't reach Google Calendar.",
                subtitle: msg,
                action: "Retry",
                onTap: { Task { await calendar.refresh() } })
        case .loaded where scheduleItems.isEmpty:
            scheduleEmptyRow
        default:
            ForEach(scheduleItems) { item in
                scheduleRow(item)
            }
        }
    }

    private var scheduleEmptyRow: some View {
        HStack {
            (Text("Nothing scheduled today. ").font(.bodySerif(16, italic: true)) +
             Text("Enjoy the quiet.").font(.bodySerif(16, italic: true)).foregroundStyle(Theme.accentDeep))
                .foregroundStyle(Theme.inkSoft)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 18)
    }

    private func scheduleStatusRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.mono(11)).foregroundStyle(Theme.inkMuted)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 18)
    }

    private func schedulePlaceholder(title: String,
                                     subtitle: String? = nil,
                                     action: String,
                                     onTap: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.bodySerif(15, italic: true))
                    .foregroundStyle(Theme.inkSoft)
                if let subtitle {
                    Text(subtitle)
                        .font(.mono(10.5))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onTap) {
                Text(action)
                    .font(.mono(10.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.paper))
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 18)
    }

    private func scheduleRow(_ item: ScheduleItem) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.time)
                    .font(.mono(14, weight: item.isNow ? .medium : .regular))
                    .foregroundStyle(item.isNow ? Theme.accentDeep : Theme.ink)
                Text(item.relative)
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.inkMuted)
            }
            .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                titleText(item)
                Text(item.subtitle)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionPill(item)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .background(item.isNow ? Theme.sidebar : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func titleText(_ item: ScheduleItem) -> some View {
        var parts = Text("")
        if !item.titleLead.isEmpty {
            parts = parts + Text(item.titleLead).font(.serif(18))
        }
        parts = parts + Text(item.titleItalic).font(.serif(18, italic: true))
        if !item.titleTail.isEmpty {
            parts = parts + Text(item.titleTail).font(.serif(18))
        }
        return parts.foregroundStyle(Theme.ink)
    }

    private func actionPill(_ item: ScheduleItem) -> some View {
        Button(action: {
            if item.isNow {
                onRequestRecording()
            } else if let url = item.conferenceURL {
                NSWorkspace.shared.open(url)
            }
        }) {
            Text(item.action)
                .font(.mono(10.5, weight: item.isNow ? .medium : .regular))
                .foregroundStyle(item.isNow ? Theme.paper : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(item.isNow ? Theme.ink : Theme.paper)
                )
                .overlay(
                    Capsule().stroke(item.isNow ? Theme.ink : Theme.strokeBold, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Greeting masthead
    private var greetingMasthead: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(eyebrowText.uppercased())
                    .font(.mono(10.5))
                    .tracking(1.8)
                    .foregroundStyle(Theme.inkMuted)
                Rectangle().fill(Theme.strokeBold).frame(height: 1)
            }

            greetingHeadline
                .fixedSize(horizontal: false, vertical: true)

            Text(standfirst)
                .font(.bodySerif(17, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var greetingHeadline: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let gold = shimmeringGold(time: t)
            let count = sessions.count
            if count == 0 {
                (Text("\(timeOfDayGreeting), ").font(.serif(40)) +
                 Text(firstName).font(.bodySerif(42, italic: true)).foregroundStyle(gold) +
                 Text(". ").font(.serif(40)) +
                 Text("Let's record your first session.").font(.serif(40, italic: true)).foregroundStyle(Theme.accentDeep))
                    .foregroundStyle(Theme.ink)
            } else {
                let phrase = count == 1 ? "one session" : "\(count) sessions"
                (Text("\(timeOfDayGreeting), ").font(.serif(40)) +
                 Text(firstName).font(.bodySerif(42, italic: true)).foregroundStyle(gold) +
                 Text(". ").font(.serif(40)) +
                 Text("You've captured ").font(.serif(40)) +
                 Text(phrase).font(.serif(40, italic: true)).foregroundStyle(Theme.accentDeep) +
                 Text(".").font(.serif(40)))
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    /// A live, slowly-sweeping linear gradient in champagne/antique gold tones.
    /// The gradient direction shifts over time so the name catches light like polished metal.
    private func shimmeringGold(time: Double) -> LinearGradient {
        // Slow 8-second loop. cos/sin produce a smooth lateral sweep.
        let phase = time * 2 * .pi / 8.0
        let xShift = (cos(phase) + 1) / 2     // 0…1
        let yShift = (sin(phase) + 1) / 2     // 0…1
        let start = UnitPoint(x: xShift, y: yShift * 0.3)
        let end   = UnitPoint(x: 1 - xShift, y: 1 - yShift * 0.3)
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color(red: 0.98, green: 0.91, blue: 0.72), location: 0.00),  // champagne highlight
                .init(color: Color(red: 0.91, green: 0.72, blue: 0.35), location: 0.35),  // warm gold
                .init(color: Color(red: 0.72, green: 0.52, blue: 0.12), location: 0.65),  // antique gold
                .init(color: Color(red: 0.55, green: 0.37, blue: 0.06), location: 1.00),  // bronze
            ]),
            startPoint: start,
            endPoint: end
        )
    }

    private var eyebrowText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        let date = f.string(from: Date())
        return "\(date) · \(sessions.count) sessions"
    }

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }

    private var standfirst: String {
        if sessions.isEmpty {
            return "Tap Begin recording below to capture your first conversation. Marty transcribes locally — nothing leaves your Mac."
        }
        return "Pick up where you left off below, or begin a new session. Marty captures the conversation and writes the transcript as it goes."
    }

    // MARK: Hero card
    private var heroCard: some View {
        ZStack {
            HeroCardBackground(reduceMotion: reduceMotion)
                .accessibilityHidden(true)

            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        HeroRecordDot(reduceMotion: reduceMotion)
                        Text("READY WHEN YOU ARE")
                            .font(.mono(10))
                            .tracking(1.8)
                            .foregroundStyle(Color(red: 0.91, green: 0.61, blue: 0.31))
                    }
                    (Text("Begin a ").font(.serif(30)) +
                     Text("new session").font(.serif(30, italic: true)).foregroundStyle(Color(red: 0.85, green: 0.83, blue: 0.78)) +
                     Text(" — or pick up where you left off.").font(.serif(30)))
                        .foregroundStyle(Color.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Marty captures the conversation, identifies speakers, and writes the summary as it goes.")
                        .font(.ui(13))
                        .foregroundStyle(Color(white: 0.78))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    heroButton(label: "recording", italic: "Begin", filled: true) {
                        onRequestRecording()
                    }
                    heroButton(label: "Import audio", italic: "", filled: false) { /* placeholder */ }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
        }
        .background(Color(red: 0.055, green: 0.039, blue: 0.031))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func heroButton(label: String, italic: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if filled {
                    Circle()
                        .fill(Color(red: 0.85, green: 0.47, blue: 0.22))
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 6, height: 6)
                }
                HStack(spacing: 4) {
                    if !italic.isEmpty {
                        Text(italic).font(.serif(16, italic: true))
                    }
                    Text(label).font(.ui(14, weight: .medium))
                }
                .foregroundStyle(filled ? Theme.ink : Color(white: 0.96))
                .padding(.trailing, 8)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .background {
                if filled {
                    Capsule().fill(Theme.paper)
                } else {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.white.opacity(0.08))
                    }
                }
            }
            .overlay(
                Capsule().stroke(filled ? .clear : Color.white.opacity(0.20), lineWidth: 0.5)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Stats
    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(label: "This week", value: "\(sessionsThisWeek)", suffix: "")
            statCard(label: "Sessions", value: "\(sessions.count)", suffix: "")
            statCard(label: "Most recent", value: relativeMostRecent, suffix: "")
            statCard(label: "Storage", value: storageReadable, suffix: "")
        }
    }

    private func statCard(label: String, value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.mono(10))
                .tracking(1.2)
                .foregroundStyle(Theme.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.serif(28))
                if !suffix.isEmpty {
                    Text(suffix).font(.serif(14)).foregroundStyle(Theme.inkMuted)
                }
            }
            .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sessionsThisWeek: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return sessions.filter { $0.date >= weekAgo }.count
    }

    private var relativeMostRecent: String {
        guard let recent = sessions.first else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: recent.date, relativeTo: Date())
    }

    private var storageReadable: String {
        let bytes = sessions.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.id.path)[.size] as? Int) ?? 0
        }.reduce(0, +)
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: Pick up where you left off
    private var pickUpWhereYouLeftOff: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                (Text("Pick up where you ").font(.serif(24)) +
                 Text("left off").font(.serif(24, italic: true)))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("all sessions →")
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.stroke).frame(height: 1.5)
            }
            .padding(.bottom, 4)

            if sessions.isEmpty {
                emptyState.padding(.vertical, 40)
            } else {
                ForEach(Array(sessions.prefix(8).enumerated()), id: \.element.id) { idx, session in
                    sessionRow(index: idx, session: session)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No sessions yet.")
                .font(.serif(20, italic: true))
                .foregroundStyle(Theme.inkSoft)
            Text("Click \"Begin recording\" to capture your first conversation.")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity)
    }

    @State private var hoverIndex: Int?

    private func sessionRow(index: Int, session: SessionSummary) -> some View {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM"
        return Button(action: { page = .past(session) }) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(String(format: "%03d", sessions.count - index))
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.serif(17))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("\(dateFormatter.string(from: session.date)) · \(session.lineCount) lines")
                        .font(.mono(10))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Text("open")
                    .font(.mono(9.5))
                    .tracking(0.6)
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.sidebar))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 14)
            .background(hoverIndex == index ? Theme.sidebar : .clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hoverIndex = inside ? index : nil }
    }
}

// MARK: - Hero card background (warm "the app is listening" treatment)

private struct HeroCardBackground: View {
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. Base warm-brown radial gradient — feels like a dimly lit room.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 0.165, green: 0.122, blue: 0.082), location: 0.0),
                        .init(color: Color(red: 0.102, green: 0.078, blue: 0.063), location: 0.45),
                        .init(color: Color(red: 0.055, green: 0.039, blue: 0.031), location: 1.0)
                    ]),
                    center: UnitPoint(x: 0.75, y: 0.5),
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height)
                )

                // 2. Breathing ambient glows.
                GlowOrb(
                    color: Color(red: 0.91, green: 0.61, blue: 0.31),
                    secondaryColor: Color(red: 0.71, green: 0.39, blue: 0.20),
                    primaryOpacity: 0.35,
                    secondaryOpacity: 0.15,
                    delay: 0,
                    reduceMotion: reduceMotion
                )
                .frame(width: geo.size.width * 0.7, height: geo.size.height * 1.8)
                .offset(x: geo.size.width * 0.35, y: -geo.size.height * 0.4)

                GlowOrb(
                    color: Color(red: 0.83, green: 0.51, blue: 0.31),
                    secondaryColor: .clear,
                    primaryOpacity: 0.20,
                    secondaryOpacity: 0.0,
                    delay: 1.5,
                    reduceMotion: reduceMotion
                )
                .frame(width: geo.size.width * 0.4, height: geo.size.height * 1.2)
                .offset(x: -geo.size.width * 0.1, y: geo.size.height * 0.35)

                // 3. Animated waveform sits behind the text.
                HeroWaveform(reduceMotion: reduceMotion)
                    .opacity(0.95)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct GlowOrb: View {
    let color: Color
    let secondaryColor: Color
    let primaryOpacity: Double
    let secondaryOpacity: Double
    let delay: Double
    let reduceMotion: Bool

    @State private var pulsing: Bool = false

    var body: some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: color.opacity(primaryOpacity), location: 0.0),
                .init(color: secondaryColor.opacity(secondaryOpacity), location: 0.35),
                .init(color: .clear, location: 0.70)
            ]),
            center: .center,
            startRadius: 0,
            endRadius: 320
        )
        .opacity(reduceMotion ? 0.70 : (pulsing ? 0.85 : 0.50))
        .blur(radius: 20)
        .onAppear {
            guard !reduceMotion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
        }
    }
}

private struct HeroWaveform: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gfx, size in
                draw(in: &gfx, size: size, time: t)
            }
        }
    }

    private func draw(in gfx: inout GraphicsContext, size: CGSize, time: Double) {
        let barCount = 27
        let leftInset: CGFloat = 30
        let rightInset: CGFloat = 30
        let usable = max(size.width - leftInset - rightInset, 1)
        let spacing = usable / CGFloat(barCount - 1)
        let centerY = size.height / 2

        for i in 0..<barCount {
            let normalized = Double(i) / Double(barCount - 1)
            let baseHeightFraction = waveformBaseHeight(at: normalized)

            let scale: Double
            if reduceMotion {
                scale = 0.8
            } else {
                // 1.6 s period, 50 ms stagger between bars
                let omega = 2.0 * .pi / 1.6
                let phase = time * omega - Double(i) * 0.05 * omega
                scale = sin(phase) * 0.3 + 0.7   // 0.4 ... 1.0
            }

            let h = baseHeightFraction * scale * Double(size.height) * 0.62
            let x = leftInset + CGFloat(i) * spacing
            let rect = CGRect(
                x: x - 1.25,
                y: centerY - CGFloat(h) / 2,
                width: 2.5,
                height: CGFloat(h)
            )
            let color = barColor(at: normalized)
            gfx.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(color))
        }
    }

    /// Taller in the middle, shorter at the edges, with a small pseudo-random
    /// per-bar variation so it doesn't look perfectly symmetrical.
    private func waveformBaseHeight(at t: Double) -> Double {
        let envelope = 0.25 + 0.55 * sin(.pi * t)
        // Pseudo-random jitter from sine of t at a different frequency.
        let jitter = sin(t * 31.0 + 1.7) * 0.08
        return max(0.15, envelope + jitter)
    }

    /// Interpolate the 4-stop gradient (pale cream → warm amber) at position t.
    private func barColor(at t: Double) -> Color {
        struct Stop { let pos: Double; let r: Double; let g: Double; let b: Double; let a: Double }
        let stops: [Stop] = [
            Stop(pos: 0.00, r: 0.961, g: 0.910, b: 0.784, a: 0.15),  // #F5E8C8
            Stop(pos: 0.40, r: 0.961, g: 0.753, b: 0.533, a: 0.45),  // #F5C088
            Stop(pos: 0.70, r: 0.910, g: 0.612, b: 0.306, a: 0.70),  // #E89C4E
            Stop(pos: 1.00, r: 0.847, g: 0.471, b: 0.220, a: 0.85),  // #D87838
        ]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if t >= a.pos && t <= b.pos {
                let local = (t - a.pos) / (b.pos - a.pos)
                return Color(
                    red: a.r + (b.r - a.r) * local,
                    green: a.g + (b.g - a.g) * local,
                    blue: a.b + (b.b - a.b) * local,
                    opacity: a.a + (b.a - a.a) * local
                )
            }
        }
        let last = stops.last!
        return Color(red: last.r, green: last.g, blue: last.b, opacity: last.a)
    }
}

private struct HeroRecordDot: View {
    let reduceMotion: Bool
    @State private var pulsing: Bool = false

    var body: some View {
        let amber = Color(red: 0.91, green: 0.61, blue: 0.31)
        Circle()
            .fill(amber)
            .frame(width: 6, height: 6)
            .shadow(color: amber.opacity(0.6), radius: 4)
            .scaleEffect(reduceMotion ? 1.0 : (pulsing ? 0.85 : 1.0))
            .opacity(reduceMotion ? 1.0 : (pulsing ? 0.7 : 1.0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
