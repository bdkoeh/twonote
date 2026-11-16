// swift-tools-version: 6.0
import PackageDescription

// The Yjs documents of PROTOCOL.md section 5, on the official y-crdt C library (yffi): the
// same engine and release line the Windows client uses through YDotNet.
//
// Yrs.xcframework is built on the Mac by ./build-xcframework.sh and is not committed.
let package = Package(
    name: "YrsKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15), // so `swift test` runs on the build host
    ],
    products: [
        .library(name: "YrsKit", targets: ["YrsKit"]),
    ],
    dependencies: [
        .package(path: "../TwoNoteKit"),
    ],
    targets: [
        .binaryTarget(name: "YrsBinary", path: "Yrs.xcframework"),
        // The C header of the library (MIT, copied from y-crdt by build-xcframework.sh).
        .target(name: "CYrs", dependencies: ["YrsBinary"]),
        .target(
            name: "YrsKit",
            dependencies: [
                "CYrs",
                .product(name: "TwoNoteDocuments", package: "TwoNoteKit"),
            ]
        ),
        .testTarget(name: "YrsKitTests", dependencies: ["YrsKit", "CYrs"]),
    ],
    swiftLanguageModes: [.v6]
)
