// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EntrevoixShared",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "EntrevoixCore", targets: ["EntrevoixCore"]),
        .library(name: "EntrevoixOpenAIAdapters", targets: ["EntrevoixOpenAIAdapters"]),
        .library(name: "EntrevoixAppleAdapters", targets: ["EntrevoixAppleAdapters"])
    ],
    targets: [
        .target(name: "EntrevoixCore"),
        .target(name: "EntrevoixOpenAIAdapters", dependencies: ["EntrevoixCore"]),
        .target(name: "EntrevoixAppleAdapters", dependencies: ["EntrevoixCore"]),
        .testTarget(name: "EntrevoixCoreTests", dependencies: ["EntrevoixCore"]),
        .testTarget(
            name: "EntrevoixAdapterAPITests",
            dependencies: [
                "EntrevoixCore",
                "EntrevoixOpenAIAdapters",
                "EntrevoixAppleAdapters"
            ]
        )
    ]
)
