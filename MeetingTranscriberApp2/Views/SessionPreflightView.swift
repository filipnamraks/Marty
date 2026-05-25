import SwiftUI

struct SessionPreflightView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var transcriber: LiveTranscriber
    var onStart: () -> Void

    private let defaultsKey = "Marty.defaultSessionContext"

    @State private var context: String = ""
    @State private var rememberAsDefault: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.stroke)
            content
            Divider().background(Theme.stroke)
            footer
        }
        .frame(width: 620, height: 540)
        .background(Theme.paper)
        .tint(Theme.ink)
        .onAppear(perform: loadDefault)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("BEFORE WE START")
                    .font(.mono(10.5))
                    .tracking(1.8)
                    .foregroundStyle(Theme.inkMuted)
                Rectangle().fill(Theme.strokeBold).frame(height: 1)
            }
            (Text("Anything ").font(.serif(34)) +
             Text("Marty").font(.serif(34)) +
             Text(" should know?").font(.serif(34, italic: true)).foregroundStyle(Theme.accentDeep))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Names, technical terms, who's on the call, what you'll be talking about. Marty feeds this to Whisper as context so it transcribes proper nouns and jargon correctly.")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: $context)
                .font(.bodySerif(15, italic: false))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("EXAMPLES")
                    .font(.mono(9.5))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkMuted)
                exampleRow("\"I'm Filip, talking to Sarah from Acme about pricing.\"")
                exampleRow("\"Project is Marty — a SwiftUI macOS meeting transcriber.\"")
                exampleRow("\"Mention of WhisperKit, ScreenCaptureKit, Anthropic.\"")
            }

            Toggle(isOn: $rememberAsDefault) {
                Text("Remember this as the default context for future sessions")
                    .font(.ui(12))
                    .foregroundStyle(Theme.inkSoft)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxHeight: .infinity)
    }

    private func exampleRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("—")
                .font(.mono(11))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.bodySerif(13, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip and start") { startNow(context: "") }
                .buttonStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(Theme.inkSoft)
            Button(action: { startNow(context: context) }) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 11))
                    Text("Start recording")
                        .font(.ui(13, weight: .medium))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Theme.ink)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func loadDefault() {
        context = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    private func startNow(context: String) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriber.sessionContext = trimmed
        if rememberAsDefault {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
        dismiss()
        onStart()
    }
}
