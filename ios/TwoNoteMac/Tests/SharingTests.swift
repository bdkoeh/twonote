import AppKit
import Foundation
import Security
import SwiftUI
import Testing
import TwoNoteCrypto
import TwoNoteDocuments
import UniformTypeIdentifiers
import WidgetKit
import YrsKit
@testable import TwoNote
@testable import TwoNoteCore

// Stage M2 on the Mac: the Keychain moving from the login keychain to the data-protection
// Keychain, Touch ID there, Share to TwoNote, twonote:// links and the widget's titles.
// The share extension's model and the widget's views are compiled into the app as well, so
// these run what the extensions run, minus their process.

/// A Keychain that refuses to store anything (full disk, a damaged keychain).
private final class RefusingSecretStore: SecretStore, @unchecked Sendable {
    func get(_ name: String) -> String? { nil }
    func set(_ name: String, _ value: String) throws { throw KeychainError(status: errSecIO) }
    func remove(_ name: String) {}
}

/// A Keychain that stores, but hands back something else (it must not be trusted then).
private final class GarblingSecretStore: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    func get(_ name: String) -> String? { inner.get(name).map { $0 + "?" } }
    func set(_ name: String, _ value: String) throws { inner.set(name, value) }
    func remove(_ name: String) { inner.remove(name) }
}

/// Whether the test host was signed with a development team and its provisioning profile
/// (DEVELOPMENT_TEAM in Config/Local.xcconfig). Without one it is signed ad hoc, has no Keychain
/// access group and so no data-protection Keychain: the tests of the real Keychain cannot run.
private let teamSigned = !(Bundle.main.object(forInfoDictionaryKey: "TwoNoteKeychainAccessGroup") as? String ?? "").isEmpty
private let noTeamReason: Comment = "needs a build signed with a development team (DEVELOPMENT_TEAM in Config/Local.xcconfig)"

@MainActor
@Suite("keychain migration", .serialized)
struct KeychainMigrationTests {
    @Test func whatAnM1BuildLeftMovesOnceAndTheAccountStaysSignedIn() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        // Stage M1: the secrets in the login keychain (here: a stand-in), no migration.
        let login = InMemorySecretStore()
        mac.secretStore = MacSecretStore(primary: login, legacy: nil)
        var (app, _) = try await mac.launchEnrolled(seed)
        let secretKey = try #require(login.get(SecretNames.secretKey))
        let token = try #require(login.get(SecretNames.sessionToken))
        await app.lock()
        await app.client?.close()

        // The M2 build: data-protection Keychain first, the login keychain moved over at launch.
        let protected = InMemorySecretStore()
        let store = MacSecretStore(primary: protected, legacy: login)
        #expect(store.migrate() == .init(moved: [SecretNames.secretKey, SecretNames.sessionToken]))
        #expect(protected.get(SecretNames.secretKey) == secretKey && protected.get(SecretNames.sessionToken) == token)
        #expect(login.get(SecretNames.secretKey) == nil && login.get(SecretNames.sessionToken) == nil, "the old items are gone")
        #expect(store.migrate().isEmpty, "once")

        // Still signed in: locked (not set-up), the password unlocks, and the server still takes the token.
        mac.secretStore = store
        app = await mac.launch()
        #expect(app.phase == .locked)
        try await app.unlock(password: testPassword)
        let library = try #require(app.library)
        try await eventually("synced with the moved token") {
            SyncSummary(app.client!.syncMonitor.status).kind == .synced
        }
        #expect(library.notebook(seed.notebookId) != nil)
        // A token renewed from now on goes to the new place only.
        try store.set(SecretNames.sessionToken, "renewed")
        #expect(protected.get(SecretNames.sessionToken) == "renewed" && login.get(SecretNames.sessionToken) == nil)

        // Signing out removes both places' items.
        login.set(SecretNames.secretKey, "left over")
        await app.removeAccount()
        #expect(protected.get(SecretNames.secretKey) == nil && login.get(SecretNames.secretKey) == nil)
        #expect(app.phase == .setUp)
    }

    @Test func aMoveThatFailsLeavesTheOldItemsInUse() async throws {
        let login = InMemorySecretStore()
        login.set(SecretNames.secretKey, "T2-KEY")
        login.set(SecretNames.sessionToken, "token")

        let refusing = MacSecretStore(primary: RefusingSecretStore(), legacy: login)
        #expect(refusing.migrate() == .init(failed: [SecretNames.secretKey, SecretNames.sessionToken]))
        #expect(login.get(SecretNames.secretKey) == "T2-KEY", "kept where it was")
        #expect(refusing.get(SecretNames.secretKey) == "T2-KEY", "and still read from there: nobody is signed out")

        // A copy that does not read back the same is not trusted, and not left behind either.
        let garbling = GarblingSecretStore()
        let checked = MacSecretStore(primary: garbling, legacy: login)
        #expect(checked.migrate().failed == [SecretNames.secretKey, SecretNames.sessionToken])
        #expect(garbling.inner.get(SecretNames.secretKey) == nil && login.get(SecretNames.secretKey) == "T2-KEY")

        // Next launch, with a working Keychain, it moves.
        let protected = InMemorySecretStore()
        #expect(MacSecretStore(primary: protected, legacy: login).migrate().moved == [SecretNames.secretKey, SecretNames.sessionToken])

        // Already in the new place (an earlier move whose deletion did not happen): the new place wins.
        login.set(SecretNames.secretKey, "stale")
        #expect(MacSecretStore(primary: protected, legacy: login).migrate() == .init(discarded: [SecretNames.secretKey]))
        #expect(protected.get(SecretNames.secretKey) == "T2-KEY" && login.get(SecretNames.secretKey) == nil)

        // Nothing to move from: nothing happens.
        #expect(MacSecretStore(primary: protected, legacy: nil).migrate().isEmpty)
    }

    @Test(.enabled(if: teamSigned, noTeamReason))
    func theRealKeychainsAsThisSignedAppSeesThem() throws {
        // The test host is the signed app with its provisioning profile: the data-protection
        // Keychain is open to it now (in stage M1 this said errSecMissingEntitlement).
        #expect(MacSecretStore.dataProtectionKeychainAvailable)
        let service = "TwoNote-tests-\(UUID().uuidString)"
        let login = KeychainSecretStore(service: service, dataProtection: false)
        let protected = KeychainSecretStore(service: service, dataProtection: true)
        defer {
            for name in MacSecretStore.names {
                login.remove(name)
                protected.remove(name)
            }
        }
        try login.set(SecretNames.secretKey, "T2-TEST-KEY")
        try login.set(SecretNames.sessionToken, "test-token")
        #expect(protected.get(SecretNames.secretKey) == nil, "two separate keychains")

        let store = MacSecretStore(primary: protected, legacy: login)
        #expect(store.migrate().moved == [SecretNames.secretKey, SecretNames.sessionToken])
        #expect(protected.get(SecretNames.secretKey) == "T2-TEST-KEY" && protected.get(SecretNames.sessionToken) == "test-token")
        #expect(login.get(SecretNames.secretKey) == nil && login.get(SecretNames.sessionToken) == nil)

        // The item is the iPhone's kind: this device only, after first unlock, in the app's own group.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: SecretNames.secretKey,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        // <team>.<prefix>.mac, the one group in the app's entitlements (from Config/*.xcconfig).
        #expect(attributes[kSecAttrAccessGroup as String] as? String == SharedContainer.infoValue("TwoNoteKeychainAccessGroup"))
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
    }
}

@MainActor
@Suite("Touch ID on the Mac", .serialized)
struct MacTouchIDTests {
    @Test func theBiometricKeyIsTheUnlockKeyAndAChangedFingerprintTurnsItOff() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        mac.biometrics.biometry = .touchID // a Mac with a sensor, or a Magic Keyboard with Touch ID
        var (app, _) = try await mac.launchEnrolled(seed)
        #expect(app.biometricOffer)
        app.answerBiometricOffer(enable: true)
        let stored = try #require(mac.biometrics.stored)
        #expect(stored.count == 32, "only the 32-byte unlock key, never the password")
        #expect(stored.range(of: Data(testPassword.utf8)) == nil)
        let unlockKey = try await #require(app.client).unlockKey(password: testPassword)
        #expect(stored == unlockKey)

        await app.lock()
        try await app.unlockWithBiometrics()
        #expect(app.phase == .unlocked)
        #expect(mac.biometrics.reasons.last == "unlock your notes")

        // A fingerprint added on this Mac: the system drops the item; the password is asked again.
        await app.lock()
        await app.client?.close()
        mac.biometrics.changeEnrolledFingerprints()
        app = await mac.launch()
        #expect(!app.biometricUnlockEnabled)
        #expect(app.biometricNotice?.contains("changed") == true)
        try await app.unlock(password: testPassword)
        #expect(app.biometricOffer, "offered again after the password")
        app.answerBiometricOffer(enable: false)
        await app.lock()
    }

    @Test(.enabled(if: teamSigned, noTeamReason))
    func theRealStoreOnThisMac() {
        // The data-protection Keychain is there now, so the real store is the one the Mac app
        // uses; on a Mac without a sensor it reports none and stores nothing.
        let store = KeychainBiometricStore(service: "TwoNote-tests-\(UUID().uuidString)")
        defer { store.remove() }
        if store.biometry == .none {
            #expect(!store.hasKey())
            #expect(throws: (any Error).self) { try store.save(Data(repeating: 1, count: 32)) }
            #expect(!store.hasKey())
        } else {
            // A Mac with Touch ID: the item can be stored without a prompt and is there.
            #expect(throws: Never.self) { try store.save(Data(repeating: 1, count: 32)) }
            #expect(store.hasKey())
        }
    }
}

@MainActor
@Suite("Share to TwoNote on the Mac", .serialized)
struct MacShareTests {
    @Test func whatIsSharedWhileLockedBecomesAPageAfterTheUnlockAndSyncs() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)

        // The extension before TwoNote was ever unlocked here: the plain message.
        let early = ShareModel(container: mac.shared)
        early.load(ShareInput(texts: ["x"]))
        #expect(early.state == .notSetUp)

        var (app, library) = try await mac.launchEnrolled(seed)
        #expect(mac.inbox.publicKey != nil)
        await app.lock()

        // The extension's model, as the Share menu of Safari hands it a page.
        let sheet = ShareModel(container: mac.shared)
        sheet.load(ShareInput(contentText: "Bitterns of the marsh", urls: ["https://example.org/birds/bittern"]))
        guard case .ready(let draft) = sheet.state else { Issue.record("no draft: \(sheet.state)"); return }
        #expect(sheet.title == "Bitterns of the marsh")
        #expect(draft.url == "https://example.org/birds/bittern")
        sheet.title = "Bittern article"
        #expect(sheet.save())
        #expect(mac.inbox.waitingItems().count == 1)
        for secret in ["Bittern", "example.org", "marsh"] {
            #expect(!contains(secret, in: mac.shared.root), "“\(secret)” is readable in the App Group container")
        }
        await app.importSharedItems()
        #expect(app.waitingSharedItems == 1, "counted while locked, not opened")

        await app.client?.close()
        app = await mac.launch()
        try await app.unlock(password: testPassword)
        library = try #require(app.library)
        #expect(app.waitingSharedItems == 0 && mac.inbox.waitingItems().isEmpty)
        #expect(library.notice?.text == "1 Shared Item Added")
        let notebook = try #require(library.notebook(seed.notebookId))
        let inbox = try #require(notebook.sections.first { $0.title == "Inbox" })
        #expect(notebook.pages(in: inbox.id).map(\.title) == ["Bittern article"])
        #expect(library.notice?.sectionId == inbox.id)
        let id = try #require(notebook.pages(in: inbox.id).first?.id)
        let page = try await library.open(PageRef(notebookId: seed.notebookId, pageId: id)).page
        #expect(page.runs.first == TextRun(text: "https://example.org/birds/bittern", attributes: [PageAttribute.link: .string("https://example.org/birds/bittern")]))
        try await eventually("the other device has the shared page") {
            try await seed.a.syncNow()
            return seed.tree.page(id)?.title == "Bittern article"
        }
        await app.lock()
    }

    @Test func whatTheMacsShareMenuHandsOverIsReadAsTextAndLinksOnly() async throws {
        let page = NSExtensionItem()
        page.attributedContentText = NSAttributedString(string: "Marsh Birds Weekly")
        page.attachments = [NSItemProvider(object: NSURL(string: "https://example.org/weekly")!)]
        let selection = NSExtensionItem()
        selection.attachments = [NSItemProvider(object: "Booming call at dawn." as NSString)]
        let file = NSExtensionItem()
        file.attachments = [NSItemProvider(contentsOf: URL(fileURLWithPath: "/etc/hosts"))!]

        let input = await ShareInput.read([page, selection, file])
        #expect(input.contentText == "Marsh Birds Weekly")
        #expect(input.urls == ["https://example.org/weekly"])
        #expect(input.texts == ["Booming call at dawn."])
        let draft = ShareDraft(input)
        #expect(draft.suggestedTitle == "Marsh Birds Weekly" && draft.url == "https://example.org/weekly")
    }

    @Test func theSheetAndTheSettingsRowsSayWhatTheyShould() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let (app, library) = try await mac.launchEnrolled(seed)

        let model = ShareModel(container: mac.shared)
        model.load(ShareInput(texts: ["Booming call at dawn near the reedbed."], urls: ["https://example.org/calls"]))
        let stage = Stage(width: MacShareView.width, height: 480)
        defer { stage.close() }
        stage.show(MacShareView(model: model, onCancel: {}, onSaved: {}))
        var seen = ""
        try await eventually("the sheet is drawn (read: \(seen))", timeout: .seconds(20)) {
            stage.pump(0.2)
            seen = try stage.recognizedText().joined(separator: " ")
            if seen.contains("Save to TwoNote") && seen.contains("Booming call") && seen.contains("Cancel") { return true }
            print("[sheet] \(seen)")
            return false
        }

        // Settings > Sharing: the destination, then what is waiting once something is.
        stage.show(SharingSettings(library: library).environment(app).frame(width: 520))
        try await eventually("the sharing settings are drawn", timeout: .seconds(20)) {
            stage.pump(0.2)
            let words = try stage.recognizedText().joined(separator: " ")
            return words.contains("Shared Items Go To") && words.contains("Show Recent Pages in Widget") && !words.contains("Waiting")
        }
        // The picker's values: a section, and back to the default.
        let destination = SharingSettings.destination(library)
        #expect(destination.wrappedValue == "")
        destination.wrappedValue = SharingSettings.tag(seed.notebookId, seed.sectionId)
        #expect(library.chosenShareDestination?.sectionId == seed.sectionId)
        #expect(library.shareDestinationSummary == "Kestrel field journal › Marsh observations")
        #expect(destination.wrappedValue == SharingSettings.tag(seed.notebookId, seed.sectionId))
        destination.wrappedValue = ""
        #expect(library.chosenShareDestination == nil)

        await app.lock()
        try mac.inbox.add(SharedItem(title: "Later", text: "x", url: nil))
        app.refreshWaitingSharedItems()
        #expect(app.waitingSharedItems == 1)
        try await app.unlock(password: testPassword)
        #expect(app.waitingSharedItems == 0, "added at the unlock")
        await app.lock()
    }
}

@MainActor
@Suite("links on the Mac", .serialized)
struct MacLinkTests {
    @Test func theAppleEventOfOpenTwonoteNewIsReadExactly() {
        func event(_ text: String) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyDirectObject))
            return event
        }
        #expect(AppDelegate.url(in: event("twonote://new")).flatMap(DeepLink.init(url:)) == .newNote)
        #expect(AppDelegate.url(in: event("twonote://search")).flatMap(DeepLink.init(url:)) == .search)
        #expect(AppDelegate.url(in: event("twonote://new?text=x")).flatMap(DeepLink.init(url:)) == nil)
        #expect(AppDelegate.url(in: event("https://example.org")).flatMap(DeepLink.init(url:)) == nil)
        let other = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(AppDelegate.url(in: other) == nil)
        // The app's Info.plist claims the scheme.
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        #expect(types?.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("twonote") == true } == true)
    }

    @Test func newNoteWhileLockedMakesThePageAfterTheUnlockWithTheTitleReady() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        var (app, library) = try await mac.launchEnrolled(seed)
        library.setPath([.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        let ref = PageRef(notebookId: seed.notebookId, pageId: seed.pageId)
        _ = try await library.open(ref)
        await app.lock()

        await app.open(.newNote)
        #expect(app.pendingLink == .newNote && app.library == nil)
        try await app.unlock(password: testPassword)
        library = try #require(app.library)
        #expect(app.pendingLink == nil)
        let pages = try #require(library.notebook(seed.notebookId)).pages(in: seed.sectionId)
        #expect(pages.count == 2)
        let new = try #require(pages.first { $0.id != seed.pageId })
        try await eventually("the new page is open") { library.editor?.ref.pageId == new.id }
        let stage = Stage()
        defer { stage.close() }
        stage.show(try #require(library.editor).host)
        try await eventually("the title of the new page has the keyboard") {
            stage.pump(0.05)
            return library.editor?.host.titleField.currentEditor() != nil
        }

        // Search while unlocked on the Mac's three columns: the open page stays open.
        await app.open(.search)
        #expect(library.wantsSearchFocus)
        #expect(library.selectedPage?.pageId == new.id, "the page stays beside the list")
        await app.lock()
    }
}

@MainActor
@Suite("the widget on the Mac", .serialized)
struct MacWidgetTests {
    @Test func titlesOnlyWhileTheSwitchIsOnAndGoneOnSignOut() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let (app, library) = try await mac.launchEnrolled(seed)
        #expect(!app.showsRecentPagesInWidget, "off unless switched on")
        app.publishRecentPages()
        #expect(RecentPages.load(from: mac.shared) == nil)
        #expect(!contains("Tuesday", in: mac.shared.root))

        app.setShowsRecentPagesInWidget(true)
        #expect(RecentPages.load(from: mac.shared)?.pages.map(\.title) == ["Tuesday at the hide"])
        #expect(mac.widgetReloads == 1)
        #expect(!contains("Bittern", in: mac.shared.root) && !contains("Kestrel", in: mac.shared.root), "titles only")
        library.renamePage(PageRef(notebookId: seed.notebookId, pageId: seed.pageId), title: "Renamed on the Mac")
        try await eventually("the titles follow") { RecentPages.load(from: mac.shared)?.pages.first?.title == "Renamed on the Mac" }

        app.setShowsRecentPagesInWidget(false)
        #expect(!FileManager.default.fileExists(atPath: mac.shared.recentPagesURL.path))
        app.setShowsRecentPagesInWidget(true)
        #expect(RecentPages.load(from: mac.shared) != nil)
        await app.removeAccount()
        #expect(!FileManager.default.fileExists(atPath: mac.shared.recentPagesURL.path))
        #expect(!app.showsRecentPagesInWidget)
    }

    @Test func theWidgetShowsButtonsUntilThereAreTitles() async throws {
        let stage = Stage(width: 364, height: 170)
        defer { stage.close() }
        func words(_ view: some View) async throws -> String {
            stage.show(view.padding(16).frame(width: 364, height: 170))
            var text = ""
            try await eventually("the widget is drawn", timeout: .seconds(20)) {
                stage.pump(0.2)
                text = try stage.recognizedText().joined(separator: " ")
                if text.contains("Search") || text.contains("Recent") { return true }
                print("[widget] \(text)")
                return false
            }
            return text
        }
        let small = try await words(TwoNoteWidgetView(recent: nil, size: .systemSmall))
        #expect(small.contains("New Note") && small.contains("Search") && !small.contains("Continue"))
        let medium = try await words(TwoNoteWidgetView(recent: nil, size: .systemMedium))
        #expect(medium.contains("New Note") && medium.contains("Search") && medium.contains("Continue"))
        let titles = RecentPages(pages: [.init(notebookId: "n", pageId: "p", title: "Marsh Birds Weekly")])
        let recent = try await words(TwoNoteWidgetView(recent: titles, size: .systemMedium))
        #expect(recent.contains("Recent Pages") && recent.contains("Marsh Birds Weekly"))
        // An empty list (the switch on, nothing edited yet) shows the buttons.
        let empty = try await words(TwoNoteWidgetView(recent: RecentPages(pages: []), size: .systemMedium))
        #expect(empty.contains("Continue"))
    }
}

/// Every file under a folder with its content, for looking for things that must not be there.
private func contains(_ text: String, in folder: URL) -> Bool {
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
    for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        if let data = try? Data(contentsOf: file), data.range(of: Data(text.utf8)) != nil { return true }
    }
    return false
}

extension Installation {
    var inbox: ShareInbox { ShareInbox(container: shared) }
}
