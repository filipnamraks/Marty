import SwiftUI

@main
struct MeetingTranscriberApp2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Marty") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Fetch Agenda…") {
                    NotificationCenter.default.post(name: .martyTogglePalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button("Run Demo Session") {
                    NotificationCenter.default.post(name: .martyRunDemo, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Run Demo Session (Real Fills)") {
                    NotificationCenter.default.post(name: .martyRunDemoRealFills, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift, .option])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
