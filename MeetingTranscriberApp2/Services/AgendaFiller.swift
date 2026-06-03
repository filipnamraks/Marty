import Foundation

/// Keeps the meeting agenda filled from the live transcript, then runs one final
/// polish pass on stop. Updates AgendaSection.filledContent + status on the
/// @MainActor LiveTranscriber so the UI re-renders.
///
/// Live updates are INCREMENTAL: each pass sends only the new transcript since the
/// last update (plus the sections' current notes) and merges the new info in — it
/// never re-reads the whole transcript. That keeps each pass small and roughly
/// constant in cost no matter how long the meeting runs, so the model only briefly
/// touches the GPU and doesn't starve WhisperKit. The one full re-read happens in
/// finalize() on stop, when WhisperKit has released the GPU.
@MainActor
final class AgendaFiller {
    private weak var transcriber: LiveTranscriber?
    private var tickTask: Task<Void, Never>?
    private var lastProcessedLineCount = 0
    private var inFlight = false

    /// Fire a live update once this many new transcript lines have accumulated.
    /// Content-triggered (not a wall-clock timer): no work when nothing was said,
    /// a bounded delta when speech is flowing.
    private let newLinesThreshold = 6

    init(transcriber: LiveTranscriber) {
        self.transcriber = transcriber
    }

    /// Begin live incremental fills. Safe to call multiple times — repeat calls are no-ops.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                await self?.maybeIncrementalFill()
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

    private func maybeIncrementalFill() async {
        guard let t = transcriber, t.agenda != nil else { return }
        guard t.state == .running else { return }
        guard !inFlight else { return }
        let total = t.lines.count
        guard total - lastProcessedLineCount >= newLinesThreshold else { return }

        inFlight = true
        defer { inFlight = false }
        // Capture the delta and advance the cursor BEFORE the await; lines that
        // arrive during the request are picked up by the next tick.
        let newLines = Array(t.lines[lastProcessedLineCount..<total])
        lastProcessedLineCount = total

        await runIncremental(newLines: newLines)
    }

    /// Merge only the sections the new snippet changed; leave the rest untouched.
    private func runIncremental(newLines: [TranscriptLine]) async {
        guard let t = transcriber, var agenda = t.agenda else { return }
        let engine = OllamaEngine.fromStorage()

        let result: OllamaEngine.AgendaFillResult
        do {
            result = try await engine.fillAgendaIncremental(agenda: agenda, newTranscript: newLines)
        } catch {
            transcriber?.agendaFillState = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        transcriber?.agendaFillState = .ready
        guard t.state == .running else { return }

        let changed = Set(result.sections.keys)
        for i in agenda.sections.indices {
            if agenda.sections[i].userEdited { continue }
            let id = agenda.sections[i].id
            guard let merged = result.sections[id] else { continue }   // unchanged → leave as-is
            agenda.sections[i].filledContent = merged
            agenda.sections[i].filledAt = Date()
            agenda.sections[i].isDraft = true
            agenda.sections[i].status = .filled
        }
        // Highlight the latest changed section as "writing now".
        if let lastChanged = agenda.sections.lastIndex(where: { changed.contains($0.id) && !$0.userEdited }) {
            agenda.sections[lastChanged].status = .writing
        }
        // Off-agenda is incremental too: append new tangents to the parking lot.
        appendOffAgenda(result.offAgenda, into: &agenda, draft: true)

        if t.state == .running { t.agenda = agenda }
    }

    /// Append new off-agenda bullets to the "Off agenda" parking-lot section,
    /// creating it on first use. (The final pass replaces it wholesale instead.)
    private func appendOffAgenda(_ items: [String], into agenda: inout Agenda, draft: Bool) {
        guard !items.isEmpty else { return }
        let parkingHeading = "Off agenda"
        let newBullets = items.map { "- \($0)" }.joined(separator: "\n")
        if let idx = agenda.sections.firstIndex(where: { $0.heading == parkingHeading }) {
            let existing = agenda.sections[idx].filledContent
            agenda.sections[idx].filledContent = existing.isEmpty ? newBullets : existing + "\n" + newBullets
            agenda.sections[idx].isDraft = draft
            agenda.sections[idx].status = .offAgenda
        } else {
            agenda.sections.append(AgendaSection(
                heading: parkingHeading,
                subheading: "Topics that didn't fit the agenda",
                level: 2,
                filledContent: newBullets,
                filledAt: Date(),
                isDraft: draft,
                status: .offAgenda
            ))
        }
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
