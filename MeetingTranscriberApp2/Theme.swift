import SwiftUI

// Convenience hex initializer so the palette below reads like the mockup's CSS.
extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double(hex         & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

/// Design language: "Dark everywhere, except the page."
///
/// The app *chrome* (left sidebar, context bars, the desk the page rests on, the
/// transcript dock, the command palette) is dark — see `Theme.D`. The *page* —
/// the white document sheet and every content/modal surface that reads like a
/// document — uses the light tokens at the top level of `Theme`. Content views
/// (Summary/Transcript/Export/Library/…) and modals keep referencing the
/// top-level tokens and therefore render as light "pages"; only the dark chrome
/// references `Theme.D`.
enum Theme {
    // MARK: - The page (white sheet + light content/modal surfaces)
    static let paper       = Color(hex: 0xFFFFFF)  // the sheet itself
    static let sidebar     = Color(hex: 0xF3F4F6)  // subtle raised surface on the page (inputs, cards, hover)
    static let sidebarBar  = Color(hex: 0xECEEF1)
    static let stroke      = Color(hex: 0xEDEDF0)  // hairline rules / borders
    static let strokeBold  = Color(hex: 0xE2E4E8)

    static let ink         = Color(hex: 0x1B1C20)  // primary text on the page
    static let inkSoft     = Color(hex: 0x5A5D65)  // secondary text
    static let inkMuted    = Color(hex: 0x9A9EA7)  // tertiary text / meta

    static let accent      = Color(hex: 0x5E6AD2)  // indigo — the page's accent
    static let accentSoft  = Color(hex: 0x5E6AD2).opacity(0.12)
    static let accentDeep  = Color(hex: 0x5E6AD2)  // emphasis (italic headlines, "connected" marks)

    static let hover       = Color(hex: 0xF0F1F3)

    static let amber       = Color(hex: 0xB8732E)  // the "Them" speaker in the transcript
    static let amberBright = Color(hex: 0x5E6AD2)  // the section being written (now indigo)
    static let liveBg      = Color(hex: 0x5E6AD2).opacity(0.05)  // indigo wash on the writing section
    static let terminalBg  = Color(hex: 0x1A1A1A)

    // Status chips — indigo (writing) / green (filled & refined)
    static let chipDoneFg     = Color(hex: 0x3AAB74)
    static let chipDoneBg     = Color(hex: 0x3AAB74).opacity(0.10)
    static let chipDoneBorder = Color(hex: 0x3AAB74).opacity(0.30)
    static let chipLiveFg     = Color(hex: 0x5E6AD2)
    static let chipLiveBg     = Color(hex: 0x5E6AD2).opacity(0.10)
    static let chipLiveBorder = Color(hex: 0x5E6AD2).opacity(0.30)

    // Error / danger text (e.g. a failed fetch)
    static let recordRed   = Color(hex: 0xEC6A5E)
    static let recordText  = Color(hex: 0xEC6A5E)

    // MARK: - The chrome (dark "Linear" shell)
    enum D {
        static let room    = Color(hex: 0x050506)  // behind the whole window
        static let app     = Color(hex: 0x0A0B0D)
        static let panel   = Color(hex: 0x0E0F12)  // sidebar / context bar
        static let desk    = Color(hex: 0x08090B)  // the surface the sheet rests on
        static let line    = Color(hex: 0x1D1F24)  // dividers on dark
        static let line2   = Color(hex: 0x17181C)

        static let text    = Color(hex: 0xF3F4F6)  // primary text on dark
        static let sub     = Color(hex: 0xA4A8B2)  // secondary
        static let mut     = Color(hex: 0x6B6F78)  // tertiary / meta

        static let accent      = Color(hex: 0x7C87F2)  // indigo on dark
        static let accentDeep  = Color(hex: 0x5E6AD2)
        static let accentSoft  = Color(hex: 0x7C87F2).opacity(0.14)
        static let green       = Color(hex: 0x54C79A)

        static let navOnBg = Color(hex: 0x191B20)  // active nav row
        static let dockBg  = Color(hex: 0x0C0D0F)  // transcript dock
        static let kkBg    = Color(hex: 0x121317)  // ⌘K chip background
        static let dotGray = Color(hex: 0x3A3D44)  // idle recent-session dot

        // Workspace badge gradient (M avatar)
        static let badgeTop    = Color(hex: 0x7C87F2)
        static let badgeBottom = Color(hex: 0xA878F2)
        static var badgeGradient: LinearGradient {
            LinearGradient(colors: [badgeTop, badgeBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        // Desk background: dark base + two indigo radial glows (top & bottom).
        static var deskGlow: some View {
            ZStack {
                desk
                RadialGradient(colors: [Color(hex: 0x7C87F2).opacity(0.16), .clear],
                               center: .init(x: 0.5, y: -0.05),
                               startRadius: 0, endRadius: 620)
                RadialGradient(colors: [Color(hex: 0xA878F2).opacity(0.07), .clear],
                               center: .init(x: 0.5, y: 1.2),
                               startRadius: 0, endRadius: 720)
            }
        }
    }
}

// Typography: the whole app uses Apple's system fonts — San Francisco for
// headlines, body, and UI, and SF Mono for metadata. No custom/bundled fonts.
// SF is crisp at every size and metrically close to the mockup's Inter /
// JetBrains Mono. These four functions are the SINGLE swap point: to adopt
// Inter + JetBrains Mono later, change only the bodies here (e.g.
// `Font.custom("Inter", size: size)`) — no call-site churn.
extension Font {
    // Display headlines — system San Francisco.
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let base = Font.system(size: size)
        return italic ? base.italic() : base
    }

    // Body prose — system San Francisco.
    static func bodySerif(_ size: CGFloat, italic: Bool = false) -> Font {
        let base = Font.system(size: size)
        return italic ? base.italic() : base
    }

    // UI sans — system San Francisco.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // Technical / metadata — system monospaced (SF Mono).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// Reusable border modifier
struct EditorialBorder: ViewModifier {
    var color: Color = Theme.stroke
    var width: CGFloat = 1.5
    var corner: CGFloat = 0
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(color, lineWidth: width)
        )
    }
}

extension View {
    func editorialBorder(_ color: Color = Theme.stroke, width: CGFloat = 1.5, corner: CGFloat = 0) -> some View {
        modifier(EditorialBorder(color: color, width: width, corner: corner))
    }
}
