# TwoNote protocol v1

The contract between every client (Windows now, iOS later) and the server. Language-neutral.
If code and this file disagree, fix one of them in the same change.

## Conventions

- HTTP + JSON under `/api/v1`. Field names are camelCase.
- Binary values in JSON are **base64url without padding**.
- Ids (`accountId`, `deviceId`, `notebookId`, `docId`, `clientUpdateId`) are 16 random bytes,
  written as 32 lowercase hex characters in URLs, JSON and additional data.
- Authenticated requests carry `Authorization: Bearer <token>`.
- Errors: `{ "error": "<code>", "message": "<human text>" }` with a 4xx/5xx status.

## 1. Cryptography

Primitives (libsodium names): `crypto_pwhash` (Argon2id v1.3), HKDF-SHA256 (RFC 5869),
`crypto_sign` (Ed25519), `crypto_aead_xchacha20poly1305_ietf`.

### 1.1 Secret Key

16 random bytes. Display form: `T2-` followed by the 26-character Crockford base32 encoding
(no padding, uppercase), grouped `T2-XXXXXX-XXXXXX-XXXXXX-XXXXXXXX`. Bits are taken
most-significant first; the final symbol holds the last 3 bits followed by two zero bits.

Parsing ignores case, hyphens and all whitespace, maps `O→0`, `I→1`, `L→1`, and accepts input
with the `T2` prefix omitted. It rejects `U`, any other character, a wrong length, and a final
symbol whose low two bits are not zero.

### 1.2 Key derivation

Inputs: `password` (string), `secretKey` (16 bytes), `accountId` (16 bytes), `kdfSalt`
(16 bytes), `kdfParams = { "alg": "argon2id13", "ops": 3, "memKiB": 65536 }`.

```
k_pw      = Argon2id(UTF8(NFKC(password)), kdfSalt, ops, memKiB * 1024, outLen = 32)
k_sk      = HKDF-SHA256(ikm = secretKey, salt = accountId, info = "twonote/v1/2skd", len = 32)
root      = k_pw XOR k_sk
unlockKey = HKDF-SHA256(ikm = root, salt = (none), info = "twonote/v1/unlock", len = 32)
authSeed  = HKDF-SHA256(ikm = root, salt = (none), info = "twonote/v1/auth",   len = 32)
(authPublicKey, authPrivateKey) = Ed25519 key pair from seed authSeed
```

`info` strings are ASCII with no terminator. "salt = (none)" means the RFC 5869 default of
32 zero bytes. Argon2id parallelism is 1 (libsodium's fixed value).

A client receives `kdfParams` from the server, so it must refuse anything outside
`alg = "argon2id13"`, `ops` 1–16, `memKiB` 8192–1048576 rather than let a hostile server
dictate its memory use. Passwords containing unpaired surrogates are rejected. The public key
on the wire is the raw 32 bytes.

### 1.3 Sealed blob

Every encrypted value uses one format:

```
blob = 0x01 || nonce (24 random bytes) || XChaCha20-Poly1305(key, nonce, plaintext, aad)
aad  = UTF8("twonote/v1|" + kind + "|" + id)
```

| kind | key | id | plaintext |
|---|---|---|---|
| `vault` | unlockKey | accountId | vaultKey (32 random bytes) |
| `nbkey` | vaultKey | notebookId | notebookKey (32 random bytes) |
| `update` | notebookKey | docId | one Yjs v1 update |
| `snapshot` | notebookKey | docId | one Yjs v1 update encoding the full document state |

`id` in the additional data is the 32-character lowercase hex form. A `vault` or `nbkey` blob
whose plaintext is not exactly 32 bytes counts as a failed open.

A blob that fails to open is discarded and reported; it is never applied.

### 1.4 Login signature

`signature = Ed25519-Sign(authPrivateKey, UTF8("twonote/v1/login") || nonce)` where `nonce` is
the 32 bytes issued by `auth/start`.

### 1.5 Test vectors

`docs/test-vectors.json` holds fixed inputs and expected outputs for 1.1–1.4 (with a fixed
nonce for 1.3). Every client implementation must pass them. Binary values in that file are
lowercase hex, not the base64url used on the wire.

## 2. Server data model

One account per server. The server stores: the account record, devices and their tokens
(hashed), wrapped keys, and an event log. Every write to a document gets the next value of a
single account-wide counter, `seq` (starts at 1).

## 3. Endpoints

### Unauthenticated

`GET /api/v1/status` → `{ "version": "…", "protocol": 1, "registrationOpen": true }`

`POST /api/v1/register` — allowed only while no account exists (else `403 registration_closed`)
```
→ { username, accountId, kdfSalt, kdfParams, authPublicKey, wrappedVaultKey, deviceName }
← 201 { deviceId, token }
```

`POST /api/v1/auth/start`
```
→ { username }
← { accountId, kdfSalt, kdfParams, challengeId, nonce }
```
Challenges expire after 60 seconds and are single use. Unknown usernames get a deterministic
fake response so the endpoint does not reveal whether an account exists.

`POST /api/v1/auth/finish`
```
→ { challengeId, signature, deviceName, deviceId? }
← { deviceId, token, wrappedVaultKey }
```
`401 bad_signature` on failure. Failed attempts are rate limited per source address
(5 per minute, then `429`).

### Authenticated

`GET /api/v1/devices` → `[{ deviceId, name, createdAt, lastSeenAt, current }]`
`DELETE /api/v1/devices/{deviceId}` — revokes that device's token.

`POST /api/v1/account/rekey` → `{ kdfSalt, kdfParams, authPublicKey, wrappedVaultKey }`
Replaces the credentials after a password or Secret Key change. Other devices' tokens are
revoked.

`GET /api/v1/notebooks` → `[{ notebookId, wrappedKey }]`
`PUT /api/v1/notebooks/{notebookId}` → `{ wrappedKey }` (create or replace)
`DELETE /api/v1/notebooks/{notebookId}` — deletes the notebook, its documents and their events.

`GET /api/v1/docs` → `[{ docId, notebookId, snapshotSeq }]` (`snapshotSeq` is 0 when none)

`POST /api/v1/docs/{docId}/updates`
```
→ { notebookId, updates: [{ clientUpdateId, blob }] }
← { seqs: [n, …], head }
```
Creates the document on first use. Idempotent per `clientUpdateId`: a repeat returns the
original `seq`. `404 unknown_notebook` if the notebook does not exist; `410 doc_deleted` if the
document was deleted (see "Deletion" below).

`GET /api/v1/docs/{docId}/snapshot` → `{ coveredSeq, blob }` or `404`

`PUT /api/v1/docs/{docId}/snapshot` → `{ coveredSeq, blob }`
The snapshot must contain every update of that document with `seq ≤ coveredSeq`; the server
then deletes those update events and appends a `snapshot` event. `409` if `coveredSeq` is lower
than the stored one.

`DELETE /api/v1/docs/{docId}` — deletes the document, keeps a tombstone for its id and appends a
`docDeleted` event.

`GET /api/v1/events?after={seq}&limit={n}` (default 500, max 2000)
```
← { events: [
      { seq, type: "update",     docId, notebookId, deviceId, blob },
      { seq, type: "snapshot",   docId, notebookId, coveredSeq },
      { seq, type: "docDeleted", docId, notebookId },
      { seq, type: "notebooksChanged" } ],
    head, more }
```
Events are returned in `seq` order. A client keeps one cursor for the whole account.

### WebSocket

`GET /api/v1/ws`, then the client's first text frame is `{ "token": "…" }`. The server replies
`{ "head": n }` and sends `{ "head": n }` again each time `head` advances. The client reacts by
calling `/events`. No document data travels over the socket.

### Details that apply across endpoints

**Mutation responses**

| Request | Response |
|---|---|
| `PUT /notebooks/{id}`, `DELETE /notebooks/{id}`, `DELETE /docs/{id}` | 200 `{ head }` |
| `PUT /docs/{id}/snapshot` | 200 `{ seq, head }` |
| `DELETE /devices/{id}`, `POST /account/rekey` | 204 |

**Error codes**: 400 `invalid_request`; 401 `unauthorized`, `bad_signature` (also for an
expired, unknown or reused challenge); 403 `registration_closed`; 404 `unknown_notebook`,
`unknown_doc`, `no_snapshot`, `unknown_device`, `not_found`; 409 `stale_snapshot`,
`notebook_mismatch`, `update_id_conflict`; 410 `doc_deleted`; 413 `blob_too_large`,
`payload_too_large`; 429 `rate_limited` (with `Retry-After`); 500 `internal`.

**Limits**: blob ≤ 8 MiB; wrapped key ≤ 4096 bytes; ≤ 1000 updates per push and at least one;
request body ≤ 64 MiB; username ≤ 64 characters, matched case-insensitively after trimming;
device name ≤ 100 characters. JSON field names are case-sensitive; unknown fields are ignored.

**Timestamps** are ISO-8601 UTC strings. `lastSeenAt` is refreshed at most once a minute.

**Devices**: `auth/finish` with a known `deviceId` keeps that device, renames it and replaces
its token; an unknown well-formed id is created under that id. Revoked devices are removed
from `/devices`, and any open WebSocket of theirs is closed.

**Snapshots**: `snapshotSeq` in `GET /docs` is the stored snapshot's `coveredSeq`. A snapshot
needs `1 ≤ coveredSeq ≤ head`; a value equal to the stored one replaces it. Storing a snapshot
also removes that document's earlier `snapshot` events.

**Idempotency** survives compaction: a repeated `clientUpdateId` returns its original `seq`
even after a snapshot removed the update. The same id on a different document is
`409 update_id_conflict`.

**Deletion**: `DELETE /docs` removes that document's earlier events and appends `docDeleted`.
The server keeps a tombstone for the deleted id: every later push to it is answered
`410 doc_deleted` (including a retry of a `clientUpdateId` that had been acknowledged before
the deletion), so a device that was offline during the deletion cannot re-create the document.
The client reacts by dropping its outbox for that document and the local document. Other
requests for a deleted document answer as for one that never existed (`404 unknown_doc`,
`404 no_snapshot`).
`DELETE /notebooks` removes all events of its documents and appends only `notebooksChanged`;
clients drop local documents of a notebook that has vanished. The tombstones of that
notebook's documents go with it: a push into a deleted notebook is `404 unknown_notebook`, and
the client drops the notebook, its documents and their outbox once `GET /notebooks` confirms
it is gone. `notebooksChanged` is appended on create, replace and delete; a `PUT` with an
identical `wrappedKey` changes nothing.

**Paging**: `limit` above 2000 is clamped. A page is also cut once its blobs exceed 16 MiB, so
it may hold fewer than `limit` events while `more` is true.

**WebSocket**: policy violations close with code 1008. Head notifications may be coalesced
(the latest always arrives) and are also sent to the device that caused them.

**Rate limiting** is keyed on the TCP peer address; `X-Forwarded-For` is not trusted, so
clients behind one proxy share a limit.

## 4. Client sync algorithm

1. First sync on a device: `GET /notebooks`, `GET /docs`, fetch and apply every snapshot, then
   read `/events` from 0.
2. Afterwards: read `/events?after=cursor` until `more` is false, applying each event, and
   store the new cursor in the same local transaction as the applied data.
   - `update`: open the blob and merge it. Events from this device are skipped by
     `clientUpdateId`/`deviceId` (so a `deviceId` belongs to exactly one local store: a device
     that lost its store enrols under a new id).
   - `snapshot`: fetch and merge the snapshot (merging is idempotent, so always safe).
   - `docDeleted`: drop the local document.
   - `notebooksChanged`: re-read `/notebooks`.
   Events are applied strictly in `seq` order. A CRDT delete that arrives before the text it
   deletes stays pending and the replica silently differs until a later snapshot merge, so
   order is a correctness requirement, not an optimisation. A page of events whose `seq`
   values are not strictly increasing is refused as a whole. When `more` is false the cursor
   becomes `head` (any events in between were removed by a snapshot or a deletion).
3. Local edits are sealed, written to a local outbox, then pushed in the order they were made
   (across documents too; consecutive edits to one document may share a request). An update
   leaves the outbox only after the server acknowledges it; a push that got no answer is
   repeated with the same `clientUpdateId`s. A notebook created locally is `PUT` before the
   first push into it. `410 doc_deleted` and `404 unknown_notebook` are handled as described
   under "Deletion" in section 3. A sync cycle pulls before it pushes.
4. Compaction: when a document has more than 200 un-snapshotted updates and the device has
   applied every event up to `head`, it uploads a snapshot with `coveredSeq = head`. A device
   that had to discard a blob of that document (1.3) does not snapshot it, because its copy
   may be incomplete. `409 stale_snapshot` means another device was faster; ignore it.

## 5. Document format (Yjs)

All documents are Yjs documents; updates use the Yjs **v1** update encoding.

### 5.1 Notebook tree document (`docId == notebookId`)

| Root | Type | Contents |
|---|---|---|
| `meta` | Map | `title: string`, `formatVersion: 1` |
| `sections` | Map | sectionId → Map `{ title: string, order: string, deleted: bool }` |
| `pages` | Map | pageId → Map `{ sectionId: string, title: string, order: string, deleted: bool, createdAt: number, updatedAt: number }` |

`pageId` is also the `docId` of that page's document; `sectionId` has the same form (32
lowercase hex characters). Deletion is the `deleted` flag (so a concurrent edit cannot resurrect
a half-deleted item); the page document itself is removed later by `DELETE /docs`.
`createdAt` and `updatedAt` are milliseconds since the Unix epoch.

`order` is a fractional index string: one or more characters from `0-9A-Za-z`, not ending in
`0`, read as the digits of a base-62 fraction. Items sort by `order` compared byte by byte
(which is the numeric order), ties by id compared the same way. To place an item, a client
writes any valid string that sorts strictly between its two neighbours (`V` for the first item
of an empty list). When the neighbours have equal `order` values, the item goes after the
tied group. A client skips `order` values it cannot parse when choosing neighbours.

### 5.2 Page document

| Root | Type | Contents |
|---|---|---|
| `meta` | Map | `formatVersion: 1` |
| `containers` | Map | containerId → Map `{ kind: "flow" }` (metadata only) |
| `c:<containerId>` | Text | the content of that container |

Each container's text is a **root-level** Text named `c:` + its id, never a value nested in a
Map: root types exist implicitly, so two devices that both initialise a page cannot replace
each other's text. The device that creates a page writes `meta`, the `containers` entry and
the first newline; a device that merely opens a page writes nothing. v1 pages have exactly one container with the fixed id `main` (text
`c:main`). A future canvas adds containers with `kind: "box"` and `x`, `y`, `width`; v1 clients
ignore containers they do not understand.

General rules:

- Text indexes are UTF-16 code units. A client never splits a surrogate pair.
- Numbers (`indent`, `formatVersion`, timestamps) are written as doubles, never BigInt.
- Clients preserve block values and attributes they do not recognise.

The Text holds the whole container, Quill-delta style:

- Inline formatting is attributes on character runs: `bold`, `italic`, `underline`, `strike`,
  `code` (all `true` when set), `link` (URL string).
- Every paragraph ends with `"\n"`. Block formatting is attributes on that newline:
  `block`: `"h1" | "h2" | "h3" | "ul" | "ol" | "todo" | "code"` (absent = paragraph),
  `indent`: integer 0–8, `checked`: bool (for `todo`).
  A block change writes `block`, `indent` and `checked` together; `checked` only counts when
  `block` is `todo`. A default value (paragraph, indent 0, unchecked) is written as `null`,
  which removes the attribute.
- Inline attributes on the newline are meaningful: they are the formatting of the paragraph
  mark, which drives the list marker and text typed into an empty paragraph.
- The text always ends with a newline. The final newline is never deleted, and nothing is
  inserted after it. A client that finds it missing appends one as part of its next edit (not
  merely on opening the page, whose content may simply not have arrived yet).
- A soft line break inside a paragraph is U+2028.
