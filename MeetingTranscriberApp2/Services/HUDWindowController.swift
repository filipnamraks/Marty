import AppKit
import SwiftUI

/// Hosts the QueryHUD SwiftUI view in a floating, non-activating NSPanel so it
/// can sit over Zoom/Meet without stealing focus from the meeting app.
@MainActor
final class HUDWindowController {

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

        let size = NSSize(width: 380, height: 280)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false

        let host = NSHostingView(rootView: QueryHUD(assistant: assistant))
        panel.contentView = host

        // Position top-right with a 24pt margin.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.maxX - size.width - 24,
                y: frame.maxY - size.height - 24
            )
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
    }
}
