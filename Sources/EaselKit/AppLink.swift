import AppKit

/// How the Easel Studio apps (Easel, Reel, Tone, Flip, Quill, Folio) hand files to each other. Everything goes through a shared folder, so the
/// apps don't need to be running or know about each other beyond their bundle identifiers.
///
/// - `ToReel/`, `ToFlip/`, `ToTone/`, `ToQuill/`, `ToFolio/` — files sent to that app to import.
/// - `RoundTrip/<id>/` — files one app asks another to edit (photos to Easel, audio to Tone). The
///   editor saves back to the same file and the sender picks up the change.
public enum AppLink {
    public static let easelBundleID = "app.easel.editor"
    public static let reelBundleID = "app.easel.reel"
    public static let toneBundleID = "app.easel.tone"
    public static let flipBundleID = "app.easel.flip"
    public static let quillBundleID = "app.easel.quill"
    public static let folioBundleID = "app.easel.folio"

    /// The apps, for "Send to…" menus.
    public enum App: String, CaseIterable, Sendable {
        case easel = "Easel", reel = "Reel", tone = "Tone", flip = "Flip", quill = "Quill", folio = "Folio"

        public var bundleID: String {
            switch self {
            case .easel: return AppLink.easelBundleID
            case .reel: return AppLink.reelBundleID
            case .tone: return AppLink.toneBundleID
            case .flip: return AppLink.flipBundleID
            case .quill: return AppLink.quillBundleID
            case .folio: return AppLink.folioBundleID
            }
        }

        public var bundleName: String { rawValue + ".app" }

        /// Where files sent to this app wait to be imported.
        public var inbox: URL { AppLink.folder("To" + rawValue) }
    }

    public static var sharedFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Easel Studio", isDirectory: true))
    }

    public static func folder(_ name: String) -> URL { ensure(sharedFolder.appendingPathComponent(name, isDirectory: true)) }
    public static var toReelFolder: URL { App.reel.inbox }
    public static var roundTripFolder: URL { ensure(sharedFolder.appendingPathComponent("RoundTrip", isDirectory: true)) }

    /// True for files Reel handed to Easel for editing and expects back.
    public static func isRoundTrip(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(roundTripFolder.standardizedFileURL.path + "/")
    }

    public static func isFromEasel(_ url: URL) -> Bool { isInInbox(url, of: .reel) }

    /// True for files another app sent to `app`.
    public static func isInInbox(_ url: URL, of app: App) -> Bool {
        url.standardizedFileURL.path.hasPrefix(app.inbox.standardizedFileURL.path + "/")
    }

    /// A fresh file in `app`'s inbox.
    public static func newInboxURL(for app: App, named name: String, ext: String) -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return app.inbox.appendingPathComponent("\(name)-\(stamp).\(ext)")
    }

    /// Opens `file` in `app`. Returns false if the app couldn't be found.
    @discardableResult
    public static func open(_ file: URL, in app: App) -> Bool {
        open(file, inApp: app.bundleID, fallbackName: app.bundleName)
    }

    /// A fresh round-trip location for `name` (a copy, so originals are never overwritten).
    public static func newRoundTripURL(named name: String) -> URL {
        let dir = ensure(roundTripFolder.appendingPathComponent(UUID().uuidString, isDirectory: true))
        return dir.appendingPathComponent(name)
    }

    public static func newToReelURL(named name: String) -> URL { newInboxURL(for: .reel, named: name, ext: "png") }

    /// Finds the other app: first via Launch Services, then next to this app (e.g. both in `build/`).
    public static func appURL(bundleID: String, fallbackName: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(fallbackName)
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    /// Opens `file` in the other app. Returns false if that app couldn't be found.
    @discardableResult
    public static func open(_ file: URL, inApp bundleID: String, fallbackName: String) -> Bool {
        guard let app = appURL(bundleID: bundleID, fallbackName: fallbackName) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config)
        return true
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
