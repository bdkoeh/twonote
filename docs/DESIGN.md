# TwoNote — design

A simpler OneNote for Windows: self-hosted on Docker, end-to-end encrypted so the server only
ever stores ciphertext.

## Scope

| Area | Decision |
|---|---|
| Page model | Rich-text pages; the format leaves room for a free-form canvas later |
| Content | Formatted text and lists (headings, bold/italic, bullets, numbers, to-dos, links, code). No images, tables or attachments yet |
| Users | One user, several devices. No sharing |
| Windows client | WinUI 3 / .NET |
| Sync | Offline-first; edits from two devices merge automatically (encrypted CRDT) |
| Unlock | Master password + Secret Key, printable Emergency Kit |
| Network | LAN and VPN |
| Later | Other clients (iOS), so protocol, crypto and document format stay language-neutral |

## Components

```
TwoNote.App      WinUI 3 shell: notebook/section/page navigation, editor, unlock, settings
TwoNote.Core     .NET library: crypto, key hierarchy, document model, local store, sync client
TwoNote.Server   ASP.NET Core + SQLite, one container: auth, ciphertext log, WebSocket fan-out
docs/PROTOCOL.md Language-neutral wire format, crypto spec and test vectors
```

The server is deliberately dumb. It authenticates devices, appends opaque blobs to per-document
logs and tells other devices that something new arrived. It cannot merge, search or read anything.

## Encryption

Primitives come from libsodium, which has maintained bindings for both .NET and Swift.

**Two-secret key derivation**

- Secret Key: 128 random bits generated on the first device, shown as `T2-XXXXXX-XXXXXX-...`,
  stored in the Windows Credential Locker and printed on the Emergency Kit.
- `k_pw = Argon2id(NFKC(password), salt, 64 MiB, 3 passes)`
- `k_sk = HKDF-SHA256(secretKey, salt = accountId)`
- `root = k_pw XOR k_sk`
- `unlockKey` and `authSeed` are two separate HKDF outputs of `root`

Exact parameters and labels are in `docs/PROTOCOL.md` section 1.2.

A stolen server database cannot be brute-forced against the password alone, because the Secret
Key never leaves the devices.

**Login without a password-equivalent on the server**

`authSeed` becomes an Ed25519 key pair. The server stores only the public key and logs a device
in by having it sign a fresh nonce, then issues a per-device session token. Nothing replayable
crosses the wire (this matters because LAN deployments may run plain HTTP), and a database leak
does not let anyone log in.

**Key hierarchy**

```
unlockKey ──wraps──> vaultKey (random 256-bit)
vaultKey  ──wraps──> notebookKey (random, one per notebook)
notebookKey ──encrypts──> every update and snapshot of that notebook's documents
```

- All encryption is XChaCha20-Poly1305 with random nonces; the additional data binds each blob
  to its document id and kind, so the server cannot swap blobs between documents.
- Changing the password re-wraps `vaultKey` only.
- Per-notebook keys cost nothing now and are what sharing would need later.

**What the server can still see**: number of documents, blob sizes, timing, device ids. Not
titles, structure or content — the notebook tree is itself an encrypted document.

**No recovery**: lose the password and every copy of the Secret Key and the notes are gone. The
Emergency Kit is the only safety net.

**Not audited**: the design uses standard primitives in standard ways, but it has had no
independent security review.

## Documents and live merge

- CRDT: **Yrs** (the Rust port of Yjs) through YDotNet on Windows; YSwift wraps the same core for
  a future iOS client, so both would share one binary update format.
- One CRDT document per notebook holds the tree (sections, pages, titles, order).
- One CRDT document per page holds content.
- Page content is a set of **containers**, each one rich-text stream (inline formatting on
  character runs, paragraph formatting on the newline that ends each paragraph). That shape
  maps directly onto a rich-text control and merges character by character. Pages currently
  have exactly one flow container. A later canvas adds containers with `x, y, width` without
  changing the format.

## Sync protocol

- Each account has an append-only event log on the server: `(seq, docId, deviceId, ciphertext)`.
- A client pushes encrypted CRDT updates, pulls everything after its last seen `seq`, and holds a
  WebSocket open to be told when to pull.
- Compaction: a client uploads an encrypted snapshot covering updates up to `seq N`; the server
  then drops those updates.
- Offline: edits queue in the local store and push on reconnect. Events are applied strictly in
  order; CRDT merge then makes concurrent edits converge without conflict copies.

## Local storage

SQLite per device holding the same ciphertext the server holds, plus an outbox. Decrypted
content exists only in memory while unlocked. Search is an in-memory index built on demand.

## Server and deployment

- One image, one volume (`/data` with the SQLite file), one port. An Unraid template is included.
- Registration is open only until the first account exists.
- TLS is optional (LAN/VPN), but login rate limiting is on regardless.
- Backup = copy `/data`. It is all ciphertext.

## The editor

WinUI 3's `RichEditBox` was not designed to be driven by a CRDT. The binding in
`src/TwoNote.App/Editor` works by reconciliation: a shadow model holds the last state the control
and the CRDT agreed on, local changes are found by diffing the control against it, and remote
changes are applied as ranged edits that keep the caret and scroll position stable. Native undo
is off; undo goes through the CRDT so it only undoes your own edits.

The app's self-test (`src/TwoNote.App/run-selftest.ps1`) checks control = shadow = document after
every step, including randomised concurrent edits between two editors.

## Open items

- Real IME input, mouse drag-and-drop of text, touch and pen are untested.
- To-do checkboxes rely on undocumented RichEdit list-marker behaviour.
- Code blocks get a monospace font and a background behind the text only.
- Notebooks cannot be deleted from the UI, and deleted sections and pages cannot be restored.
- There is no way yet to seed a fresh server from a device if the server's data is lost.
- The Unraid template has not been tried on a real Unraid server.
- No installer, no automatic updates, and the app is unsigned.
- Secrets sit in the Windows Credential Locker, which any process of the same Windows user
  can read.

## Licensing and accounts

Nothing in the toolchain or the dependencies needs a paid licence, a sign-in or an account. The
app is built with the `dotnet` command line only; Visual Studio is not needed. .NET, ASP.NET
Core, Geralt and YDotNet/Yrs are MIT; libsodium is ISC; SQLite is public domain.

**Exception: the Windows App SDK (WinUI 3).** Its NuGet package is not MIT. It ships under the
proprietary "Microsoft Software License Terms": free, no account or sign-in, redistribution of
its files with the app is allowed, use is limited to Windows, and the terms say the software
"may collect information about you and your use of the software, and send that to Microsoft".
It is the only dependency that is not permissively licensed.
