import SwiftUI
import EaselKit

@main
struct ReelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Reel", id: "main") {
            ContentView(studio: appDelegate.studio)
        }
        .defaultSize(width: 1500, height: 940)
        .commands { ReelCommands(studio: appDelegate.studio) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let studio = Studio()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        Task { await ReelSelfTest.runIfRequested(studio) }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        studio.open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        studio.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
