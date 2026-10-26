// swift-tools-version: 6.4
import PackageDescription

// Keep platform-specific executables and native tests out of the other platform's build graph.
let mobile = Context.environment["TOY_BOX_MOBILE"] == "1"

let package = Package(
    name: "ToyBoxDesktop",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "ChannelKit", targets: ["ChannelKit"]),
        .library(name: "ChannelClient", targets: ["ChannelClient"]),
        .library(name: "ChannelIntelligence", targets: ["ChannelIntelligence"]),
        .library(name: "ToyBoxUI", targets: ["ToyBoxUI"]),
    ] + (mobile ? [
        .executable(name: "ToyBoxMobile", targets: ["ToyBoxMobile"]),
    ] : [
        .executable(name: "ToyBoxDesktop", targets: ["ToyBoxDesktop"]),
        .executable(name: "ToyBoxShare", targets: ["ToyBoxShare"]),
        .executable(name: "ToyBoxWidget", targets: ["ToyBoxWidget"]),
    ]),
    dependencies: mobile ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "ChannelKit"),
        .target(name: "ChannelClient", dependencies: ["ChannelKit"]),
        .target(name: "ChannelIntelligence", dependencies: ["ChannelKit"]),
        .target(name: "ToyBoxUI", dependencies: ["ChannelKit", "ChannelClient"]),
    ] + (mobile ? [
        .executableTarget(name: "ToyBoxMobile", dependencies: ["ChannelClient", "ChannelIntelligence", "ToyBoxUI"]),
        .testTarget(name: "ToyBoxMobileTests", dependencies: ["ToyBoxMobile"]),
    ] : [
        .target(name: "ToyBoxControlIntents", swiftSettings: [.unsafeFlags(["-application-extension"])]),
        .executableTarget(
            name: "ToyBoxShare",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "ToyBoxWidget",
            dependencies: ["ChannelKit", "ToyBoxControlIntents"],
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),
        .executableTarget(
            name: "ToyBoxDesktop",
            dependencies: [
                "ChannelKit", "ChannelClient", "ChannelIntelligence", "ToyBoxUI",
                "ToyBoxControlIntents",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "ToyBoxDesktopTests", dependencies: ["ToyBoxDesktop"]),
        .testTarget(name: "ToyBoxShareTests", dependencies: ["ToyBoxShare"]),
        .testTarget(name: "ToyBoxWidgetTests", dependencies: ["ToyBoxWidget"]),
    ]) + [
        .testTarget(
            name: "ChannelKitTests",
            dependencies: ["ChannelKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ChannelClientTests", dependencies: ["ChannelClient"]),
        .testTarget(name: "ToyBoxUITests", dependencies: ["ToyBoxUI"]),
        .testTarget(
            name: "ChannelIntelligenceTests",
            dependencies: ["ChannelIntelligence"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
