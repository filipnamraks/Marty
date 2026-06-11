import Foundation
import os

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
/// SCHEDULING is time-based: ~one fill per `targetInterval` when new content
/// exists. If WhisperKit has queued utterances the fill defers briefly — but
/// HARD-FIRES once `maxWait` has elapsed. A cloud fill uses zero local GPU, so
/// there's nothing to collide with; the defer is only politeness to the
/// MainActor. The hard-fire is what guarantees fills can't starve in a
/// continuous two-stream conversation (the failure mode of the old idle gate,
/// where `pendingTranscriptions` rarely hit 0 and the agenda stayed empty).
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
    /// Consecutive failures of the CURRENT chunk (resets when the cursor moves).
    private var consecutiveFailures = 0

    private static let log = Logger(subsystem: "com.filip.meetingtranscriber", category: "agenda-fill")

    /// Don't bother the model for fewer new lines than this.
    static let minNewLines = 2
    /// Aim for one fill per this many seconds.
    static let targetInterval: TimeInterval = 30
    /// With WhisperKit busy, defer at most this long past the target before
    /// firing anyway — the starvation ceiling.
    static let maxWait: TimeInterval = 45
    /// Already-processed lines re-sent as routing context (never re-extracted).
    static let contextLineCount = 3
    /// Hard cap on lines per fill. Bounded input → bounded output, so a backlog
    /// (from a failed fill or a burst of speech) can never grow a response past
    /// the token budget — the compounding-failure loop that froze live fills:
    /// fail → bigger delta → truncated JSON → fail → bigger still, forever.
    /// A backlog larger than this drains chunk by chunk in catch-up mode.
    static let maxLinesPerFill = 12
    /// After this many consecutive failures of the SAME chunk, skip it and move
    /// on — the lines are recovered by finalize(), which re-reads everything.
    /// Live coverage of a poison chunk is worth less than every fill after it.
    static let maxChunkFailures = 3

    init(transcriber: LiveTranscriber) {
        self.transcriber = transcriber
    }

    /// Begin live incremental fills. Safe to call multiple times — repeat calls are no-ops.
    func start() {
        guard tickTask == nil else { return }
        // Seed the clock partially elapsed so the first fill lands ~halfway into
        // the first interval — early enough that the document visibly comes alive.
        lastFillAttemptAt = Date().addingTimeInterval(-Self.targetInterval / 2)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                await self?.maybeIncrementalFill()
            }
        }
    }

    /// The go/no-go decision for one tick, as a pure function so it's trivially
    /// testable and the policy is readable in one place.
    static func shouldFill(elapsed: TimeInterval, newLines: Int, pending: Int) -> Bool {
        guard newLines >= minNewLines else { return false }
        // Catch-up: a full chunk's worth of backlog drains on the 3s tick
        // instead of waiting out the interval (one request in flight at a time
        // regardless — the inFlight guard upstream serializes us).
        if newLines >= maxLinesPerFill { return true }
        guard elapsed >= targetInterval else { return false }
        guard pending > 0 else { return true }   // WhisperKit idle → go
        return elapsed >= maxWait                // busy: defer, then hard-fire
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
        // The refined document is the deliverable — make sure it's on disk.
        t.persistAgendaSidecar()
    }

    // MARK: - Private

    private func maybeIncrementalFill() async {
        guard let t = transcriber, t.agenda != nil else { return }
        guard t.state == .running else { return }
        guard !inFlight else { return }
        let total = t.lines.count
        guard Self.shouldFill(elapsed: Date().timeIntervalSince(lastFillAttemptAt),
                              newLines: total - lastProcessedLineCount,
                              pending: t.pendingTranscriptions) else { return }

        inFlight = true
        lastFillAttemptAt = Date()
        defer { inFlight = false }
        // Take the OLDEST chunk of the backlog, capped at maxLinesPerFill, and
        // advance the cursor only past what this attempt actually covered —
        // on SUCCESS, so a transient engine error doesn't drop lines from the
        // live agenda (finalize() would be the only one to ever see them).
        let backlog = total - lastProcessedLineCount
        let chunkEnd = min(total, lastProcessedLineCount + Self.maxLinesPerFill)
        let newLines = Array(t.lines[lastProcessedLineCount..<chunkEnd])
        // A few already-processed lines ride along as routing context, so a
        // snippet that opens mid-thought is filed by what preceded it.
        let contextStart = max(0, lastProcessedLineCount - Self.contextLineCount)
        let contextLines = Array(t.lines[contextStart..<lastProcessedLineCount])

        Self.log.info("fill attempt: chunk \(newLines.count) lines, backlog \(backlog), failures \(self.consecutiveFailures)")
        let t0 = Date()
        if await runIncremental(newLines: newLines, contextLines: contextLines) {
            lastProcessedLineCount = chunkEnd
            consecutiveFailures = 0
            Self.log.info("fill ok in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1))s, cursor → \(chunkEnd)")
        } else {
            consecutiveFailures += 1
            Self.log.error("fill failed (\(self.consecutiveFailures)/\(Self.maxChunkFailures)) on lines \(self.lastProcessedLineCount)..<\(chunkEnd)")
            if consecutiveFailures >= Self.maxChunkFailures {
                // Self-heal: skip the poison chunk so every fill after it can
                // succeed. finalize() re-reads the full transcript and recovers
                // these lines in the final document.
                Self.log.error("skipping chunk after \(Self.maxChunkFailures) failures — lines \(self.lastProcessedLineCount)..<\(chunkEnd) deferred to finalize()")
                transcriber?.noteAgendaFillIssue("live fill skipped \(chunkEnd - lastProcessedLineCount) lines after repeated errors — they'll appear in the final document")
                lastProcessedLineCount = chunkEnd
                consecutiveFailures = 0
            }
        }
    }

    /// Append the new bullets the snippet produced to their sections; leave the
    /// rest untouched. Returns false on engine failure so the caller can retry
    /// the same delta next tick.
    private func runIncremental(newLines: [TranscriptLine], contextLines: [TranscriptLine]) async -> Bool {
        guard let t = transcriber, let snapshot = t.agenda else { return false }

        let result: AgendaFillResult
        do {
            let engine = try AnthropicEngine.fromStorage()
            result = try await engine.fillAgendaIncremental(agenda: snapshot, newTranscript: newLines,
                                                            contextLines: contextLines)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.error("incremental fill error: \(message)")
            transcriber?.agendaFillState = .error(message)
            transcriber?.noteAgendaFillIssue("agenda fill failed — retrying (\(message))")
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

        if t.state == .running {
            t.agenda = agenda
            t.persistAgendaSidecar()
        }
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
            let engine = try AnthropicEngine.fromStorage()
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
