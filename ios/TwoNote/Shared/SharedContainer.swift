import Foundation

// What the app and its extensions share
// -------------------------------------
// The share extension and the widget run while the notes are locked, in their own processes.
// The only place all three can reach is the App Group container, which is NOT part of the
// encrypted store. The rule for it: no note content, no titles and no keys that open anything,
// with one exception the user has to switch on (recent page titles for the widget).
//
// What can be in it:
//
//   share-inbox.pub        A public key (32 bytes). With it the share extension can seal items
//                          that only the unlocked app can open; it opens nothing itself.
//                          Written by the app the first time it is unlocked.
//   ShareInbox/*.tnshare   Shared items waiting for the app, each a libsodium sealed box to
//                          that public key. Unreadable without the private key, which exists
//                          only wrapped under the vault key, in the app's own container.
//   widget-recent.json     Only while "Show Recent Pages in Widget" is on: the titles (and ids)
//                          of the most recently edited pages, in the clear.
//
// Signing out removes all three.

/// The App Group container, or a stand-in folder in tests.
struct SharedContainer: Sendable {
    /// The App Group's identifier, from the running bundle's Info.plist (TwoNoteAppGroup), where
    /// the build puts it from ../Config/TwoNote.xcconfig: group.<prefix>.app on the iPhone, and
    /// <team>.<prefix>.mac on the Mac, whose App Group is team-prefixed (see
    /// TwoNoteMac/Entitlements/TwoNoteMac.entitlements). The app, its extensions and the tests
    /// hosted in the app all have it.
    static let groupIdentifier = infoValue("TwoNoteAppGroup")

    /// What the Darwin notifications of TwoNote are named under (TwoNoteNotificationPrefix):
    /// <prefix>.app on the iPhone; the App Group on the Mac, since a sandboxed Mac process may
    /// only post names under its App Group.
    static let notificationPrefix = infoValue("TwoNoteNotificationPrefix")

    /// Posted (as a Darwin notification, across processes) when the share extension has left an item.
    static let inboxChangedNotification = notificationPrefix + ".share-inbox-changed"

    /// A value the build writes into every TwoNote bundle's Info.plist; empty if it is missing,
    /// which makes the App Group unavailable (`appGroup` is nil) rather than wrong.
    static func infoValue(_ key: String, in bundle: Bundle = .main) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            assertionFailure("\(key) is missing from \(bundle.bundleURL.lastPathComponent)'s Info.plist (see project.yml)")
            return ""
        }
        return value
    }

    let root: URL

    /// The real container; nil when the App Group is not available to this process.
    static var appGroup: SharedContainer? {
        guard !groupIdentifier.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier).map(SharedContainer.init(root:))
    }

    var publicKeyURL: URL { root.appendingPathComponent("share-inbox.pub") }
    var inboxURL: URL { root.appendingPathComponent("ShareInbox", isDirectory: true) }
    var recentPagesURL: URL { root.appendingPathComponent("widget-recent.json") }
}
