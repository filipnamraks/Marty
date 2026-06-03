import SwiftUI

/// ⌘K command palette — fetch a meeting agenda from a local source
/// (Calendar / Notion / Drive) the way a tiny MCP server would. Keyboard-driven:
/// type to search, ↑↓ to choose, ↵ to import, esc to dismiss.
struct CommandPalette: View {
    var calendar: CalendarStore
    var onImport: (Agenda) -> Void
    var onDismiss: () -> Void

    @State private var query: String = ""
    @State private var results: [AgendaCandidate] = []
    @State private var selected: Int = 0
    @State private var searching = false
    @State private var importing = false
    @State private var error: String?
    @State private var searchToken = 0
    @FocusState private var focused: Bool

    private var resolver: AgendaResolver { AgendaResolver.standard(calendar: calendar) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            panel
                .padding(.top, 118)
        }
        .onAppear { focused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            queryRow
            Divider().overlay(Color(hex: 0x222429))
            content
            footer
        }
        .frame(width: 560)
        .environment(\.colorScheme, .dark)   // native TextField renders light text on the dark panel
        .background(Color(hex: 0x141519))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(hex: 0x26282E), lineWidth: 1))
        .shadow(color: .black.opacity(0.7), radius: 50, y: 30)
        // Keyboard navigation (arrows/return bubble up from the focused field;
        // esc is caught reliably via a hidden cancel-action button).
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .background(Button("", action: onDismiss).keyboardShortcut(.cancelAction).hidden())
    }

    private var queryRow: some View {
        HStack(spacing: 11) {
            Text("⌘").font(.ui(15)).foregroundStyle(Theme.D.accent)
            TextField("", text: $query, prompt:
                Text("the weekly product sync, today at 10").foregroundStyle(Theme.D.mut))
                .textFieldStyle(.plain)
                .font(.ui(15))
                .foregroundStyle(.white)
                .tint(Theme.D.accent)
                .focused($focused)
                .onSubmit { importSelected() }
                .onChange(of: query) { _, q in scheduleSearch(q) }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            hintLine("Type a meeting name to search Calendar, Notion & Drive")
        } else if searching {
            hintLine("Searching…")
        } else if results.isEmpty {
            hintLine("No matches — connect a source in Settings")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Found via local MCP")
                    .font(.ui(10.5, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.D.mut)
                    .padding(.horizontal, 18).padding(.top, 11).padding(.bottom, 5)
                ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                    resultRow(c, isSelected: i == selected)
                        .onTapGesture { selected = i; importSelected() }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func resultRow(_ c: AgendaCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon(for: c.source))
                .font(.system(size: 13))
                .foregroundStyle(Theme.D.sub)
                .frame(width: 18)
            Text(c.title).font(.ui(13.5)).foregroundStyle(Theme.D.text).lineLimit(1)
            Spacer(minLength: 8)
            Text(sourceLabel(c.source))
                .font(.ui(10, weight: .semibold))
                .foregroundStyle(Theme.D.accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.D.accentSoft))
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(isSelected ? Theme.D.accentSoft : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Theme.D.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Text(error ?? "↑↓ to choose · ↵ to import agenda · esc to close")
                .foregroundStyle(error == nil ? Theme.D.mut : Theme.recordText)
            Spacer()
            if importing {
                Text("importing…").foregroundStyle(Theme.D.accent)
            } else if !results.isEmpty {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .foregroundStyle(Theme.D.mut)
            }
        }
        .font(.mono(11))
        .padding(.horizontal, 18).padding(.vertical, 9)
        .overlay(Rectangle().fill(Color(hex: 0x222429)).frame(height: 1), alignment: .top)
    }

    private func hintLine(_ text: String) -> some View {
        Text(text)
            .font(.ui(13)).foregroundStyle(Theme.D.mut)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // MARK: - Behavior

    private func scheduleSearch(_ q: String) {
        error = nil
        searchToken += 1
        let token = searchToken
        let intent = q.trimmingCharacters(in: .whitespaces)
        guard !intent.isEmpty else { results = []; searching = false; return }
        searching = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard token == searchToken else { return }
            let found = await resolver.candidates(for: intent)
            guard token == searchToken else { return }
            results = found
            selected = 0
            searching = false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    private func importSelected() {
        guard !importing, results.indices.contains(selected) else { return }
        let candidate = results[selected]
        importing = true
        error = nil
        Task {
            do {
                let agenda = try await resolver.fetchAgenda(for: candidate)
                importing = false
                onImport(agenda)
            } catch {
                importing = false
                self.error = error.localizedDescription
            }
        }
    }

    private func icon(for source: String) -> String {
        switch source {
        case "calendar": return "calendar"
        case "notion":   return "doc.text"
        case "drive":    return "doc"
        default:         return "magnifyingglass"
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "calendar": return "Calendar"
        case "notion":   return "Notion"
        case "drive":    return "Drive"
        default:         return source.capitalized
        }
    }
}
