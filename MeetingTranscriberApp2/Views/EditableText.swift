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
        // No box, no outline — just an inline caret, like editing in a word doc.
        if multiline {
            TextEditor(text: $buffer)
                .font(font)
                .foregroundStyle(color)
                .scrollContentBackground(.hidden)
                .tint(Theme.ink)
                .focused($focused)
                .frame(minHeight: 54)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: focused) { _, f in if !f { commit() } }
        } else {
            TextField("", text: $buffer)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(color)
                .tint(Theme.ink)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
        }
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
