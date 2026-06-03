import SwiftUI

/// Choose which parts of the finished meeting to keep — agenda, transcript,
/// and/or summary — and save them to the library under one file.
struct AddToLibrarySheet: View {
    @Bindable var transcriber: LiveTranscriber
    var existing: SavedMeeting? = nil
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var includeAgenda = true
    @State private var includeTranscript = true
    @State private var includeSummary = true

    private var hasAgenda: Bool { transcriber.agenda?.sections.isEmpty == false }
    private var hasTranscript: Bool { !(transcriber.cleanedLines ?? transcriber.lines).isEmpty }
    private var hasSummary: Bool { transcriber.summary != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        ((includeAgenda && hasAgenda) || (includeTranscript && hasTranscript) || (includeSummary && hasSummary))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            (Text("Add to ").font(.serif(24)) +
             Text("library").font(.serif(24, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(".").font(.serif(24)))
                .foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("TITLE").font(.mono(10)).tracking(1.6).foregroundStyle(Theme.inkMuted)
                TextField("Weekly product sync", text: $title)
                    .textFieldStyle(.plain).font(.ui(13))
                    .padding(10)
                    .background(Theme.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT TO KEEP").font(.mono(10)).tracking(1.6).foregroundStyle(Theme.inkMuted)
                partRow(title: "Meeting Agenda", subtitle: "The agenda document and its notes",
                        on: $includeAgenda, available: hasAgenda)
                partRow(title: "Transcript", subtitle: "The full conversation",
                        on: $includeTranscript, available: hasTranscript)
                partRow(title: "Summary", subtitle: "Headline, key points, decisions, actions",
                        on: $includeSummary, available: hasSummary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain).font(.ui(13)).foregroundStyle(Theme.inkSoft)
                Button(action: save) {
                    Text("Save to library")
                        .font(.ui(13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(canSave ? Theme.accent : Theme.inkMuted))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.paper)
        .tint(Theme.accent)
        .onAppear {
            title = existing?.title
                ?? transcriber.agenda?.title
                ?? transcriber.summary?.title
                ?? "Untitled meeting"
            includeAgenda = hasAgenda
            includeTranscript = hasTranscript
            includeSummary = hasSummary
        }
    }

    private func partRow(title: String, subtitle: String, on: Binding<Bool>, available: Bool) -> some View {
        Button(action: { if available { on.wrappedValue.toggle() } }) {
            HStack(spacing: 11) {
                Image(systemName: (on.wrappedValue && available) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle((on.wrappedValue && available) ? Theme.accent : Theme.inkMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(13, weight: .medium)).foregroundStyle(available ? Theme.ink : Theme.inkMuted)
                    Text(available ? subtitle : "Not available for this meeting")
                        .font(.ui(11)).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(available ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private func save() {
        let lines = (transcriber.cleanedLines ?? transcriber.lines).map {
            SavedMeeting.Line(timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text)
        }
        let keepAgenda = includeAgenda && hasAgenda
        let keepTranscript = includeTranscript && hasTranscript
        let keepSummary = includeSummary && hasSummary

        let meeting = SavedMeeting(
            id: existing?.id ?? UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespaces),
            date: existing?.date ?? Date(),
            includesAgenda: keepAgenda,
            includesTranscript: keepTranscript,
            includesSummary: keepSummary,
            agenda: keepAgenda ? transcriber.agenda : nil,
            transcript: keepTranscript ? lines : nil,
            summary: keepSummary ? transcriber.summary : nil
        )
        SavedLibraryStore.save(meeting)
        onSaved()
        dismiss()
    }
}
