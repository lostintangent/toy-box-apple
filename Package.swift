// swift-tools-version: 6.4
import PackageDescription

// Keep platform-specific executables and native tests out of the other platform's build graph.
let mobile = Context.environment["TOY_BOX_MOBILE"] == "1"

func simulatedEntitlements(_ bundleID: String) -> [LinkerSetting] {
    guard let directory = Context.environment["TOY_BOX_SIMULATOR_ENTITLEMENTS"] else { return [] }
    return [.unsafeFlags([
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
        "-Xlinker", "\(directory)/\(bundleID).plist",
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__ents_der",
        "-Xlinker", "\(directory)/\(bundleID).plist.der",
    ])]
}

let package = Package(
    name: "ToyBoxDesktop",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "ChannelKit", targets: ["ChannelKit"]),
        .library(name: "ChannelClient", targets: ["ChannelClient"]),
        .library(name: "ChannelIntelligence", targets: ["ChannelIntelligence"]),
        .library(name: "ToyBoxUI", targets: ["ToyBoxUI"]),
        .library(name: "ToyBoxWidgetViews", targets: ["ToyBoxWidgetViews"]),
    ] + (mobile ? [
        .executable(name: "ToyBoxMobile", targets: ["ToyBoxMobile"]),
        .executable(name: "ToyBoxMobileWidget", targets: ["ToyBoxMobileWidget"]),
        .executable(name: "ToyBoxMobileNotification", targets: ["ToyBoxMobileNotification"]),
        .executable(name: "ToyBoxMobileShare", targets: ["ToyBoxMobileShare"]),
    ] : [
        .executable(name: "ToyBoxDesktop", targets: ["ToyBoxDesktop"]),
        .executable(name: "ToyBoxShare", targets: ["ToyBoxShare"]),
        .executable(name: "ToyBoxWidget", targets: ["ToyBoxWidget"]),
    ]),
    dependencies: mobile ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "ChannelKit", path: "Sources/Shared/ChannelKit"),
        .target(name: "ChannelClient", dependencies: ["ChannelKit"], path: "Sources/Shared/ChannelClient"),
        .target(name: "ChannelIntelligence", dependencies: ["ChannelKit", "ChannelClient"],
                path: "Sources/Shared/ChannelIntelligence"),
        .target(name: "ToyBoxUI", dependencies: ["ChannelKit", "ChannelClient"], path: "Sources/Shared/ToyBoxUI"),
        .target(name: "ToyBoxWidgetViews", dependencies: ["ChannelKit"], path: "Sources/Shared/ToyBoxWidgetViews",
                swiftSettings: [.unsafeFlags(["-application-extension"])]),
    ] + (mobile ? [
        .target(name: "ToyBoxMobileIntegrations", dependencies: ["ChannelKit", "ChannelClient", "ToyBoxUI"],
                path: "Sources/Mobile/ToyBoxMobileIntegrations",
                swiftSettings: [.unsafeFlags(["-application-extension"])]),
        .executableTarget(name: "ToyBoxMobile", dependencies: [
            "ChannelClient", "ChannelIntelligence", "ToyBoxUI", "ToyBoxMobileIntegrations"
        ], path: "Sources/Mobile/ToyBoxMobile", linkerSettings: simulatedEntitlements("dev.toybox.mobile")),
        .executableTarget(
            name: "ToyBoxMobileWidget", dependencies: ["ChannelKit", "ToyBoxMobileIntegrations", "ToyBoxWidgetViews"],
            path: "Sources/Mobile/Extensions/ToyBoxMobileWidget",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
                + simulatedEntitlements("dev.toybox.mobile.widget")
        ),
        .executableTarget(
            name: "ToyBoxMobileNotification", dependencies: ["ChannelKit", "ToyBoxMobileIntegrations"],
            path: "Sources/Mobile/Extensions/ToyBoxMobileNotification",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
                + simulatedEntitlements("dev.toybox.mobile.notification")
        ),
        .executableTarget(
            name: "ToyBoxMobileShare", dependencies: ["ChannelKit", "ChannelClient", "ToyBoxUI", "ToyBoxMobileIntegrations"],
            path: "Sources/Mobile/Extensions/ToyBoxMobileShare",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
                + simulatedEntitlements("dev.toybox.mobile.share")
        ),
        .testTarget(name: "ToyBoxMobileTests", dependencies: ["ToyBoxMobile"], path: "Tests/Mobile/ToyBoxMobileTests"),
        .testTarget(name: "ToyBoxMobileIntegrationsTests",
                    dependencies: ["ChannelClient", "ChannelKit", "ToyBoxMobileIntegrations"],
                    path: "Tests/Mobile/ToyBoxMobileIntegrationsTests"),
        .testTarget(name: "ToyBoxMobileWidgetTests", dependencies: ["ToyBoxMobileWidget"],
                    path: "Tests/Mobile/Extensions/ToyBoxMobileWidgetTests"),
    ] : [
        .target(name: "ToyBoxControlIntents", path: "Sources/Desktop/ToyBoxControlIntents",
                swiftSettings: [.unsafeFlags(["-application-extension"])]),
        .executableTarget(
            name: "ToyBoxShare",
            path: "Sources/Desktop/Extensions/ToyBoxShare",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "ToyBoxWidget",
            dependencies: ["ChannelKit", "ToyBoxControlIntents", "ToyBoxWidgetViews"],
            path: "Sources/Desktop/Extensions/ToyBoxWidget",
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),
        .executableTarget(
            name: "ToyBoxDesktop",
            dependencies: [
                "ChannelKit", "ChannelClient", "ChannelIntelligence", "ToyBoxUI",
                "ToyBoxControlIntents",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Desktop/ToyBoxDesktop",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "ToyBoxDesktopTests", dependencies: ["ToyBoxDesktop"], path: "Tests/Desktop/ToyBoxDesktopTests"),
        .testTarget(name: "ToyBoxShareTests", dependencies: ["ToyBoxShare"],
                    path: "Tests/Desktop/Extensions/ToyBoxShareTests"),
        .testTarget(name: "ToyBoxWidgetTests", dependencies: ["ToyBoxWidget"],
                    path: "Tests/Desktop/Extensions/ToyBoxWidgetTests"),
    ]) + [
        .testTarget(
            name: "ChannelKitTests",
            dependencies: ["ChannelKit"],
            path: "Tests/Shared/ChannelKitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ChannelClientTests", dependencies: ["ChannelClient"], path: "Tests/Shared/ChannelClientTests"),
        .testTarget(name: "ToyBoxUITests", dependencies: ["ToyBoxUI"], path: "Tests/Shared/ToyBoxUITests"),
        .testTarget(
            name: "ChannelIntelligenceTests",
            dependencies: ["ChannelIntelligence"],
            path: "Tests/Shared/ChannelIntelligenceTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
