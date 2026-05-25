import SwiftUI
import AppKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, apiKey, permissions, done
        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .apiKey: return "API key"
            case .permissions: return "Permissions"
            case .done: return "Ready"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var apiKey: String = SecureStorage.read(SecureStorage.anthropicAPIKey) ?? ""
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider().background(Theme.stroke)
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().background(Theme.stroke)
            footerNav
        }
        .frame(width: 720, height: 560)
        .background(Theme.paper)
        .tint(Theme.ink)
    }

    // MARK: Step indicator
    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                HStack(spacing: 6) {
                    Text(String(format: "%02d", s.rawValue + 1))
                        .font(.mono(10))
                        .foregroundStyle(s == step ? Theme.ink : Theme.inkMuted)
                    Text(s.label.uppercased())
                        .font(.mono(10))
                        .tracking(1.8)
                        .foregroundStyle(s == step ? Theme.ink : Theme.inkMuted)
                }
                if s != Step.allCases.last {
                    Rectangle().fill(Theme.stroke).frame(height: 1).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
    }

    // MARK: Step content
    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .apiKey: apiKeyStep
        case .permissions: permissionsStep
        case .done: doneStep
        }
    }

    // MARK: Welcome
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            eyebrow("Hello.")
            (Text("Welcome to ").font(.serif(44)) +
             Text("Marty").font(.serif(44)).foregroundStyle(Theme.ink) +
             Text(".").font(.serif(44, italic: true)).foregroundStyle(Theme.accent))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("A local-first meeting transcriber. It captures your mic and the other side of the conversation, transcribes both, and asks Claude to make sense of it — all without anything leaving your Mac except the bit you choose to send for the summary.")
                .font(.bodySerif(16, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(4)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Text("This takes about a minute.")
                .font(.mono(11))
                .tracking(1.2)
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: API key
    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            eyebrow("Step 02 · Marty's brain")
            (Text("Add your ").font(.serif(36)) +
             Text("Anthropic").font(.serif(36, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(" key.").font(.serif(36)))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Marty uses Claude to summarize meetings and polish transcripts. Each summary costs roughly $0.005. Your key is stored only in your macOS Keychain — never uploaded anywhere.")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("ANTHROPIC API KEY")
                    .font(.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkMuted)
                SecureField("sk-ant-…", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .padding(10)
                    .background(Theme.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button(action: openConsole) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                        Text("Get a key at console.anthropic.com")
                    }
                    .font(.mono(11))
                    .foregroundStyle(Theme.accentDeep)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: testKey) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal").font(.system(size: 11))
                        Text("Test connection").font(.ui(11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.sidebar)
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(apiKey.isEmpty || testStatus == .testing)
                testStatusBadge
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var testStatusBadge: some View {
        switch testStatus {
        case .idle: EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("testing").font(.mono(10)).foregroundStyle(Theme.inkMuted)
            }
        case .success:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                Text("works").font(.mono(10)).foregroundStyle(Theme.accentDeep)
            }
        case .failure(let msg):
            Text(msg).font(.mono(10)).foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24)).lineLimit(2)
        }
    }

    // MARK: Permissions
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            eyebrow("Step 03 · Two permissions")
            (Text("Let Marty ").font(.serif(36)) +
             Text("listen.").font(.serif(36, italic: true)).foregroundStyle(Theme.accentDeep))
                .foregroundStyle(Theme.ink)

            Text("Marty needs microphone access to hear you, and screen recording access to hear the other side of meetings (Zoom, Meet, YouTube, etc.). Both are fully local — nothing leaves your Mac.")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)

            VStack(spacing: 12) {
                permissionCard(icon: "mic.fill",
                               title: "Microphone",
                               body: "Captures your voice for the [You] track.",
                               buttonLabel: "Open Microphone Settings",
                               url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                permissionCard(icon: "rectangle.on.rectangle",
                               title: "Screen Recording",
                               body: "Captures system audio for the [Them] track. macOS uses this same permission for any system audio capture.",
                               buttonLabel: "Open Screen Recording Settings",
                               url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func permissionCard(icon: String, title: String, body: String, buttonLabel: String, url: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentDeep)
                .frame(width: 36, height: 36)
                .background(Theme.sidebar)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.serif(18)).foregroundStyle(Theme.ink)
                Text(body)
                    .font(.ui(12))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: { NSWorkspace.shared.open(URL(string: url)!) }) {
                Text(buttonLabel)
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.paper)
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.sidebar)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Done
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            eyebrow("Step 04 · Ready")
            (Text("All ").font(.serif(48)) +
             Text("set").font(.serif(48, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(".").font(.serif(48)))
                .foregroundStyle(Theme.ink)

            Text("Click \"New recording\" in the sidebar when you're ready. Marty will transcribe live and write the summary after you stop.")
                .font(.bodySerif(15, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            tipsList
                .padding(.top, 12)
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tipsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            tip("Use headphones during meetings so your mic doesn't pick up speaker audio.")
            tip("Transcripts auto-save to ~/Documents/MeetingTranscripts/ as Markdown.")
            tip("Settings (gear icon, bottom of sidebar) lets you change model or update your key.")
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 6)
            Text(text)
                .font(.ui(12.5))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer nav
    private var footerNav: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
                }
                .buttonStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            if step == .apiKey {
                Button("Skip for now") { complete(skipKey: true) }
                    .buttonStyle(.plain)
                    .font(.ui(13))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.trailing, 6)
            }
            Button(action: handlePrimary) {
                HStack(spacing: 8) {
                    Text(primaryLabel)
                        .font(.ui(13, weight: .medium))
                    if step != .done {
                        Image(systemName: "arrow.right").font(.system(size: 11))
                    }
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

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .apiKey: return "Continue"
        case .permissions: return "Continue"
        case .done: return "Open Marty"
        }
    }

    private func handlePrimary() {
        switch step {
        case .welcome:
            step = .apiKey
        case .apiKey:
            persistKey()
            step = .permissions
        case .permissions:
            step = .done
        case .done:
            complete(skipKey: false)
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.mono(10.5))
            .tracking(1.8)
            .foregroundStyle(Theme.inkMuted)
    }

    // MARK: Actions
    private func persistKey() {
        if apiKey.isEmpty {
            SecureStorage.delete(SecureStorage.anthropicAPIKey)
        } else {
            SecureStorage.write(SecureStorage.anthropicAPIKey, value: apiKey)
        }
    }

    private func complete(skipKey: Bool) {
        if !skipKey { persistKey() }
        UserDefaults.standard.set(true, forKey: "Marty.hasCompletedOnboarding")
        dismiss()
    }

    private func openConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
    }

    private func testKey() {
        SecureStorage.write(SecureStorage.anthropicAPIKey, value: apiKey)
        testStatus = .testing
        Task {
            do {
                let engine = try AnthropicEngine.fromStorage()
                let probe = TranscriptLine(timestamp: Date(), speaker: "You", text: "Hello, this is a connectivity test.")
                _ = try await engine.summarize(transcript: [probe])
                await MainActor.run { testStatus = .success }
            } catch {
                await MainActor.run { testStatus = .failure(error.localizedDescription) }
            }
        }
    }
}
