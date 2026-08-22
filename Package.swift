// swift-tools-version:6.0
import PackageDescription

// A clean SwiftUI macOS app template. One executable target, one test
// target, zero third-party dependencies — add your own under `dependencies`
// and wire them into the `CityDesk` target as you grow the app.
let package = Package(
    name: "CityDesk",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "CityDesk",
            path: "Sources/CityDesk",
            swiftSettings: [
                // Swift 6 strict concurrency from day one — cheaper to start
                // here than to retrofit it later.
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CityDeskTests",
            dependencies: ["CityDesk"],
            path: "Tests/CityDeskTests"
        ),
    ]
)
