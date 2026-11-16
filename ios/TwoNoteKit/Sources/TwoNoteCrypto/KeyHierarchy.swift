import Foundation

/// unlockKey wraps vaultKey; vaultKey wraps one notebookKey per notebook; a notebookKey seals
/// that notebook's updates and snapshots (PROTOCOL.md 1.3). Every result is a sealed blob,
/// ready for the wire after base64url encoding.
///
/// The `open`/`unwrap` functions throw ``SealedBlobError`` for a blob that must be discarded
/// and ``CryptoInputError`` for a key or id of the wrong length.
public enum KeyHierarchy {
    /// Length of vaultKey and notebookKey in bytes.
    public static let keyLength = SealedBlob.keyLength

    /// Generates a random vaultKey.
    public static func createVaultKey() -> SecretBytes { .random(count: keyLength) }

    /// Generates a random notebookKey.
    public static func createNotebookKey() -> SecretBytes { .random(count: keyLength) }

    // MARK: keys

    /// Seals vaultKey under unlockKey, bound to the account.
    public static func wrapVaultKey(
        unlockKey: SecretBytes, accountId: Data, vaultKey: SecretBytes
    ) throws(CryptoInputError) -> Data {
        try SealedBlob.sealKey(vaultKey, under: unlockKey, kind: .vault, id: accountId)
    }

    /// Opens a wrapped vaultKey. Failure means wrong password or Secret Key, wrong account, or
    /// a damaged blob.
    public static func unwrapVaultKey(
        unlockKey: SecretBytes, accountId: Data, wrappedVaultKey: Data
    ) throws -> SecretBytes {
        try SealedBlob.openKey(key: unlockKey, kind: .vault, id: accountId, blob: wrappedVaultKey)
    }

    /// Seals notebookKey under vaultKey, bound to the notebook.
    public static func wrapNotebookKey(
        vaultKey: SecretBytes, notebookId: Data, notebookKey: SecretBytes
    ) throws(CryptoInputError) -> Data {
        try SealedBlob.sealKey(notebookKey, under: vaultKey, kind: .notebookKey, id: notebookId)
    }

    /// Opens a wrapped notebookKey. Failure means the wrong vaultKey or notebook, or a damaged
    /// blob.
    public static func unwrapNotebookKey(
        vaultKey: SecretBytes, notebookId: Data, wrappedNotebookKey: Data
    ) throws -> SecretBytes {
        try SealedBlob.openKey(key: vaultKey, kind: .notebookKey, id: notebookId, blob: wrappedNotebookKey)
    }

    // MARK: documents

    /// Seals one Yjs v1 update of the document `docId`.
    public static func sealUpdate(
        notebookKey: SecretBytes, docId: Data, update: Data
    ) throws(CryptoInputError) -> Data {
        try SealedBlob.seal(key: notebookKey, kind: .update, id: docId, plaintext: update)
    }

    /// Opens an `update` blob of the document `docId`.
    public static func openUpdate(notebookKey: SecretBytes, docId: Data, blob: Data) throws -> Data {
        try SealedBlob.open(key: notebookKey, kind: .update, id: docId, blob: blob)
    }

    /// Seals a full-state Yjs v1 update of the document `docId`.
    public static func sealSnapshot(
        notebookKey: SecretBytes, docId: Data, snapshot: Data
    ) throws(CryptoInputError) -> Data {
        try SealedBlob.seal(key: notebookKey, kind: .snapshot, id: docId, plaintext: snapshot)
    }

    /// Opens a `snapshot` blob of the document `docId`.
    public static func openSnapshot(notebookKey: SecretBytes, docId: Data, blob: Data) throws -> Data {
        try SealedBlob.open(key: notebookKey, kind: .snapshot, id: docId, blob: blob)
    }
}
