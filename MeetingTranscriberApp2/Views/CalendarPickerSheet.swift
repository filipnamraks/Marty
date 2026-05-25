import SwiftUI
import AppKit

enum CalendarSourceKind: String, Identifiable, CaseIterable {
    case google, notion, apple
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google Calendar"
        case .notion: return "Notion Calendar"
        case .apple:  return "Apple Calendar"
        }
    }

    var blurb: String {
        switch self {
        case .google: return "Sign in once with your Google account."
        case .notion: return "Sync events from your Notion calendar database."
        case .apple:  return "Read events from the macOS Calendar app."
        }
    }

    var letter: String {
        switch self {
        case .google: return "G"
        case .notion: return "N"
        case .apple:  return ""
        }
    }

    var assetName: String {
        switch self {
        case .google: return "GoogleCalendarLogo"
        case .notion: return "NotionCalendarLogo"
        case .apple:  return "AppleCalendarLogo"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .google: return true
        case .notion, .apple: return false
        }
    }
}

struct CalendarPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var calendar: CalendarStore

    @State private var selected: CalendarSourceKind? = nil
    @State private var connectStatus: ConnectStatus = .idle

    enum ConnectStatus: Equatable {
        case idle, connecting, connected, failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.stroke)
            Group {
                if let kind = selected {
                    guide(for: kind)
                } else {
                    chooser
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .background(Theme.paper)
        .tint(Theme.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            if selected != nil {
                Button(action: { selected = nil; connectStatus = .idle }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12))
                        Text("Back").font(.ui(12))
                    }
                    .foregroundStyle(Theme.inkSoft)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            (Text("Connect your ").font(.serif(22)) +
             Text("schedule").font(.serif(22, italic: true)))
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

    // MARK: Chooser (3 cards)

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pick where your meetings live. Marty reads only today's events, never writes anything.")
                .font(.bodySerif(14, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 4)

            VStack(spacing: 12) {
                ForEach(CalendarSourceKind.allCases) { kind in
                    providerCard(kind)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private func providerCard(_ kind: CalendarSourceKind) -> some View {
        Button(action: { selected = kind }) {
            HStack(spacing: 14) {
                providerIcon(kind)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(kind.displayName)
                            .font(.serif(18))
                            .foregroundStyle(Theme.ink)
                        if !kind.isAvailable {
                            Text("soon")
                                .font(.mono(9))
                                .tracking(0.8)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.sidebar))
                                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                                .foregroundStyle(Theme.inkMuted)
                        }
                    }
                    Text(kind.blurb)
                        .font(.bodySerif(13, italic: true))
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(14)
            .background(Theme.paper)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func providerIcon(_ kind: CalendarSourceKind) -> some View {
        Image(kind.assetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 44, height: 44)
    }

    // MARK: Guide (per-provider)

    @ViewBuilder
    private func guide(for kind: CalendarSourceKind) -> some View {
        switch kind {
        case .google: googleGuide
        case .notion: comingSoon(for: kind)
        case .apple:  comingSoon(for: kind)
        }
    }

    private var googleGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                providerIcon(.google)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Calendar")
                        .font(.serif(22))
                        .foregroundStyle(Theme.ink)
                    Text("Read-only access to your primary calendar.")
                        .font(.bodySerif(13, italic: true))
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }
            stepsList([
                "We'll open Google in your browser.",
                "Sign in and approve calendar access.",
                "We'll catch the redirect and store your refresh token in the macOS Keychain."
            ])

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(action: connectGoogle) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                        Text(googleButtonLabel)
                            .font(.ui(13, weight: .medium))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.ink))
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(connectStatus == .connecting)

                connectStatusBadge
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var googleButtonLabel: String {
        switch connectStatus {
        case .connected: return "Connected"
        case .connecting: return "Waiting for browser…"
        default: return "Open Google to sign in"
        }
    }

    @ViewBuilder
    private var connectStatusBadge: some View {
        switch connectStatus {
        case .idle:
            EmptyView()
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting…").font(.mono(11)).foregroundStyle(Theme.inkMuted)
            }
        case .connected:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentDeep)
                Text(calendar.connectedEmail ?? "Connected")
                    .font(.mono(11))
                    .foregroundStyle(Theme.accentDeep)
            }
        case .failure(let msg):
            Text(msg)
                .font(.mono(11))
                .foregroundStyle(Color(red: 0.54, green: 0.29, blue: 0.24))
                .lineLimit(3)
        }
    }

    private func connectGoogle() {
        connectStatus = .connecting
        Task {
            await calendar.connect()
            if calendar.connectedEmail != nil {
                connectStatus = .connected
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            } else if case .error(let msg) = calendar.state {
                connectStatus = .failure(msg)
            } else {
                connectStatus = .idle
            }
        }
    }

    // MARK: Coming-soon screens

    private func comingSoon(for kind: CalendarSourceKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                providerIcon(kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.serif(22))
                        .foregroundStyle(Theme.ink)
                    Text("Coming soon.")
                        .font(.bodySerif(13, italic: true))
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }

            comingSoonCopy(kind)

            Spacer(minLength: 0)

            HStack {
                Button(action: { selected = nil }) {
                    Text("Try another source →")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.paper))
                        .overlay(Capsule().stroke(Theme.strokeBold, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func comingSoonCopy(_ kind: CalendarSourceKind) -> some View {
        switch kind {
        case .notion:
            stepsList([
                "You'll create an internal Notion integration with read access to your calendar database.",
                "Paste the integration token into Marty.",
                "Marty reads today's events from your database properties."
            ])
        case .apple:
            stepsList([
                "Marty requests permission to read your local Calendars.",
                "Today's events from every enabled macOS calendar appear here.",
                "Nothing leaves your machine."
            ])
        case .google:
            EmptyView()
        }
    }

    // MARK: Building blocks

    private func stepsList(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, text in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(idx + 1)")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 18, alignment: .leading)
                    Text(text)
                        .font(.bodySerif(14))
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
