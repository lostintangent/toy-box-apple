// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ToyBoxDesktop",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "ChannelKit", targets: ["ChannelKit"]),
        .library(name: "ChannelClient", targets: ["ChannelClient"]),
        .library(name: "ChannelIntelligence", targets: ["ChannelIntelligence"]),
        .executable(name: "ToyBoxDesktop", targets: ["ToyBoxDesktop"]),
    ],
    targets: [
        .target(name: "ChannelKit"),
        .target(name: "ChannelClient", dependencies: ["ChannelKit"]),
        .target(name: "ChannelIntelligence", dependencies: ["ChannelKit"]),
        .executableTarget(name: "ToyBoxDesktop", dependencies: ["ChannelKit", "ChannelClient", "ChannelIntelligence"]),
        .testTarget(
            name: "ChannelKitTests",
            dependencies: ["ChannelKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ChannelClientTests", dependencies: ["ChannelClient"]),
        .testTarget(name: "ToyBoxDesktopTests", dependencies: ["ToyBoxDesktop"]),
        .testTarget(
            name: "ChannelIntelligenceTests",
            dependencies: ["ChannelIntelligence"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
