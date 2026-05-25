import SwiftUI

struct SidebarView: View {
    @Bindable var transcriber: LiveTranscriber
    @Binding var sessions: [SessionSummary]
    @Binding var page: Page
    var onOpenSettings: () -> Void
    var onRequestRecording: () -> Void

    @State private var hoverItem: String?

    private var isHome: Bool {
        if case .home = page { return true } else { return false }
    }
    private var isLive: Bool {
        if case .live = page { return true } else { return false }
    }
    private var isLibrary: Bool {
        if case .library = page { return true } else { return false }
    }
    private var activePastID: URL? {
        if case .past(let s) = page { return s.id } else { return nil }
    }

    private var todayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE · d MMMM"
        return f.string(from: Date()).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            cta
            todaySection
            librarySection
            volumesSection
            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 22)
        .frame(width: 220)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.strokeBold).frame(width: 1.5)
        }
    }

    // MARK: Brand
    private var brand: some View {
        Button(action: { page = .home }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Marty")
                        .font(.serif(26))
                        .foregroundStyle(Theme.ink)
                    Text(".")
                        .font(.serif(26, italic: true))
                        .foregroundStyle(Theme.accent)
                }
                Text(todayLabel)
                    .font(.mono(9.5))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1.5)
        }
        .padding(.bottom, 16)
    }

    // MARK: CTA
    private var cta: some View {
        Button(action: { handleCTA() }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(white: 0.85))
                    Circle().fill(Theme.ink).frame(width: 8, height: 8)
                }
                .frame(width: 24, height: 24)
                Text(transcriber.state == .running ? "Stop recording" : "New recording")
                    .font(.ui(12.5, weight: .medium))
                    .foregroundStyle(Color.white)
                Spacer()
                Text("⌥␣")
                    .font(.mono(10))
                    .foregroundStyle(Color(white: 0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                LinearGradient(colors: [Theme.ink, Color(red: 0.16, green: 0.16, blue: 0.16)],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 22)
    }

    private func handleCTA() {
        switch transcriber.state {
        case .idle: onRequestRecording()
        case .running: transcriber.stop()
        default: break
        }
    }

    // MARK: Today
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Today")
            navRow(label: "Home", icon: "house", showsLiveDot: false, isActive: isHome)
                .onTapGesture { page = .home }
            navRow(label: "Live", icon: "circle.dotted", showsLiveDot: transcriber.state == .running, isActive: isLive)
                .onTapGesture { page = .live }
        }
        .padding(.bottom, 6)
    }

    // MARK: Library
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            libraryHeader
            if sessions.isEmpty {
                Text("No sessions yet")
                    .font(.ui(11))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(sessions.prefix(6)) { session in
                    librarySessionRow(session)
                }
                if sessions.count > 6 {
                    Button(action: { page = .library }) {
                        HStack {
                            Text("Show all \(sessions.count) →")
                                .font(.mono(10))
                                .foregroundStyle(Theme.inkMuted)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var libraryHeader: some View {
        Button(action: { page = .library }) {
            HStack {
                Text("LIBRARY")
                    .font(.mono(9.5))
                    .tracking(1.5)
                    .foregroundStyle(isLibrary ? Theme.ink : Theme.inkMuted)
                Spacer()
                Text("\(sessions.count)")
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func librarySessionRow(_ session: SessionSummary) -> some View {
        let isActive = activePastID == session.id
        let bg: Color = isActive ? Theme.paper : (hoverItem == session.id.path ? Theme.hover : .clear)
        let stroke: Color = isActive ? Theme.stroke : .clear
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.title)
                .font(.ui(12.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Theme.ink : Theme.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(f.string(from: session.date))
                .font(.mono(10))
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(bg)
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in hoverItem = inside ? session.id.path : nil }
        .onTapGesture { page = .past(session) }
    }

    // MARK: Volumes (placeholders)
    private var volumesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Volumes")
            ForEach(["I — Customer", "II — Internal", "III — Interviews", "IV — Personal"], id: \.self) { name in
                navRow(label: name, showsLiveDot: false, isActive: false)
            }
        }
    }

    // MARK: Footer
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.stroke)
            VStack(alignment: .leading, spacing: 4) {
                footerRow("Sessions", String(sessions.count))
                footerRow("Plan", "Local")
                footerRow("Build", "α")
            }
            .padding(.top, 14)
            profileRow
                .padding(.top, 12)
            settingsButton
        }
    }

    @Bindable private var profile: UserProfile = .shared

    private var profileRow: some View {
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
            HStack(spacing: 9) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.isSignedIn ? "Signed in as" : "Profile")
                        .font(.mono(8.5))
                        .tracking(1.4)
                        .foregroundStyle(Theme.inkMuted)
                    Text(profile.displayName)
                        .font(.ui(12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Theme.paper)
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.sidebar)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1.5)
                )
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(profile.initials)
                    .font(.serif(15))
                    .foregroundStyle(Theme.ink)
                Text(".")
                    .font(.serif(15, italic: true))
                    .foregroundStyle(Theme.accent)
            }
            .offset(y: 1)
        }
        .frame(width: 28, height: 28)
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                Text("Settings")
                    .font(.ui(12))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func footerRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.mono(10.5)).foregroundStyle(Theme.inkMuted)
            Spacer()
            Text(value).font(.mono(10.5, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    // MARK: Helpers
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.mono(9.5))
            .tracking(1.5)
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func navRow(label: String, icon: String? = nil, showsLiveDot: Bool, isActive: Bool) -> some View {
        HStack(spacing: 9) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isActive ? Theme.ink : Theme.inkMuted)
                    .frame(width: 14)
            }
            Text(label)
                .font(.ui(12.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Theme.ink : Theme.inkSoft)
            Spacer()
            if showsLiveDot {
                LivePulseDot()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? Theme.paper : (hoverItem == label ? Theme.hover : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(isActive ? Theme.stroke : .clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in hoverItem = inside ? label : nil }
    }
}

// Small reusable Marty icon — same look as the app icon, scaled.
struct MartyMiniIcon: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                .fill(Theme.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1.5)
                )
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("M")
                    .font(.serif(size * 0.62))
                    .foregroundStyle(Theme.ink)
                Text(".")
                    .font(.serif(size * 0.62, italic: true))
                    .foregroundStyle(Theme.accent)
            }
            .offset(y: size * 0.05)
        }
        .frame(width: size, height: size)
    }
}

// Pulsing dot used for the Live indicator.
struct LivePulseDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 7, height: 7)
            .overlay(
                Circle().stroke(Theme.accent.opacity(pulse ? 0 : 0.45), lineWidth: 6)
                    .scaleEffect(pulse ? 2.4 : 1)
            )
            .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            .onAppear { pulse = true }
    }
}
