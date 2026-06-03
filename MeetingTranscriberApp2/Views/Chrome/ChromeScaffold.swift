import SwiftUI

// Reusable pieces of the dark "Linear" chrome that wraps the white document
// sheet. See Theme.D for the dark palette. "Dark everywhere, except the page."

// MARK: - Desk

/// The dark surface a sheet rests on: indigo-glow background + a centered,
/// vertically-scrolling slot for the white `Sheet`.
struct DeskBackground<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
        .background(Theme.D.deskGlow)
    }
}

// MARK: - Sheet

/// The white document. A clean page that floats on the dark desk.
/// Pass `maxWidth: .infinity` for a near-edge-to-edge writing surface.
struct Sheet<Content: View>: View {
    var maxWidth: CGFloat = 720
    var padding: EdgeInsets = .init(top: 56, leading: 72, bottom: 64, trailing: 72)
    var horizontalMargin: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(padding)
            .frame(maxWidth: maxWidth)
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 50, y: 30)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            .padding(.horizontal, horizontalMargin)
    }
}

// MARK: - Context bar

/// The slim dark top bar: a breadcrumb on the left, caller-supplied controls
/// on the right.
struct ContextBar<Trailing: View>: View {
    var breadcrumb: [String]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(breadcrumb.enumerated()), id: \.offset) { i, crumb in
                    if i > 0 {
                        Text("/").foregroundStyle(Theme.D.mut)
                    }
                    Text(crumb)
                        .foregroundStyle(i == breadcrumb.count - 1 ? Theme.D.text : Theme.D.sub)
                        .fontWeight(i == breadcrumb.count - 1 ? .semibold : .regular)
                        .lineLimit(1)
                }
            }
            .font(.ui(13))
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(Theme.D.panel)
        .overlay(Rectangle().fill(Theme.D.line).frame(height: 1), alignment: .bottom)
    }
}

extension ContextBar where Trailing == EmptyView {
    init(breadcrumb: [String]) {
        self.init(breadcrumb: breadcrumb) { EmptyView() }
    }
}

/// A small ⌘K affordance for the context bar / sheet.
struct CommandKChip: View {
    var label: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("⌘K").font(.mono(11))
                if let label { Text(label).font(.ui(11)) }
            }
            .foregroundStyle(Theme.D.sub)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.D.kkBg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.D.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Film grain

/// A faint, deterministic noise overlay that gives the dark chrome depth.
/// Drawn once via Canvas (no per-frame cost); barely-there on the white sheet.
struct FilmGrain: View {
    var opacity: Double = 0.04

    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    let h = (Int(x) &* 73856093) ^ (Int(y) &* 19349663)
                    let a = Double(h & 0xFF) / 255.0
                    if a > 0.55 {
                        ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                                 with: .color(.white.opacity((a - 0.55) * 0.6)))
                    }
                    x += step
                }
                y += step
            }
        }
        .opacity(opacity)
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
}

// MARK: - Equalizer

/// Animated bars used in the recording pill (4 bars) and the transcript dock (5).
struct EqualizerView: View {
    var barCount: Int = 4
    var color: Color = Theme.D.accent
    var maxHeight: CGFloat = 11
    var barWidth: CGFloat = 2

    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: animating ? maxHeight : 3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.12),
                        value: animating
                    )
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
        .onAppear { animating = true }
    }
}

// MARK: - Section progress meter

enum MeterSegment { case done, writing, empty }

/// Five-segment progress meter under the sheet title (filled / writing / upcoming).
struct SectionMeter: View {
    var segments: [MeterSegment]
    var label: String

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Capsule()
                        .fill(color(for: seg))
                        .frame(height: 4)
                        .opacity(seg == .writing ? (pulse ? 0.55 : 1) : 1)
                }
            }
            .frame(maxWidth: 260)

            Text(label)
                .font(.mono(10.5, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func color(for seg: MeterSegment) -> Color {
        switch seg {
        case .done:    return Theme.chipDoneFg
        case .writing: return Theme.accent
        case .empty:   return Theme.strokeBold
        }
    }
}

// MARK: - Blinking caret

/// A small blinking caret (thin rule) for the live "typing" line on the sheet.
struct SheetCaret: View {
    var height: CGFloat = 15
    var color: Color = Theme.accent

    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: height)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}
