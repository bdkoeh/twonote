import Foundation
import TwoNoteCrypto

// The wire types of PROTOCOL.md section 3. Field names are the protocol's camelCase names;
// binary values travel as base64url without padding; ids are 32 lowercase hex characters.

/// The server answered with a protocol error (PROTOCOL.md section 3, "Error codes").
public struct ApiError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The HTTP status.
    public let status: Int
    /// The protocol error code, e.g. `bad_signature` or `doc_deleted` (`http_<status>` when the body had none).
    public let code: String
    /// The server's human-readable text.
    public let message: String
    /// The `Retry-After` value of a 429 in seconds, when the server sent one.
    public let retryAfter: TimeInterval?

    public init(status: Int, code: String, message: String, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }

    public var description: String { "The server answered \(status) \(code)." }
}

/// The server could not be reached, or the connection failed before a complete answer arrived.
/// For a phone this is the normal state away from home, not a fault.
public struct ServerUnreachableError: Error, Sendable, CustomStringConvertible {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// The server answered with something PROTOCOL.md does not allow.
public struct ProtocolViolationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The protocol error codes a client reacts to.
public enum ErrorCodes {
    public static let unauthorized = "unauthorized"
    public static let badSignature = "bad_signature"
    public static let registrationClosed = "registration_closed"
    public static let unknownNotebook = "unknown_notebook"
    public static let unknownDoc = "unknown_doc"
    public static let noSnapshot = "no_snapshot"
    public static let unknownDevice = "unknown_device"
    public static let staleSnapshot = "stale_snapshot"
    public static let docDeleted = "doc_deleted"
    public static let rateLimited = "rate_limited"
}

/// A binary JSON value: base64url without padding on the wire, `Data` in Swift.
@propertyWrapper
public struct Base64URL: Codable, Equatable, Sendable {
    public var wrappedValue: Data

    public init(wrappedValue: Data) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let data = WireEncoding.data(base64URL: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Value is not base64url without padding.")
        }
        wrappedValue = data
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(WireEncoding.base64URLString(wrappedValue))
    }
}

/// `GET /status`.
public struct ServerStatus: Codable, Equatable, Sendable {
    public var version: String
    public var protocolVersion: Int
    public var registrationOpen: Bool

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case registrationOpen
    }
}

/// Body of `POST /register`.
public struct RegisterRequest: Codable, Sendable {
    public var username: String
    public var accountId: String
    @Base64URL public var kdfSalt: Data
    public var kdfParams: KdfParams
    @Base64URL public var authPublicKey: Data
    @Base64URL public var wrappedVaultKey: Data
    public var deviceName: String

    public init(
        username: String, accountId: String, kdfSalt: Data, kdfParams: KdfParams, authPublicKey: Data,
        wrappedVaultKey: Data, deviceName: String
    ) {
        self.username = username
        self.accountId = accountId
        self.kdfSalt = kdfSalt
        self.kdfParams = kdfParams
        self.authPublicKey = authPublicKey
        self.wrappedVaultKey = wrappedVaultKey
        self.deviceName = deviceName
    }
}

/// Answer of `POST /register`.
public struct DeviceSession: Codable, Sendable {
    public var deviceId: String
    public var token: String
}

/// Answer of `POST /auth/start`.
public struct AuthChallenge: Codable, Sendable {
    public var accountId: String
    @Base64URL public var kdfSalt: Data
    public var kdfParams: KdfParams
    public var challengeId: String
    @Base64URL public var nonce: Data
}

/// Answer of `POST /auth/finish`.
public struct AuthResult: Codable, Sendable {
    public var deviceId: String
    public var token: String
    @Base64URL public var wrappedVaultKey: Data
}

/// One entry of `GET /devices`.
public struct DeviceInfo: Decodable, Equatable, Identifiable, Sendable {
    public var deviceId: String
    public var name: String
    public var createdAt: Date
    public var lastSeenAt: Date
    public var current: Bool

    public var id: String { deviceId }

    private enum CodingKeys: String, CodingKey {
        case deviceId, name, createdAt, lastSeenAt, current
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        name = try c.decode(String.self, forKey: .name)
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
        createdAt = try Self.date(c, .createdAt)
        lastSeenAt = try Self.date(c, .lastSeenAt)
    }

    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
        let text = try c.decode(String.self, forKey: key)
        guard let date = WireDate.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not an ISO-8601 timestamp.")
        }
        return date
    }
}

/// ISO-8601 UTC timestamps with any number of fractional digits (the server writes seven).
enum WireDate {
    static func parse(_ text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text[text.index(after: dot)...]
            let digits = afterDot.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
            fraction = value
            whole = String(text[..<dot]) + afterDot.dropFirst(digits.count)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole)?.addingTimeInterval(fraction)
    }
}

/// Body of `POST /account/rekey`.
public struct RekeyRequest: Codable, Sendable {
    @Base64URL public var kdfSalt: Data
    public var kdfParams: KdfParams
    @Base64URL public var authPublicKey: Data
    @Base64URL public var wrappedVaultKey: Data

    public init(kdfSalt: Data, kdfParams: KdfParams, authPublicKey: Data, wrappedVaultKey: Data) {
        self.kdfSalt = kdfSalt
        self.kdfParams = kdfParams
        self.authPublicKey = authPublicKey
        self.wrappedVaultKey = wrappedVaultKey
    }
}

/// One entry of `GET /notebooks`.
public struct NotebookEntry: Codable, Equatable, Sendable {
    public var notebookId: String
    @Base64URL public var wrappedKey: Data
}

/// One entry of `GET /docs`. `snapshotSeq` is 0 when the document has no snapshot.
public struct DocEntry: Codable, Equatable, Sendable {
    public var docId: String
    public var notebookId: String
    public var snapshotSeq: Int64
}

/// One update in a push.
public struct OutgoingUpdate: Codable, Sendable {
    public var clientUpdateId: String
    @Base64URL public var blob: Data

    public init(clientUpdateId: String, blob: Data) {
        self.clientUpdateId = clientUpdateId
        self.blob = blob
    }
}

/// Answer of `POST /docs/{docId}/updates`.
public struct PushResult: Codable, Sendable {
    public var seqs: [Int64]
    public var head: Int64
}

/// A stored snapshot (`GET` and `PUT /docs/{docId}/snapshot`).
public struct SnapshotEntry: Codable, Sendable {
    public var coveredSeq: Int64
    @Base64URL public var blob: Data

    public init(coveredSeq: Int64, blob: Data) {
        self.coveredSeq = coveredSeq
        self.blob = blob
    }
}

/// Answer of `PUT /docs/{docId}/snapshot`.
public struct PutSnapshotResult: Codable, Sendable {
    public var seq: Int64
    public var head: Int64
}

/// One event of `GET /events`. Which fields are set depends on `type`.
public struct ServerEvent: Decodable, Sendable {
    public static let update = "update"
    public static let snapshot = "snapshot"
    public static let docDeleted = "docDeleted"
    public static let notebooksChanged = "notebooksChanged"

    public var seq: Int64
    public var type: String
    public var docId: String?
    public var notebookId: String?
    public var deviceId: String?
    public var blob: Data?
    public var coveredSeq: Int64?

    private enum CodingKeys: String, CodingKey {
        case seq, type, docId, notebookId, deviceId, blob, coveredSeq
    }

    init(seq: Int64, type: String, docId: String? = nil, notebookId: String? = nil, deviceId: String? = nil,
         blob: Data? = nil, coveredSeq: Int64? = nil) {
        self.seq = seq
        self.type = type
        self.docId = docId
        self.notebookId = notebookId
        self.deviceId = deviceId
        self.blob = blob
        self.coveredSeq = coveredSeq
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        type = try c.decode(String.self, forKey: .type)
        docId = try c.decodeIfPresent(String.self, forKey: .docId)
        notebookId = try c.decodeIfPresent(String.self, forKey: .notebookId)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        coveredSeq = try c.decodeIfPresent(Int64.self, forKey: .coveredSeq)
        if let text = try c.decodeIfPresent(String.self, forKey: .blob) {
            guard let data = WireEncoding.data(base64URL: text) else {
                throw DecodingError.dataCorruptedError(forKey: .blob, in: c, debugDescription: "Value is not base64url without padding.")
            }
            blob = data
        }
    }
}

/// Answer of `GET /events`.
public struct EventsPage: Decodable, Sendable {
    public var events: [ServerEvent]
    public var head: Int64
    public var more: Bool
}

struct HeadMessage: Codable, Sendable {
    var head: Int64
}

struct ErrorBody: Decodable {
    var error: String?
    var message: String?
}

struct AuthStartBody: Encodable {
    var username: String
}

struct AuthFinishBody: Encodable {
    var challengeId: String
    @Base64URL var signature: Data
    var deviceName: String
    var deviceId: String?
}

struct PutNotebookBody: Encodable {
    @Base64URL var wrappedKey: Data
}

struct PushBody: Encodable {
    var notebookId: String
    var updates: [OutgoingUpdate]
}

struct TokenHello: Encodable {
    var token: String
}
