import SwiftUI

/// Click-to-edit text. Shows the value (or a muted placeholder) until you click
/// it, then becomes an inline field. Commits when you click away, press Return
/// (single line), or hit Done / ⌘Return (multiline). The whole point: just click
/// and write.
struct EditableText: View {
    let text: String
    var placeholder: String = "Click to add…"
    var font: Font = .bodySerif(14.5)
    var color: Color = Theme.ink
    var multiline: Bool = false
    var onCommit: (String) -> Void

    @State private var editing = false
    @State private var buffer = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            editor
        } else {
            Text(text.isEmpty ? placeholder : text)
                .font(font)
                .foregroundStyle(text.isEmpty ? Theme.inkMuted.opacity(0.7) : color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
                .help("Click to edit")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if multiline {
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $buffer)
                    .font(font)
                    .foregroundStyle(color)
                    .scrollContentBackground(.hidden)
                    .tint(Theme.accent)
                    .focused($focused)
                    .frame(minHeight: 90)
                    .padding(8)
                    .background(fieldBackground)
                Button(action: commit) {
                    Text("Done").font(.ui(11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .onChange(of: focused) { _, f in if !f { commit() } }
        } else {
            TextField("", text: $buffer)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(color)
                .tint(Theme.accent)
                .focused($focused)
                .onSubmit(commit)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(fieldBackground)
                .onChange(of: focused) { _, f in if !f { commit() } }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.sidebar)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.5), lineWidth: 1.5))
    }

    private func beginEditing() {
        buffer = text
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onCommit(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
