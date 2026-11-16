import Foundation
import TwoNoteCore
import TwoNoteCrypto
import TwoNoteDocuments
import YrsKit

// Share to TwoNote
// ----------------
// The share extension runs while the notes are locked and cannot open the vault. So the app,
// the first time it is unlocked, makes a key pair for a "share inbox": the public key goes
// into the App Group container, where the extension finds it; the private key is sealed under
// the vault key and kept in the app's own container, so only an unlocked app can read it. The
// extension seals every shared item to the public key (a libsodium sealed box) and leaves it
// in the inbox folder. It cannot read the item back, and neither can anything else that gets
// at the container. The next time the app is unlocked - at once if it is unlocked already - it
// opens the items, makes a page of each, and deletes the files.
//
// Never added twice: the extension draws the id of the future page and seals it into the item.
// The app creates the page under that id, waits until the page is in the local store, and
// only then deletes the file. If the app dies in between, the next run finds the page already
// there and just removes the file (or finishes a page that got its entry but not its text).

/// Where shared items go.
@MainActor
enum ShareDestination {
    nonisolated static let notebookKey = "share.notebook"
    nonisolated static let sectionKey = "share.section"
    /// The section that is made for shared items when the user has not chosen one.
    nonisolated static let inboxTitle = "Inbox"

    /// The section the user chose (or that was made for them), if it still exists.
    static func chosen(in library: LibraryModel, defaults: UserDefaults) -> (notebookId: String, sectionId: String)? {
        guard let notebookId = defaults.string(forKey: notebookKey), let sectionId = defaults.string(forKey: sectionKey),
              library.notebook(notebookId)?.section(sectionId) != nil else { return nil }
        return (notebookId, sectionId)
    }

    static func choose(notebookId: String, sectionId: String, defaults: UserDefaults) {
        defaults.set(notebookId, forKey: notebookKey)
        defaults.set(sectionId, forKey: sectionKey)
    }

    /// Back to the default: an "Inbox" section in the first notebook.
    static func reset(defaults: UserDefaults) {
        defaults.removeObject(forKey: notebookKey)
        defaults.removeObject(forKey: sectionKey)
    }

    /// The destination, making the Inbox section in the first notebook if nothing (valid) is
    /// chosen. Nil while there is no notebook on this device.
    static func resolve(in library: LibraryModel, defaults: UserDefaults) -> (notebookId: String, sectionId: String)? {
        if let chosen = chosen(in: library, defaults: defaults) { return chosen }
        guard let notebook = library.notebooks.first,
              let sectionId = library.ensureSection(notebookId: notebook.id, title: inboxTitle) else { return nil }
        library.chooseShareDestination((notebook.id, sectionId))
        return (notebook.id, sectionId)
    }

    /// The destination in words, for Settings: "Trip Notes › Inbox".
    static func summary(in library: LibraryModel, defaults: UserDefaults) -> String {
        if let chosen = chosen(in: library, defaults: defaults), let notebook = library.notebook(chosen.notebookId),
           let section = notebook.section(chosen.sectionId) {
            return "\(notebook.displayTitle) › \(section.title.isEmpty ? "Untitled Section" : section.title)"
        }
        guard let notebook = library.notebooks.first else { return inboxTitle }
        return "\(notebook.displayTitle) › \(inboxTitle)"
    }
}

/// A shared item as page content.
enum SharedItemPage {
    /// The body of the page: the text, its paragraphs kept, then the link on a line of its own,
    /// as a real link.
    static func runs(_ item: SharedItem) -> [TextRun] {
        var runs: [TextRun] = []
        if !item.text.isEmpty {
            runs.append(TextRun(text: item.url == nil ? item.text : item.text + "\n"))
        }
        if let url = item.url {
            runs.append(TextRun(text: url, attributes: [PageAttribute.link: .string(url)]))
        }
        return runs
    }

    /// Writes the body into a page that has nothing in it yet, as one edit.
    @MainActor
    static func write(_ item: SharedItem, to page: any PageText) {
        let runs = runs(item)
        guard !runs.isEmpty else { return }
        page.edit { editor in
            var position = 0
            for run in runs {
                editor.insert(run.text, at: position, attributes: run.attributes)
                position += run.text.utf16.count
            }
        }
    }
}

/// The app's side of the share inbox: the key pair, and turning waiting items into pages.
@MainActor
struct ShareImporter {
    /// What the private key is sealed as under the vault key.
    static let keyLabel = "share-inbox-key"

    struct Outcome: Equatable {
        /// Pages made in this run.
        var added = 0
        /// Items still in the inbox (there was no notebook to put them in, or the store refused).
        var waiting = 0
        /// Where the last page went.
        var notebookId: String?
        var sectionId: String?
    }

    let container: SharedContainer
    /// The private key sealed under the vault key, in the app's own container.
    let privateKeyURL: URL
    let defaults: UserDefaults

    var inbox: ShareInbox { ShareInbox(container: container) }

    /// Makes sure the inbox has its key pair and that the public key in the App Group
    /// container is the one that belongs to the private key. Needs the account unlocked.
    @discardableResult
    func prepareKeys(_ client: TwoNoteClient) throws -> (publicKey: Data, privateKey: SecretBytes) {
        let manager = FileManager.default
        var pair: (publicKey: Data, privateKey: SecretBytes)
        if let blob = try? Data(contentsOf: privateKeyURL), let key = try? client.openForThisDevice(blob, label: Self.keyLabel),
           let publicKey = try? SealedBox.publicKey(for: key) {
            pair = (publicKey, key)
        } else {
            // First unlock, another account's leftover, or a damaged file: a new pair. Items
            // sealed to an older public key can no longer be opened and are dropped on import.
            pair = SealedBox.generateKeyPair()
            let blob = try client.sealForThisDevice(pair.privateKey, label: Self.keyLabel)
            try manager.createDirectory(at: privateKeyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.write(to: privateKeyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        if (try? Data(contentsOf: container.publicKeyURL)) != pair.publicKey {
            try manager.createDirectory(at: container.root, withIntermediateDirectories: true)
            try pair.publicKey.write(to: container.publicKeyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try? manager.createDirectory(at: container.inboxURL, withIntermediateDirectories: true)
        Self.excludeFromBackup(container.publicKeyURL)
        Self.excludeFromBackup(container.inboxURL)
        return pair
    }

    /// Turns every waiting item into a page. Files that are not items sealed to this inbox
    /// (damaged, too large, from an earlier key) are removed; files that cannot be read right
    /// now are left for the next run.
    func importWaiting(into library: LibraryModel) async -> Outcome {
        var outcome = Outcome()
        let client = library.client
        guard client.state == .unlocked, let keys = try? prepareKeys(client) else {
            outcome.waiting = inbox.waitingItems().count
            return outcome
        }
        removeLeftovers()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        for file in inbox.waitingItems() {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= ShareInbox.maxItemSize else {
                remove(file)
                continue
            }
            guard let sealed = try? Data(contentsOf: file) else { continue } // unreadable right now
            guard let plaintext = try? SealedBox.open(sealed, publicKey: keys.publicKey, privateKey: keys.privateKey),
                  let item = try? decoder.decode(SharedItem.self, from: plaintext), item.isValid else {
                remove(file)
                continue
            }
            do {
                if let existing = library.pageEntry(item.id) {
                    // Made in an earlier run that did not get as far as removing the file.
                    if !existing.page.deleted {
                        try await finish(item, notebookId: existing.notebookId, in: library)
                    }
                } else {
                    guard let place = ShareDestination.resolve(in: library, defaults: defaults) else { break } // no notebook yet
                    let page = try await client.createPage(
                        notebookId: place.notebookId, sectionId: place.sectionId, title: item.title, pageId: item.id)
                    SharedItemPage.write(item, to: page)
                    client.closePage(item.id)
                    outcome.added += 1
                    (outcome.notebookId, outcome.sectionId) = (place.notebookId, place.sectionId)
                }
            } catch {
                break // locked in the meantime, or the store is in trouble: the item stays
            }
            // The file goes only when the page is in the local store.
            await client.flushPendingEdits()
            guard client.state == .unlocked else { break }
            remove(file)
        }
        outcome.waiting = inbox.waitingItems().count
        return outcome
    }

    /// A page that has its entry in the notebook but no text: write the text now.
    private func finish(_ item: SharedItem, notebookId: String, in library: LibraryModel) async throws {
        guard !SharedItemPage.runs(item).isEmpty else { return }
        let client = library.client
        let page = try await client.openPage(notebookId: notebookId, pageId: item.id)
        if page.length == 0 {
            page.initialize()
        }
        if page.length <= 1 {
            SharedItemPage.write(item, to: page)
        }
        if library.selectedPage?.pageId != item.id {
            client.closePage(item.id)
        }
    }

    /// Half-written files a share extension that was killed left behind.
    private func removeLeftovers() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: container.inboxURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for file in files where file.pathExtension != ShareInbox.itemExtension {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < Date().addingTimeInterval(-600) {
                remove(file)
            }
        }
    }

    private func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Removes the key pair and everything that is waiting (signing out).
    func removeEverything() {
        remove(privateKeyURL)
        remove(container.publicKeyURL)
        remove(container.inboxURL)
    }
}

/// The titles the widget may show, written only while the user has the setting on.
@MainActor
enum RecentPagesFile {
    /// The most recently edited pages of the account, newest first.
    static func recent(in notebooks: [LibraryModel.Notebook]) -> RecentPages {
        var all: [(page: PageInfo, notebookId: String)] = []
        for notebook in notebooks {
            for section in notebook.sections {
                all += notebook.pages(in: section.id).map { ($0, notebook.id) }
            }
        }
        all.sort { $0.page.updatedAt != $1.page.updatedAt ? $0.page.updatedAt > $1.page.updatedAt : $0.page.id < $1.page.id }
        return RecentPages(pages: all.prefix(RecentPages.limit).map {
            RecentPages.Page(notebookId: $0.notebookId, pageId: $0.page.id, title: $0.page.title)
        })
    }

    /// Writes the file if it differs from what is there. True if it changed.
    static func write(_ recent: RecentPages, to container: SharedContainer) -> Bool {
        guard RecentPages.load(from: container) != recent, let data = try? JSONEncoder().encode(recent) else { return false }
        try? FileManager.default.createDirectory(at: container.root, withIntermediateDirectories: true)
        // The widget draws while the device is locked, so the file has to be readable then.
        guard (try? data.write(to: container.recentPagesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else {
            return false
        }
        var url = container.recentPagesURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }

    /// Removes the file. True if there was one.
    static func remove(from container: SharedContainer) -> Bool {
        let existed = FileManager.default.fileExists(atPath: container.recentPagesURL.path)
        try? FileManager.default.removeItem(at: container.recentPagesURL)
        return existed
    }
}
