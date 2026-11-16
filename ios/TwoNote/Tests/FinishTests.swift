import Foundation
import Testing
import TwoNoteDocuments
import UIKit
import YrsKit
@testable import TwoNote
@testable import TwoNoteCore

// Biometric unlock, auto-lock, search, settings and the format bar, against the in-memory
// protocol server.

@MainActor
@Suite("security and search logic")
struct FinishLogicTests {
    @Test func autoLockDelaysDecideWhenToLock() {
        #expect(AutoLockDelay.standard == .fiveMinutes)
        #expect(AutoLockDelay.allCases.map(\.title) == ["Immediately", "After 1 Minute", "After 5 Minutes", "After 15 Minutes", "Never"])
        #expect(AutoLockDelay.immediately.shouldLock(after: .zero))
        #expect(!AutoLockDelay.oneMinute.shouldLock(after: .seconds(59)))
        #expect(AutoLockDelay.oneMinute.shouldLock(after: .seconds(60)))
        #expect(!AutoLockDelay.fiveMinutes.shouldLock(after: .seconds(299)))
        #expect(AutoLockDelay.fiveMinutes.shouldLock(after: .seconds(301)))
        #expect(!AutoLockDelay.fifteenMinutes.shouldLock(after: .seconds(14 * 60)))
        #expect(AutoLockDelay.fifteenMinutes.shouldLock(after: .seconds(15 * 60)))
        #expect(!AutoLockDelay.never.shouldLock(after: .seconds(1_000_000)))
    }

    private func corpus() -> SearchCorpus {
        func entry(_ target: SearchHit.Target, _ title: String, _ location: String, _ text: String = "") -> SearchCorpus.Entry {
            .init(target: target, title: title, location: location, foldedTitle: SearchCorpus.fold(title), text: text, foldedText: SearchCorpus.fold(text))
        }
        let long = String(repeating: "Reeds and water as far as the eye can see. ", count: 12)
        return SearchCorpus(entries: [
            entry(.notebook("n1"), "Field Journal", ""),
            entry(.section(notebookId: "n1", sectionId: "s1"), "Marsh", "Field Journal"),
            entry(.page(PageRef(notebookId: "n1", pageId: "p1")), "Monday at the hide", "Field Journal › Marsh",
                  "Bittern sighting\nBooming call heard at dawn near the reedbed.\nRefill the thermos\n"),
            entry(.page(PageRef(notebookId: "n1", pageId: "p2")), "Café list", "Field Journal › Marsh",
                  long + "The crème brûlée at the marsh café was excellent.\nSecond line.\n"),
            entry(.page(PageRef(notebookId: "n1", pageId: "p3")), "Empty", "Field Journal › Marsh"),
        ])
    }

    @Test func searchFindsTitlesAndTextIgnoringCaseAndAccents() {
        let corpus = corpus()
        #expect(corpus.search("").isEmpty)
        #expect(corpus.search("   ").isEmpty)
        #expect(corpus.search("zebra").isEmpty)

        // A word that is in a notebook title, a section title and a page's text.
        let marsh = corpus.search("MARSH")
        #expect(marsh.map(\.title) == ["Marsh", "Café list"], "title matches first; the notebook is called Field Journal")
        #expect(marsh[0].location == "Field Journal")

        let journal = corpus.search("journal")
        #expect(journal.map(\.target) == [.notebook("n1")])

        // Text, with the match located in the page and marked in the snippet.
        let booming = corpus.search("booming CALL")
        #expect(booming.map(\.title) == ["Monday at the hide"])
        #expect(booming[0].location == "Field Journal › Marsh")
        #expect(booming[0].textMatch == NSRange(location: 17, length: 12))
        #expect(booming[0].snippet == "Bittern sighting Booming call heard at dawn near the reedbed. Refill the thermos")
        let marked = try! #require(booming[0].snippetMatch)
        #expect((booming[0].snippet as NSString).substring(with: marked) == "Booming call")

        // Accents and case do not matter, in either direction.
        #expect(corpus.search("creme brulee").map(\.title) == ["Café list"])
        #expect(corpus.search("CAFE").map(\.title) == ["Café list"])
        let brulee = corpus.search("brûlée")[0]
        #expect(brulee.snippet.hasPrefix("…"), "text before the match was left out: \(brulee.snippet)")
        #expect(brulee.snippet.contains("crème brûlée at the marsh café"))
        #expect(!brulee.snippet.contains("\n"))
        #expect((brulee.snippet as NSString).substring(with: try! #require(brulee.snippetMatch)) == "brûlée")

        // Every word has to be there, in the title or the text; the order does not matter.
        #expect(corpus.search("thermos monday").map(\.title) == ["Monday at the hide"])
        #expect(corpus.search("thermos tuesday").isEmpty)

        // A title match on a page shows the beginning of its text.
        let monday = corpus.search("hide")[0]
        #expect(monday.snippet.hasPrefix("Bittern sighting"))
        #expect(monday.snippetMatch == nil)
        #expect(corpus.search("empty")[0].snippet == "")
    }

    @Test func changePasswordFormSaysWhatIsMissing() {
        #expect(ChangePasswordView.problem(current: "", new: "", verify: "") == "")
        #expect(ChangePasswordView.problem(current: "old password", new: "short", verify: "")?.contains("at least 8") == true)
        #expect(ChangePasswordView.problem(current: "old password", new: "old password", verify: "old password")?.contains("same") == true)
        #expect(ChangePasswordView.problem(current: "old password", new: "new password", verify: "") == "")
        #expect(ChangePasswordView.problem(current: "old password", new: "new password", verify: "new passwrd")?.contains("match") == true)
        #expect(ChangePasswordView.problem(current: "old password", new: "new password", verify: "new password") == nil)
    }

    @Test func settingsFailuresAreExplained() {
        let unreachable = ServerUnreachableError("The server could not be reached (-1004).")
        let devices = UserMessage.serverActionFailure(unreachable, action: "Showing your devices")
        #expect(devices.title == "Can’t Reach the Server")
        #expect(devices.detail.hasPrefix("Showing your devices needs a connection"))
        #expect(UserMessage.serverActionFailure(ApiError(status: 401, code: "unauthorized", message: ""), action: "x").title == "Sign In Required")
        #expect(UserMessage.biometricsFailure(ClientError.wrongCredentials, .touchID).detail.contains("Touch ID was not turned on"))
        #expect(UserMessage.biometricsFailure(BiometricFailure.unavailable, .faceID).title == "Face ID Isn’t Available")
        #expect(UserMessage.deleteNotebookOffline.title == "Can’t Delete While Offline")
        #expect(BiometryKind.touchID.name == "Touch ID" && BiometryKind.faceID.symbol == "faceid")
    }
}

@MainActor
@Suite("biometric unlock", .serialized)
struct BiometricUnlockTests {
    @Test func offerAfterThePasswordThenTheSensorUnlocksAndThePasswordStillDoes() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        phone.biometrics.biometry = .touchID
        var (app, _) = try await phone.launchEnrolled(seed)

        // Setting up typed the password: the offer is up, nothing is stored before the answer.
        #expect(app.biometry == .touchID)
        #expect(app.biometricOffer)
        #expect(!app.biometricUnlockEnabled)
        #expect(phone.biometrics.stored == nil)
        app.answerBiometricOffer(enable: true)
        #expect(app.biometricUnlockEnabled && !app.biometricOffer)

        // What the Keychain item holds: the 32-byte unlock key - not the password, not the Secret Key.
        let stored = try #require(phone.biometrics.stored)
        #expect(stored.count == 32)
        #expect(stored != Data(testPassword.utf8))
        #expect(!String(decoding: stored, as: UTF8.self).contains(testPassword))
        #expect(stored == (try await app.client!.unlockKey(password: testPassword)))

        // Relaunch: locked; a match unlocks without the password.
        await app.client?.close()
        app = await phone.launch()
        #expect(app.phase == .locked && app.biometricUnlockEnabled)
        try await app.unlockWithBiometrics()
        #expect(app.phase == .unlocked)
        #expect(app.library?.notebook(seed.notebookId) != nil)
        #expect(!app.biometricOffer, "already answered")
        #expect(phone.biometrics.prompts == 1)

        // A finger that is not recognised: still locked, still enabled, and the password works.
        await app.lock()
        phone.biometrics.outcome = .failed
        await #expect(throws: UnlockFailure.biometry(.failed)) { try await app.unlockWithBiometrics() }
        phone.biometrics.outcome = .fallback
        await #expect(throws: UnlockFailure.biometry(.fallback)) { try await app.unlockWithBiometrics() }
        #expect(app.phase == .locked && app.biometricUnlockEnabled && app.library == nil)
        try await app.unlock(password: testPassword)
        #expect(app.phase == .unlocked)
        #expect(!app.biometricOffer)
        await app.client?.close()
    }

    @Test func decliningIsRememberedAndSettingsCanTurnItOnAndOff() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        phone.biometrics.biometry = .faceID
        var (app, _) = try await phone.launchEnrolled(seed)
        #expect(app.biometricOffer)
        app.answerBiometricOffer(enable: false)
        #expect(!app.biometricUnlockEnabled && phone.biometrics.stored == nil)

        await app.client?.close()
        app = await phone.launch()
        try await app.unlock(password: testPassword)
        #expect(!app.biometricOffer, "asked once only")
        try await app.unlockWithBiometrics() // not enabled: does nothing
        #expect(phone.biometrics.prompts == 0)

        // The switch in Settings needs the password.
        do {
            try await app.setBiometricUnlock(true, password: "not the password")
            Issue.record("a wrong password turned biometric unlock on")
        } catch let message as UserMessage {
            #expect(message.title == "Incorrect Password")
        }
        #expect(!app.biometricUnlockEnabled && phone.biometrics.stored == nil)
        try await app.setBiometricUnlock(true, password: testPassword)
        #expect(app.biometricUnlockEnabled && phone.biometrics.stored?.count == 32)

        try await app.setBiometricUnlock(false)
        #expect(!app.biometricUnlockEnabled && phone.biometrics.stored == nil, "turning it off removes the key")

        // No sensor: nothing to offer, nothing to turn on.
        phone.biometrics.biometry = .none
        await app.lock()
        try await app.unlock(password: testPassword)
        #expect(app.biometry == .none && !app.biometricOffer)
        do {
            try await app.setBiometricUnlock(true, password: testPassword)
            Issue.record("biometric unlock was turned on without a sensor")
        } catch let message as UserMessage {
            #expect(message.title.contains("Isn’t Available"))
        }
        await app.client?.close()
    }

    @Test func changedFingerprintsInvalidateTheKeyAndThePasswordIsAskedAgain() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        phone.biometrics.biometry = .touchID
        var (app, _) = try await phone.launchEnrolled(seed)
        app.answerBiometricOffer(enable: true)
        await app.lock()

        // While the app is running.
        phone.biometrics.changeEnrolledFingerprints()
        await #expect(throws: UnlockFailure.biometry(.invalidated)) { try await app.unlockWithBiometrics() }
        #expect(app.phase == .locked && !app.biometricUnlockEnabled)
        #expect(app.biometricNotice?.contains("changed") == true)
        try await app.unlock(password: testPassword)
        #expect(app.biometricNotice == nil)
        #expect(app.biometricOffer, "it is offered again, with the new fingerprints")
        app.answerBiometricOffer(enable: true)
        #expect(app.biometricUnlockEnabled)

        // While the app was not running: noticed at launch, without a prompt.
        await app.client?.close()
        phone.biometrics.changeEnrolledFingerprints()
        app = await phone.launch()
        #expect(app.phase == .locked && !app.biometricUnlockEnabled)
        #expect(app.biometricNotice != nil)
        #expect(phone.biometrics.prompts == 1)
        await app.client?.close()
    }

    @Test func aPasswordChangeRenewsTheKeyAndTheOtherDeviceSignsInAgain() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        phone.biometrics.biometry = .touchID
        var (app, library) = try await phone.launchEnrolled(seed)
        app.answerBiometricOffer(enable: true)
        let oldKey = try #require(phone.biometrics.stored)
        let newPassword = "four new unrelated words"

        do {
            try await app.changePassword(current: "wrong", new: newPassword)
            Issue.record("a wrong current password was accepted")
        } catch let message as UserMessage {
            #expect(message.title == "Incorrect Password")
        }
        phone.transport.offline = true
        do {
            try await app.changePassword(current: testPassword, new: newPassword)
            Issue.record("the password was changed without the server")
        } catch let message as UserMessage {
            #expect(message.title == "Can’t Reach the Server")
        }
        phone.transport.offline = false
        #expect(phone.biometrics.stored == oldKey)

        try await app.changePassword(current: testPassword, new: newPassword)
        let newKey = try #require(phone.biometrics.stored)
        #expect(newKey != oldKey, "the unlock key belongs to the password")
        #expect(app.biometricUnlockEnabled)

        // Still syncing with the token it has; an edit goes out.
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        editor.page.append(" - after the change")

        // The other device was signed out by the change; with the new password it syncs again
        // and receives what this device wrote after the change.
        _ = try? await seed.a.syncNow()
        #expect(seed.a.client.sync.status.state == .authRequired)
        try await seed.a.client.signInAgain(password: newPassword)
        try await eventually("the other device receives the edit") {
            try await seed.a.syncNow()
            return seed.page.text.contains("after the change")
        }

        // Relaunch: the sensor unlocks with the renewed key; the old password is refused, the new one works.
        await app.client?.close()
        app = await phone.launch()
        try await app.unlockWithBiometrics()
        #expect(app.phase == .unlocked)
        await app.lock()
        await #expect(throws: UnlockFailure.wrongPassword) { try await app.unlock(password: testPassword) }
        try await app.unlock(password: newPassword)
        #expect(app.phase == .unlocked)
        await app.client?.close()
    }

    @Test func aKeyFromBeforeAPasswordChangeElsewhereIsDroppedAndThePasswordAsked() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        phone.biometrics.biometry = .touchID
        let (app, _) = try await phone.launchEnrolled(seed)
        app.answerBiometricOffer(enable: true)

        // The other device changes the password; this one is told to sign in again and does.
        let newPassword = "four new unrelated words"
        try await seed.a.client.changePassword(currentPassword: testPassword, newPassword: newPassword)
        app.client?.sync.requestSync()
        try await eventually("this device is asked to sign in again") { SyncSummary(app.client!.syncMonitor.status).kind == .needsSignIn }
        let staleKey = try #require(phone.biometrics.stored)
        try await app.signInAgain(password: newPassword)
        #expect(app.biometricUnlockEnabled)
        #expect(phone.biometrics.stored != staleKey, "signing in again stores the key of the new password")
        await app.lock()
        try await app.unlockWithBiometrics()
        #expect(app.phase == .unlocked)

        // A stale key (as if the renewal had not happened) is refused by the store and removed.
        await app.lock()
        try phone.biometrics.save(staleKey)
        await #expect(throws: UnlockFailure.biometry(.invalidated)) { try await app.unlockWithBiometrics() }
        #expect(!app.biometricUnlockEnabled && phone.biometrics.stored == nil)
        #expect(app.biometricNotice?.contains("password has changed") == true)
        try await app.unlock(password: newPassword)
        await app.client?.close()
    }
}

@MainActor
@Suite("auto-lock", .serialized)
struct AutoLockTests {
    @Test func theAppLocksAfterTheChosenTimeInTheBackground() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        var (app, _) = try await phone.launchEnrolled(seed)
        #expect(app.autoLock == .fiveMinutes, "the default")

        // Four minutes away: still unlocked.
        await app.didEnterBackground(waitForSync: .milliseconds(200))
        #expect(app.phase == .unlocked)
        phone.clockOffset += .seconds(4 * 60)
        await app.willEnterForeground()
        await app.didBecomeActive()
        #expect(app.phase == .unlocked)

        // The time in front does not count: six more minutes there, then one minute away.
        phone.clockOffset += .seconds(6 * 60)
        await app.didEnterBackground(waitForSync: .milliseconds(200))
        phone.clockOffset += .seconds(60)
        await app.didBecomeActive()
        #expect(app.phase == .unlocked)

        // Six minutes away: locked before anything is shown.
        await app.didEnterBackground(waitForSync: .milliseconds(200))
        phone.clockOffset += .seconds(6 * 60)
        await app.willEnterForeground()
        #expect(app.phase == .locked && app.library == nil)
        await app.didBecomeActive()
        #expect(app.phase == .locked)
        try await app.unlock(password: testPassword)

        // Never.
        app.autoLock = .never
        await app.didEnterBackground(waitForSync: .milliseconds(200))
        phone.clockOffset += .seconds(48 * 3600)
        await app.didBecomeActive()
        #expect(app.phase == .unlocked)

        // Immediately: locked as soon as the app is in the background, edits saved first.
        app.autoLock = .immediately
        let library = try #require(app.library)
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        editor.page.append(" - typed just before leaving")
        await app.didEnterBackground(waitForSync: .seconds(5))
        #expect(app.phase == .locked && app.library == nil)
        try await seed.a.syncNow()
        #expect(seed.page.text.contains("typed just before leaving"))

        // The choice is kept across launches.
        await app.client?.close()
        app = await phone.launch()
        #expect(app.autoLock == .immediately)
        try await app.unlock(password: testPassword)
        app.autoLock = .fifteenMinutes
        await app.didEnterBackground(waitForSync: .milliseconds(200))
        phone.clockOffset += .seconds(14 * 60)
        await app.didBecomeActive()
        #expect(app.phase == .unlocked)
        await app.didEnterBackground(waitForSync: .milliseconds(200))
        phone.clockOffset += .seconds(16 * 60)
        await app.didBecomeActive()
        #expect(app.phase == .locked)
        await app.client?.close()
    }
}

@MainActor
@Suite("settings", .serialized)
struct SettingsTests {
    @Test func devicesAreListedAndRevokedAndSigningOutRemovesThisDevice() async throws {
        let seed = try await Seed.make()
        let laptop = try await seed.enrol("Laptop")
        let phone = Installation(seed.server)
        phone.biometrics.biometry = .touchID
        let (app, _) = try await phone.launchEnrolled(seed)
        app.answerBiometricOffer(enable: true)
        app.autoLock = .oneMinute

        var devices = try await app.devices()
        #expect(devices.count == 3)
        #expect(devices[0].current && devices[0].name == "Phone", "this device first")
        #expect(Set(devices.dropFirst().map(\.name)) == ["Device A", "Device Laptop"])

        // Revoke the laptop: it is off the list and can no longer sync.
        let target = try #require(devices.first { $0.name == "Device Laptop" })
        try await app.revokeDevice(target.deviceId)
        devices = try await app.devices()
        #expect(devices.map(\.name).sorted() == ["Device A", "Phone"])
        _ = try? await laptop.syncNow()
        #expect(laptop.client.sync.status.state == .authRequired)

        // Offline: explained, nothing changes.
        phone.transport.offline = true
        do {
            _ = try await app.devices()
            Issue.record("the device list loaded without the server")
        } catch let message as UserMessage {
            #expect(message.title == "Can’t Reach the Server")
        }
        phone.transport.offline = false

        // Sign out: this device leaves the account's list, and nothing of the account is left here.
        await app.removeAccount()
        #expect(app.phase == .setUp && app.client == nil)
        #expect(try await seed.a.client.devices().map(\.name) == ["Device A"])
        #expect(phone.secrets.get(SecretNames.secretKey) == nil && phone.secrets.get(SecretNames.sessionToken) == nil)
        #expect(phone.biometrics.stored == nil, "the biometric key goes too")
        #expect(!app.biometricUnlockEnabled && app.autoLock == .fiveMinutes)
        #expect(!FileManager.default.fileExists(atPath: phone.databasePath))
        let relaunched = await phone.launch()
        #expect(relaunched.phase == .setUp && relaunched.autoLock == .fiveMinutes && !relaunched.biometricUnlockEnabled)

        await laptop.client.close()
    }

    @Test func signingOutWithoutTheServerStillRemovesEverythingHere() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, _) = try await phone.launchEnrolled(seed)
        phone.transport.offline = true
        await app.removeAccount()
        #expect(app.phase == .setUp)
        #expect(phone.secrets.get(SecretNames.secretKey) == nil)
        phone.transport.offline = false
        #expect(try await seed.a.client.devices().count == 2, "the server never heard of it; the device can be revoked from another one")
    }

    @Test func theSecretKeyIsShownOnlyAfterThePasswordOrTheSensor() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        phone.biometrics.biometry = .touchID
        let (app, _) = try await phone.launchEnrolled(seed)
        app.answerBiometricOffer(enable: false)

        do {
            _ = try await app.secretKey(password: "guess")
            Issue.record("the Secret Key was shown for a wrong password")
        } catch let message as UserMessage {
            #expect(message.title == "Incorrect Password")
        }
        #expect(try await app.secretKey(password: testPassword) == seed.secretKey)

        // The sensor is only accepted while it also unlocks the app.
        await #expect(throws: BiometricFailure.unavailable) { _ = try await app.secretKeyAfterBiometricCheck() }
        #expect(phone.biometrics.prompts == 0)
        try await app.setBiometricUnlock(true, password: testPassword)
        phone.biometrics.outcome = .failed
        await #expect(throws: BiometricFailure.failed) { _ = try await app.secretKeyAfterBiometricCheck() }
        phone.biometrics.outcome = nil
        #expect(try await app.secretKeyAfterBiometricCheck() == seed.secretKey)

        // Not while locked.
        await app.lock()
        await #expect(throws: (any Error).self) { _ = try await app.secretKey(password: testPassword) }
        await app.client?.close()
    }

    @Test func aNotebookOnTheServerCannotBeDeletedOfflineAndTheAppSaysSoFirst() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        try await eventually("synced") { SyncSummary(app.client!.syncMonitor.status).kind == .synced }
        #expect(await library.deleteNotebookObstacle(seed.notebookId) == nil, "online: go ahead and ask")

        phone.transport.offline = true
        app.client?.sync.requestSync()
        try await eventually("offline") { SyncSummary(app.client!.syncMonitor.status).kind == .offline }
        #expect(await library.deleteNotebookObstacle(seed.notebookId) == .deleteNotebookOffline)

        // A notebook made here that the server has never seen can go at once.
        await library.createNotebook(title: "Scratch")
        let scratch = try #require(library.notebooks.first { $0.title == "Scratch" })
        #expect(await library.deleteNotebookObstacle(scratch.id) == nil)
        await library.deleteNotebook(scratch.id)
        #expect(library.alert == nil && library.notebook(scratch.id) == nil)
        await app.client?.close()
    }

    @Test func theStatusCountsPagesNotKeystrokes() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        try await eventually("synced") { SyncSummary(app.client!.syncMonitor.status).kind == .synced }
        phone.transport.offline = true

        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        for word in ["one ", "two ", "three ", "four ", "five "] {
            editor.page.append(word)
        }
        await app.client?.flushPendingEdits()
        try await eventually("the edits are counted") { app.client!.syncMonitor.status.pendingUpdates >= 5 }
        var summary = SyncSummary(app.client!.syncMonitor.status)
        #expect(summary.pendingPages == 1 && summary.pendingNotebooks == 0)
        #expect(summary.waiting == "1 Page")

        library.renamePage(editor.ref, title: "Renamed offline")
        await app.client?.flushPendingEdits()
        try await eventually("the rename is counted") { app.client!.syncMonitor.status.pendingNotebooks == 1 }
        summary = SyncSummary(app.client!.syncMonitor.status)
        #expect(summary.waiting == "1 Page and Notebook Changes")
        try await eventually("offline is shown") { SyncSummary(app.client!.syncMonitor.status).title == "Offline · Changes Waiting" }

        phone.transport.offline = false
        app.client?.sync.requestSync()
        try await eventually("sent") { SyncSummary(app.client!.syncMonitor.status).kind == .synced }
        #expect(SyncSummary(app.client!.syncMonitor.status).waiting == nil)
        await app.client?.close()
    }
}

@MainActor
@Suite("search", .serialized)
struct SearchTests {
    @Test func textTypedHereAndElsewhereIsFoundAndOpeningAResultShowsThePage() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let search = library.search
        search.debounce = .zero
        let pageRef = PageRef(notebookId: seed.notebookId, pageId: seed.pageId)

        // The page written by the other device before this one existed.
        try await eventually("the seeded page is indexed") {
            await search.refresh()
            search.query = "bittern"
            await search.settle()
            return search.hits.count == 1
        }
        #expect(search.isActive)
        #expect(search.hits[0].target == .page(pageRef))
        #expect(search.hits[0].title == "Tuesday at the hide")
        #expect(search.hits[0].location == "Kestrel field journal › Marsh observations")
        #expect(search.hits[0].snippet == "Bittern sighting")
        #expect(search.hits[0].textMatch == NSRange(location: 0, length: 7))

        // Titles: the notebook and the section.
        search.query = "kestrel"
        await search.settle()
        #expect(search.hits.map(\.target) == [.notebook(seed.notebookId)])
        search.query = "observ"
        await search.settle()
        #expect(search.hits.map(\.target) == [.section(notebookId: seed.notebookId, sectionId: seed.sectionId)])

        // Typed here, a moment ago, in a new page.
        await library.addPage(notebookId: seed.notebookId, sectionId: seed.sectionId)
        let newRef = try #require(library.selectedPage)
        try await eventually("the new page opens") { library.editor?.ref == newRef }
        library.renamePage(newRef, title: "Shopping")
        library.editor?.page.append("Oat milk and marmalade")
        await app.client?.flushPendingEdits()
        await search.refresh()
        search.query = "MARMALADE"
        await search.settle()
        #expect(search.hits.map(\.title) == ["Shopping"])

        // Typed on the other device while the results are up.
        seed.page.append("\nGreat crested grebe on the lagoon")
        try await seed.a.syncNow()
        search.query = "grebe"
        try await eventually("the other device's text is found") {
            await search.refresh()
            await search.settle()
            return search.hits.count == 1
        }
        let hit = search.hits[0]
        #expect(hit.target == .page(pageRef))
        #expect(hit.snippet.contains("Great crested grebe"))

        // Opening the result: the section's list, the page, the search over.
        library.setPath([])
        library.open(hit)
        #expect(search.query.isEmpty && !search.isActive)
        #expect(library.path == [.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        #expect(library.selectedPage == pageRef)
        try await eventually("the page opens") { library.editor?.ref == pageRef }

        // A deleted page is not found any more.
        library.deletePage(newRef)
        await search.refresh()
        search.query = "marmalade"
        await search.settle()
        #expect(search.hits.isEmpty)

        // Locking forgets every text.
        #expect(search.indexedPages == 1)
        await app.lock()
        #expect(search.indexedPages == 0 && search.hits.isEmpty && search.query.isEmpty)
        await app.client?.close()
    }

    @Test func aResultScrollsThePageToTheMatch() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let lines = (1...400).map { $0 == 300 ? "The needle is on this line" : "Line \($0) of a long page" }
        seed.page.append("\n" + lines.joined(separator: "\n"))
        try await seed.a.syncNow()
        let search = library.search
        search.debounce = .zero
        search.query = "needle"
        try await eventually("the long page is indexed") {
            await search.refresh()
            await search.settle()
            return search.hits.count == 1
        }
        let hit = search.hits[0]
        let match = try #require(hit.textMatch)

        let stage = try Stage()
        defer { stage.close() }
        library.open(hit)
        try await eventually("the page opens") { library.editor != nil }
        let editor = try #require(library.editor)
        stage.show(editor.host)
        let textView = editor.textView
        #expect((textView.text as NSString).substring(with: match) == "needle")
        try await eventually("the match is on screen") {
            guard let position = textView.position(from: textView.beginningOfDocument, offset: match.location) else { return false }
            let rect = textView.caretRect(for: position)
            let top = textView.contentOffset.y + textView.adjustedContentInset.top
            return textView.contentOffset.y > 1000 && rect.minY >= top && rect.maxY <= textView.contentOffset.y + textView.bounds.height
        }
        await app.client?.close()
    }

    @Test func searchStaysQuickWithAFewHundredPages() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        var (app, library) = try await phone.launchEnrolled(seed)
        phone.transport.offline = true // only this device matters here

        // 300 pages of about 1,900 characters each, one of them with a word of its own.
        let words = ["heron", "reedbed", "dawn", "lagoon", "thermos", "notebook", "binoculars", "tide", "ringing", "warbler", "sedge", "hide"]
        let client = try #require(app.client)
        for index in 0..<300 {
            let page = try await client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Entry \(index)")
            // Written in 40 separate edits, the way typing produces a page (one stored update each).
            var n = index
            for _ in 0..<40 {
                var text = ""
                while text.count < 45 {
                    n = (n &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
                    text += words[n % words.count] + (n % 11 == 0 ? ".\n" : " ")
                }
                page.edit { $0.insert(text, at: $0.length - 1, attributes: [:]) }
            }
            if index == 217 { page.edit { $0.insert("the only xylophone in the marsh", at: $0.length - 1, attributes: [:]) } }
            client.closePage(page.docId)
        }
        await client.flushPendingEdits()
        await client.close()

        // A fresh launch: unlock, and time how long the texts take to be readable for search.
        let clock = ContinuousClock()
        app = await phone.launch()
        let unlockStart = clock.now
        try await app.unlock(password: testPassword)
        library = try #require(app.library)
        let unlockTime = clock.now - unlockStart
        let search = library.search
        search.debounce = .zero
        try await eventually("every page is indexed", timeout: .seconds(60)) { search.indexedPages == 301 && !search.indexing }
        let indexTime = clock.now - unlockStart

        // A second pass with nothing changed reads no page again.
        let idleStart = clock.now
        await search.refresh()
        let idleTime = clock.now - idleStart

        // Queries: the corpus is put together on the main actor and searched off it.
        var slowest = Duration.zero
        for query in ["xylophone", "heron dawn", "zzzz", "e", "the only xylophone in the marsh", "Entry 21"] {
            let start = clock.now
            search.query = query
            await search.settle()
            slowest = max(slowest, clock.now - start)
        }
        search.query = "xylophone"
        await search.settle()
        #expect(search.hits.map(\.title) == ["Entry 217"])
        search.query = "Entry 21"
        await search.settle()
        #expect(search.hits.count == 13, "Entry 21, 121, 221 and 210…219, by title")
        search.query = "heron dawn"
        await search.settle()
        #expect(search.hits.count == 200, "capped")

        print("[search] 300 pages: unlock \(unlockTime), all text readable for search after \(indexTime), idle refresh \(idleTime), slowest query \(slowest)")
        #expect(slowest < .milliseconds(250))
        #expect(idleTime < .milliseconds(250))
        await app.client?.close()
    }
}

@MainActor
@Suite("format bar", .serialized)
struct FormatBarTests {
    private func labels(_ bar: FormatBar) -> [String] {
        (bar.toolbar.items ?? []).compactMap(\.accessibilityLabel)
    }

    @Test func everyCommandIsWithinTwoTapsAndWideBarsShowMore() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        let bar = editor.formatBar

        #expect(FormatBar.Layout.forWidth(466) == .narrow, "the Duo's cover display")
        #expect(FormatBar.Layout.forWidth(430) == .narrow)
        #expect(FormatBar.Layout.forWidth(600) == .narrow)
        #expect(FormatBar.Layout.forWidth(669) == .medium, "the Duo unfolded")
        #expect(FormatBar.Layout.forWidth(820) == .wide, "an iPad")

        bar.apply(.narrow)
        #expect(labels(bar) == ["Paragraph Style", "Bold", "Italic", "Lists", "More Formatting", "Hide Keyboard"])

        bar.apply(.medium)
        #expect(labels(bar) == [
            "Paragraph Style", "Bold", "Italic", "Bulleted List", "Numbered List", "Checklist",
            "Decrease Indent", "Increase Indent", "More Formatting", "Hide Keyboard",
        ])

        bar.apply(.wide)
        #expect(labels(bar) == [
            "Paragraph Style", "Bold", "Italic", "Underline", "Bulleted List", "Numbered List", "Checklist",
            "Decrease Indent", "Increase Indent", "Undo", "More Formatting", "Hide Keyboard",
        ])

        // The buttons do what they say, and show the state of the paragraph the cursor is in.
        func item(_ label: String) throws -> UIBarButtonItem {
            try #require(bar.toolbar.items?.first { $0.accessibilityLabel == label })
        }
        func tap(_ label: String) throws {
            let item = try item(label)
            let action = try #require(item.primaryAction)
            action.performWithSender(item, target: nil)
        }
        let stage = try Stage()
        defer { stage.close() }
        stage.show(editor.host)
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 3, length: 0)

        try tap("Bulleted List")
        #expect(editor.page.runs.last?.attributes[PageAttribute.block] == .string("ul"))
        #expect(try item("Bulleted List").isSelected && !(try item("Numbered List").isSelected))
        try tap("Numbered List")
        #expect(editor.page.runs.last?.attributes[PageAttribute.block] == .string("ol"))
        #expect(try item("Numbered List").isSelected && !(try item("Bulleted List").isSelected))
        #expect(!(try item("Decrease Indent").isEnabled))
        try tap("Increase Indent")
        #expect(try item("Decrease Indent").isEnabled)
        try tap("Decrease Indent")
        try tap("Checklist")
        #expect(editor.page.runs.last?.attributes[PageAttribute.block] == .string("todo"))
        editor.page.breakUndoGroup() // quick edits otherwise merge into one undo step
        try tap("Checklist")
        #expect(editor.page.runs.last?.attributes[PageAttribute.block] == nil)
        #expect(try item("Undo").isEnabled)
        try tap("Undo")
        #expect(editor.page.runs.last?.attributes[PageAttribute.block] == .string("todo"))

        editor.textView.selectedRange = NSRange(location: 0, length: 7)
        try tap("Underline")
        #expect(editor.page.runs.first?.attributes[PageAttribute.underline] == .bool(true))
        #expect(try item("Underline").isSelected)
        await app.client?.close()
    }
}
