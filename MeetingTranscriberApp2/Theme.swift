import SwiftUI

enum Theme {
    // Warm-paper palette from the mockup
    static let paper       = Color(red: 0xFB/255, green: 0xFA/255, blue: 0xF6/255)  // #fbfaf6
    static let sidebar     = Color(red: 0xF5/255, green: 0xF1/255, blue: 0xE8/255)  // #f5f1e8
    static let sidebarBar  = Color(red: 0xF0/255, green: 0xEC/255, blue: 0xE4/255)  // #f0ece4
    static let stroke      = Color(red: 0xE0/255, green: 0xDC/255, blue: 0xD0/255)  // #e0dcd0
    static let strokeBold  = Color(red: 0xD8/255, green: 0xD2/255, blue: 0xC2/255)  // #d8d2c2

    static let ink         = Color(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255)  // #1a1a1a
    static let inkSoft     = Color(red: 0x4A/255, green: 0x4A/255, blue: 0x4A/255)  // #4a4a4a
    static let inkMuted    = Color(red: 0x88/255, green: 0x88/255, blue: 0x80/255)  // #888880

    static let accent      = Color(red: 0x6B/255, green: 0x6B/255, blue: 0x66/255)  // #6b6b66
    static let accentSoft  = Color(red: 0xE8/255, green: 0xE5/255, blue: 0xDF/255)  // #e8e5df
    static let accentDeep  = Color(red: 0x3A/255, green: 0x3A/255, blue: 0x36/255)  // #3a3a36

    static let hover       = Color(red: 0xEC/255, green: 0xE6/255, blue: 0xD5/255)  // #ece6d5

    static let amber       = Color(red: 0x8A/255, green: 0x7A/255, blue: 0x55/255)  // for "Other" speaker
    static let amberBright = Color(red: 0xC8/255, green: 0x9A/255, blue: 0x3E/255)  // live-section accent
    static let liveBg      = Color(red: 0xFD/255, green: 0xFB/255, blue: 0xF3/255)  // section being filled
    static let terminalBg  = Color(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255)

    // Status chip palette
    static let chipDoneFg     = Color(red: 0x3F/255, green: 0x7D/255, blue: 0x4F/255)
    static let chipDoneBg     = Color(red: 0xEE/255, green: 0xF6/255, blue: 0xEF/255)
    static let chipDoneBorder = Color(red: 0xBC/255, green: 0xD9/255, blue: 0xC2/255)
    static let chipLiveFg     = Color(red: 0xB0/255, green: 0x7A/255, blue: 0x1E/255)
    static let chipLiveBg     = Color(red: 0xFB/255, green: 0xF3/255, blue: 0xDF/255)
    static let chipLiveBorder = Color(red: 0xE6/255, green: 0xD4/255, blue: 0xA6/255)

    // Recording pill
    static let recordRed   = Color(red: 0xD8/255, green: 0x50/255, blue: 0x3A/255)
    static let recordText  = Color(red: 0xB9/255, green: 0x4C/255, blue: 0x38/255)
}

extension Font {
    // Editorial serif — Instrument Serif for headlines
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "Instrument Serif Italic" : "Instrument Serif", size: size)
    }

    // Body prose — Newsreader (used italic in mockup for editorial copy)
    static func bodySerif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "Newsreader Italic" : "Newsreader", size: size)
    }

    // UI sans — Inter
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Inter-Bold"
        case .semibold: name = "Inter-SemiBold"
        case .medium: name = "Inter-Medium"
        case .light, .thin, .ultraLight: name = "Inter-Light"
        default: name = "Inter-Regular"
        }
        return .custom(name, size: size)
    }

    // Technical / metadata — JetBrains Mono
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .medium || weight == .semibold || weight == .bold
            ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular"
        return .custom(name, size: size)
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
