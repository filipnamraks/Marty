import Foundation
import SwiftUI

/// Replays a scripted conversation through the live LiveTranscriber UI so you can
/// demo Marty without recording a real meeting. Lines stream in at realistic
/// cadence; the masthead clock ticks; activity feed updates; on auto-stop the
/// normal summary + cleanTranscript pipeline runs against the mock content.
///
/// Triggered by View → Run Demo Session (⇧⌘D).
///
/// `useRealFills` (View → Run Demo Session (Real Fills), ⌥⇧⌘D) swaps the
/// hardcoded draft/refined bullets for a real AgendaFiller driving the
/// configured fill engine — the end-to-end test of the live fill pipeline
/// without recording a meeting. The script appends to `t.lines` with
/// `t.state == .running` and `pendingTranscriptions == 0`, so the filler runs
/// exactly as it would live.
@MainActor
final class DemoSession {

    struct ScriptLine {
        let speaker: String           // "You" or "Them"
        let pauseBefore: TimeInterval // real-world sleep between this and the prior line
        let meetingOffset: TimeInterval // synthetic seconds from the meeting start (07:15:00) — what's shown as the line timestamp
        let text: String
    }

    /// The synthetic meeting starts at 07:15:00 today. Line timestamps shown in
    /// TranscriptView are this base plus each line's `meetingOffset`.
    private static var meetingBaseTime: Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 7
        comps.minute = 15
        comps.second = 0
        return cal.date(from: comps) ?? Date()
    }

    private weak var transcriber: LiveTranscriber?
    private var replayTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var mdHandle: FileHandle?
    private var startedAt: Date?
    private var seenSpeakers: Set<String> = []
    /// Drive a real AgendaFiller (configured engine) instead of scripted bullets.
    private let useRealFills: Bool
    private var filler: AgendaFiller?

    init(transcriber: LiveTranscriber, useRealFills: Bool = false) {
        self.transcriber = transcriber
        self.useRealFills = useRealFills
    }

    // MARK: - Lifecycle

    /// Spins up a fake live session and starts replaying the script. No-op if
    /// the transcriber is already running.
    func start() {
        guard let t = transcriber, t.state == .idle else { return }

        // Reset to a clean slate.
        t.lines = []
        t.activityEvents = []
        t.elapsedSeconds = 0
        t.transcriptFileURL = nil
        t.summary = nil
        t.summaryState = .idle
        t.cleanedLines = nil
        t.cleaningState = .idle

        // Give the demo a real agenda so it drives the live document flow.
        var agenda = AgendaParser.parse(markdown: Self.demoAgendaMarkdown)
        for i in agenda.sections.indices { agenda.sections[i].status = .upcoming }
        t.agenda = agenda
        t.agendaFillState = .idle

        seenSpeakers = []
        startedAt = Date()

        // Mirror LiveTranscriber.start()'s .md file creation so the demo lands
        // in ~/Documents/MeetingTranscripts and shows up in Library afterward.
        openTranscriptFile(on: t)

        t.state = .running
        t.statusMessage = "Listening — demo"
        t.activityEvents.append(ActivityEvent(.sessionStarted))

        startElapsedTimer()
        if useRealFills {
            let realFiller = AgendaFiller(transcriber: t)
            filler = realFiller
            realFiller.start()
        }
        replayTask = Task { [weak self] in await self?.replay() }
    }

    /// Cancels playback and runs the post-stop Claude pipeline. Called automatically
    /// when the script reaches the last line, or manually if the user invokes Stop.
    func stop() {
        replayTask?.cancel(); replayTask = nil
        tickTimer?.invalidate(); tickTimer = nil

        guard let t = transcriber else { return }
        // Close the .md handle so summarisers / Library scanner see the final file.
        try? mdHandle?.close()
        mdHandle = nil

        guard t.state == .running else { return }
        t.state = .stopping
        t.statusMessage = "Stopping…"
        t.activityEvents.append(ActivityEvent(.sessionEnded))

        if useRealFills {
            // Real pipeline: stop the live ticks and run the authoritative
            // refine pass — exactly what LiveTranscriber.stop() does.
            let realFiller = filler
            filler = nil
            t.agendaFillState = .loading
            Task { [weak t] in
                guard let t else { return }
                realFiller?.stop()
                await realFiller?.finalize()
                await MainActor.run {
                    t.agendaFillState = .ready
                    t.state = .idle
                    t.statusMessage = "Ready when you are"
                }
            }
            return
        }

        // Settle the agenda into refined notes (the "After" state).
        if var agenda = t.agenda {
            for i in agenda.sections.indices {
                agenda.sections[i].status = .refined
                if i < Self.refinedBullets.count {
                    agenda.sections[i].filledContent = Self.refinedBullets[i]
                }
            }
            t.agenda = agenda
            t.agendaFillState = .ready
        }

        Task { [weak t] in
            guard let t else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await t.generateSummary() }
                group.addTask { await t.cleanTranscript() }
            }
            await MainActor.run {
                t.state = .idle
                t.statusMessage = "Ready when you are"
            }
        }
    }

    // MARK: - Replay

    private func replay() async {
        let script = Self.websiteChangesScript
        for line in script {
            if Task.isCancelled { return }
            if line.pauseBefore > 0 {
                try? await Task.sleep(nanoseconds: UInt64(line.pauseBefore * 1_000_000_000))
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in self?.append(line) }
        }
        await MainActor.run { [weak self] in self?.stop() }
    }

    private func append(_ line: ScriptLine) {
        guard let t = transcriber else { return }
        // Synthetic timestamp based on the meeting start (07:15:00), not real wall-clock.
        let synthetic = Self.meetingBaseTime.addingTimeInterval(line.meetingOffset)
        let entry = TranscriptLine(timestamp: synthetic, speaker: line.speaker, text: line.text)
        if !seenSpeakers.contains(line.speaker) {
            seenSpeakers.insert(line.speaker)
            t.activityEvents.append(ActivityEvent(.newSpeaker, detail: line.speaker))
        }
        t.lines.append(entry)
        t.activityEvents.append(ActivityEvent(.utteranceSaved, detail: line.speaker))

        // Real fills: AgendaFiller reads t.lines on its own clock; the scripted
        // section statuses would just fight it.
        if !useRealFills {
            updateAgendaFill(offset: line.meetingOffset)
        }

        // Append to .md with the synthetic timestamp.
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let written = "[\(f.string(from: synthetic))] [\(line.speaker)] \(line.text)\n"
        try? mdHandle?.write(contentsOf: Data(written.utf8))
    }

    // MARK: - Helpers

    /// Progressively fills the agenda as the conversation moves through topics:
    /// sections before the active one read "Filled", the active one "Writing",
    /// the rest "Upcoming".
    private func updateAgendaFill(offset: TimeInterval) {
        guard let t = transcriber, var agenda = t.agenda else { return }
        let active = Self.sectionIndex(forOffset: offset)
        for i in agenda.sections.indices {
            if i < active {
                agenda.sections[i].status = .filled
                agenda.sections[i].filledContent = i < Self.draftBullets.count ? Self.draftBullets[i] : ""
            } else if i == active {
                agenda.sections[i].status = .writing
                agenda.sections[i].filledContent = i < Self.draftBullets.count ? Self.draftBullets[i] : ""
            } else {
                agenda.sections[i].status = .upcoming
                agenda.sections[i].filledContent = ""
            }
        }
        t.agenda = agenda
    }

    /// Which agenda section the given meeting offset (seconds) belongs to.
    private static func sectionIndex(forOffset offset: TimeInterval) -> Int {
        switch offset {
        case ..<28:    return 0   // homepage hero
        case ..<88:    return 1   // CTA A/B test
        case ..<140:   return 2   // pricing page
        case ..<160:   return 3   // mobile dashboard
        default:       return 4   // SEO & wrap-up
        }
    }

    private func startElapsedTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let t = self.transcriber, let start = self.startedAt else { return }
                t.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func openTranscriptFile(on t: LiveTranscriber) {
        let dir = SessionsScanner.transcriptsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = DateFormatter()
        ts.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("\(ts.string(from: Date())).md")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let header = DateFormatter()
        header.dateFormat = "yyyy-MM-dd HH:mm"
        try? handle.write(contentsOf: Data("# Meeting transcript — \(header.string(from: Date()))\n\n".utf8))
        self.mdHandle = handle
        t.transcriptFileURL = url
    }

    // MARK: - Demo agenda

    /// Five sections matching the website-review script below. " — " splits each
    /// line into a heading + subheading via AgendaParser.
    private static let demoAgendaMarkdown = """
        # Website Review — Weekly Sync
        ## Homepage hero — New copy, photography & CTA placement
        ## CTA A/B test — "Get started" vs "Try it free"
        ## Pricing page — Simplifying the tiers
        ## Mobile dashboard — Responsive pass
        ## SEO & wrap-up — Meta tags and next steps
        """

    /// Short, factual bullets written live as each section is discussed.
    private static let draftBullets: [String] = [
        "- Homepage hero redesigned — new copy and photography.\n- CTA moved above the fold; reads more confident.",
        "- A/B tested the CTA label: \"Try it free\" vs \"Get started\".\n- \"Try it free\" won click-through by ~11%.",
        "- Pricing page rewritten: four tiers down to three.\n- Comparison table removed; annual toggle added.",
        "- Mobile responsiveness pass on the dashboard.\n- Last page that breaks below 500px wide.",
        "- SEO meta tags fixed — per-page Open Graph & Twitter cards.\n- Regroup next Thursday.",
    ]

    /// Polished, labelled bullets produced on the refine pass.
    private static let refinedBullets: [String] = [
        "- **Change —** homepage hero redesigned with new copy and photography.\n- **Effect —** CTA moved above the fold; the page reads more confidently.",
        "- **Result —** \"Try it free\" beat \"Get started\" by ~11% on click-through.\n- **Caveat —** significance marginal (p≈0.04 over 9 days).\n- **Next —** a confirmation test wraps end of next week.",
        "- **Change —** simplified four tiers to three and removed the comparison table.\n- **Add —** annual billing toggle.\n- **Effect —** \"which plan?\" support tickets fell ~20%.",
        "- **Scope —** responsive pass on the dashboard (last page breaking below 500px).\n- **Owner —** due next Friday.",
        "- **Fixed —** per-page Open Graph & Twitter cards (better LinkedIn previews).\n- **Next —** regroup Thursday on the A/B follow-up and mobile dashboard.",
    ]

    // MARK: - Script

    /// Filip ("You") + Sven Andersson ("Them") reviewing recent website changes.
    /// All English. Each line directly responds to the previous one — clear red
    /// thread through hero → A/B test → pricing → mobile → SEO → wrap.
    ///
    /// `pauseBefore` controls demo replay pacing (~45s end-to-end).
    /// `meetingOffset` controls the displayed transcript timestamp (07:15:00 + offset).
    private static let websiteChangesScript: [ScriptLine] = [
        .init(speaker: "You",  pauseBefore: 0.5, meetingOffset: 0,
              text: "Sven, thanks for jumping on. I want to walk you through what we shipped on the website this week, then we can talk about what's next."),
        .init(speaker: "Them", pauseBefore: 2.4, meetingOffset: 8,
              text: "Sounds good. Where do you want to start?"),
        .init(speaker: "You",  pauseBefore: 1.6, meetingOffset: 12,
              text: "Homepage hero, first. We redesigned it — new copy, new photography, and the CTA moved above the fold."),
        .init(speaker: "Them", pauseBefore: 2.4, meetingOffset: 22,
              text: "Yeah, I saw it go live yesterday. The new version feels much more confident — the old hero really buried the value prop."),
        .init(speaker: "You",  pauseBefore: 1.8, meetingOffset: 32,
              text: "Glad you agree. While we were rebuilding the hero we also A/B tested the CTA label: Get started versus Try it free. Free won by about eleven percent on click-through."),
        .init(speaker: "Them", pauseBefore: 2.6, meetingOffset: 46,
              text: "Eleven percent is meaningful. Was that statistically significant at our traffic volume?"),
        .init(speaker: "You",  pauseBefore: 1.8, meetingOffset: 54,
              text: "Just barely. We ran it nine days and hit a p-value around oh-point-oh-four. I want a second confirmation test before we commit long-term."),
        .init(speaker: "Them", pauseBefore: 2.4, meetingOffset: 68,
              text: "Smart. When would you expect that follow-up to wrap?"),
        .init(speaker: "You",  pauseBefore: 1.4, meetingOffset: 76,
              text: "End of next week. I'll send you the numbers as soon as we have them."),
        .init(speaker: "Them", pauseBefore: 2.2, meetingOffset: 82,
              text: "Perfect. And the pricing page — what did you end up changing there?"),
        .init(speaker: "You",  pauseBefore: 1.8, meetingOffset: 91,
              text: "Full rewrite. We simplified from four tiers to three, killed the feature comparison table, and added an annual toggle."),
        .init(speaker: "Them", pauseBefore: 2.6, meetingOffset: 103,
              text: "You killed the comparison table? Weren't people using that to figure out which plan to pick?"),
        .init(speaker: "You",  pauseBefore: 1.8, meetingOffset: 114,
              text: "The heatmaps showed almost nobody was scrolling to it. And support tickets asking which plan is right for me actually dropped twenty percent in the two weeks after we removed it."),
        .init(speaker: "Them", pauseBefore: 2.4, meetingOffset: 130,
              text: "Counterintuitive but I'll take that result. What's the next push?"),
        .init(speaker: "You",  pauseBefore: 1.6, meetingOffset: 140,
              text: "Mobile responsiveness pass on the dashboard. It's the last page that still breaks below five hundred pixels wide. Should be done by next Friday."),
        .init(speaker: "Them", pauseBefore: 2.4, meetingOffset: 152,
              text: "Great. And the SEO meta-tags issue I flagged last week — did that get fixed?"),
        .init(speaker: "You",  pauseBefore: 1.8, meetingOffset: 163,
              text: "Fixed. Open graph and Twitter cards now generate per-page instead of falling back to the site default. That should help LinkedIn previews especially."),
        .init(speaker: "Them", pauseBefore: 2.4, meetingOffset: 175,
              text: "Excellent. Let's regroup next Thursday, same time, and look at the A/B follow-up and the mobile dashboard."),
        .init(speaker: "You",  pauseBefore: 1.4, meetingOffset: 184,
              text: "Works for me. I'll send a calendar invite later today."),
    ]
}
