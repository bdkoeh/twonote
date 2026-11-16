# TwoNote for iOS and macOS

Native TwoNote clients for the iPhone/iPad and the Mac (SwiftUI and AppKit), with the same
end-to-end encryption, sync protocol (`../docs/PROTOCOL.md`) and Yjs documents as the Windows
client. This folder holds the Swift packages, both Xcode projects (as XcodeGen specs) and the
scripts that build and test them.

## Requirements

- A Mac with Apple Silicon. Everything is built for arm64 only (the Rust library, the
  simulator slice and the Mac app); Intel Macs are not supported.
- Xcode 27.1 with the iOS 27.1 simulator runtime (verified with Xcode 27.1 build 27A9269 on
  macOS 27.2). The apps' deployment targets are iOS 27.1 and macOS 27.0; the Swift packages
  alone build for iOS 18 / macOS 15.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`; 2.44.1 was used).
  The `.xcodeproj` files are generated, not committed.
- Rust through rustup (`brew install rustup`, `rustup default stable`) with the three Apple
  targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin`.
  Only needed to build `YrsKit/Yrs.xcframework` once (see below).
- Docker, only for the end-to-end runs: they start the TwoNote server from the image
  `twonote-server:latest`, built from the repository root with
  `docker build -f deploy/Dockerfile -t twonote-server:latest .`
- Python 3 (the end-to-end runs' small control helpers; the one that ships with the Xcode
  command line tools is enough).
- An Apple developer account only for installing on an iPhone, and for the Mac app's
  data-protection Keychain and Touch ID. Simulator builds and an ad hoc signed Mac build need
  none.

## What is here

| Folder | What it is |
| --- | --- |
| `TwoNoteKit/` | Swift package: `TwoNoteCrypto` (the key hierarchy and envelopes on libsodium, through swift-sodium's `Clibsodium`), `TwoNoteDocuments` (the document interfaces the apps are written against), `TwoNoteEditor` (the page editor's model and its UITextView binding). |
| `YrsKit/` | Swift package: the Yjs documents on the official y-crdt C library (yffi), the same engine and release line (0.26) the Windows client uses. `build-xcframework.sh` builds `Yrs.xcframework` from a pinned y-crdt commit. |
| `TwoNoteCore/` | Swift package: the client core (API client, live head listener, local SQLite store, vault, sync engine), a port of `src/TwoNote.Core`. |
| `TwoNote/` | The iOS app (XcodeGen `project.yml`): the app, a share extension and a widget, unit tests and UI (end-to-end) tests. |
| `TwoNoteMac/` | The native Mac app (XcodeGen `project.yml`): app, share extension, widget, unit tests and an XCUITest version of the end-to-end run. It compiles the iOS app's model code (`../TwoNote/Sources/Model`, `../TwoNote/Shared`) with its own views. |
| `Config/` | `TwoNote.xcconfig`, the identity and signing settings both projects use, and `Local.xcconfig.example` for your own values. |
| `tools/` | Shared scripts: `config.sh` (the identity, for the other scripts), `check-config.sh`, `gui-job.sh` (runs a command in the logged-in desktop session), `device-install.sh` / `device-install-job.sh` (build and install on an iPhone). |

`Spikes/EditorSpike` is the early editor experiment (two replicas of one page side by side). It is
not needed to build the apps, but its tests are the UIKit editor binding's tests.

## Identity and signing

Every bundle id, App Group, Keychain access group and notification name is derived from two
settings in `Config/`:

| Setting | Default (`TwoNote.xcconfig`) | Yours (`Local.xcconfig`) |
| --- | --- | --- |
| `DEVELOPMENT_TEAM` | empty: no team | your team id |
| `TWONOTE_BUNDLE_PREFIX` | `com.example.twonote` | a prefix you own |

From those, with prefix `P` and team `T`:

- iOS: `P.app`, `P.app.share`, `P.app.widget`; App Group `group.P.app`.
- Mac: `P.mac`, `P.mac.share`, `P.mac.widget`; App Group and Keychain access group `T.P.mac`
  (team-prefixed, the Mac's form, which needs no App Group registered in the developer account).

The entitlements files expand these as build settings, and each bundle's Info.plist carries
the App Group (`TwoNoteAppGroup`) and the notification prefix (`TwoNoteNotificationPrefix`),
which `TwoNote/Shared/SharedContainer.swift` reads at run time. The URL scheme is always
`twonote://`.

Without a team (no `Local.xcconfig`):

- the iOS app builds and runs in the simulator (signed ad hoc there, as always); iPhone builds
  are not possible;
- the Mac app is signed ad hoc ("Sign to Run Locally") with
  `TwoNoteMac/Entitlements/TwoNoteMac-NoTeam.entitlements`, which leaves out the Keychain
  access group (a restricted entitlement that needs a provisioning profile). Such a build keeps
  its secrets in the login keychain and offers no Touch ID; the unit tests of the real
  data-protection Keychain are skipped. It is for running on the Mac that built it.

`xcodegen` prints which team and prefix it generates with, and what to do when none is set.

## Building

All commands run on the Mac, from this `ios/` folder.

1. Build the y-crdt library (once, and again only when `YCRDT_COMMIT` in the script changes;
   it clones y-crdt into `YrsKit/.build`):

   ```sh
   bash YrsKit/build-xcframework.sh
   ```

2. Set your identity (skip this for simulator-only work):

   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   # edit DEVELOPMENT_TEAM and TWONOTE_BUNDLE_PREFIX
   ```

3. Generate the projects:

   ```sh
   (cd TwoNote && xcodegen)
   (cd TwoNoteMac && xcodegen)
   ```

   Then open `TwoNote/TwoNote.xcodeproj` or `TwoNoteMac/TwoNoteMac.xcodeproj` in Xcode, or use
   the scripts below (they run `xcodegen` themselves). Run `xcodegen` again after changing
   `Local.xcconfig` or a `project.yml`.

4. Install:
   - iPhone: pair it with the Mac, then
     `TWONOTE_DEVICE=<id from xcrun devicectl list devices> bash tools/device-install.sh TwoNote TwoNote`
     (over SSH use `tools/device-install-job.sh` with the same arguments: signing needs the
     desktop session's keychain). Needs `DEVELOPMENT_TEAM`.
   - Mac: `bash TwoNoteMac/tools/install-mac.sh` builds the Release app and installs it as
     `~/Applications/TwoNote.app`. With a team, the Mac must be registered in your developer
     account so that automatic signing can make the development provisioning profile.

Signing does not work from an SSH session (the signing key is out of reach:
`errSecInternalComponent`). The Mac scripts notice an SSH session and hand themselves to
`tools/gui-job.sh`, which runs them as a launchd job in the logged-in user's desktop session and
waits for them, so someone has to be logged in on the Mac.

## Tests

| What | Command | Needs |
| --- | --- | --- |
| Swift packages | `swift test` in `TwoNoteKit`, `YrsKit`, `TwoNoteCore` | the xcframework (YrsKit, TwoNoteCore) |
| iOS unit tests (in-memory server) | `TwoNote/tools/test.sh -only-testing:TwoNoteTests` | an iOS 27.1 simulator: `TWONOTE_SIM="<name>"` (default "iPhone Duo") |
| iOS end-to-end (the app in the simulator, against a server container, with a second device in the test process) | `TwoNote/tools/e2e.sh` | Docker, `twonote-server:latest` |
| Mac unit tests | `bash TwoNoteMac/tools/test-mac.sh` | |
| Mac end-to-end (the real signed app against a server container) | `bash TwoNoteMac/tools/e2e-mac.sh` | Docker, a team (`Local.xcconfig`) |

The end-to-end runs start their own container (`twonote-ios-app-e2e` on port 18090,
`twonote-mac-e2e` on 127.0.0.1:18190), remove it afterwards and touch no other container.
Screenshots go to `TwoNote/shots` and `TwoNoteMac/shots` (`TWONOTE_SHOTS=` turns them off);
logs to each project's `.build/`.

`TwoNoteCore`'s `ContainerE2ETests` run only when `TWONOTE_E2E_URL` points at a fresh server.

The Mac end-to-end run uses the same bundle id as an installed TwoNote, so it shares its
container, Keychain items and App Group and wipes them; it refuses to start while TwoNote on
that Mac is signed in.

## Known limitations

- Apple Silicon only.
- The Mac share extension is not in the Share menu until the user switches it on once, in
  System Settings' extensions settings (Sharing), which the Share menu's "Edit Extensions..."
  also opens.
- Touch ID and the data-protection Keychain on the Mac need a build signed with a team and a
  development provisioning profile, i.e. the Mac registered in the team's account. An ad hoc
  build falls back to the login keychain without Touch ID.
- XCUITest on the Mac needs macOS "automation mode", which an administrator has to confirm on
  screen the first time. `e2e-mac.sh` therefore drives the app from inside instead
  (`Sources/Debug/EndToEndDriver*.swift`); `TWONOTE_E2E_XCUITEST=1` runs the XCUITest version
  once that has been confirmed.
- Signing builds must run in a logged-in desktop session (see Building).

## Third-party code

- [y-crdt](https://github.com/y-crdt/y-crdt) (yrs and its C bindings yffi), MIT licence. Built
  from source by `YrsKit/build-xcframework.sh`; its header is copied into
  `YrsKit/Sources/CYrs/include/libyrs.h` with its licence notice.
- [swift-sodium](https://github.com/jedisct1/swift-sodium) and the
  [libsodium](https://libsodium.org) it bundles, ISC licence. Fetched by Swift Package Manager
  (pinned to 0.9.1 in `TwoNoteKit/Package.resolved`); only its `Clibsodium` product is used.
