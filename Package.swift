// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexProviderSyncMacApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexProviderSyncMacApp", targets: ["CodexProviderSyncMacApp"])
    ],
    targets: [
        .executableTarget(
            name: "CodexProviderSyncMacApp",
            path: "Sources/CodexSyncMacApp"
        )
    ]
)
