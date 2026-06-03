import SwiftUI

/// The library — saved meetings shown as Google-Drive-style document cards:
/// a preview, the meeting headline, and the date, newest first.
struct LibraryView: View {
    @Binding var meetings: [SavedMeeting]
    @Binding var page: Page
    var onDelete: (SavedMeeting) -> Void

    @State private var search: String = ""
    @State private var pendingDelete: SavedMeeting? = nil

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)]

    private var filtered: [SavedMeeting] {
        guard !search.isEmpty else { return meetings }
        return meetings.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if filtered.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(filtered) { meeting in
                            MeetingCard(meeting: meeting,
                                        onOpen: { page = .saved(meeting.id) },
                                        onDelete: { pendingDelete = meeting })
                        }
                    }
                }
            }
            .padding(28)
        }
        .background(Theme.D.deskGlow)
        .alert("Move to Trash?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Move to Trash", role: .destructive) {
                if let m = pendingDelete { onDelete(m); pendingDelete = nil }
            }
        } message: {
            if let m = pendingDelete {
                Text("\"\(m.title)\" will be moved to the Trash.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library")
                .font(.serif(30).weight(.semibold))
                .foregroundStyle(Theme.D.text)
            Text("Every meeting you've saved — agenda, transcript, and summary.")
                .font(.ui(13))
                .foregroundStyle(Theme.D.sub)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.D.mut)
                TextField("", text: $search,
                          prompt: Text("Search meetings").foregroundStyle(Theme.D.mut))
                    .textFieldStyle(.plain).font(.ui(13)).foregroundStyle(Theme.D.text)
                    .tint(Theme.D.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.D.kkBg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.D.line, lineWidth: 1))
            .frame(maxWidth: 360)
            .environment(\.colorScheme, .dark)
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(search.isEmpty ? "Nothing saved yet" : "No matches")
                .font(.serif(20)).foregroundStyle(Theme.D.text)
            Text(search.isEmpty
                 ? "Finish a meeting and press “Add to library” to keep it here."
                 : "Try a different search.")
                .font(.ui(13)).foregroundStyle(Theme.D.sub)
        }
        .padding(.top, 30)
    }
}

// MARK: - Card

private struct MeetingCard: View {
    let meeting: SavedMeeting
    var onOpen: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 0) {
                preview
                footer
            }
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.D.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkSoft)
                            .padding(7)
                            .background(Circle().fill(Theme.paper).shadow(color: .black.opacity(0.15), radius: 3))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
            Divider()
            Button("Move to Trash", role: .destructive, action: onDelete)
        }
    }

    // A small document-like preview, à la Drive thumbnails.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.serif(15).weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.bodySerif(10.5))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 150, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white)
        .clipped()
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "doc.text.fill").font(.system(size: 11)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(Self.dateFormatter.string(from: meeting.date))
                    .font(.mono(10)).foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }

    private var previewLines: [String] {
        if let agenda = meeting.agenda, !agenda.sections.isEmpty {
            return agenda.sections.prefix(6).map { "• \($0.heading)" }
        }
        if let summary = meeting.summary {
            if !summary.summary.isEmpty { return [summary.summary] }
            if !summary.keyPoints.isEmpty { return summary.keyPoints.prefix(6).map { "• \($0)" } }
        }
        if let lines = meeting.transcript, !lines.isEmpty {
            return lines.prefix(6).map { "\($0.speaker): \($0.text)" }
        }
        return [meeting.partsLabel]
    }
}
