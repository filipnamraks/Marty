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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
