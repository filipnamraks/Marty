import SwiftUI

/// Collapsible "live transcript (raw)" peek at the bottom of the agenda document.
/// The transcript is no longer the deliverable — it's a glanceable confirmation
/// that capture is working. Shows the last few lines when open; just a header
/// strip when collapsed.
struct TranscriptDrawer: View {
    let lines: [TranscriptLine]
    @Binding var isOpen: Bool
    var hidden: Bool = false

    private let visibleLineCount = 3

    var body: some View {
        if hidden {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                header
                if isOpen {
                    linesView(lines: tail)
                }
            }
            .background(Color.white)
            .overlay(
                Rectangle().frame(height: 1).foregroundStyle(Theme.stroke),
                alignment: .top
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
            .animation(.easeInOut(duration: 0.18), value: isOpen)
        }
    }

    private var tail: [TranscriptLine] {
        Array(lines.suffix(visibleLineCount))
    }

    private var header: some View {
        Button(action: { isOpen.toggle() }) {
            HStack {
                Text("↑ live transcript (raw)")
                    .font(.mono(10.5, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Text(isOpen ? "collapse ▾" : "expand ▴")
                    .font(.mono(10.5, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white)
            .overlay(
                Rectangle().frame(height: 1).foregroundStyle(Theme.stroke),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    private func linesView(lines: [TranscriptLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if lines.isEmpty {
                Text("Waiting for the first words…")
                    .font(.bodySerif(12.5, italic: true))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            } else {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.speaker)
                            .font(.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(line.text)
                            .font(.bodySerif(12.5))
                            .foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
