// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StereoKit",
    platforms: [.iOS("27.0"), .macOS("27.0"), .tvOS("27.0")],
    products: [
        .library(name: "StereoModel", targets: ["StereoModel"]),
        .library(name: "SubsonicClient", targets: ["SubsonicClient"]),
        .library(name: "RadioBrowserClient", targets: ["RadioBrowserClient"]),
        .library(name: "StereoStore", targets: ["StereoStore"]),
        .library(name: "StereoPlayback", targets: ["StereoPlayback"]),
        .library(name: "StereoRadio", targets: ["StereoRadio"]),
        .library(name: "StereoSystem", targets: ["StereoSystem"]),
        .library(name: "StereoDownloads", targets: ["StereoDownloads"]),
        .library(name: "StereoDiscovery", targets: ["StereoDiscovery"]),
        .library(name: "StereoUI", targets: ["StereoUI"]),
        .library(name: "StereoSync", targets: ["StereoSync"]),
        .library(name: "StereoRemote", targets: ["StereoRemote"]),
        .library(name: "StereoWidgetData", targets: ["StereoWidgetData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "StereoModel"),
        .target(name: "SubsonicClient", dependencies: ["StereoModel"]),
        .target(name: "RadioBrowserClient", dependencies: ["StereoModel"]),
        .target(name: "StereoStore", dependencies: ["StereoModel", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "StereoPlayback", dependencies: ["StereoModel"]),
        .target(name: "StereoRadio", dependencies: ["StereoModel", "RadioBrowserClient", "StereoPlayback"]),
        .target(name: "StereoSystem", dependencies: ["StereoModel", "StereoPlayback"]),
        .target(name: "StereoDownloads", dependencies: ["StereoModel", "StereoStore", "SubsonicClient"]),
        .target(name: "StereoDiscovery", dependencies: ["StereoModel", "StereoStore", "SubsonicClient"]),
        .target(name: "StereoSync", dependencies: ["StereoModel", "StereoStore"]),
        .target(name: "StereoRemote", dependencies: ["StereoModel"]),
        // Foundation-only, so the widget extension links nothing else.
        .target(name: "StereoWidgetData"),
        .target(
            name: "StereoUI",
            dependencies: [
                "StereoModel", "SubsonicClient", "RadioBrowserClient", "StereoStore",
                "StereoPlayback", "StereoRadio", "StereoSystem", "StereoDownloads", "StereoDiscovery", "StereoSync", "StereoRemote", "StereoWidgetData",
            ]
        ),

        .testTarget(name: "StereoModelTests", dependencies: ["StereoModel"]),
        .testTarget(name: "SubsonicClientTests", dependencies: ["SubsonicClient"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RadioBrowserClientTests", dependencies: ["RadioBrowserClient"]),
        .testTarget(name: "StereoStoreTests", dependencies: ["StereoStore"]),
        .testTarget(name: "StereoPlaybackTests", dependencies: ["StereoPlayback"], resources: [.copy("Fixtures")]),
        .testTarget(name: "StereoRadioTests", dependencies: ["StereoRadio"]),
        .testTarget(name: "StereoDownloadsTests", dependencies: ["StereoDownloads", "StereoStore", "SubsonicClient"]),
        .testTarget(name: "StereoDiscoveryTests", dependencies: ["StereoDiscovery"], resources: [.copy("Fixtures")]),
        .testTarget(name: "StereoSyncTests", dependencies: ["StereoSync", "StereoStore"]),
        .testTarget(name: "StereoRemoteTests", dependencies: ["StereoRemote"]),
        .testTarget(name: "StereoWidgetDataTests", dependencies: ["StereoWidgetData"]),
        .testTarget(name: "StereoUITests", dependencies: ["StereoUI"]),
        // Runs against a real Navidrome. Skipped unless STEREO_IT_URL is set (see Tests/IntegrationTests).
        .testTarget(name: "IntegrationTests", dependencies: ["SubsonicClient", "StereoStore", "StereoPlayback"]),
    ],
    swiftLanguageModes: [.v6]
)
