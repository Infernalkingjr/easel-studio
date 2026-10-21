import SwiftUI
import EaselKit

@main
struct FlipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Flip", id: "main") {
            ContentView(studio: appDelegate.studio)
        }
        .defaultSize(width: 1440, height: 920)
        .commands { FlipCommands(studio: appDelegate.studio) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let studio = FlipStudio()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        Task { await FlipSelfTest.runIfRequested(studio) }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) { studio.open(urls) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        studio.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
