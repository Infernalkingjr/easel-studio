import SwiftUI
import EaselKit

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Folio", id: "main") {
            ContentView(reader: appDelegate.reader)
        }
        .defaultSize(width: 1280, height: 900)
        .commands { FolioCommands(reader: appDelegate.reader) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let reader = FolioReader()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        Task { await FolioSelfTest.runIfRequested(reader) }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) { reader.open(urls) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        reader.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { reader.rememberPosition() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
