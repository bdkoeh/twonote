import Foundation
import TwoNoteCrypto
@testable import TwoNoteCore

/// An in-memory server that follows PROTOCOL.md sections 2 and 3, with switches for the
/// failures the tests need. It parses and builds JSON with JSONSerialization, independently of
/// the client's Codable types, so the wire format is checked from the other side.
final class FakeServer: @unchecked Sendable {
    struct Event {
        var seq: Int64
        var type: String
        var docId: String?
        var notebookId: String?
        var deviceId: String?
        var blob: Data?
        var coveredSeq: Int64?
    }

    struct Account {
        var username: String
        var accountId: String
        var kdfSalt: String
        var kdfParams: [String: Any]
        var authPublicKey: Data
        var wrappedVaultKey: String
    }

    struct Doc {
        var notebookId: String
        var snapshot: (coveredSeq: Int64, blob: String)?
    }

    private let lock = NSLock()
    private(set) var account: Account?
    private var devices: [String: (name: String, token: String?, createdAt: Date)] = [:]
    private var challenges: [String: (nonce: Data, real: Bool)] = [:]
    private var notebooks: [String: String] = [:]
    private var docs: [String: Doc] = [:]
    private var tombstones: Set<String> = []
    private var updateIds: [String: (docId: String, seq: Int64)] = [:]
    private var eventLog: [Event] = []
    private var headValue: Int64 = 0
    private var sockets: [(socket: FakeSocket, deviceId: String)] = []
    private var log: [String] = []
    private var bodies: [Data] = []

    // Switches (set under `configure`).
    var maxEventsPerPage: Int?
    /// Rewrites the events of a `/events` answer (JSON objects) before it is sent.
    var eventsFilter: (@Sendable (_ device: String, _ events: [[String: Any]]) -> [[String: Any]])?

    func configure(_ body: (FakeServer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(self)
    }

    var head: Int64 { locked { headValue } }
    var events: [Event] { locked { eventLog } }
    var requests: [String] { locked { log } }
    var requestBodies: [Data] { locked { bodies } }
    var snapshots: [String: Int64] { locked { docs.compactMapValues { $0.snapshot?.coveredSeq } } }
    var notebookIds: [String] { locked { notebooks.keys.sorted() } }
    var docIds: [String] { locked { docs.keys.sorted() } }
    var registrationOpen: Bool { locked { account == nil } }

    /// Flips one byte of a stored update blob, as a corrupted disk or a hostile server would.
    func tamper(seq: Int64) {
        locked {
            if let i = eventLog.firstIndex(where: { $0.seq == seq }), var blob = eventLog[i].blob {
                blob[blob.count - 1] ^= 0x01
                eventLog[i].blob = blob
            }
        }
    }

    func tamperSnapshot(docId: String) {
        locked {
            if let snapshot = docs[docId]?.snapshot, var blob = WireEncoding.data(base64URL: snapshot.blob) {
                blob[blob.count - 1] ^= 0x01
                docs[docId]?.snapshot = (snapshot.coveredSeq, WireEncoding.base64URLString(blob))
            }
        }
    }

    /// Closes every open WebSocket, as a restarting server does.
    func dropSockets() {
        let open = locked { () -> [FakeSocket] in
            let list = sockets.map(\.socket)
            sockets = []
            return list
        }
        open.forEach { $0.serverClose(code: 1001) }
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: HTTP

    struct Answer {
        var status: Int
        var json: Any?
        var headers: [String: String] = [:]
    }

    private static func error(_ status: Int, _ code: String) -> Answer {
        Answer(status: status, json: ["error": code, "message": "fake server: \(code)"])
    }

    func handle(_ request: URLRequest, client: String) -> Answer {
        let before = head
        let answer = locked { route(request, client: client) }
        if head != before {
            notifyHead()
        }
        return answer
    }

    private func route(_ request: URLRequest, client: String) -> Answer {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.hasPrefix("/api/v1/") else {
            return Self.error(404, "not_found")
        }
        let method = request.httpMethod ?? "GET"
        let path = String(components.path.dropFirst("/api/v1/".count))
        let parts = path.split(separator: "/").map(String.init)
        log.append("\(client) \(method) \(path)")
        if let body = request.httpBody {
            bodies.append(body)
        }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]

        switch (method, parts.first ?? "", parts.count) {
        case ("GET", "status", 1):
            return Answer(status: 200, json: ["version": "fake", "protocol": 1, "registrationOpen": account == nil])
        case ("POST", "register", 1):
            return register(body)
        case ("POST", "auth", 2) where parts[1] == "start":
            return authStart(body)
        case ("POST", "auth", 2) where parts[1] == "finish":
            return authFinish(body)
        default:
            break
        }

        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer "),
              let deviceId = devices.first(where: { $0.value.token == String(header.dropFirst(7)) })?.key else {
            return Self.error(401, "unauthorized")
        }

        switch (method, parts.first ?? "", parts.count) {
        case ("GET", "devices", 1):
            let formatter = ISO8601DateFormatter()
            return Answer(status: 200, json: devices.filter { $0.value.token != nil }.keys.sorted().map { id -> [String: Any] in
                // Seven fractional digits, as .NET writes them.
                let stamp = formatter.string(from: devices[id]!.createdAt).replacingOccurrences(of: "Z", with: ".1234567Z")
                return ["deviceId": id, "name": devices[id]!.name, "createdAt": stamp, "lastSeenAt": stamp, "current": id == deviceId]
            })
        case ("DELETE", "devices", 2):
            guard devices[parts[1]] != nil else { return Self.error(404, "unknown_device") }
            devices[parts[1]]?.token = nil
            closeSockets(of: parts[1])
            return Answer(status: 204)
        case ("POST", "account", 2) where parts[1] == "rekey":
            guard var account, let salt = body["kdfSalt"] as? String, let params = body["kdfParams"] as? [String: Any],
                  let key = (body["authPublicKey"] as? String).flatMap(WireEncoding.data(base64URL:)),
                  let wrapped = body["wrappedVaultKey"] as? String else { return Self.error(400, "invalid_request") }
            account.kdfSalt = salt
            account.kdfParams = params
            account.authPublicKey = key
            account.wrappedVaultKey = wrapped
            self.account = account
            for id in devices.keys where id != deviceId {
                devices[id]?.token = nil
                closeSockets(of: id)
            }
            return Answer(status: 204)
        case ("GET", "notebooks", 1):
            return Answer(status: 200, json: notebooks.keys.sorted().map { ["notebookId": $0, "wrappedKey": notebooks[$0]!] })
        case ("PUT", "notebooks", 2):
            guard let wrapped = body["wrappedKey"] as? String else { return Self.error(400, "invalid_request") }
            if notebooks[parts[1]] != wrapped {
                notebooks[parts[1]] = wrapped
                append(Event(seq: 0, type: "notebooksChanged"))
            }
            return Answer(status: 200, json: ["head": headValue])
        case ("DELETE", "notebooks", 2):
            guard notebooks.removeValue(forKey: parts[1]) != nil else { return Self.error(404, "unknown_notebook") }
            let gone = Set(docs.filter { $0.value.notebookId == parts[1] }.keys)
            docs = docs.filter { !gone.contains($0.key) }
            eventLog.removeAll { $0.notebookId == parts[1] }
            append(Event(seq: 0, type: "notebooksChanged"))
            return Answer(status: 200, json: ["head": headValue])
        case ("GET", "docs", 1):
            return Answer(status: 200, json: docs.keys.sorted().map {
                ["docId": $0, "notebookId": docs[$0]!.notebookId, "snapshotSeq": docs[$0]!.snapshot?.coveredSeq ?? 0] as [String: Any]
            })
        case ("POST", "docs", 3) where parts[2] == "updates":
            return pushUpdates(docId: parts[1], deviceId: deviceId, body)
        case ("GET", "docs", 3) where parts[2] == "snapshot":
            guard let doc = docs[parts[1]] else { return Self.error(404, "unknown_doc") }
            guard let snapshot = doc.snapshot else { return Self.error(404, "no_snapshot") }
            return Answer(status: 200, json: ["coveredSeq": snapshot.coveredSeq, "blob": snapshot.blob])
        case ("PUT", "docs", 3) where parts[2] == "snapshot":
            guard let doc = docs[parts[1]] else { return Self.error(404, "unknown_doc") }
            guard let covered = (body["coveredSeq"] as? NSNumber)?.int64Value, let blob = body["blob"] as? String,
                  covered >= 1, covered <= headValue else { return Self.error(400, "invalid_request") }
            if let stored = doc.snapshot, covered < stored.coveredSeq { return Self.error(409, "stale_snapshot") }
            docs[parts[1]]?.snapshot = (covered, blob)
            eventLog.removeAll { $0.docId == parts[1] && ($0.type == "snapshot" || ($0.type == "update" && $0.seq <= covered)) }
            append(Event(seq: 0, type: "snapshot", docId: parts[1], notebookId: doc.notebookId, coveredSeq: covered))
            return Answer(status: 200, json: ["seq": headValue, "head": headValue])
        case ("DELETE", "docs", 2):
            guard let doc = docs.removeValue(forKey: parts[1]) else { return Self.error(404, "unknown_doc") }
            eventLog.removeAll { $0.docId == parts[1] }
            tombstones.insert(parts[1])
            append(Event(seq: 0, type: "docDeleted", docId: parts[1], notebookId: doc.notebookId))
            return Answer(status: 200, json: ["head": headValue])
        case ("GET", "events", 1):
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let after = Int64(query["after"] ?? "") ?? 0
            let limit = min(Int(query["limit"] ?? "") ?? 500, maxEventsPerPage ?? 2000)
            let matching = eventLog.filter { $0.seq > after }
            var page = matching.prefix(limit).map(Self.json)
            if let eventsFilter {
                page = eventsFilter(client, page)
            }
            return Answer(status: 200, json: ["events": page, "head": headValue, "more": matching.count > limit])
        default:
            return Self.error(404, "not_found")
        }
    }

    private static func json(_ event: Event) -> [String: Any] {
        var object: [String: Any] = ["seq": event.seq, "type": event.type]
        object["docId"] = event.docId
        object["notebookId"] = event.notebookId
        object["deviceId"] = event.deviceId
        object["blob"] = event.blob.map(WireEncoding.base64URLString)
        object["coveredSeq"] = event.coveredSeq
        return object
    }

    private func append(_ event: Event) {
        headValue += 1
        var event = event
        event.seq = headValue
        eventLog.append(event)
    }

    private static func newId() -> String {
        (try? WireEncoding.hexString(id: WireEncoding.newId())) ?? ""
    }

    private func issueDevice(name: String, id: String? = nil) -> [String: Any] {
        let deviceId = id ?? Self.newId()
        let token = WireEncoding.base64URLString(SecretBytes.random(count: 32).copyToData())
        devices[deviceId] = (name, token, devices[deviceId]?.createdAt ?? Date())
        return ["deviceId": deviceId, "token": token]
    }

    private func register(_ body: [String: Any]) -> Answer {
        guard account == nil else { return Self.error(403, "registration_closed") }
        guard let username = body["username"] as? String, let accountId = body["accountId"] as? String,
              WireEncoding.id(hex: accountId) != nil,
              let salt = body["kdfSalt"] as? String, WireEncoding.data(base64URL: salt)?.count == 16,
              let params = body["kdfParams"] as? [String: Any], params["alg"] as? String == "argon2id13",
              let key = (body["authPublicKey"] as? String).flatMap(WireEncoding.data(base64URL:)), key.count == 32,
              let wrapped = body["wrappedVaultKey"] as? String, WireEncoding.data(base64URL: wrapped) != nil,
              let deviceName = body["deviceName"] as? String else {
            return Self.error(400, "invalid_request")
        }
        account = Account(username: username, accountId: accountId, kdfSalt: salt, kdfParams: params, authPublicKey: key, wrappedVaultKey: wrapped)
        return Answer(status: 201, json: issueDevice(name: deviceName))
    }

    private func authStart(_ body: [String: Any]) -> Answer {
        guard let username = body["username"] as? String else { return Self.error(400, "invalid_request") }
        let challengeId = Self.newId()
        let nonce = LoginSignature.newNonce()
        let known = account.flatMap { $0.username.lowercased() == username.trimmingCharacters(in: .whitespaces).lowercased() ? $0 : nil }
        challenges[challengeId] = (nonce, known != nil)
        return Answer(status: 200, json: [
            "accountId": known?.accountId ?? Self.newId(),
            "kdfSalt": known?.kdfSalt ?? WireEncoding.base64URLString(KeyDerivation.newSalt()),
            "kdfParams": known?.kdfParams ?? ["alg": "argon2id13", "ops": 1, "memKiB": 8192],
            "challengeId": challengeId,
            "nonce": WireEncoding.base64URLString(nonce),
        ])
    }

    private func authFinish(_ body: [String: Any]) -> Answer {
        guard let challengeId = body["challengeId"] as? String, let name = body["deviceName"] as? String,
              let signature = (body["signature"] as? String).flatMap(WireEncoding.data(base64URL:)) else {
            return Self.error(400, "invalid_request")
        }
        guard let challenge = challenges.removeValue(forKey: challengeId), challenge.real, let account,
              LoginSignature.verify(authPublicKey: account.authPublicKey, nonce: challenge.nonce, signature: signature) else {
            return Self.error(401, "bad_signature")
        }
        var answer = issueDevice(name: name, id: body["deviceId"] as? String)
        answer["wrappedVaultKey"] = account.wrappedVaultKey
        return Answer(status: 200, json: answer)
    }

    private func pushUpdates(docId: String, deviceId: String, _ body: [String: Any]) -> Answer {
        guard let notebookId = body["notebookId"] as? String, let updates = body["updates"] as? [[String: Any]],
              !updates.isEmpty, updates.count <= 1000, WireEncoding.id(hex: docId) != nil else {
            return Self.error(400, "invalid_request")
        }
        if tombstones.contains(docId) { return Self.error(410, "doc_deleted") }
        guard notebooks[notebookId] != nil else { return Self.error(404, "unknown_notebook") }
        if let doc = docs[docId], doc.notebookId != notebookId { return Self.error(409, "notebook_mismatch") }
        var parsed: [(id: String, blob: Data)] = []
        for update in updates {
            guard let id = update["clientUpdateId"] as? String, WireEncoding.id(hex: id) != nil,
                  let blob = (update["blob"] as? String).flatMap(WireEncoding.data(base64URL:)) else {
                return Self.error(400, "invalid_request")
            }
            if let known = updateIds[id], known.docId != docId { return Self.error(409, "update_id_conflict") }
            parsed.append((id, blob))
        }
        if docs[docId] == nil {
            docs[docId] = Doc(notebookId: notebookId, snapshot: nil)
        }
        var seqs: [Int64] = []
        for (id, blob) in parsed {
            if let known = updateIds[id] {
                seqs.append(known.seq)
                continue
            }
            append(Event(seq: 0, type: "update", docId: docId, notebookId: notebookId, deviceId: deviceId, blob: blob))
            updateIds[id] = (docId, headValue)
            seqs.append(headValue)
        }
        return Answer(status: 200, json: ["seqs": seqs, "head": headValue])
    }

    // MARK: WebSocket

    fileprivate func hello(_ socket: FakeSocket, _ text: String) {
        let accepted = locked { () -> Int64? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let token = object["token"] as? String,
                  let deviceId = devices.first(where: { $0.value.token == token })?.key else { return nil }
            sockets.append((socket, deviceId))
            return headValue
        }
        if let accepted {
            socket.deliver("{\"head\":\(accepted)}")
        } else {
            socket.serverClose(code: 1008)
        }
    }

    private func notifyHead() {
        let (open, value) = locked { (sockets.map(\.socket), headValue) }
        open.forEach { $0.deliver("{ \"head\": \(value) }") }
    }

    /// Call with the lock held.
    private func closeSockets(of deviceId: String) {
        let closing = sockets.filter { $0.deviceId == deviceId }.map(\.socket)
        sockets.removeAll { $0.deviceId == deviceId }
        DispatchQueue.global().async {
            closing.forEach { $0.serverClose(code: 1008) }
        }
    }
}

/// One client's connection to the fake server, with its own failure switches.
final class FakeTransport: HTTPTransport, WebSocketConnector, @unchecked Sendable {
    private struct State {
        var offline = false
        var loseAnswers: (matching: String, count: Int)?
        var override: (@Sendable (URLRequest) -> FakeServer.Answer?)?
    }

    let server: FakeServer
    let name: String
    private let state = Locked(State())

    init(server: FakeServer, name: String) {
        self.server = server
        self.name = name
    }

    /// True makes every request and WebSocket connect fail as "cannot connect".
    var offline: Bool {
        get { state.withLock { $0.offline } }
        set {
            state.withLock { $0.offline = newValue }
        }
    }

    /// The next `count` requests whose path contains `matching` are carried out by the server,
    /// but their answers never arrive.
    func loseAnswers(matching: String, count: Int = 1) {
        state.withLock { $0.loseAnswers = (matching, count) }
    }

    /// Answers requests itself when the closure returns something.
    func overrideAnswers(_ body: (@Sendable (URLRequest) -> FakeServer.Answer?)?) {
        state.withLock { $0.override = body }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await Task.yield()
        let (offline, override) = state.withLock { ($0.offline, $0.override) }
        if offline {
            throw URLError(.cannotConnectToHost)
        }
        let answer = override?(request) ?? server.handle(request, client: name)
        let lost = state.withLock { s -> Bool in
            guard let lose = s.loseAnswers, request.url?.path.contains(lose.matching) == true else { return false }
            s.loseAnswers = lose.count > 1 ? (lose.matching, lose.count - 1) : nil
            return true
        }
        if lost {
            throw URLError(.networkConnectionLost)
        }
        let data = try answer.json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        return (data, response)
    }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        if offline || !["ws", "wss"].contains(url.scheme ?? "") || url.path != "/api/v1/ws" {
            throw URLError(.cannotConnectToHost)
        }
        return FakeSocket(server: server)
    }
}

final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    private struct State {
        var queue: [String] = []
        var waiter: CheckedContinuation<WebSocketFrame, any Error>?
        var closed: (any Error)?
    }

    private let server: FakeServer
    private let state = Locked(State())

    init(server: FakeServer) {
        self.server = server
    }

    func send(text: String) async throws {
        if let closed = state.withLock({ $0.closed }) {
            throw closed
        }
        server.hello(self, text)
    }

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock { s -> Result<WebSocketFrame, any Error>? in
                if !s.queue.isEmpty {
                    return .success(.text(s.queue.removeFirst()))
                }
                if let closed = s.closed {
                    return .failure(closed)
                }
                s.waiter = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func close() {
        finish(URLError(.cancelled))
    }

    fileprivate func serverClose(code: Int) {
        finish(WebSocketClosedError(code: code))
    }

    fileprivate func deliver(_ text: String) {
        let waiter = state.withLock { s -> CheckedContinuation<WebSocketFrame, any Error>? in
            guard s.closed == nil else { return nil }
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            s.queue.append(text)
            return nil
        }
        waiter?.resume(returning: .text(text))
    }

    private func finish(_ error: any Error) {
        let waiter = state.withLock { s -> CheckedContinuation<WebSocketFrame, any Error>? in
            if s.closed == nil {
                s.closed = error
            }
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: error)
    }
}
