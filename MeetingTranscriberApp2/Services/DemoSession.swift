import Foundation
import SwiftUI

/// Replays a scripted conversation through the live LiveTranscriber UI so you can
/// demo Marty without recording a real meeting. Lines stream in at realistic
/// cadence; the masthead clock ticks; activity feed updates; on auto-stop the
/// normal summary + cleanTranscript pipeline runs against the mock content.
///
/// Triggered by View → Run Demo Session (⇧⌘D).
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

    init(transcriber: LiveTranscriber) {
        self.transcriber = transcriber
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

        seenSpeakers = []
        startedAt = Date()

        // Mirror LiveTranscriber.start()'s .md file creation so the demo lands
        // in ~/Documents/MeetingTranscripts and shows up in Library afterward.
        openTranscriptFile(on: t)

        t.state = .running
        t.statusMessage = "Listening — demo"
        t.activityEvents.append(ActivityEvent(.sessionStarted))

        startElapsedTimer()
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

        // Append to .md with the synthetic timestamp.
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let written = "[\(f.string(from: synthetic))] [\(line.speaker)] \(line.text)\n"
        try? mdHandle?.write(contentsOf: Data(written.utf8))
    }

    // MARK: - Helpers

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
