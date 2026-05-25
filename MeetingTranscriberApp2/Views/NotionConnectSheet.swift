import SwiftUI
import AppKit

/// Step-by-step "Connect Notion" sheet. Filip creates an internal integration
/// in Notion, shares the pages/databases he wants Marty to see, and pastes the
/// token. Marty verifies the token by calling /users/me and stores the
/// workspace name for the Settings "Connected to <name>" badge.
struct NotionConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onConnected: () -> Void = {}

    @State private var token: String = ""
    @State private var status: ConnectStatus = .idle

    enum ConnectStatus: Equatable {
        case idle
        case verifying
        case success(workspace: String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.stroke)
            ScrollView { body_ }
            Divider().background(Theme.stroke)
            footer
        }
        .frame(width: 540, height: 560)
        .background(Theme.paper)
        .tint(Theme.ink)
    }

    private var header: some View {
        HStack(alignment: .center) {
            (Text("Connect ").font(.serif(22)) +
             Text("Notion").font(.serif(22, italic: true)))
                .foregroundStyle(Theme.ink)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Marty asks Claude Haiku 4.5 to search your Notion when a question sounds like it might be in your workspace. The integration only sees pages and databases you explicitly share with it.")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 4)

            stepsList([
                .init(num: 1, title: "Create an integration",
                      body: "Open notion.so/profile/integrations and click \"New integration\". Pick your workspace, give it a name like \"Marty\", capability: read content. Save."),
                .init(num: 2, title: "Copy the Internal Integration Token",
                      body: "On the next screen, copy the long secret_xxx token. Paste it below."),
                .init(num: 3, title: "Share the right pages",
                      body: "In Notion, open each database or page you want Marty to see → \"…\" menu → \"Connect to\" → pick Marty. Without this, search returns nothing."),
            ])

            VStack(alignment: .leading, spacing: 8) {
                Text("INTEGRATION TOKEN")
                    .font(.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkMuted)
                SecureField("secret_…", text: $token)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .padding(10)
                    .background(Theme.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Stored locally in your macOS Keychain. Never sent anywhere except api.notion.com.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }

            HStack(spacing: 12) {
                Button(action: connect) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 12))
                        Text(connectLabel)
                            .font(.ui(12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.sidebar)
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(token.isEmpty || status == .verifying)

                statusBadge
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var connectLabel: String {
        switch status {
        case .verifying:           return "Verifying…"
        case .success:             return "Reconnect"
        default:                   return "Connect"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .idle: EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying token…").font(.mono(11)).foregroundStyle(Theme.inkMuted)
            }
        case .success(let workspace):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                Text("Connected to \(workspace)").font(.mono(11)).foregroundStyle(Theme.accentDeep)
            }
        case .failure(let msg):
            Text(msg)
                .font(.mono(11))
                .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                .lineLimit(3)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open notion.so/profile/integrations →") {
                if let url = URL(string: "https://www.notion.so/profile/integrations") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.ui(12))
            .foregroundStyle(Theme.inkSoft)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.ui(13, weight: .medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.ink))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Connect

    private func connect() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        status = .verifying
        Task {
            let provider = NotionProvider(token: t)
            do {
                let workspace = try await provider.verifyAndFetchWorkspaceName()
                SecureStorage.write(SecureStorage.notionToken, value: t)
                SecureStorage.write(SecureStorage.notionWorkspaceName, value: workspace)
                await MainActor.run {
                    status = .success(workspace: workspace)
                    onConnected()
                }
            } catch {
                await MainActor.run {
                    status = .failure(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Steps list

    private struct Step: Identifiable {
        let num: Int
        let title: String
        let body: String
        var id: Int { num }
    }

    private func stepsList(_ steps: [Step]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(step.num)")
                        .font(.mono(12, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 18, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.serif(15))
                            .foregroundStyle(Theme.ink)
                        Text(step.body)
                            .font(.bodySerif(13))
                            .foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
