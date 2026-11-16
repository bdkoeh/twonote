// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TwoNoteKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15), // so `swift test` runs on the build host
    ],
    products: [
        .library(name: "TwoNoteCrypto", targets: ["TwoNoteCrypto"]),
        .library(name: "TwoNoteDocuments", targets: ["TwoNoteDocuments"]),
        .library(name: "TwoNoteEditor", targets: ["TwoNoteEditor"]),
    ],
    dependencies: [
        // ISC licence. Only its Clibsodium product (libsodium's C API) is used.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.9.1"),
    ],
    targets: [
        .target(
            name: "TwoNoteCrypto",
            dependencies: [
                .product(name: "Clibsodium", package: "swift-sodium"),
            ]
        ),
        // The document interfaces the app is written against (no dependencies).
        .target(name: "TwoNoteDocuments"),
        // The page editor: shadow model and reconciliation (any platform), an in-memory page for
        // tests, and the UITextView binding (UIKit only).
        .target(name: "TwoNoteEditor", dependencies: ["TwoNoteDocuments"]),
        .testTarget(
            name: "TwoNoteEditorTests",
            dependencies: ["TwoNoteEditor", "TwoNoteDocuments"]
        ),
        .testTarget(
            name: "TwoNoteCryptoTests",
            dependencies: ["TwoNoteCrypto"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
