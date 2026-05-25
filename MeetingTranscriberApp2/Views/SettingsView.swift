import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onShowOnboarding: (() -> Void)? = nil
    var onConnectCalendar: () -> Void = {}
    @ObservedObject var calendar: CalendarStore

    @State private var apiKey: String = ""
    @State private var model: SummaryModel = .haiku45
    @State private var testStatus: TestStatus = .idle
    @State private var nameField: String = ""
    @Bindable private var profile: UserProfile = .shared

    enum TestStatus: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.stroke)
            content
            Divider().background(Theme.stroke)
            footer
        }
        .frame(width: 540, height: 540)
        .background(Theme.paper)
        .tint(Theme.ink)
        .onAppear(perform: loadFromStorage)
    }

    private var header: some View {
        HStack {
            (Text("Settings").font(.serif(28)) +
             Text(".").font(.serif(28, italic: true)).foregroundStyle(Theme.accent))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private var content: some View {
        ScrollView {
            contentInner
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentInner: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Profile
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR NAME")
                    .font(.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkMuted)
                TextField("Filip Skarman", text: $nameField)
                    .textFieldStyle(.plain)
                    .font(.ui(13))
                    .padding(10)
                    .background(Theme.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Used for greetings and as the [You] speaker label in transcripts.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }

            // API key
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Get one at console.anthropic.com → Settings → Keys. Stored locally in your macOS Keychain.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }

            // Google Calendar
            googleCalendarSection

            // Notion
            notionSection

            // Exa (web search)
            exaSection

            // Model picker
            VStack(alignment: .leading, spacing: 8) {
                Text("DEFAULT MODEL")
                    .font(.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkMuted)
                Picker("", selection: $model) {
                    ForEach(SummaryModel.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .padding(.horizontal, 4)
                Text("Haiku is recommended: ~$0.005 per typical session.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }

            // Test button + status
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button(action: testKey) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 12))
                            Text("Test connection")
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
                    .disabled(apiKey.isEmpty || testStatus == .testing)
                    testStatusBadge
                }
            }

        }
    }

    @ViewBuilder
    private var testStatusBadge: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.mono(11)).foregroundStyle(Theme.inkMuted)
            }
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentDeep)
                Text("Works").font(.mono(11)).foregroundStyle(Theme.accentDeep)
            }
        case .failure(let msg):
            Text(msg)
                .font(.mono(11))
                .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                .lineLimit(2)
        }
    }

    @State private var showNotionConnect: Bool = false
    @State private var notionWorkspace: String? = SecureStorage.read(SecureStorage.notionWorkspaceName)
    @State private var exaKey: String = SecureStorage.read(SecureStorage.exaApiKey) ?? ""
    @State private var exaStatus: ExaConnectStatus = .idle

    enum ExaConnectStatus: Equatable {
        case idle, verifying, ok, failure(String)
    }

    private var exaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXA WEB SEARCH")
                .font(.mono(10))
                .tracking(1.6)
                .foregroundStyle(Theme.inkMuted)
            SecureField("exa-…", text: $exaKey)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .padding(10)
                .background(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Button(action: verifyAndSaveExa) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 12))
                        Text("Save & test")
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
                .disabled(exaKey.isEmpty || exaStatus == .verifying)
                exaBadge
                Spacer()
                if !exaKey.isEmpty {
                    Button("Clear") {
                        SecureStorage.delete(SecureStorage.exaApiKey)
                        exaKey = ""
                        exaStatus = .idle
                    }
                    .buttonStyle(.plain)
                    .font(.ui(11))
                    .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                }
            }
            Text("Get a key at dashboard.exa.ai. Free tier: 1,000 searches/month. Marty uses Exa for real-time web data (weather, news, prices).")
                .font(.bodySerif(13, italic: true))
                .foregroundStyle(Theme.inkSoft)
        }
    }

    @ViewBuilder
    private var exaBadge: some View {
        switch exaStatus {
        case .idle: EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.mono(11)).foregroundStyle(Theme.inkMuted)
            }
        case .ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                Text("Works").font(.mono(11)).foregroundStyle(Theme.accentDeep)
            }
        case .failure(let msg):
            Text(msg)
                .font(.mono(11))
                .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                .lineLimit(2)
        }
    }

    private func verifyAndSaveExa() {
        let k = exaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        SecureStorage.write(SecureStorage.exaApiKey, value: k)
        exaStatus = .verifying
        Task {
            do {
                try await ExaProvider(apiKey: k).verify()
                await MainActor.run { exaStatus = .ok }
            } catch {
                await MainActor.run { exaStatus = .failure(error.localizedDescription) }
            }
        }
    }

    private var notionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTION")
                .font(.mono(10))
                .tracking(1.6)
                .foregroundStyle(Theme.inkMuted)
            if let workspace = notionWorkspace,
               let _ = SecureStorage.read(SecureStorage.notionToken) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentDeep)
                    Text("Connected to \(workspace)")
                        .font(.ui(12))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Disconnect") {
                        SecureStorage.delete(SecureStorage.notionToken)
                        SecureStorage.delete(SecureStorage.notionWorkspaceName)
                        notionWorkspace = nil
                    }
                    .buttonStyle(.plain)
                    .font(.ui(11))
                    .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                }
                Text("Marty can search this workspace when you ask about people, companies, or notes.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            } else {
                HStack(spacing: 12) {
                    Button(action: { showNotionConnect = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                            Text("Connect Notion")
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
                }
                Text("Marty searches your Notion when a question sounds like it's about your workspace.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .sheet(isPresented: $showNotionConnect) {
            NotionConnectSheet(onConnected: {
                notionWorkspace = SecureStorage.read(SecureStorage.notionWorkspaceName)
            })
        }
    }

    private var googleCalendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GOOGLE CALENDAR")
                .font(.mono(10))
                .tracking(1.6)
                .foregroundStyle(Theme.inkMuted)
            if let email = calendar.connectedEmail {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentDeep)
                    Text("Connected as \(email)")
                        .font(.ui(12))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Disconnect") {
                        calendar.disconnect()
                    }
                    .buttonStyle(.plain)
                    .font(.ui(11))
                    .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                }
                Text("Today's events show up in your home dashboard.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            } else {
                HStack(spacing: 12) {
                    Button(action: onConnectCalendar) {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.circle")
                                .font(.system(size: 12))
                            Text("Connect Calendar")
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
                }
                Text("Choose your source — Google, Notion, or Apple Calendar.")
                    .font(.bodySerif(13, italic: true))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Clear key") {
                SecureStorage.delete(SecureStorage.anthropicAPIKey)
                apiKey = ""
                testStatus = .idle
            }
            .buttonStyle(.plain)
            .font(.ui(12))
            .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
            if let onShowOnboarding {
                Button("Show onboarding") { onShowOnboarding() }
                    .buttonStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.leading, 12)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(Theme.inkSoft)
            Button(action: saveAndDismiss) {
                Text("Save")
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Theme.ink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func loadFromStorage() {
        apiKey = SecureStorage.read(SecureStorage.anthropicAPIKey) ?? ""
        if let raw = SecureStorage.read(SecureStorage.preferredModel),
           let m = SummaryModel(rawValue: raw) {
            model = m
        }
        nameField = profile.name
    }

    private func saveAndDismiss() {
        if apiKey.isEmpty {
            SecureStorage.delete(SecureStorage.anthropicAPIKey)
        } else {
            SecureStorage.write(SecureStorage.anthropicAPIKey, value: apiKey)
        }
        SecureStorage.write(SecureStorage.preferredModel, value: model.rawValue)
        let trimmed = nameField.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            profile.signIn(name: trimmed)
        }
        dismiss()
    }

    private func testKey() {
        // Persist temporarily so AnthropicEngine.fromStorage picks it up
        SecureStorage.write(SecureStorage.anthropicAPIKey, value: apiKey)
        SecureStorage.write(SecureStorage.preferredModel, value: model.rawValue)
        testStatus = .testing
        Task {
            do {
                let engine = try AnthropicEngine.fromStorage(model: model)
                let probe = TranscriptLine(timestamp: Date(),
                                           speaker: "You",
                                           text: "Hello, this is a connectivity test.")
                _ = try await engine.summarize(transcript: [probe])
                await MainActor.run { testStatus = .success }
            } catch {
                await MainActor.run { testStatus = .failure(error.localizedDescription) }
            }
        }
    }
}
