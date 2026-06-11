import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onShowOnboarding: (() -> Void)? = nil
    var onConnectCalendar: () -> Void = {}
    @ObservedObject var calendar: CalendarStore

    @State private var whisperModel: String = WhisperConfig.model
    @State private var whisperLanguage: String = WhisperConfig.languageSetting
    @State private var nameField: String = ""
    @State private var apiKeyField: String = ""
    @State private var keyStatus: KeyCheckStatus = .idle
    @Bindable private var profile: UserProfile = .shared

    enum KeyCheckStatus: Equatable {
        case idle, checking, valid, invalid, offline
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.stroke)
            content
            Divider().background(Theme.stroke)
            footer
        }
        .frame(width: 540, height: 560)
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
            VStack(alignment: .leading, spacing: 24) {
                profileSection
                intelligenceSection
                transcriptionSection
                googleCalendarSection
                notionSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("YOUR NAME")
            TextField("Filip Skarman", text: $nameField)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .padding(10)
                .background(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            caption("Used for greetings and as the [You] speaker label in transcripts.")
        }
    }

    private var intelligenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("INTELLIGENCE (CLAUDE)")
            HStack(spacing: 10) {
                Text("API key")
                    .font(.ui(12)).foregroundStyle(Theme.inkSoft)
                    .frame(width: 84, alignment: .leading)
                SecureField("sk-ant-…", text: $apiKeyField)
                    .textFieldStyle(.plain).font(.mono(12))
                    .padding(8)
                    .background(Theme.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                Button(action: checkAPIKey) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal").font(.system(size: 12))
                        Text("Test key").font(.ui(12, weight: .medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.sidebar)
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(keyStatus == .checking || apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
                keyBadge
            }
            caption("Agenda fills, summaries and cleanup run on Claude (\(CloudLLM.defaultLiveModel) live, \(CloudLLM.defaultRefineModel) polish) — only transcript text is sent, never audio. Roughly $0.30–0.60 per meeting hour.")
        }
    }

    @ViewBuilder
    private var keyBadge: some View {
        switch keyStatus {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.mono(11)).foregroundStyle(Theme.inkMuted)
            }
        case .valid:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                Text("Key valid").font(.mono(11)).foregroundStyle(Theme.accentDeep)
            }
        case .invalid:
            Text("Invalid key — check it in the Anthropic console")
                .font(.mono(11)).foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24)).lineLimit(2)
        case .offline:
            Text("Couldn't reach api.anthropic.com — offline?")
                .font(.mono(11)).foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24)).lineLimit(2)
        }
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("TRANSCRIPTION (WHISPERKIT)")
            caption("On-device speech-to-text — audio never leaves this Mac. Turbo is near large-v3 accuracy at a fraction of the cost.")

            modelField(title: "Whisper", text: $whisperModel,
                       placeholder: WhisperConfig.defaultModel,
                       suggestions: WhisperConfig.modelSuggestions)

            HStack(spacing: 10) {
                Text("Language")
                    .font(.ui(12)).foregroundStyle(Theme.inkSoft)
                    .frame(width: 84, alignment: .leading)
                Picker("", selection: $whisperLanguage) {
                    ForEach(WhisperConfig.languageOptions, id: \.code) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            caption("Pinning the language skips per-utterance detection — more accurate on short clips.")
        }
    }

    private func modelField(title: String, text: Binding<String>,
                            placeholder: String,
                            suggestions: [LocalModelOption]) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.ui(12)).foregroundStyle(Theme.inkSoft)
                .frame(width: 84, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.mono(12))
                .padding(8)
                .background(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Menu {
                ForEach(suggestions) { opt in
                    Button(opt.label) { text.wrappedValue = opt.tag }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }

    // MARK: Notion

    @State private var showNotionConnect: Bool = false
    @State private var notionWorkspace: String? = SecureStorage.read(SecureStorage.notionWorkspaceName)

    private var notionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("NOTION")
            if let workspace = notionWorkspace,
               SecureStorage.read(SecureStorage.notionToken) != nil {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                    Text("Connected to \(workspace)").font(.ui(12)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Disconnect") {
                        SecureStorage.delete(SecureStorage.notionToken)
                        SecureStorage.delete(SecureStorage.notionWorkspaceName)
                        notionWorkspace = nil
                    }
                    .buttonStyle(.plain).font(.ui(11)).foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                }
                caption("Marty can pull a meeting agenda from this workspace by name.")
            } else {
                Button(action: { showNotionConnect = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").font(.system(size: 12))
                        Text("Connect Notion").font(.ui(12, weight: .medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.sidebar)
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                caption("Optional — lets you fetch an agenda from a Notion page by describing it.")
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
            fieldLabel("GOOGLE CALENDAR")
            if let email = calendar.connectedEmail {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentDeep)
                    Text("Connected as \(email)").font(.ui(12)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Disconnect") { calendar.disconnect() }
                        .buttonStyle(.plain).font(.ui(11)).foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                }
                caption("Lets you fetch an agenda from an upcoming event by describing it.")
            } else {
                Button(action: onConnectCalendar) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.circle").font(.system(size: 12))
                        Text("Connect Calendar").font(.ui(12, weight: .medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.sidebar)
                    .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                caption("Optional — describe a meeting and Marty pulls its agenda.")
            }
        }
    }

    private var footer: some View {
        HStack {
            if let onShowOnboarding {
                Button("Show onboarding") { onShowOnboarding() }
                    .buttonStyle(.plain).font(.ui(12)).foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain).font(.ui(13)).foregroundStyle(Theme.inkSoft)
            Button(action: saveAndDismiss) {
                Text("Save")
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(Theme.ink).clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
    }

    // MARK: Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.mono(10)).tracking(1.6).foregroundStyle(Theme.inkMuted)
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.bodySerif(13, italic: true)).foregroundStyle(Theme.inkSoft)
    }

    private func loadFromStorage() {
        whisperModel = WhisperConfig.model
        whisperLanguage = WhisperConfig.languageSetting
        nameField = profile.name
        apiKeyField = SecureStorage.read(SecureStorage.anthropicAPIKey) ?? ""
    }

    private func saveAndDismiss() {
        persistModels()
        let trimmed = nameField.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { profile.signIn(name: trimmed) }
        dismiss()
    }

    private func persistModels() {
        let whisper = whisperModel.trimmingCharacters(in: .whitespaces)
        WhisperConfig.model = whisper.isEmpty ? WhisperConfig.defaultModel : whisper
        WhisperConfig.languageSetting = whisperLanguage
        // The key lives in the Keychain, never UserDefaults. Clearing the field
        // deletes the item.
        let key = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            SecureStorage.delete(SecureStorage.anthropicAPIKey)
        } else {
            SecureStorage.write(SecureStorage.anthropicAPIKey, value: key)
        }
    }

    private func checkAPIKey() {
        let key = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .checking
        Task {
            let status = await AnthropicEngine.checkKey(key)
            await MainActor.run {
                switch status {
                case .valid: keyStatus = .valid
                case .invalid: keyStatus = .invalid
                case .offline: keyStatus = .offline
                }
            }
        }
    }
}
