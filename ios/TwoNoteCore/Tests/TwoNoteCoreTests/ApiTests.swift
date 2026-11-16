import Foundation
import Testing
import TwoNoteCrypto
@testable import TwoNoteCore

/// A transport that answers from a closure and records what was sent.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let recorded = Locked<[URLRequest]>([])
    private let answer: @Sendable (URLRequest) throws -> (Int, String, [String: String])

    init(_ answer: @escaping @Sendable (URLRequest) throws -> (Int, String, [String: String])) {
        self.answer = answer
    }

    var requests: [URLRequest] {
        recorded.withLock { $0 }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let (status, body, headers) = try answer(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private let anId = String(repeating: "ab", count: 16)

@Suite("api client")
struct ApiTests {
    private func api(_ transport: StubTransport, token: String? = "tok") -> TwoNoteApi {
        let api = TwoNoteApi(serverURL: URL(string: "https://notes.example:8443/")!, transport: transport)
        api.token = token
        return api
    }

    @Test func requestsFollowTheWireConventions() async throws {
        let transport = StubTransport { request in
            switch request.url!.path {
            case "/api/v1/status": (200, #"{"version":"1.2.3","protocol":1,"registrationOpen":true,"extra":"ignored"}"#, [:])
            case "/api/v1/events": (200, #"{"events":[{"seq":4,"type":"update","docId":"\#(anId)","notebookId":"\#(anId)","deviceId":"\#(anId)","blob":"AQID_-8"},{"seq":9,"type":"somethingNew"}],"head":9,"more":false}"#, [:])
            case "/api/v1/account/rekey": (204, "", [:])
            default: (200, #"{"seqs":[5,6],"head":6}"#, [:])
            }
        }
        let api = api(transport)
        #expect(api.webSocketURL.absoluteString == "wss://notes.example:8443/api/v1/ws")
        #expect(TwoNoteApi(serverURL: URL(string: "http://nas.local:8080")!).webSocketURL.absoluteString == "ws://nas.local:8080/api/v1/ws")

        let status = try await api.status()
        #expect(status == ServerStatus(version: "1.2.3", protocolVersion: 1, registrationOpen: true))
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == nil)

        let page = try await api.events(after: 3, limit: 50)
        #expect(transport.requests[1].url?.absoluteString == "https://notes.example:8443/api/v1/events?after=3&limit=50")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(page.events.count == 2 && page.head == 9 && !page.more)
        #expect(page.events[0].blob == Data([1, 2, 3, 0xFF, 0xEF]))
        #expect(page.events[1].type == "somethingNew")

        let pushed = try await api.pushUpdates(
            docId: anId, notebookId: anId,
            updates: [OutgoingUpdate(clientUpdateId: anId, blob: Data([0xFB, 0xFF])), OutgoingUpdate(clientUpdateId: anId, blob: Data([1]))])
        #expect(pushed.seqs == [5, 6])
        let request = transport.requests[2]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/docs/\(anId)/updates")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["notebookId"] as? String == anId)
        let updates = try #require(body["updates"] as? [[String: String]])
        #expect(updates == [["clientUpdateId": anId, "blob": "-_8"], ["clientUpdateId": anId, "blob": "AQ"]]) // base64url, no padding

        try await api.rekey(RekeyRequest(kdfSalt: Data(count: 16), kdfParams: .default, authPublicKey: Data(count: 32), wrappedVaultKey: Data([9])))
        let rekey = try #require(try JSONSerialization.jsonObject(with: transport.requests[3].httpBody!) as? [String: Any])
        #expect(rekey["wrappedVaultKey"] as? String == "CQ")
        #expect((rekey["kdfParams"] as? [String: Any])?["memKiB"] as? Int == 65536)
        #expect((rekey["kdfParams"] as? [String: Any])?["alg"] as? String == "argon2id13")

        // Ids are checked before anything is sent.
        await #expect(throws: ClientError.self) { try await api.deleteDoc("../status") }
        await #expect(throws: ClientError.self) { try await api.deleteDoc(anId.uppercased()) }
        #expect(transport.requests.count == 4)
    }

    @Test func failuresAreTyped() async throws {
        let transport = StubTransport { request in
            switch request.url!.lastPathComponent {
            case "finish": (429, #"{"error":"rate_limited","message":"slow down"}"#, ["Retry-After": "42"])
            case "docs": (410, #"{"error":"doc_deleted","message":"gone"}"#, [:])
            case "notebooks": (503, "<html>bad gateway</html>", [:])
            case "devices": (500, "oops", [:])
            case "status": throw URLError(.timedOut)
            case "start": throw URLError(.cancelled)
            case "snapshot": (404, #"{"error":"no_snapshot","message":"none"}"#, [:])
            case "events": (200, #"{"events":[{"seq":5,"type":"update"},{"seq":5,"type":"update"}],"head":5,"more":false}"#, [:])
            default: (200, "not json", [:])
            }
        }
        let api = api(transport)

        do {
            _ = try await api.authFinish(challengeId: anId, signature: Data(count: 64), deviceName: "x")
            Issue.record("expected an error")
        } catch let error as ApiError {
            #expect(error == ApiError(status: 429, code: "rate_limited", message: "slow down", retryAfter: 42))
        }
        do {
            _ = try await api.docs()
            Issue.record("expected an error")
        } catch let error as ApiError {
            #expect(error.status == 410 && error.code == ErrorCodes.docDeleted && error.retryAfter == nil)
        }
        // A gateway error without a protocol body, a timeout: the server is unreachable.
        await #expect(throws: ServerUnreachableError.self) { _ = try await api.notebooks() }
        await #expect(throws: ServerUnreachableError.self) { _ = try await api.status() }
        // Any other status without a body still carries the status.
        do {
            _ = try await api.devices()
            Issue.record("expected an error")
        } catch let error as ApiError {
            #expect(error.status == 500 && error.code == "http_500")
        }
        await #expect(throws: CancellationError.self) { _ = try await api.authStart(username: "bob") }
        #expect(try await api.snapshot(docId: anId) == nil)
        await #expect(throws: ProtocolViolationError.self) { _ = try await api.events(after: 0) }
        await #expect(throws: ProtocolViolationError.self) { _ = try await api.putNotebook(anId, wrappedKey: Data([1])) }

        // Without a token nothing is sent at all.
        let before = transport.requests.count
        api.token = nil
        do {
            _ = try await api.docs()
            Issue.record("expected an error")
        } catch let error as ApiError {
            #expect(error.status == 401 && error.code == ErrorCodes.unauthorized)
        }
        #expect(transport.requests.count == before)
    }

    @Test func timestampsWithAnyNumberOfFractionalDigitsAreRead() throws {
        let base = try #require(WireDate.parse("2026-11-14T08:30:00Z"))
        #expect(base.timeIntervalSince1970 == 1_794_645_000)
        #expect(WireDate.parse("2026-11-14T08:30:00.5Z") == base.addingTimeInterval(0.5))
        #expect(abs(WireDate.parse("2026-11-14T08:30:00.1234567Z")!.timeIntervalSince(base) - 0.1234567) < 1e-6)
        #expect(WireDate.parse("2026-11-14T09:30:00.250+01:00") == base.addingTimeInterval(0.25))
        #expect(WireDate.parse("yesterday") == nil)
        #expect(WireDate.parse("2026-11-14T08:30:00.Z") == nil)
    }
}

@MainActor
@Suite("head listener")
struct HeadListenerTests {
    @Test func reportsHeadsReconnectsAfterADropAndReportsARejectedToken() async throws {
        let seed = try await Seed.make()
        let server = seed.server
        let transport = FakeTransport(server: server, name: "L")
        let token = Locked<String?>(seed.a.secrets.get(SecretNames.sessionToken))
        let heads = Locked<[Int64]>([])
        let connections = Locked<[Bool]>([])
        let rejected = Locked(0)
        let listener = HeadListener(
            url: URL(string: "ws://fake.test:8080/api/v1/ws")!,
            token: { token.withLock { $0 } },
            connector: transport,
            initialBackoff: .milliseconds(20), maxBackoff: .milliseconds(100),
            onHead: { head in heads.withLock { $0.append(head) } },
            onConnectionChanged: { connected in connections.withLock { $0.append(connected) } },
            onRejected: { rejected.withLock { $0 += 1 } })

        func wait(_ what: String, _ condition: @Sendable () -> Bool) async throws {
            for _ in 0..<500 where !condition() {
                try await Task.sleep(for: .milliseconds(10))
            }
            if !condition() {
                throw TimedOut(description: what)
            }
        }

        listener.start()
        listener.start() // a second start changes nothing
        let head = server.head
        try await wait("the first head") { heads.withLock { $0 == [head] } }
        #expect(listener.isConnected)
        #expect(listener.connectionCount == 1)

        // A write by any device is announced.
        seed.page.append(" more")
        try await seed.a.syncNow()
        try await wait("a new head") { heads.withLock { $0.last == server.head } && server.head > head }

        // The server restarts: the listener reconnects by itself and hears the head again.
        server.dropSockets()
        try await wait("a reconnect") { listener.connectionCount >= 2 && listener.isConnected && connections.withLock { $0.contains(false) } }

        // While the server is unreachable it keeps trying, quietly.
        transport.offline = true
        server.dropSockets()
        try await wait("the connection is lost") { !listener.isConnected }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!listener.isConnected)
        transport.offline = false
        try await wait("it is back") { listener.isConnected }

        // A token the server does not know is closed with 1008.
        token.withLock { $0 = "not-a-token" }
        server.dropSockets()
        try await wait("the rejection") { rejected.withLock { $0 > 0 } }
        #expect(!listener.isConnected)

        // Without a token it does not connect at all.
        await listener.stop()
        let count = listener.connectionCount
        token.withLock { $0 = nil }
        listener.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(listener.connectionCount == count)
        await listener.stop()
        #expect(!listener.isConnected)
    }
}
