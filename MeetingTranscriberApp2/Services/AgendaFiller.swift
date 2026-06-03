import Foundation

/// Periodically asks Claude to fill the meeting's agenda from the live transcript,
/// and runs one final polish pass on stop. Updates AgendaSection.filledContent +
/// status on the @MainActor LiveTranscriber so the UI re-renders.
///
/// Pacing: at most one in-flight request at a time; minimum 30s between draft
/// passes; skips a tick if no new transcript lines arrived.
@MainActor
final class AgendaFiller {
    private weak var transcriber: LiveTranscriber?
    private var tickTask: Task<Void, Never>?
    private var lastLineCount = 0
    private var lastFillAt: Date?
    private var inFlight = false

    private let draftInterval: TimeInterval = 30

    init(transcriber: LiveTranscriber) {
        self.transcriber = transcriber
    }

    /// Begin periodic draft fills. Safe to call multiple times — repeat calls are no-ops.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                await self?.maybeDraftFill()
            }
        }
    }

    /// Stop periodic fills. Does not run the final pass — call `finalize()` for that.
    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Run one final, polished fill pass over the complete transcript.
    func finalize() async {
        guard let t = transcriber, var agenda = t.agenda, !t.lines.isEmpty else { return }
        await runFill(agenda: &agenda, transcript: t.lines, mode: .refined)
        t.agenda = agenda
        // Mark refined.
        for i in t.agenda?.sections.indices ?? 0..<0 {
            if let filled = t.agenda?.sections[i].filledContent, !filled.isEmpty,
               filled != "Not covered in this meeting." {
                t.agenda?.sections[i].status = .refined
                t.agenda?.sections[i].isDraft = false
            } else if t.agenda?.sections[i].filledContent == "Not covered in this meeting." {
                t.agenda?.sections[i].status = .notCovered
                t.agenda?.sections[i].isDraft = false
            }
        }
    }

    // MARK: - Private

    private func maybeDraftFill() async {
        guard let t = transcriber, var agenda = t.agenda else { return }
        guard t.state == .running else { return }
        guard !inFlight else { return }
        guard t.lines.count > lastLineCount else { return }
        if let last = lastFillAt, Date().timeIntervalSince(last) < draftInterval { return }

        inFlight = true
        defer { inFlight = false }
        lastLineCount = t.lines.count
        lastFillAt = Date()

        await runFill(agenda: &agenda, transcript: t.lines, mode: .draft)
        if t.state == .running { t.agenda = agenda }
    }

    private func runFill(agenda: inout Agenda, transcript: [TranscriptLine], mode: OllamaEngine.FillMode) async {
        let engine = OllamaEngine.fromStorage()

        let result: OllamaEngine.AgendaFillResult
        do {
            result = try await engine.fillAgenda(agenda: agenda, transcript: transcript, mode: mode)
        } catch {
            // Surface connection/model errors so the UI isn't silently empty.
            transcriber?.agendaFillState = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        transcriber?.agendaFillState = .ready

        // Find the "active" section — earliest index that has content in the new
        // result but not before, used by the UI to highlight "writing now".
        var writingIndex: Int? = nil
        for i in agenda.sections.indices {
            if agenda.sections[i].userEdited { continue }
            let id = agenda.sections[i].id
            let prev = agenda.sections[i].filledContent
            let next = result.sections[id] ?? prev
            if next != prev, !next.isEmpty {
                writingIndex = i
            }
        }

        for i in agenda.sections.indices {
            let id = agenda.sections[i].id
            // Never overwrite a section the user has hand-edited.
            if agenda.sections[i].userEdited { continue }
            guard let new = result.sections[id] else { continue }
            agenda.sections[i].filledContent = new
            agenda.sections[i].filledAt = Date()
            agenda.sections[i].isDraft = (mode == .draft)
            if new.isEmpty {
                agenda.sections[i].status = .upcoming
            } else if mode == .draft {
                agenda.sections[i].status = (i == writingIndex) ? .writing : .filled
            }
            // refined status handled in finalize()
        }

        // Off-agenda: append or refresh the parking-lot section. Identify it by a
        // sentinel heading so repeated passes don't duplicate it.
        let parkingHeading = "Off agenda"
        if !result.offAgenda.isEmpty {
            let bullets = result.offAgenda.map { "- \($0)" }.joined(separator: "\n")
            if let idx = agenda.sections.firstIndex(where: { $0.heading == parkingHeading }) {
                agenda.sections[idx].filledContent = bullets
                agenda.sections[idx].isDraft = (mode == .draft)
                agenda.sections[idx].status = (mode == .draft) ? .filled : .refined
            } else {
                agenda.sections.append(AgendaSection(
                    heading: parkingHeading,
                    subheading: "Topics that didn't fit the agenda",
                    level: 2,
                    filledContent: bullets,
                    filledAt: Date(),
                    isDraft: (mode == .draft),
                    status: .offAgenda
                ))
            }
        }
    }
}
