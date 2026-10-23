// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ToyBoxChannels",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "ChannelKit", targets: ["ChannelKit"]),
        .library(name: "ChannelClient", targets: ["ChannelClient"]),
        .executable(name: "ToyBoxChannels", targets: ["ToyBoxChannels"]),
    ],
    targets: [
        .target(name: "ChannelKit"),
        .target(name: "ChannelClient", dependencies: ["ChannelKit"]),
        .executableTarget(name: "ToyBoxChannels", dependencies: ["ChannelKit", "ChannelClient"]),
        .testTarget(
            name: "ChannelKitTests",
            dependencies: ["ChannelKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ChannelClientTests", dependencies: ["ChannelClient"]),
        .testTarget(name: "ToyBoxChannelsTests", dependencies: ["ToyBoxChannels"]),
    ]
)
