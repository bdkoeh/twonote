import Foundation
import TwoNoteCrypto

/// Carries one HTTP request. The default is `URLSessionTransport`; tests inject an in-memory server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport: an ephemeral `URLSession` (no cookies, no cache, nothing on disk) that
/// fails fast instead of waiting for connectivity.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout * 4, 120)
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerUnreachableError("The server did not answer with HTTP.")
        }
        return (data, http)
    }
}

/// Typed client for every HTTP endpoint of PROTOCOL.md section 3. Failures surface as
/// `ApiError` (the server said no), `ServerUnreachableError` (no usable answer) or
/// `ProtocolViolationError` (an answer outside the protocol). Safe to use from any task; its
/// work never runs on the main actor's thread unless the transport does.
public final class TwoNoteApi: Sendable {
    /// The server this client talks to (scheme, host and port; no path).
    public let serverURL: URL

    private let base: String
    private let transport: any HTTPTransport
    private let tokenBox = Locked<String?>(nil)

    /// - Parameters:
    ///   - serverURL: for example `http://nas.local:8080`.
    ///   - transport: optional transport override (tests).
    ///   - timeout: per-request timeout of the default transport, in seconds.
    public init(serverURL: URL, transport: (any HTTPTransport)? = nil, timeout: TimeInterval = 30) {
        self.serverURL = serverURL
        var text = serverURL.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        base = text + "/api/v1/"
        self.transport = transport ?? URLSessionTransport(timeout: timeout)
    }

    /// The session token sent with authenticated requests. Never logged.
    public var token: String? {
        get { tokenBox.withLock { $0 } }
        set { tokenBox.withLock { $0 = newValue } }
    }

    /// The WebSocket address of the head listener endpoint: `ws` for `http`, `wss` for `https`.
    public var webSocketURL: URL {
        var components = URLComponents(string: base + "ws") ?? URLComponents()
        components.scheme = serverURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components.url ?? serverURL
    }

    // MARK: Unauthenticated

    /// `GET /status`.
    public func status() async throws -> ServerStatus {
        try await send("GET", "status", authenticated: false)
    }

    /// `POST /register`: creates the account and its first device.
    public func register(_ request: RegisterRequest) async throws -> DeviceSession {
        try await send("POST", "register", body: request, authenticated: false)
    }

    /// `POST /auth/start`: fetches the KDF inputs and a login challenge.
    public func authStart(username: String) async throws -> AuthChallenge {
        try await send("POST", "auth/start", body: AuthStartBody(username: username), authenticated: false)
    }

    /// `POST /auth/finish`: answers the challenge. `deviceId` re-uses an existing device.
    public func authFinish(challengeId: String, signature: Data, deviceName: String, deviceId: String? = nil) async throws -> AuthResult {
        try await send(
            "POST", "auth/finish",
            body: AuthFinishBody(challengeId: challengeId, signature: signature, deviceName: deviceName, deviceId: deviceId),
            authenticated: false)
    }

    // MARK: Authenticated

    /// `GET /devices`.
    public func devices() async throws -> [DeviceInfo] {
        try await send("GET", "devices")
    }

    /// `DELETE /devices/{deviceId}`: revokes that device's token.
    public func deleteDevice(_ deviceId: String) async throws {
        _ = try await perform("DELETE", "devices/" + Self.id(deviceId), body: nil, authenticated: true)
    }

    /// `POST /account/rekey`: replaces the credentials; other devices are revoked.
    public func rekey(_ request: RekeyRequest) async throws {
        _ = try await perform("POST", "account/rekey", body: try Self.encode(request), authenticated: true)
    }

    /// `GET /notebooks`.
    public func notebooks() async throws -> [NotebookEntry] {
        try await send("GET", "notebooks")
    }

    /// `PUT /notebooks/{notebookId}`: creates or replaces; returns the new head.
    @discardableResult
    public func putNotebook(_ notebookId: String, wrappedKey: Data) async throws -> Int64 {
        let answer: HeadMessage = try await send("PUT", "notebooks/" + Self.id(notebookId), body: PutNotebookBody(wrappedKey: wrappedKey))
        return answer.head
    }

    /// `DELETE /notebooks/{notebookId}`; returns the new head.
    @discardableResult
    public func deleteNotebook(_ notebookId: String) async throws -> Int64 {
        let answer: HeadMessage = try await send("DELETE", "notebooks/" + Self.id(notebookId))
        return answer.head
    }

    /// `GET /docs`.
    public func docs() async throws -> [DocEntry] {
        try await send("GET", "docs")
    }

    /// `POST /docs/{docId}/updates`. Idempotent per `clientUpdateId`.
    public func pushUpdates(docId: String, notebookId: String, updates: [OutgoingUpdate]) async throws -> PushResult {
        let result: PushResult = try await send(
            "POST", "docs/\(try Self.id(docId))/updates", body: PushBody(notebookId: notebookId, updates: updates))
        guard result.seqs.count == updates.count else {
            throw ProtocolViolationError("The server acknowledged a different number of updates than were pushed.")
        }
        return result
    }

    /// `GET /docs/{docId}/snapshot`; nil when the document has none (or does not exist).
    public func snapshot(docId: String) async throws -> SnapshotEntry? {
        do {
            return try await send("GET", "docs/\(try Self.id(docId))/snapshot")
        } catch let error as ApiError where error.status == 404 {
            return nil
        }
    }

    /// `PUT /docs/{docId}/snapshot`.
    public func putSnapshot(docId: String, coveredSeq: Int64, blob: Data) async throws -> PutSnapshotResult {
        try await send("PUT", "docs/\(try Self.id(docId))/snapshot", body: SnapshotEntry(coveredSeq: coveredSeq, blob: blob))
    }

    /// `DELETE /docs/{docId}`; returns the new head.
    @discardableResult
    public func deleteDoc(_ docId: String) async throws -> Int64 {
        let answer: HeadMessage = try await send("DELETE", "docs/" + Self.id(docId))
        return answer.head
    }

    /// `GET /events?after=&limit=`. A page whose seqs are not strictly increasing is refused as a whole.
    public func events(after: Int64, limit: Int = 500) async throws -> EventsPage {
        let page: EventsPage = try await send("GET", "events?after=\(after)&limit=\(limit)")
        var last = after
        for event in page.events {
            // Order is a correctness requirement (PROTOCOL.md section 4), so it is checked, not assumed.
            guard event.seq > last else {
                throw ProtocolViolationError("The server returned events out of seq order.")
            }
            last = event.seq
        }
        return page
    }

    // MARK: Plumbing

    private static func id(_ id: String) throws -> String {
        guard WireEncoding.id(hex: id) != nil else {
            throw ClientError.invalidArgument("An id is exactly 32 lowercase hex characters.")
        }
        return id
    }

    private static func encode(_ body: some Encodable) throws -> Data {
        try JSONEncoder().encode(body)
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, authenticated: Bool = true) async throws -> Response {
        try Self.decode(await perform(method, path, body: nil, authenticated: authenticated))
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String, body: some Encodable, authenticated: Bool = true
    ) async throws -> Response {
        try Self.decode(await perform(method, path, body: try Self.encode(body), authenticated: authenticated))
    }

    private static func decode<Response: Decodable>(_ payload: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            throw ProtocolViolationError("The server sent an answer that is not valid for this endpoint.")
        }
    }

    /// Sends one request and returns the body of a 2xx answer.
    private func perform(_ method: String, _ path: String, body: Data?, authenticated: Bool) async throws -> Data {
        guard let url = URL(string: base + path) else {
            throw ClientError.invalidArgument("The server address is not usable.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token else {
                throw ApiError(status: 401, code: ErrorCodes.unauthorized, message: "This device has no session token.")
            }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }

        let payload: Data
        let response: HTTPURLResponse
        do {
            (payload, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ServerUnreachableError {
            throw error
        } catch let error as URLError {
            // Only the error code: it names no request content.
            throw ServerUnreachableError(
                error.code == .timedOut ? "The server did not answer in time." : "The server could not be reached (\(error.code.rawValue)).")
        } catch {
            throw ServerUnreachableError("The server could not be reached.")
        }

        let status = response.statusCode
        if (200..<300).contains(status) {
            return payload
        }

        let error = try? JSONDecoder().decode(ErrorBody.self, from: payload)
        // Gateways in front of the server answer 502-504 without a protocol body: that is "unreachable".
        if error?.error == nil, (502...504).contains(status) {
            throw ServerUnreachableError("The server is unavailable (HTTP \(status)).")
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        throw ApiError(
            status: status, code: error?.error ?? "http_\(status)", message: error?.message ?? "HTTP \(status)", retryAfter: retryAfter)
    }
}
