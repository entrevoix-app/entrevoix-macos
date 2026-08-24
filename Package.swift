// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Entrevoix",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "Entrevoix",
            targets: ["Entrevoix"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/entrevoix-app/entrevoix-shared.git",
            exact: "0.1.0"
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts.git",
            exact: "1.10.0"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "Entrevoix",
            dependencies: [
                .product(name: "EntrevoixCore", package: "entrevoix-shared"),
                .product(name: "EntrevoixOpenAIAdapters", package: "entrevoix-shared"),
                .product(name: "EntrevoixAppleAdapters", package: "entrevoix-shared"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "EntrevoixCoreTests",
            dependencies: [
                .product(name: "EntrevoixCore", package: "entrevoix-shared")
            ]
        ),
        .testTarget(
            name: "EntrevoixTests",
            dependencies: [
                "Entrevoix",
                .product(name: "EntrevoixCore", package: "entrevoix-shared"),
                .product(name: "EntrevoixOpenAIAdapters", package: "entrevoix-shared"),
                .product(name: "EntrevoixAppleAdapters", package: "entrevoix-shared")
            ]
        )
    ]
)
