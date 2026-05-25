import SwiftUI
import AppKit

struct LibraryView: View {
    @Binding var sessions: [SessionSummary]
    @Binding var page: Page

    @State private var search: String = ""
    @State private var renaming: SessionSummary? = nil
    @State private var pendingDelete: SessionSummary? = nil

    private var filtered: [SessionSummary] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead
                searchBar
                ForEach(groupedByBucket, id: \.0) { (bucket, items) in
                    bucketSection(label: bucket, items: items)
                }
                if filtered.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 36)
        }
        .background(Theme.paper)
        .sheet(item: $renaming) { session in
            RenameSheet(session: session, onSave: { newTitle in
                SessionTitleStore.setCustomTitle(newTitle, for: session.id)
                refresh()
            })
        }
        .alert("Move to Trash?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Move to Trash", role: .destructive) {
                if let s = pendingDelete {
                    SessionsScanner.delete(s)
                    pendingDelete = nil
                    refresh()
                }
            }
        } message: {
            if let s = pendingDelete {
                Text("\"\(s.title)\" will be moved to the Trash. You can restore it from Finder.")
            }
        }
    }

    // MARK: Masthead
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(eyebrowText.uppercased())
                    .font(.mono(10.5))
                    .tracking(1.8)
                    .foregroundStyle(Theme.inkMuted)
                Rectangle().fill(Theme.strokeBold).frame(height: 1)
            }
            (Text("Your ").font(.serif(44)) +
             Text("library").font(.serif(44, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(".").font(.serif(44)))
                .foregroundStyle(Theme.ink)
            Text("Every meeting Marty has captured, grouped by when it happened.")
                .font(.bodySerif(16, italic: true))
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var eyebrowText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return "\(f.string(from: Date())) · \(sessions.count) sessions"
    }

    // MARK: Search
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkMuted)
            TextField("Search by title…", text: $search)
                .textFieldStyle(.plain)
                .font(.ui(12.5))
                .foregroundStyle(Theme.ink)
            if !search.isEmpty {
                Button(action: { search = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.sidebar)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420, alignment: .leading)
    }

    // MARK: Buckets
    private var groupedByBucket: [(String, [SessionSummary])] {
        let calendar = Calendar.current
        let now = Date()
        let startToday = calendar.startOfDay(for: now)
        let startYesterday = calendar.date(byAdding: .day, value: -1, to: startToday)!
        let startWeek = calendar.date(byAdding: .day, value: -7, to: startToday)!
        let startMonth = calendar.date(byAdding: .day, value: -30, to: startToday)!

        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var week: [SessionSummary] = []
        var month: [SessionSummary] = []
        var earlier: [SessionSummary] = []

        for s in filtered {
            if s.date >= startToday { today.append(s) }
            else if s.date >= startYesterday { yesterday.append(s) }
            else if s.date >= startWeek { week.append(s) }
            else if s.date >= startMonth { month.append(s) }
            else { earlier.append(s) }
        }

        return [
            ("Today", today),
            ("Yesterday", yesterday),
            ("This week", week),
            ("This month", month),
            ("Earlier", earlier),
        ].filter { !$0.1.isEmpty }
    }

    @ViewBuilder
    private func bucketSection(label: String, items: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label.uppercased())
                    .font(.mono(10))
                    .tracking(1.8)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Text("\(items.count)")
                    .font(.mono(10))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.stroke).frame(height: 1.5)
            }
            .padding(.bottom, 6)

            ForEach(items) { session in
                LibraryRow(session: session,
                           onOpen: { page = .past(session) },
                           onRename: { renaming = session },
                           onDelete: { pendingDelete = session })
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Theme.inkMuted)
            Text(search.isEmpty ? "No sessions yet." : "Nothing matches \"\(search)\".")
                .font(.serif(20, italic: true))
                .foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func refresh() {
        sessions = SessionsScanner.scan()
    }
}

private struct LibraryRow: View {
    let session: SessionSummary
    var onOpen: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM · HH:mm"
        return f
    }()

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.serif(18))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("\(Self.dateFormatter.string(from: session.date)) · \(session.lineCount) lines")
                        .font(.mono(10.5))
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                if hovering {
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSoft)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rename")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .background(hovering ? Theme.sidebar : .clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovering = inside }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Rename…") { onRename() }
            Divider()
            Button("Move to Trash", role: .destructive) { onDelete() }
        }
    }
}

private struct RenameSheet: View {
    let session: SessionSummary
    var onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            (Text("Rename ").font(.serif(24)) +
             Text("session").font(.serif(24, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(".").font(.serif(24)))
                .foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("TITLE")
                    .font(.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkMuted)
                TextField("Standup with engineering", text: $title)
                    .textFieldStyle(.plain)
                    .font(.ui(13))
                    .padding(10)
                    .background(Theme.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Reset to auto") {
                    onSave(nil)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.ui(13))
                    .foregroundStyle(Theme.inkSoft)
                Button {
                    onSave(title.trimmingCharacters(in: .whitespaces))
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.ui(13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Theme.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.paper)
        .tint(Theme.ink)
        .onAppear { title = session.title }
    }
}
