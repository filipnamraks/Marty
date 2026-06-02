import SwiftUI

/// The "Before" state — a blank white sheet on the dark desk. The sheet itself
/// is the agenda paste area; fetching from a meeting happens through ⌘K.
struct AgendaInputView: View {
    var onAgendaReady: (Agenda) -> Void
    var onOpenPalette: () -> Void

    @State private var pasteText: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ContextBar(breadcrumb: ["Meetings", "Untitled"]) {
                CommandKChip(label: "fetch agenda", action: onOpenPalette)
            }
            DeskBackground {
                // Near edge-to-edge: a big canvas to write the agenda in.
                Sheet(maxWidth: .infinity, horizontalMargin: 28) { sheetBody }
            }
        }
    }

    private var sheetBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Untitled meeting")
                .font(.serif(29, italic: false))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.inkMuted)
            Text("Paste an agenda below, or press ⌘K to pull one from a meeting")
                .font(.mono(12.5))
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 7)

            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.top, 16).padding(.bottom, 6)

            editor
                .frame(minHeight: 400, alignment: .topLeading)

            hintBar.padding(.top, 22)

            HStack(spacing: 8) {
                Spacer()
                Button(action: { pasteText = ""; editing = true }) {
                    Text("Clear").pageButton(filled: false)
                }
                .buttonStyle(.plain)
                .disabled(pasteText.isEmpty)
                .opacity(pasteText.isEmpty ? 0.4 : 1)

                Button(action: build) {
                    Text("Build agenda").pageButton(filled: true)
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.5 : 1)
            }
            .padding(.top, 24)
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if pasteText.isEmpty {
                (Text(samplePlaceholder) + Text(verbatim: ""))
                    .font(.bodySerif(14.5))
                    .foregroundStyle(Theme.inkMuted.opacity(0.7))
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $pasteText)
                .font(.bodySerif(14.5))
                .foregroundStyle(Color(hex: 0x33353C))
                .scrollContentBackground(.hidden)
                .tint(Theme.accent)
                .focused($editing)
                .frame(minHeight: 220)
        }
    }

    private var hintBar: some View {
        HStack(spacing: 10) {
            hint(icon: nil, "Paste plain text — Marty parses the headings into sections")
            hint(icon: "⌘K", "fetch from a meeting")
        }
    }

    private func hint(icon: String?, _ text: String) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Text(icon).font(.mono(10.5)).foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
            }
            Text(text).font(.ui(12.5)).foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xFCFCFD)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
    }

    private var trimmed: String { pasteText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func build() {
        guard !trimmed.isEmpty else { return }
        onAgendaReady(AgendaParser.parse(markdown: pasteText))
    }

    private let samplePlaceholder = """
        Weekly Product Sync
        1. Last week's metrics
        2. Onboarding redesign
        3. Pricing experiment
        4. Support backlog
        5. Next steps & owners
        """
}

private extension Text {
    /// A filled (indigo) or ghost page button label.
    func pageButton(filled: Bool) -> some View {
        self.font(.ui(13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : Theme.ink)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? Theme.accent : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(filled ? Color.clear : Theme.stroke, lineWidth: 1)
            )
    }
}
