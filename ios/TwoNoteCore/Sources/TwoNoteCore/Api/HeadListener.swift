import Foundation

/// One frame received from a WebSocket.
public enum WebSocketFrame: Sendable {
    case text(String)
    case binary(Data)
}

/// The peer closed the socket. `code` is the WebSocket close code (1008 = policy violation).
public struct WebSocketClosedError: Error, Sendable {
    public let code: Int

    public init(code: Int) {
        self.code = code
    }
}

/// An open WebSocket. `receive` throws `WebSocketClosedError` when the peer closes, any other
/// error when the connection breaks; `close` makes a pending `receive` throw.
public protocol WebSocketConnection: Sendable {
    func send(text: String) async throws
    func receive() async throws -> WebSocketFrame
    func close()
}

/// Opens WebSockets. The default uses `URLSessionWebSocketTask`; tests inject an in-memory server.
public protocol WebSocketConnector: Sendable {
    func connect(to url: URL) async throws -> any WebSocketConnection
}

/// The real connector. The handshake happens lazily: a server that cannot be reached shows up
/// as a failing first `send`.
public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func connect(to url: URL) async throws -> any WebSocketConnection {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let pinger = Locked<Task<Void, Never>?>(nil)

    init(task: URLSessionWebSocketTask) {
        self.task = task
        // URLSession sends no keep-alives by itself; without them a connection that died silently
        // (the phone left the Wi-Fi) would look open forever.
        let ping = Task { [task] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                task.sendPing { error in
                    if error != nil {
                        task.cancel(with: .abnormalClosure, reason: nil)
                    }
                }
            }
        }
        pinger.withLock { $0 = ping }
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> WebSocketFrame {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: return .binary(Data())
            }
        } catch {
            if task.closeCode != .invalid {
                throw WebSocketClosedError(code: task.closeCode.rawValue)
            }
            throw error
        }
    }

    func close() {
        pinger.withLock { $0?.cancel(); $0 = nil }
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Holds the `/ws` socket open (PROTOCOL.md section 3, "WebSocket") and reports every
/// `{ "head": n }` the server sends. Reconnects with exponential backoff and jitter for as long
/// as it runs. No document data travels over the socket; the listener only tells the sync
/// engine when to pull. Callbacks arrive on a background task.
public final class HeadListener: Sendable {
    private static let maxMessageBytes = 4096

    private struct State {
        var task: Task<Void, Never>?
        var connected = false
        var connectionCount = 0
    }

    private let url: URL
    private let token: @Sendable () -> String?
    private let connector: any WebSocketConnector
    private let initialBackoff: Duration
    private let maxBackoff: Duration
    private let onHead: @Sendable (Int64) -> Void
    private let onConnectionChanged: @Sendable (Bool) -> Void
    private let onRejected: @Sendable () -> Void
    private let state = Locked(State())

    /// - Parameters:
    ///   - url: the `ws://` or `wss://` address of `/api/v1/ws`.
    ///   - token: supplies the current session token on every (re)connect.
    ///   - connector: optional transport override (tests).
    ///   - initialBackoff: delay before the first reconnect; doubles up to `maxBackoff`.
    ///   - onHead: every head value the server sends, including the one right after connecting.
    ///   - onConnectionChanged: the socket became usable (true) or was lost (false).
    ///   - onRejected: the server closed the socket with code 1008 (token missing, unknown or revoked).
    public init(
        url: URL,
        token: @escaping @Sendable () -> String?,
        connector: (any WebSocketConnector)? = nil,
        initialBackoff: Duration = .seconds(1),
        maxBackoff: Duration = .seconds(30),
        onHead: @escaping @Sendable (Int64) -> Void,
        onConnectionChanged: @escaping @Sendable (Bool) -> Void = { _ in },
        onRejected: @escaping @Sendable () -> Void = {}
    ) {
        self.url = url
        self.token = token
        self.connector = connector ?? URLSessionWebSocketConnector()
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.onHead = onHead
        self.onConnectionChanged = onConnectionChanged
        self.onRejected = onRejected
    }

    /// True while an authenticated socket is open.
    public var isConnected: Bool { state.withLock { $0.connected } }

    /// Number of sockets opened so far (grows with every reconnect).
    public var connectionCount: Int { state.withLock { $0.connectionCount } }

    /// Starts connecting in the background. Does nothing if already running.
    public func start() {
        state.withLock { s in
            guard s.task == nil else { return }
            s.task = Task.detached { [self] in await run() }
        }
    }

    /// Closes the socket and stops reconnecting.
    public func stop() async {
        let task = state.withLock { s -> Task<Void, Never>? in
            let task = s.task
            s.task = nil
            return task
        }
        task?.cancel()
        await task?.value
    }

    private func run() async {
        var backoff = initialBackoff
        while !Task.isCancelled {
            let gotHead = await runOneConnection()
            setConnected(false)
            if gotHead {
                backoff = initialBackoff // the connection worked; the next drop starts over
            }
            do {
                // Jitter keeps several devices from reconnecting in step after a server restart.
                try await Task.sleep(for: backoff + backoff * Double.random(in: 0...0.25))
            } catch {
                break
            }
            backoff = min(maxBackoff, backoff * 2)
        }
        setConnected(false)
    }

    /// Returns true if at least one head arrived before the connection ended.
    private func runOneConnection() async -> Bool {
        guard let token = token() else { return false }
        let connection: any WebSocketConnection
        do {
            connection = try await connector.connect(to: url)
        } catch {
            return false
        }
        state.withLock { $0.connectionCount += 1 }
        defer { connection.close() }
        return await withTaskCancellationHandler {
            await listen(connection, token: token)
        } onCancel: {
            connection.close()
        }
    }

    private func listen(_ connection: any WebSocketConnection, token: String) async -> Bool {
        var gotHead = false
        do {
            let hello = try JSONEncoder().encode(TokenHello(token: token))
            try await connection.send(text: String(decoding: hello, as: UTF8.self))
            while !Task.isCancelled {
                guard case .text(let text) = try await connection.receive() else { continue }
                let bytes = Data(text.utf8)
                if bytes.count > Self.maxMessageBytes {
                    return gotHead // far larger than any head message: not our server
                }
                guard let message = try? JSONDecoder().decode(HeadMessage.self, from: bytes) else { continue }
                gotHead = true
                setConnected(true)
                onHead(message.head)
            }
        } catch let closed as WebSocketClosedError {
            if closed.code == 1008 {
                onRejected()
            }
        } catch {
            // Connection refused or dropped: reconnect.
        }
        return gotHead
    }

    private func setConnected(_ connected: Bool) {
        let changed = state.withLock { s -> Bool in
            guard s.connected != connected else { return false }
            s.connected = connected
            return true
        }
        if changed {
            onConnectionChanged(connected)
        }
    }
}
