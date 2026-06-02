import SwiftUI
import AppKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, localModel, permissions, done
        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .localModel: return "Local model"
            case .permissions: return "Permissions"
            case .done: return "Ready"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var draftModel: String = LocalLLM.draftModel
    @State private var refineModel: String = LocalLLM.refineModel
    @State private var checkStatus: CheckStatus = .idle

    enum CheckStatus: Equatable {
        case idle, checking
        case ok(missing: [String])
        case unreachable
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
        case .localModel: localModelStep
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

            Text("A fully local meeting assistant. It captures your mic and the other side of the conversation, transcribes both, and fills in your meeting agenda with a model running on your own Mac — nothing leaves the machine.")
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

    // MARK: Local model
    private var localModelStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            eyebrow("Step 02 · Marty's brain")
            (Text("Runs on a ").font(.serif(36)) +
             Text("local").font(.serif(36, italic: true)).foregroundStyle(Theme.accentDeep) +
             Text(" model.").font(.serif(36)))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Marty uses Ollama to run a model on your Mac — private, offline, no API key. Install Ollama, then pull the two models below (a fast one for live drafts, a stronger one for the final polish).")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                commandRow("ollama pull \(draftModel)")
                commandRow("ollama pull \(refineModel)")
            }
            .frame(maxWidth: 560, alignment: .leading)

            HStack(spacing: 12) {
                Button(action: openOllama) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                        Text("Get Ollama at ollama.com")
                    }
                    .font(.mono(11))
                    .foregroundStyle(Theme.accentDeep)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: checkOllama) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle").font(.system(size: 11))
                        Text("Check Ollama").font(.ui(11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.sidebar)
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(checkStatus == .checking)
                checkBadge
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func commandRow(_ command: String) -> some View {
        HStack {
            Text(command).font(.mono(12)).foregroundStyle(Theme.ink)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Theme.sidebar)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var checkBadge: some View {
        switch checkStatus {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("checking").font(.mono(10)).foregroundStyle(Theme.inkMuted)
            }
        case .ok(let missing):
            if missing.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                    Text("ready").font(.mono(10)).foregroundStyle(Theme.accentDeep)
                }
            } else {
                Text("pull: \(missing.joined(separator: ", "))")
                    .font(.mono(10)).foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24)).lineLimit(2)
            }
        case .unreachable:
            Text("not running").font(.mono(10)).foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
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

            Text("Click \"New recording\" to paste or fetch an agenda. Marty fills each section live as you talk, then polishes the whole document when you stop.")
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
            tip("Settings (gear icon, bottom of sidebar) lets you change which local models Marty uses.")
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
            if step == .localModel {
                Button("Skip for now") { complete() }
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
        case .localModel: return "Continue"
        case .permissions: return "Continue"
        case .done: return "Open Marty"
        }
    }

    private func handlePrimary() {
        switch step {
        case .welcome:
            step = .localModel
        case .localModel:
            persistModels()
            step = .permissions
        case .permissions:
            step = .done
        case .done:
            complete()
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.mono(10.5))
            .tracking(1.8)
            .foregroundStyle(Theme.inkMuted)
    }

    // MARK: Actions
    private func persistModels() {
        LocalLLM.draftModel = draftModel.trimmingCharacters(in: .whitespaces)
        LocalLLM.refineModel = refineModel.trimmingCharacters(in: .whitespaces)
    }

    private func complete() {
        persistModels()
        UserDefaults.standard.set(true, forKey: "Marty.hasCompletedOnboarding")
        dismiss()
    }

    private func openOllama() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
    }

    private func checkOllama() {
        persistModels()
        checkStatus = .checking
        Task {
            let health = await OllamaEngine.fromStorage().checkHealth()
            await MainActor.run {
                guard health.reachable else { checkStatus = .unreachable; return }
                let want = [draftModel, refineModel].map { $0.trimmingCharacters(in: .whitespaces) }
                let missing = want.filter { !$0.isEmpty && !health.installedModels.contains($0) }
                checkStatus = .ok(missing: Array(Set(missing)))
            }
        }
    }
}
