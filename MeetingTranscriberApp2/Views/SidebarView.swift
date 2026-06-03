import SwiftUI

/// The dark "Linear" sidebar. Workspace badge, real navigation only, a recent
/// list, and a profile foot. No decorative dead links.
struct SidebarView: View {
    @Bindable var transcriber: LiveTranscriber
    @Binding var meetings: [SavedMeeting]
    @Binding var page: Page
    var onOpenSettings: () -> Void
    var onRequestRecording: () -> Void
    var onOpenPalette: () -> Void

    @State private var hoverItem: String?
    @Bindable private var profile: UserProfile = .shared

    private var isHome: Bool { if case .home = page { return true } else { return false } }
    private var isLive: Bool { if case .live = page { return true } else { return false } }
    private var isLibrary: Bool { if case .library = page { return true } else { return false } }
    private var isRunning: Bool { transcriber.state == .running || transcriber.state == .loading }
    private var activeSavedId: String? { if case .saved(let id) = page { return id } else { return nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            workspaceHeader
            navRow(label: "Search", system: "magnifyingglass", isActive: false,
                   trailing: { kbd("⌘K") }) { onOpenPalette() }
            navRow(label: isRunning ? "Live meeting" : "New meeting",
                   system: isRunning ? "dot.radiowaves.left.and.right" : "plus",
                   isActive: isRunning ? isLive : isHome,
                   showsLiveDot: isRunning) {
                if isRunning { page = .live } else { onRequestRecording() }
            }
            navRow(label: "Library", system: "square.grid.2x2", isActive: isLibrary,
                   trailing: { count(meetings.count) }) { page = .library }

            recentSection

            Spacer(minLength: 12)

            navRow(label: "Settings", system: "gearshape", isActive: false) { onOpenSettings() }
            foot
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: 220)
        .background(Theme.D.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.D.line).frame(width: 1)
        }
    }

    // MARK: Workspace header
    private var workspaceHeader: some View {
        Button(action: { page = .home }) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.D.badgeGradient)
                    .frame(width: 23, height: 23)
                    .overlay(Text("M").font(.ui(12, weight: .bold)).foregroundStyle(.white))
                    .shadow(color: Theme.D.accent.opacity(0.35), radius: 5, y: 2)
                Text("Marty").font(.ui(13.5, weight: .semibold)).foregroundStyle(Theme.D.text)
                Spacer()
                Text("▾").font(.ui(11)).foregroundStyle(Theme.D.mut)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Recent
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RECENT")
                .font(.ui(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color(hex: 0x5A5E66))
                .padding(.horizontal, 9)
                .padding(.top, 16)
                .padding(.bottom, 5)

            if meetings.isEmpty && !isRunning {
                Text("No saved meetings")
                    .font(.ui(12))
                    .foregroundStyle(Theme.D.mut)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            } else {
                if isRunning {
                    recentRow(title: transcriber.agenda?.title ?? "Live meeting",
                              isLive: true,
                              elapsed: formatElapsed(transcriber.elapsedSeconds),
                              isActive: isLive) { page = .live }
                }
                ForEach(meetings.prefix(isRunning ? 5 : 6)) { meeting in
                    recentRow(title: meeting.title, isLive: false, elapsed: nil,
                              isActive: activeSavedId == meeting.id) { page = .saved(meeting.id) }
                }
            }
        }
    }

    private func recentRow(title: String, isLive: Bool, elapsed: String?, isActive: Bool,
                           action: @escaping () -> Void) -> some View {
        let key = "recent:\(title):\(isLive)"
        return Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(isLive ? Theme.D.accent : Theme.D.dotGray)
                    .frame(width: 6, height: 6)
                    .overlay {
                        if isLive {
                            Circle().stroke(Theme.D.accentSoft, lineWidth: 3).frame(width: 12, height: 12)
                        }
                    }
                Text(title)
                    .font(.ui(12.5))
                    .foregroundStyle(isActive ? Theme.D.text : Theme.D.sub)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let elapsed {
                    Text(elapsed).font(.mono(10)).foregroundStyle(Theme.D.accent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(rowBackground(active: isActive, key: key))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverItem = $0 ? key : (hoverItem == key ? nil : hoverItem) }
    }

    // MARK: Foot
    private var foot: some View {
        Menu {
            Button("Edit profile") { onOpenSettings() }
            if profile.isSignedIn {
                Divider()
                Button("Sign out", role: .destructive) { profile.signOut() }
            } else {
                Divider()
                Button("Set up profile…") { onOpenSettings() }
            }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: 0x2A2D33))
                    .frame(width: 18, height: 18)
                    .overlay(Text(profile.initials.prefix(1))
                        .font(.ui(10, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xCDD0D6)))
                Text(profile.displayName)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.D.sub)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(Theme.D.mut)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().fill(Theme.D.line).frame(height: 1), alignment: .top)
        .padding(.top, 4)
    }

    // MARK: Reusable nav row
    private func navRow<Trailing: View>(
        label: String,
        system: String,
        isActive: Bool,
        showsLiveDot: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: system)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.D.accent : Theme.D.mut)
                    .frame(width: 15)
                Text(label)
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(isActive ? Theme.D.text : Theme.D.sub)
                Spacer(minLength: 4)
                if showsLiveDot {
                    Circle().fill(Theme.D.accent).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Theme.D.accentSoft, lineWidth: 3).frame(width: 12, height: 12))
                }
                trailing()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(rowBackground(active: isActive, key: "nav:\(label)"))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverItem = $0 ? "nav:\(label)" : (hoverItem == "nav:\(label)" ? nil : hoverItem) }
    }

    private func rowBackground(active: Bool, key: String) -> some View {
        Group {
            if active {
                Theme.D.navOnBg
            } else if hoverItem == key {
                Theme.D.line2
            } else {
                Color.clear
            }
        }
    }

    private func kbd(_ s: String) -> some View {
        Text(s).font(.mono(10)).foregroundStyle(Theme.D.mut)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.D.line, lineWidth: 1))
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").font(.mono(10)).foregroundStyle(Theme.D.mut)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.D.line, lineWidth: 1))
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
