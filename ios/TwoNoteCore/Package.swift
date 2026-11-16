// swift-tools-version: 6.0
import PackageDescription

// The client core of TwoNote for iOS: API client, head listener, local store, vault, sync
// engine and the client facade (the Swift port of src/TwoNote.Core). No third-party
// dependencies: Foundation, Observation, Network and the system SQLite3 module only.
let package = Package(
    name: "TwoNoteCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15), // so `swift test` runs on the build host
    ],
    products: [
        .library(name: "TwoNoteCore", targets: ["TwoNoteCore"]),
    ],
    dependencies: [
        .package(path: "../TwoNoteKit"),
        .package(path: "../YrsKit"),
    ],
    targets: [
        .target(
            name: "TwoNoteCore",
            dependencies: [
                .product(name: "TwoNoteCrypto", package: "TwoNoteKit"),
                .product(name: "TwoNoteDocuments", package: "TwoNoteKit"),
                .product(name: "YrsKit", package: "YrsKit"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TwoNoteCoreTests",
            dependencies: [
                "TwoNoteCore",
                .product(name: "TwoNoteCrypto", package: "TwoNoteKit"),
                .product(name: "TwoNoteDocuments", package: "TwoNoteKit"),
                .product(name: "YrsKit", package: "YrsKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
