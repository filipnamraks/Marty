import AppKit
import SwiftUI

/// A small persistent Marty mark pinned to the top-right of the screen.
/// Click it to summon the full assistant HUD with the text field focused.
/// Always floats above other apps but never steals focus.
@MainActor
final class NotchWindowController {

    private var panel: NSPanel?
    private weak var assistant: LiveAssistant?

    init(assistant: LiveAssistant) {
        self.assistant = assistant
    }

    func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func build() {
        guard let assistant = assistant else { return }

        // Vertical bookmark-style tab on the right edge of the screen.
        let size = NSSize(width: 14, height: 56)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.ignoresMouseEvents = false

        let host = NSHostingView(rootView: NotchView(onTap: { [weak assistant] in
            assistant?.toggleFromNotch()
        }))
        panel.contentView = host

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            // Glue to the right edge, vertically centered. The tab pokes 14pt
            // out from the edge (the rest is rounded-off shadow padding).
            let origin = NSPoint(
                x: frame.maxX - size.width + 2,
                y: frame.midY - size.height / 2
            )
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
    }
}

private struct NotchView: View {
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .frame(width: 12, height: 50)
                .background(
                    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 7, bottomLeading: 7, bottomTrailing: 0, topTrailing: 0))
                        .fill(Theme.paper)
                        .shadow(color: .black.opacity(hovering ? 0.22 : 0.14), radius: hovering ? 7 : 4, x: -2, y: 0)
                )
                .overlay(
                    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 7, bottomLeading: 7, bottomTrailing: 0, topTrailing: 0))
                        .stroke(Theme.stroke, lineWidth: 1)
                )
                .offset(x: hovering ? -2 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}
