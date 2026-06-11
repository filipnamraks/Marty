import Foundation

/// Keeps the meeting agenda filled from the live transcript, then runs one final
/// polish pass on stop. Updates AgendaSection.filledContent + status on the
/// @MainActor LiveTranscriber so the UI re-renders.
///
/// Live updates are INCREMENTAL and APPEND-ONLY: each pass sends only the new
/// transcript since the last update (plus the sections' current notes) and the
/// model returns just the NEW bullets, which are appended here — it never
/// re-reads the whole transcript or rewrites whole sections. That keeps each
/// pass small and bounded no matter how long the meeting runs.
///
/// SCHEDULING is time-based (~one fill per `targetInterval` when new content
/// exists), with WhisperKit-awareness that differs by engine:
///  - cloud (default): if WhisperKit has queued utterances, defer briefly — but
///    HARD-FIRE once `maxWait` has elapsed. A cloud fill uses zero local GPU, so
///    there's nothing to collide with; the defer is only politeness to the
///    MainActor. This is what guarantees fills can't starve in a continuous
///    two-stream conversation (the failure mode of the old idle gate, where
///    `pendingTranscriptions` rarely hit 0 and the agenda stayed empty).
///  - local: strict idle gate, unchanged. Firing Ollama mid-Whisper-burst is the
///    GPU collision that drops sentences; finalize() remains the backstop for a
///    meeting that never pauses.
/// The one full re-read happens in finalize() on stop — that authoritative pass
/// dedupes and rewrites properly.
@MainActor
final class AgendaFiller {
    private weak var transcriber: LiveTranscriber?
    private var tickTask: Task<Void, Never>?
    private var lastProcessedLineCount = 0
    private var inFlight = false
    /// When the last fill was ATTEMPTED (not completed) — so a failing engine is
    /// retried at the normal cadence, not hammered on every 3s tick.
    private var lastFillAttemptAt = Date()

    init(transcriber: LiveTranscriber) {
        self.transcriber = transcriber
    }

    /// Begin live incremental fills. Safe to call multiple times — repeat calls are no-ops.
    func start() {
        guard tickTask == nil else { return }
        // Seed the clock partially elapsed so the first fill lands ~halfway into
        // the first interval — early enough that the document visibly comes alive.
        lastFillAttemptAt = Date().addingTimeInterval(-FillConfig.tuning.targetInterval / 2)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                await self?.maybeIncrementalFill()
            }
        }
    }

    /// The go/no-go decision for one tick, as a pure function so it's trivially
    /// testable and the policy is readable in one place.
    static func shouldFill(elapsed: TimeInterval, newLines: Int, pending: Int,
                           tuning: FillConfig.Tuning) -> Bool {
        guard newLines >= tuning.minNewLines else { return false }
        guard elapsed >= tuning.targetInterval else { return false }
        guard pending > 0 else { return true }          // WhisperKit idle → go
        guard let maxWait = tuning.maxWait else { return false }  // local: strict gate
        return elapsed >= maxWait                        // cloud: defer, then hard-fire
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
        let tuning = FillConfig.tuning
        guard Self.shouldFill(elapsed: Date().timeIntervalSince(lastFillAttemptAt),
                              newLines: total - lastProcessedLineCount,
                              pending: t.pendingTranscriptions,
                              tuning: tuning) else { return }

        inFlight = true
        lastFillAttemptAt = Date()
        defer { inFlight = false }
        // Capture the delta now; advance the cursor only on SUCCESS — otherwise
        // a transient engine error would permanently drop these lines from the
        // live agenda (only finalize() would ever see them again).
        let newLines = Array(t.lines[lastProcessedLineCount..<total])

        if await runIncremental(newLines: newLines) {
            lastProcessedLineCount = total
        }
    }

    /// Append the new bullets the snippet produced to their sections; leave the
    /// rest untouched. Returns false on engine failure so the caller can retry
    /// the same delta next tick.
    private func runIncremental(newLines: [TranscriptLine]) async -> Bool {
        guard let t = transcriber, let snapshot = t.agenda else { return false }

        let result: AgendaFillResult
        do {
            let engine = try FillConfig.makeFillEngine()
            result = try await engine.fillAgendaIncremental(agenda: snapshot, newTranscript: newLines)
        } catch {
            transcriber?.agendaFillState = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return false
        }
        transcriber?.agendaFillState = .ready
        // Re-read the agenda AFTER the await: the user may have hand-edited a
        // section mid-flight, and applying onto the pre-await snapshot would
        // silently clobber that edit (its stale userEdited flag wouldn't show it).
        guard t.state == .running, var agenda = t.agenda else { return true }

        var changed: Set<UUID> = []
        for i in agenda.sections.indices {
            if agenda.sections[i].userEdited { continue }
            let id = agenda.sections[i].id
            guard let newText = result.sections[id] else { continue }   // unchanged → leave as-is
            let existing = agenda.sections[i].filledContent
            // Append only bullets not already present (the model is told not to
            // repeat, but the small draft model sometimes echoes anyway).
            let existingKeys = Set(existing.split(separator: "\n").map(Self.bulletKey))
            let fresh = newText.split(separator: "\n")
                .filter { !Self.bulletKey($0).isEmpty && !existingKeys.contains(Self.bulletKey($0)) }
                .map(String.init)
            guard !fresh.isEmpty else { continue }
            let appended = fresh.joined(separator: "\n")
            agenda.sections[i].filledContent = existing.isEmpty ? appended : existing + "\n" + appended
            agenda.sections[i].filledAt = Date()
            agenda.sections[i].isDraft = true
            agenda.sections[i].status = .filled
            changed.insert(id)
        }
        // Highlight the latest changed section as "writing now".
        if let lastChanged = agenda.sections.lastIndex(where: { changed.contains($0.id) }) {
            agenda.sections[lastChanged].status = .writing
        }
        // Off-agenda is incremental too: append new tangents to the parking lot.
        appendOffAgenda(result.offAgenda, into: &agenda, draft: true)

        if t.state == .running { t.agenda = agenda }
        return true
    }

    /// Normalized identity of a bullet line for dedup: marker, case and
    /// surrounding whitespace don't make a point new.
    private static func bulletKey(_ line: Substring) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
        else if s.hasPrefix("-") { s = String(s.dropFirst(1)) }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
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

    private func runFill(agenda: inout Agenda, transcript: [TranscriptLine], mode: AgendaFillMode) async {
        let result: AgendaFillResult
        do {
            let engine = try FillConfig.makeFillEngine()
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
