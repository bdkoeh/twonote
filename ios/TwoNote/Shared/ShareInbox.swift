import Foundation
import TwoNoteCrypto

/// The share inbox as the share extension sees it: a public key to seal to and a folder to
/// leave sealed items in. The extension cannot read anything back, its own items included.
struct ShareInbox: Sendable {
    /// File name ending of a sealed item.
    static let itemExtension = "tnshare"
    /// Most items that may wait for the app. More are refused until the app has been opened.
    static let maxItems = 200
    /// Largest sealed item in bytes (a full-length text in a 4-byte script, with room to spare).
    static let maxItemSize = 512 * 1024

    enum Failure: Error, Equatable {
        /// The app has never been unlocked on this device: there is no key to seal to.
        case notSetUp
        /// Too many items are waiting.
        case full
        /// The item could not be written.
        case cannotWrite
    }

    let container: SharedContainer

    /// The key items are sealed to, or nil if the app has not been set up and unlocked yet.
    var publicKey: Data? {
        guard let key = try? Data(contentsOf: container.publicKeyURL), key.count == SealedBox.keyLength else { return nil }
        return key
    }

    /// The sealed items that are waiting, oldest first.
    func waitingItems() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: container.inboxURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var dated: [(file: URL, modified: Date)] = []
        for file in files where file.pathExtension == Self.itemExtension {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            dated.append((file, values?.contentModificationDate ?? .distantPast))
        }
        dated.sort { a, b in
            a.modified != b.modified ? a.modified < b.modified : a.file.lastPathComponent < b.file.lastPathComponent
        }
        return dated.map(\.file)
    }

    /// Seals an item and leaves it for the app. Nothing of it is written in the clear.
    /// - Throws: `Failure`.
    func add(_ item: SharedItem) throws {
        guard let publicKey else { throw Failure.notSetUp }
        guard waitingItems().count < Self.maxItems else { throw Failure.full }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let plaintext = try? encoder.encode(item), let sealed = try? SealedBox.seal(plaintext, to: publicKey),
              sealed.count <= Self.maxItemSize else { throw Failure.cannotWrite }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: container.inboxURL, withIntermediateDirectories: true)
            // The name says nothing about the item. Written under a name the app ignores and
            // renamed when complete, so the app never sees half an item.
            let name = UUID().uuidString.lowercased()
            let partial = container.inboxURL.appendingPathComponent(".\(name).partial")
            try sealed.write(to: partial, options: [.completeFileProtection])
            try manager.moveItem(at: partial, to: container.inboxURL.appendingPathComponent("\(name).\(Self.itemExtension)"))
        } catch {
            throw Failure.cannotWrite
        }
    }
}
