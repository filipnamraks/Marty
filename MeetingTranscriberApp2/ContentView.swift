import SwiftUI
import Combine

struct ContentView: View {
    @State private var transcriber = LiveTranscriber()
    @State private var sessions: [SessionSummary] = []
    @State private var page: Page = .home
    @State private var loadedPast: PastTranscript? = nil
    @State private var selectedTab: MainTab = .transcript
    @State private var rightSidebarVisible: Bool = true
    @State private var showSettings: Bool = false
    @State private var showOnboarding: Bool = ContentView.shouldShowOnboardingInitially()
    @State private var showCalendarPicker: Bool = false
    @State private var demo: DemoSession? = nil
    @State private var pendingAgenda: Bool = false
    @StateObject private var calendar = CalendarStore()

    private let calendarRefreshTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()

    private static func shouldShowOnboardingInitially() -> Bool {
        let completed = UserDefaults.standard.bool(forKey: "Marty.hasCompletedOnboarding")
        let hasKey = !((SecureStorage.read(SecureStorage.anthropicAPIKey) ?? "").isEmpty)
        return !completed && !hasKey
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(transcriber: transcriber,
                        sessions: $sessions,
                        page: $page,
                        onOpenSettings: { showSettings = true },
                        onRequestRecording: requestRecording)

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    if pendingAgenda {
                        AgendaInputView(
                            onAgendaReady: { agenda in
                                transcriber.agenda = agenda
                                pendingAgenda = false
                                page = .live
                                if transcriber.state == .idle { transcriber.start() }
                            },
                            onCancel: { pendingAgenda = false },
                            calendar: calendar
                        )
                    } else if case .home = page {
                        HomeView(transcriber: transcriber,
                                 page: $page,
                                 sessions: $sessions,
                                 onRequestRecording: requestRecording,
                                 onConnectCalendar: { showCalendarPicker = true },
                                 calendar: calendar)
                    } else if case .library = page {
                        LibraryView(sessions: $sessions, page: $page)
                    } else if case .live = page, transcriber.agenda != nil {
                        AgendaDocumentView(
                            transcriber: transcriber,
                            onFinish: { if transcriber.state == .running { transcriber.stop() } }
                        )
                    } else {
                        MastheadView(transcriber: transcriber, pastSession: loadedPast)
                        TabsBar(selected: $selectedTab)
                        mainContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.paper)

                if !rightSidebarVisible && shouldShowRightSidebar {
                    reopenButton
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
            }

            if rightSidebarVisible && shouldShowRightSidebar {
                rightSidebar
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.paper)
        .tint(Theme.ink)
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear {
            refreshSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .martyRunDemo)) { _ in
            runDemo()
        }
        .task { await calendar.refresh() }
        .onReceive(calendarRefreshTimer) { _ in
            Task { await calendar.refresh() }
        }
        .onChange(of: transcriber.state) { _, newState in
            if newState == .idle { refreshSessions() }
        }
        .onChange(of: page) { _, newValue in
            switch newValue {
            case .past(let session):
                loadedPast = SessionsScanner.load(session)
                if let cached = SummarySidecar.load(for: session.id) {
                    transcriber.summary = cached
                    transcriber.summaryState = .ready
                } else {
                    transcriber.summary = nil
                    transcriber.summaryState = .idle
                }
                if let cleanedCached = CleanedTranscriptSidecar.load(for: session.id) {
                    transcriber.cleanedLines = cleanedCached
                    transcriber.cleaningState = .ready
                } else {
                    transcriber.cleanedLines = nil
                    transcriber.cleaningState = .idle
                }
            case .live:
                loadedPast = nil
            case .home:
                loadedPast = nil
            case .library:
                loadedPast = nil
            }
            selectedTab = .transcript
        }
        .animation(.easeInOut(duration: 0.2), value: rightSidebarVisible)
        .sheet(isPresented: $showSettings) {
            SettingsView(onShowOnboarding: {
                showSettings = false
                UserDefaults.standard.set(false, forKey: "Marty.hasCompletedOnboarding")
                // Defer so the settings sheet finishes dismissing before the onboarding presents
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showOnboarding = true
                }
            }, onConnectCalendar: {
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showCalendarPicker = true
                }
            }, calendar: calendar)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $showCalendarPicker) {
            CalendarPickerSheet(calendar: calendar)
        }
    }

    private func requestRecording() {
        // If already recording, treat as stop.
        if transcriber.state == .running {
            transcriber.stop()
            return
        }
        // Open the agenda intake screen — once an agenda is built, recording begins.
        transcriber.agenda = nil
        pendingAgenda = true
    }

    /// The right sidebar (activity feed) is hidden during the agenda-first flow.
    /// Past sessions still get it.
    private var shouldShowRightSidebar: Bool {
        if pendingAgenda { return false }
        if case .live = page, transcriber.agenda != nil { return false }
        return true
    }

    /// Triggered by the View → Run Demo Session menu (⇧⌘D). Plays a scripted
    /// conversation through the live UI. No-op if a real session is running.
    private func runDemo() {
        guard transcriber.state == .idle else { return }
        page = .live
        let session = DemoSession(transcriber: transcriber)
        demo = session
        session.start()
    }

    @ViewBuilder
    private var rightSidebar: some View {
        let onCollapse = { rightSidebarVisible = false }
        let onOpenSettings = { showSettings = true }
        if case .home = page {
            HomeRightSidebar(sessions: $sessions,
                             transcriber: transcriber,
                             onCollapse: onCollapse)
        } else if case .library = page {
            HomeRightSidebar(sessions: $sessions,
                             transcriber: transcriber,
                             onCollapse: onCollapse)
        } else if case .past(let session) = page {
            PastSidebar(session: session,
                        loadedPast: loadedPast,
                        transcriber: transcriber,
                        onCollapse: onCollapse,
                        onOpenSettings: onOpenSettings)
        } else {
            RightSidebarView(transcriber: transcriber,
                             onCollapse: onCollapse,
                             onOpenSettings: onOpenSettings)
        }
    }

    private var reopenButton: some View {
        Button(action: { rightSidebarVisible = true }) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSoft)
                .padding(8)
                .background(Theme.sidebar)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Show right sidebar")
    }

    @ViewBuilder
    private var mainContent: some View {
        switch selectedTab {
        case .transcript:
            TranscriptView(transcriber: transcriber, pastSession: loadedPast)
        case .summary:
            SummaryView(transcriber: transcriber)
        case .export:
            ExportView(transcriber: transcriber, pastSession: loadedPast)
        case .actions, .highlights:
            comingSoon(selectedTab.rawValue)
        }
    }

    private func comingSoon(_ name: String) -> some View {
        VStack(spacing: 12) {
            Text("\(name) — coming soon")
                .font(.serif(28, italic: true))
                .foregroundStyle(Theme.inkSoft)
            Text("This view is a placeholder. Wire up the LLM and it lights up.")
                .font(.bodySerif(15, italic: true))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }

    private func refreshSessions() {
        sessions = SessionsScanner.scan()
    }
}

// Wrapper around RightSidebarView for the .past page. Adds a "Generate summary"
// CTA when no cached summary exists.
struct PastSidebar: View {
    let session: SessionSummary
    let loadedPast: PastTranscript?
    @Bindable var transcriber: LiveTranscriber
    var onCollapse: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        // RightSidebarView already handles all the states; if .idle and no key, it points to Settings.
        // The only extra affordance: a clean "Generate summary" hook for past sessions.
        RightSidebarView(
            transcriber: transcriber,
            onCollapse: onCollapse,
            onOpenSettings: onOpenSettings
        )
        .overlay(alignment: .top) {
            if case .idle = transcriber.summaryState,
               transcriber.summary == nil,
               let past = loadedPast, !past.lines.isEmpty {
                HStack {
                    Button(action: { generatePast(past) }) {
                        Text("Generate summary for this session →")
                            .font(.mono(11, weight: .medium))
                            .foregroundStyle(Theme.accentDeep)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.paper))
                            .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 52)
            }
        }
    }

    private func generatePast(_ past: PastTranscript) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines: [TranscriptLine] = past.lines.map { line in
            let ts = formatter.date(from: line.timestamp) ?? past.summary.date
            return TranscriptLine(timestamp: ts, speaker: line.speaker, text: line.text)
        }
        transcriber.lines = lines
        transcriber.transcriptFileURL = past.summary.id
        Task { await transcriber.generateSummary() }
    }
}

#Preview {
    ContentView()
}

extension Notification.Name {
    /// Posted by the View → Run Demo Session menu (⇧⌘D).
    static let martyRunDemo = Notification.Name("marty.runDemo")
}
