import Foundation
import Testing
import TwoNoteCrypto
import TwoNoteDocuments
import YrsKit
@testable import TwoNoteCore

// Headless clients against a REAL server container, over real HTTP and WebSockets
// (URLSession, URLSessionWebSocketTask, Argon2 at the default cost).
//
// Skipped unless TWONOTE_E2E_URL is set, e.g. http://127.0.0.1:18081. The container must be
// fresh (no account yet). Optional:
//   TWONOTE_E2E_RESTART   shell command that restarts the container (e.g. "docker restart twonote-ios-e2e")
//   TWONOTE_E2E_STATE     file to write the account details to, for the interop phases
//   TWONOTE_E2E_PHASE     "interop-read": only read back what the Windows client wrote (needs TWONOTE_E2E_STATE)

private let environment = ProcessInfo.processInfo.environment
private let e2eURL = environment["TWONOTE_E2E_URL"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
private let e2ePhase = environment["TWONOTE_E2E_PHASE"] ?? ""

/// The real transport with an "aeroplane mode" switch.
final class SwitchableTransport: HTTPTransport, WebSocketConnector, @unchecked Sendable {
    private let http = URLSessionTransport(timeout: 15)
    private let sockets = URLSessionWebSocketConnector()
    private let flag = Locked(false)

    var offline: Bool {
        get { flag.withLock { $0 } }
        set { flag.withLock { $0 = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if offline {
            throw URLError(.notConnectedToInternet)
        }
        return try await http.send(request)
    }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        if offline {
            throw URLError(.notConnectedToInternet)
        }
        return try await sockets.connect(to: url)
    }
}

struct InteropState: Codable {
    var username: String
    var password: String
    var secretKey: String
    var notebookId: String
    var sectionId: String
    var pageId: String
    var swiftText: String
}

@MainActor
@Suite("real container")
struct ContainerE2ETests {
    private static let username = "bob"
    private static let password = "correct horse battery staple"
    private static let heading = "Bittern sighting"
    private static let body = "Booming call heard at dawn near the reedbed 🦆"
    private static let todo = "Refill the thermos"
    private static let link = "https://example.org/bittern-survey"

    private struct RealDevice {
        var client: TwoNoteClient
        var transport: SwitchableTransport
    }

    private func device(_ url: URL, configure: (inout ClientOptions) -> Void = { _ in }) async throws -> RealDevice {
        let transport = SwitchableTransport()
        var options = ClientOptions(serverURL: url, databasePath: temporaryDatabasePath(), secretStore: InMemorySecretStore())
        options.transport = transport
        options.webSocketConnector = transport
        options.wakeOnNetworkChange = false
        options.initialRetryDelay = .milliseconds(200)
        options.maxRetryDelay = .seconds(1)
        options.maxOfflineRetryDelay = .seconds(1)
        configure(&options)
        return RealDevice(client: try await TwoNoteClient.open(options), transport: transport)
    }

    private func step(_ text: String) {
        print("[e2e] \(text)")
    }

    @Test(.enabled(if: e2eURL != nil && e2ePhase.isEmpty))
    func twoDevicesSyncEndToEndEncryptedThroughARealContainer() async throws {
        let url = try #require(e2eURL)

        step("1. the container is up and fresh")
        let probe = TwoNoteApi(serverURL: url)
        let status = try await probe.status()
        #expect(status.protocolVersion == 1)
        #expect(status.registrationOpen, "the container already has an account; start a fresh one")

        step("2. device A registers, creates notebook/section/page, types formatted text")
        let a = try await device(url)
        let secretKey = try await a.client.register(username: Self.username, password: Self.password, deviceName: "Swift A")
        #expect(try await !probe.status().registrationOpen)
        let treeA = try await a.client.createNotebook(title: "Kestrel field journal")
        let notebookId = treeA.notebookId
        let sectionId = treeA.addSection(title: "Marsh observations")
        let pageA = try await a.client.createPage(notebookId: notebookId, sectionId: sectionId, title: "Tuesday at the hide")
        let pageId = pageA.docId
        pageA.edit { editor in
            editor.insert(Self.heading + "\n" + Self.body + "\n" + Self.todo, at: 0, attributes: [:])
            editor.setBlock(newlineAt: Self.heading.utf16.count, block: "h1", indent: 0, checked: false)
            let bodyStart = Self.heading.utf16.count + 1
            editor.format(at: bodyStart, count: 7, attributes: [PageAttribute.bold: .bool(true)]) // "Booming"
            editor.format(at: bodyStart + 8, count: 4, attributes: [PageAttribute.italic: .bool(true), PageAttribute.link: .string(Self.link)]) // "call"
            editor.setBlock(newlineAt: editor.length - 1, block: "todo", indent: 1, checked: true)
        }
        try await a.client.sync.syncNow()
        #expect(a.client.sync.status.pendingUpdates == 0)
        #expect(a.client.sync.status.state == .idle)

        step("3. device B enrols with the Secret Key and the password, syncs, sees identical content")
        let b = try await device(url)
        try await b.client.enrol(username: Self.username, password: Self.password, secretKey: secretKey, deviceName: "Swift B")
        try await b.client.sync.syncNow()
        #expect(b.client.notebookIds == [notebookId])
        let treeB = try await b.client.openNotebook(notebookId)
        #expect(treeB.title == "Kestrel field journal")
        #expect(treeB.sections() == treeA.sections())
        #expect(treeB.allPages() == treeA.allPages())
        let pageB = try await b.client.openPage(notebookId: notebookId, pageId: pageId)
        #expect(pageB.text == Self.heading + "\n" + Self.body + "\n" + Self.todo + "\n")
        #expect(pageB.runs == pageA.runs)
        #expect(pageB.runs.contains { $0.text == "call" && $0.attributes[PageAttribute.link] == .string(Self.link) })
        #expect(pageB.runs.last?.attributes == [PageAttribute.block: .string("todo"), PageAttribute.indent: .number(1), PageAttribute.checked: .bool(true)])
        let devices = try await b.client.devices()
        #expect(devices.map(\.name).sorted() == ["Swift A", "Swift B"])
        #expect(devices.first { $0.current }?.deviceId == b.client.account?.deviceId)

        step("4. both devices edit offline; the edits converge")
        a.transport.offline = true
        b.transport.offline = true
        pageA.edit { $0.insert("Wrote this on the train (device A). ", at: 0, attributes: [:]) }
        treeA.addSection(title: "Owl pellets")
        pageB.edit { $0.insert(" Scribbled in the cellar (device B)", at: $0.length - 1, attributes: [:]) }
        treeB.renamePage(pageId, title: "Tuesday, renamed by B")
        await #expect(throws: ServerUnreachableError.self) { try await a.client.sync.syncNow() }
        #expect(a.client.sync.status.state == .offline)
        a.transport.offline = false
        b.transport.offline = false
        try await a.client.sync.syncNow()
        try await b.client.sync.syncNow()
        try await a.client.sync.syncNow()
        #expect(pageA.text.hasPrefix("Wrote this on the train (device A). " + Self.heading))
        #expect(pageA.text.hasSuffix(Self.todo + " Scribbled in the cellar (device B)\n"))
        #expect(pageB.text == pageA.text)
        #expect(pageB.runs == pageA.runs)
        #expect(treeB.sections() == treeA.sections())
        #expect(treeA.sections().map(\.title) == ["Marsh observations", "Owl pellets"])
        #expect(treeA.page(pageId)?.title == "Tuesday, renamed by B")

        step("5. a WebSocket head notification makes B pull by itself")
        try await b.client.sync.start()
        try await eventually("B's socket connects") { b.client.sync.status.webSocketConnected }
        let notifiedBefore = b.client.syncMonitor.lastNotifiedHead
        let pollsBefore = b.client.sync.status.lastSyncedAt
        pageA.edit { $0.insert("LIVE: ", at: 0, attributes: [PageAttribute.bold: .bool(true)]) }
        try await a.client.sync.syncNow()
        try await eventually("B shows A's edit without being asked") { pageB.text == pageA.text }
        #expect(b.client.syncMonitor.lastNotifiedHead > notifiedBefore)
        #expect(b.client.sync.status.lastSyncedAt != pollsBefore)
        // And the other way round, through both background loops.
        try await a.client.sync.start()
        try await eventually("A's socket connects") { a.client.sync.status.webSocketConnected }
        pageB.edit { $0.insert(" (B, live)", at: $0.length - 1, attributes: [:]) }
        try await eventually("A shows B's edit") { pageA.text == pageB.text && pageA.text.contains("(B, live)") }

        if let restart = environment["TWONOTE_E2E_RESTART"], !restart.isEmpty {
            step("6. the container restarts; both devices carry on")
            let before = (a.client.sync.status.cursor, b.client.sync.status.cursor)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-lc", restart]
            try process.run()
            pageA.edit { $0.insert("Typed while the server was restarting. ", at: 0, attributes: [:]) }
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            try await eventually("B receives what A typed during the restart", timeout: .seconds(60)) {
                pageB.text == pageA.text
            }
            try await eventually("both sockets are back", timeout: .seconds(60)) {
                a.client.sync.status.webSocketConnected && b.client.sync.status.webSocketConnected
            }
            pageB.edit { $0.insert(" After the restart (B).", at: $0.length - 1, attributes: [:]) }
            try await eventually("A receives B's edit after the restart", timeout: .seconds(60)) { pageA.text == pageB.text }
            try await eventually("both are idle", timeout: .seconds(30)) {
                a.client.sync.status.state == .idle && b.client.sync.status.state == .idle
                    && a.client.sync.status.pendingUpdates == 0 && b.client.sync.status.pendingUpdates == 0
            }
            #expect(a.client.sync.status.cursor > before.0 && b.client.sync.status.cursor > before.1)
            #expect(a.client.sync.issues.isEmpty && b.client.sync.issues.isEmpty)
            #expect(try await !probe.status().registrationOpen) // the account survived on the volume
        } else {
            step("6. skipped (TWONOTE_E2E_RESTART is not set)")
        }

        step("7. lock, unlock offline, a third device from scratch")
        await b.client.lock()
        b.transport.offline = true
        try await b.client.unlock(password: Self.password)
        #expect(try await b.client.openPage(notebookId: notebookId, pageId: pageId).text == pageA.text)
        let c = try await device(url)
        try await c.client.enrol(username: Self.username, password: Self.password, secretKey: secretKey, deviceName: "Swift C")
        try await c.client.sync.syncNow()
        let pageC = try await c.client.openPage(notebookId: notebookId, pageId: pageId)
        #expect(pageC.text == pageA.text)
        #expect(pageC.runs == pageA.runs)
        step("8. a device with a low threshold compacts; a new device rebuilds from the snapshot")
        let e = try await device(url) { $0.compactionThreshold = 5 }
        try await e.client.enrol(username: Self.username, password: Self.password, secretKey: secretKey, deviceName: "Swift E")
        try await e.client.sync.syncNow()
        let snapshotSeq = try #require(try await e.client.api.docs().first { $0.docId == pageId }?.snapshotSeq)
        #expect(snapshotSeq > 0)
        #expect(try await e.client.api.snapshot(docId: pageId)?.coveredSeq == snapshotSeq)
        let f = try await device(url)
        try await f.client.enrol(username: Self.username, password: Self.password, secretKey: secretKey, deviceName: "Swift F")
        try await f.client.sync.syncNow()
        let pageF = try await f.client.openPage(notebookId: notebookId, pageId: pageId)
        #expect(pageF.text == pageA.text)
        #expect(pageF.runs == pageA.runs)
        try await a.client.sync.syncNow() // A merges the snapshot event; nothing changes
        pageA.edit { $0.insert("After the snapshot. ", at: 0, attributes: [:]) }
        try await a.client.sync.syncNow()
        try await f.client.sync.syncNow()
        #expect(pageF.text == pageA.text)
        #expect(pageF.text.hasPrefix("After the snapshot. Typed while") || environment["TWONOTE_E2E_RESTART"] == nil)

        step("9. deletions: a page purged while another device typed into it, and a whole notebook")
        b.transport.offline = false
        let doomed = try await a.client.createPage(notebookId: notebookId, sectionId: sectionId, title: "Doomed")
        doomed.edit { $0.insert("not long for this world", at: 0, attributes: [:]) }
        let second = try await a.client.createNotebook(title: "Second notebook")
        try await a.client.sync.syncNow()
        try await b.client.sync.syncNow()
        #expect(b.client.notebookIds.sorted() == [notebookId, second.notebookId].sorted())
        let doomedB = try await b.client.openPage(notebookId: notebookId, pageId: doomed.docId)
        let secondB = try await b.client.openNotebook(second.notebookId)
        #expect(doomedB.text == "not long for this world\n")
        #expect(secondB.title == "Second notebook")
        b.transport.offline = true
        doomedB.edit { $0.insert("typed offline into a page that is being deleted ", at: 0, attributes: [:]) }
        secondB.addSection(title: "typed offline into a notebook that is being deleted")
        treeA.setPageDeleted(doomed.docId)
        try await a.client.sync.syncNow()
        try await a.client.purgePage(notebookId: notebookId, pageId: doomed.docId)
        try await a.client.deleteNotebook(second.notebookId)
        #expect(doomed.isDeleted && second.isDeleted)
        b.transport.offline = false
        try await b.client.sync.syncNow()
        #expect(doomedB.isDeleted && secondB.isDeleted)
        #expect(b.client.sync.status.pendingUpdates == 0)
        #expect(b.client.notebookIds == [notebookId])
        #expect(try await !b.client.api.docs().contains { $0.docId == doomed.docId })
        #expect(try await b.client.api.notebooks().map(\.notebookId) == [notebookId])
        // The tombstone answers as PROTOCOL.md says, so a stale device cannot re-create the document.
        let stale = [OutgoingUpdate(clientUpdateId: try WireEncoding.hexString(id: WireEncoding.newId()), blob: Data(count: 60))]
        do {
            _ = try await b.client.api.pushUpdates(docId: doomed.docId, notebookId: notebookId, updates: stale)
            Issue.record("the push to a deleted document was accepted")
        } catch let error as ApiError {
            #expect(error.status == 410 && error.code == ErrorCodes.docDeleted)
        }
        do {
            _ = try await b.client.api.pushUpdates(docId: second.notebookId, notebookId: second.notebookId, updates: stale)
            Issue.record("the push into a deleted notebook was accepted")
        } catch let error as ApiError {
            #expect(error.status == 404 && error.code == ErrorCodes.unknownNotebook)
        }

        step("10. password change: the other device is signed out until it signs in again")
        let newPassword = "an even more correct horse"
        try await a.client.changePassword(currentPassword: Self.password, newPassword: newPassword)
        try await a.client.sync.syncNow()
        await #expect(throws: ApiError.self) { try await b.client.sync.syncNow() }
        #expect(b.client.sync.status.state == .authRequired)
        await #expect(throws: ClientError.wrongCredentials) { try await b.client.signInAgain(password: Self.password) }
        try await b.client.signInAgain(password: newPassword)
        try await b.client.sync.syncNow()
        #expect(b.client.sync.status.state == .idle)
        await b.client.lock()
        await #expect(throws: ClientError.wrongCredentials) { try await b.client.unlock(password: Self.password) }
        try await b.client.unlock(password: newPassword)
        let after = try await b.client.devices()
        step("devices after the password change: \(after.map(\.name).sorted())")
        #expect(after.contains { $0.name == "Swift A" } && after.contains { $0.name == "Swift B" && $0.current })
        for device in [a, b, c, e, f] {
            #expect(device.client.sync.issues.isEmpty)
        }

        step("final text: \(pageA.text.replacingOccurrences(of: "\n", with: "⏎"))")

        if let path = environment["TWONOTE_E2E_STATE"], !path.isEmpty {
            let state = InteropState(
                username: Self.username, password: newPassword, secretKey: secretKey, notebookId: notebookId,
                sectionId: sectionId, pageId: pageId, swiftText: pageA.text)
            try JSONEncoder().encode(state).write(to: URL(fileURLWithPath: path))
            step("wrote the interop state file")
        }
        for client in [a.client, b.client, c.client, e.client, f.client] {
            await client.close()
        }
    }

    /// After the Windows client core (.NET) enrolled against the same container, read the page
    /// written here, appended to it and created a page of its own: a fresh Swift device must see all of it.
    @Test(.enabled(if: e2eURL != nil && e2ePhase == "interop-read"))
    func aSwiftDeviceReadsWhatTheWindowsClientWrote() async throws {
        let url = try #require(e2eURL)
        let path = try #require(environment["TWONOTE_E2E_STATE"])
        let state = try JSONDecoder().decode(InteropState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let d = try await device(url)
        try await d.client.enrol(username: state.username, password: state.password, secretKey: state.secretKey, deviceName: "Swift D")
        try await d.client.sync.syncNow()
        #expect(d.client.sync.issues.isEmpty)

        let devices = try await d.client.devices()
        step("devices: \(devices.map(\.name).sorted())")
        #expect(devices.contains { $0.name == "Windows core" })

        let tree = try await d.client.openNotebook(state.notebookId)
        let pages = tree.allPages()
        step("pages: \(pages.map(\.title))")
        let dotnetEntry = try #require(pages.first { $0.title == "Written by the Windows client" })
        let dotnetPage = try await d.client.openPage(notebookId: state.notebookId, pageId: dotnetEntry.id)
        step(".NET page text: \(dotnetPage.text.replacingOccurrences(of: "\n", with: "⏎"))")
        step(".NET page runs: \(dotnetPage.runs)")
        #expect(dotnetPage.text == "Hello from .NET\nA bold claim and a list item\n")
        #expect(dotnetPage.runs.contains { $0.text == "bold" && $0.attributes[PageAttribute.bold] == .bool(true) })
        #expect(dotnetPage.runs.first { $0.text == "\n" }?.attributes[PageAttribute.block] == .string("h2"))
        #expect(dotnetPage.runs.last?.attributes[PageAttribute.block] == .string("ul"))

        // The page written by Swift, with the line .NET appended to it.
        let swiftPage = try await d.client.openPage(notebookId: state.notebookId, pageId: state.pageId)
        step("Swift page text now: \(swiftPage.text.replacingOccurrences(of: "\n", with: "⏎"))")
        #expect(swiftPage.text == String(state.swiftText.dropLast()) + " [appended by .NET]\n")
        #expect(tree.sections().map(\.title).contains("Added by .NET"))

        // And back: Swift answers on the .NET page, for the Windows side to read.
        dotnetPage.edit { $0.insert("Swift was here. ", at: 0, attributes: [PageAttribute.italic: .bool(true)]) }
        try await d.client.sync.syncNow()
        #expect(d.client.sync.status.pendingUpdates == 0)
        await d.client.close()
    }
}
