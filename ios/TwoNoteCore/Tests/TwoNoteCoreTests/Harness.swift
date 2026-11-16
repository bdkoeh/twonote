import Foundation
import Testing
import TwoNoteCrypto
import TwoNoteDocuments
import YrsKit
@testable import TwoNoteCore

let testPassword = "correct horse battery staple"
let testUsername = "bob"

/// Cheap KDF parameters (the protocol minimum) so the tests do not spend their time in Argon2.
let fastKdf = KdfParams(alg: KdfParams.argon2id13, ops: 1, memKiB: 8192)

struct TimedOut: Error, CustomStringConvertible {
    var description: String
}

/// Polls until `condition` holds.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(10), _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TimedOut(description: "Timed out waiting for: \(what)")
}

func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("twonote-tests-\(UUID().uuidString)")
        .appendingPathComponent("store.db").path
}

/// One device of the account: a client with its own database, secret store and connection.
@MainActor
final class Device {
    let client: TwoNoteClient
    let transport: FakeTransport
    let secrets: InMemorySecretStore
    let databasePath: String
    private let configure: (inout ClientOptions) -> Void

    private init(client: TwoNoteClient, transport: FakeTransport, secrets: InMemorySecretStore, databasePath: String,
                 configure: @escaping (inout ClientOptions) -> Void) {
        self.client = client
        self.transport = transport
        self.secrets = secrets
        self.databasePath = databasePath
        self.configure = configure
    }

    static func make(
        _ server: FakeServer, _ name: String, databasePath: String = temporaryDatabasePath(),
        secrets: InMemorySecretStore = InMemorySecretStore(), transport: FakeTransport? = nil,
        configure: @escaping (inout ClientOptions) -> Void = { _ in }
    ) async throws -> Device {
        let transport = transport ?? FakeTransport(server: server, name: name)
        var options = ClientOptions(serverURL: URL(string: "http://fake.test:8080")!, databasePath: databasePath, secretStore: secrets)
        options.transport = transport
        options.webSocketConnector = transport
        options.kdfParams = fastKdf
        options.useWebSocket = false
        options.wakeOnNetworkChange = false
        options.pushDebounce = .milliseconds(20)
        options.initialRetryDelay = .milliseconds(40)
        options.maxRetryDelay = .milliseconds(200)
        options.maxOfflineRetryDelay = .milliseconds(200)
        configure(&options)
        let client = try await TwoNoteClient.open(options)
        return Device(client: client, transport: transport, secrets: secrets, databasePath: databasePath, configure: configure)
    }

    /// Closes this client and opens a new one on the same database and secrets ("app restart").
    func restart() async throws -> Device {
        await client.close()
        return try await Device.make(
            transport.server, transport.name, databasePath: databasePath, secrets: secrets, transport: transport, configure: configure)
    }

    var sync: SyncEngine { client.sync }
    var status: SyncStatus { client.sync.status }

    func syncNow() async throws {
        try await client.sync.syncNow()
    }

    /// A second connection to this device's database, for looking at what is stored.
    func inspectStore() throws -> LocalStore {
        try LocalStore.open(path: databasePath)
    }
}

/// A registered first device with one notebook, one section and one page, all synced.
@MainActor
struct Seed {
    var server: FakeServer
    var a: Device
    var secretKey: String
    var notebookId: String
    var sectionId: String
    var pageId: String
    var tree: YrsNotebookTree
    var page: YrsPageDocument

    static func make(configureA: @escaping (inout ClientOptions) -> Void = { _ in }) async throws -> Seed {
        let server = FakeServer()
        let a = try await Device.make(server, "A", configure: configureA)
        let secretKey = try await a.client.register(username: testUsername, password: testPassword, deviceName: "Device A")
        let tree = try await a.client.createNotebook(title: "Kestrel field journal")
        let sectionId = tree.addSection(title: "Marsh observations")
        let page = try await a.client.createPage(notebookId: tree.notebookId, sectionId: sectionId, title: "Tuesday at the hide")
        page.edit { $0.insert("Bittern sighting", at: 0, attributes: [:]) }
        try await a.syncNow()
        return Seed(
            server: server, a: a, secretKey: secretKey, notebookId: tree.notebookId, sectionId: sectionId, pageId: page.docId,
            tree: tree, page: page)
    }

    /// Enrols another device and brings it up to date.
    func enrol(_ name: String, sync: Bool = true, configure: @escaping (inout ClientOptions) -> Void = { _ in }) async throws -> Device {
        let device = try await Device.make(server, name, configure: configure)
        try await device.client.enrol(username: testUsername, password: testPassword, secretKey: secretKey, deviceName: "Device \(name)")
        if sync {
            try await device.syncNow()
        }
        return device
    }
}

extension YrsPageDocument {
    /// Types text at the start of the page.
    func prepend(_ text: String) {
        edit { $0.insert(text, at: 0, attributes: [:]) }
    }

    /// Types text at the end of the last paragraph.
    func append(_ text: String) {
        edit { $0.insert(text, at: $0.length - 1, attributes: [:]) }
    }
}
