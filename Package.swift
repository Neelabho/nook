// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Nook", targets: ["Nook"]),
    ],
    targets: [
        // Pure, testable logic: Shelf transactions, interaction state machine,
        // Ollama client, settings validation, Spotify parsing. No AppKit.
        .target(name: "NookCore", path: "Sources/NookCore"),
        // The AppKit/SwiftUI application shell.
        .executableTarget(
            name: "Nook",
            dependencies: ["NookCore"],
            path: "Sources/Nook",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "NookCoreTests", dependencies: ["NookCore"], path: "Tests/NookCoreTests"),
    ]
)
