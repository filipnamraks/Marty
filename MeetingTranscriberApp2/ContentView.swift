import SwiftUI
import Combine

struct ContentView: View {
    @State private var transcriber = LiveTranscriber()
    @State private var sessions: [SessionSummary] = []
    @State private var page: Page = .home
    @State private var loadedPast: PastTranscript? = nil
    @State private var selectedTab: MainTab = .transcript
    @State private var showSettings: Bool = false
    @State private var showOnboarding: Bool = ContentView.shouldShowOnboardingInitially()
    @State private var showCalendarPicker: Bool = false
    @State private var showPalette: Bool = false
    @State private var showExport: Bool = false
    @State private var showAddToLibrary: Bool = false
    @State private var savedMeetings: [SavedMeeting] = []
    @State private var openedSaved: SavedMeeting? = nil
    @State private var demo: DemoSession? = nil
    @StateObject private var calendar = CalendarStore()

    private let calendarRefreshTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()

    private static func shouldShowOnboardingInitially() -> Bool {
        !UserDefaults.standard.bool(forKey: "Marty.hasCompletedOnboarding")
    }

    var body: some View {
        ZStack {
            Theme.D.room.ignoresSafeArea()
            HStack(spacing: 0) {
                SidebarView(transcriber: transcriber,
                            meetings: $savedMeetings,
                            page: $page,
                            onOpenSettings: { showSettings = true },
                            onRequestRecording: requestRecording,
                            onOpenPalette: { showPalette = true })

                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.D.app)
            }
            FilmGrain().ignoresSafeArea()
            if showPalette {
                CommandPalette(
                    calendar: calendar,
                    onImport: importAgenda,
                    onDismiss: { showPalette = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showPalette)
        .tint(Theme.accent)
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear {
            refreshSessions()
            refreshLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .martyRunDemo)) { _ in
            runDemo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .martyRunDemoRealFills)) { _ in
            runDemo(realFills: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .martyTogglePalette)) { _ in
            showPalette.toggle()
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
                // Restore the session's agenda document (auto-saved sidecar) so
                // closing the app never loses it; re-attach persistence so
                // further edits keep saving.
                if let cachedAgenda = AgendaSidecar.load(for: session.id) {
                    transcriber.agenda = cachedAgenda
                    transcriber.agendaFillState = .ready
                    transcriber.attachAgendaPersistence(to: session.id)
                } else {
                    transcriber.agenda = nil
                    transcriber.detachAgendaPersistence()
                }
            case .saved(let id):
                openSavedMeeting(id)
            case .live:
                loadedPast = nil
                openedSaved = nil
            case .home:
                loadedPast = nil
                openedSaved = nil
            case .library:
                loadedPast = nil
                openedSaved = nil
            }
            selectedTab = .transcript
        }
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
        .sheet(isPresented: $showAddToLibrary) {
            AddToLibrarySheet(transcriber: transcriber, existing: openedSaved, onSaved: {
                refreshLibrary()
            })
        }
        .sheet(isPresented: $showExport) {
            ZStack(alignment: .topTrailing) {
                ExportView(transcriber: transcriber, pastSession: loadedPast)
                Button(action: { showExport = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(14)
            }
            .frame(width: 640, height: 640)
        }
    }

    // MARK: - Right column (page routing)

    @ViewBuilder
    private var rightColumn: some View {
        if case .home = page {
            // Home landing IS the agenda intake — the new experience first.
            AgendaInputView(onAgendaReady: importAgenda,
                            onOpenPalette: { showPalette = true })
        } else if case .library = page {
            LibraryView(meetings: $savedMeetings, page: $page, onDelete: { meeting in
                SavedLibraryStore.delete(meeting.id)
                refreshLibrary()
            })
        } else if case .live = page, transcriber.agenda != nil {
            documentView
        } else if case .saved = page {
            documentView
        } else if case .past = page, transcriber.agenda != nil {
            // A past session whose agenda document was auto-saved reopens as
            // the document, not the bare transcript.
            documentView
        } else {
            pastSessionView
        }
    }

    private var documentView: some View {
        AgendaDocumentView(
            transcriber: transcriber,
            pastSession: loadedPast,
            onFinish: { if transcriber.state == .running { transcriber.stop() } },
            onExport: { showExport = true },
            onAddToLibrary: { showAddToLibrary = true }
        )
    }

    private var pastSessionView: some View {
        VStack(spacing: 0) {
            ContextBar(breadcrumb: ["Library", loadedPast?.summary.title ?? "Session"]) {
                Button(action: { showExport = true }) {
                    Text("Export")
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.D.accentDeep))
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                MastheadView(transcriber: transcriber, pastSession: loadedPast)
                TabsBar(selected: $selectedTab)
                mainContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
        }
    }

    private func importAgenda(_ agenda: Agenda) {
        transcriber.agenda = agenda
        page = .live
        if transcriber.state == .idle { transcriber.start() }
        showPalette = false
    }

    private func requestRecording() {
        // If already recording, treat as stop.
        if transcriber.state == .running {
            transcriber.stop()
            return
        }
        // Return to the home landing — which is the agenda intake.
        transcriber.agenda = nil
        page = .home
    }

    /// Triggered by the View → Run Demo Session menu (⇧⌘D). Plays a scripted
    /// conversation through the live UI. No-op if a real session is running.
    /// `realFills` (⌥⇧⌘D) drives a real AgendaFiller against the configured
    /// fill engine instead of the scripted bullets.
    private func runDemo(realFills: Bool = false) {
        guard transcriber.state == .idle else { return }
        page = .live
        let session = DemoSession(transcriber: transcriber, useRealFills: realFills)
        demo = session
        session.start()
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

    private func refreshLibrary() {
        savedMeetings = SavedLibraryStore.all()
    }

    /// Load a saved meeting into the transcriber and show it in the document view.
    private func openSavedMeeting(_ id: String) {
        loadedPast = nil
        guard transcriber.state == .idle, let m = SavedLibraryStore.load(id: id) else { return }
        openedSaved = m
        // A library meeting's agenda doesn't belong to any session on disk —
        // never let it overwrite a session's auto-saved sidecar.
        transcriber.detachAgendaPersistence()
        transcriber.agenda = m.agenda
        transcriber.agendaFillState = .ready   // a saved meeting always shows its finished actions
        if let lines = m.transcript {
            transcriber.cleanedLines = lines.map { TranscriptLine(timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text) }
            transcriber.cleaningState = .ready
        } else {
            transcriber.cleanedLines = nil
            transcriber.cleaningState = .idle
        }
        transcriber.summary = m.summary
        transcriber.summaryState = m.summary != nil ? .ready : .idle
    }
}

#Preview {
    ContentView()
}

extension Notification.Name {
    /// Posted by the View → Run Demo Session menu (⇧⌘D).
    static let martyRunDemo = Notification.Name("marty.runDemo")
    /// Posted by View → Run Demo Session (Real Fills) (⌥⇧⌘D) — same script,
    /// but a real AgendaFiller drives the configured fill engine.
    static let martyRunDemoRealFills = Notification.Name("marty.runDemoRealFills")
    /// Posted by the ⌘K menu command — toggles the command palette.
    static let martyTogglePalette = Notification.Name("marty.togglePalette")
}
