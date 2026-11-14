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
        .library(name: "ToyBoxKit", targets: ["ToyBoxKit"]),
        .library(name: "ToyBoxClient", targets: ["ToyBoxClient"]),
        .library(name: "ToyBoxIntelligence", targets: ["ToyBoxIntelligence"]),
        .library(name: "ToyBoxUI", targets: ["ToyBoxUI"]),
        .library(name: "ToyBoxWidgetViews", targets: ["ToyBoxWidgetViews"]),
    ] + (mobile ? [
        .executable(name: "ToyBoxMobile", targets: ["ToyBoxMobile"]),
        .executable(name: "ToyBoxMobileWidget", targets: ["ToyBoxMobileWidget"]),
        .executable(name: "ToyBoxMobileNotification", targets: ["ToyBoxMobileNotification"]),
        .executable(name: "ToyBoxMobileShare", targets: ["ToyBoxMobileShare"]),
    ] : [
        .executable(name: "ToyBoxDesktop", targets: ["ToyBoxDesktop"]),
        .executable(name: "ToyBoxDesktopShare", targets: ["ToyBoxDesktopShare"]),
        .executable(name: "ToyBoxDesktopWidget", targets: ["ToyBoxDesktopWidget"]),
    ]),
    dependencies: mobile ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "ToyBoxKit", path: "Sources/Shared/ToyBoxKit"),
        .target(name: "ToyBoxClient", dependencies: ["ToyBoxKit"], path: "Sources/Shared/ToyBoxClient"),
        .target(name: "ToyBoxIntelligence", dependencies: ["ToyBoxKit", "ToyBoxClient"],
                path: "Sources/Shared/ToyBoxIntelligence"),
        .target(name: "ToyBoxUI", dependencies: ["ToyBoxKit", "ToyBoxClient"], path: "Sources/Shared/ToyBoxUI"),
        .target(name: "ToyBoxWidgetViews", dependencies: ["ToyBoxKit"], path: "Sources/Shared/ToyBoxWidgetViews",
                swiftSettings: [.unsafeFlags(["-application-extension"])]),
    ] + (mobile ? [
        .target(name: "ToyBoxMobileIntegrations", dependencies: ["ToyBoxKit", "ToyBoxClient", "ToyBoxUI"],
                path: "Sources/Mobile/ToyBoxMobileIntegrations",
                swiftSettings: [.unsafeFlags(["-application-extension"])]),
        .executableTarget(name: "ToyBoxMobile", dependencies: [
            "ToyBoxClient", "ToyBoxIntelligence", "ToyBoxUI", "ToyBoxMobileIntegrations"
        ], path: "Sources/Mobile/ToyBoxMobile", linkerSettings: simulatedEntitlements("dev.toybox.mobile")),
        .executableTarget(
            name: "ToyBoxMobileWidget", dependencies: ["ToyBoxKit", "ToyBoxMobileIntegrations", "ToyBoxWidgetViews"],
            path: "Sources/Mobile/Extensions/ToyBoxMobileWidget",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
                + simulatedEntitlements("dev.toybox.mobile.widget")
        ),
        .executableTarget(
            name: "ToyBoxMobileNotification", dependencies: ["ToyBoxKit", "ToyBoxMobileIntegrations"],
            path: "Sources/Mobile/Extensions/ToyBoxMobileNotification",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
                + simulatedEntitlements("dev.toybox.mobile.notification")
        ),
        .executableTarget(
            name: "ToyBoxMobileShare", dependencies: ["ToyBoxKit", "ToyBoxClient", "ToyBoxUI", "ToyBoxMobileIntegrations"],
            path: "Sources/Mobile/Extensions/ToyBoxMobileShare",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
                + simulatedEntitlements("dev.toybox.mobile.share")
        ),
        .testTarget(name: "ToyBoxMobileTests", dependencies: ["ToyBoxMobile"], path: "Tests/Mobile/ToyBoxMobileTests"),
        .testTarget(name: "ToyBoxMobileIntegrationsTests",
                    dependencies: ["ToyBoxClient", "ToyBoxKit", "ToyBoxMobileIntegrations"],
                    path: "Tests/Mobile/ToyBoxMobileIntegrationsTests"),
        .testTarget(name: "ToyBoxMobileWidgetTests", dependencies: ["ToyBoxMobileWidget"],
                    path: "Tests/Mobile/Extensions/ToyBoxMobileWidgetTests"),
    ] : [
        .target(name: "ToyBoxControlIntents", path: "Sources/Desktop/ToyBoxControlIntents",
                swiftSettings: [.unsafeFlags(["-application-extension"])]),
        .executableTarget(
            name: "ToyBoxDesktopShare",
            path: "Sources/Desktop/Extensions/ToyBoxDesktopShare",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "ToyBoxDesktopWidget",
            dependencies: ["ToyBoxKit", "ToyBoxControlIntents", "ToyBoxWidgetViews"],
            path: "Sources/Desktop/Extensions/ToyBoxDesktopWidget",
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),
        .executableTarget(
            name: "ToyBoxDesktop",
            dependencies: [
                "ToyBoxKit", "ToyBoxClient", "ToyBoxIntelligence", "ToyBoxUI",
                "ToyBoxControlIntents",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Desktop/ToyBoxDesktop",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "ToyBoxDesktopTests", dependencies: ["ToyBoxDesktop"], path: "Tests/Desktop/ToyBoxDesktopTests"),
        .testTarget(name: "ToyBoxDesktopShareTests", dependencies: ["ToyBoxDesktopShare"],
                    path: "Tests/Desktop/Extensions/ToyBoxDesktopShareTests"),
        .testTarget(name: "ToyBoxDesktopWidgetTests", dependencies: ["ToyBoxDesktopWidget"],
                    path: "Tests/Desktop/Extensions/ToyBoxDesktopWidgetTests"),
    ]) + [
        .testTarget(
            name: "ToyBoxKitTests",
            dependencies: ["ToyBoxKit"],
            path: "Tests/Shared/ToyBoxKitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ToyBoxClientTests", dependencies: ["ToyBoxClient"], path: "Tests/Shared/ToyBoxClientTests"),
        .testTarget(name: "ToyBoxUITests", dependencies: ["ToyBoxUI"], path: "Tests/Shared/ToyBoxUITests"),
        .testTarget(
            name: "ToyBoxIntelligenceTests",
            dependencies: ["ToyBoxIntelligence"],
            path: "Tests/Shared/ToyBoxIntelligenceTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
