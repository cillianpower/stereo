// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TunerKit",
    platforms: [.iOS("27.0"), .macOS("27.0"), .tvOS("27.0")],
    products: [
        .library(name: "TunerModel", targets: ["TunerModel"]),
        .library(name: "SubsonicClient", targets: ["SubsonicClient"]),
        .library(name: "RadioBrowserClient", targets: ["RadioBrowserClient"]),
        .library(name: "TunerStore", targets: ["TunerStore"]),
        .library(name: "TunerPlayback", targets: ["TunerPlayback"]),
        .library(name: "TunerRadio", targets: ["TunerRadio"]),
        .library(name: "TunerSystem", targets: ["TunerSystem"]),
        .library(name: "TunerDownloads", targets: ["TunerDownloads"]),
        .library(name: "TunerDiscovery", targets: ["TunerDiscovery"]),
        .library(name: "TunerUI", targets: ["TunerUI"]),
        .library(name: "TunerSync", targets: ["TunerSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "TunerModel"),
        .target(name: "SubsonicClient", dependencies: ["TunerModel"]),
        .target(name: "RadioBrowserClient", dependencies: ["TunerModel"]),
        .target(name: "TunerStore", dependencies: ["TunerModel", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "TunerPlayback", dependencies: ["TunerModel"]),
        .target(name: "TunerRadio", dependencies: ["TunerModel", "RadioBrowserClient", "TunerPlayback"]),
        .target(name: "TunerSystem", dependencies: ["TunerModel", "TunerPlayback"]),
        .target(name: "TunerDownloads", dependencies: ["TunerModel", "TunerStore", "SubsonicClient"]),
        .target(name: "TunerDiscovery", dependencies: ["TunerModel", "TunerStore", "SubsonicClient"]),
        .target(name: "TunerSync", dependencies: ["TunerModel", "TunerStore"]),
        .target(
            name: "TunerUI",
            dependencies: [
                "TunerModel", "SubsonicClient", "RadioBrowserClient", "TunerStore",
                "TunerPlayback", "TunerRadio", "TunerSystem", "TunerDownloads", "TunerDiscovery", "TunerSync",
            ]
        ),

        .testTarget(name: "TunerModelTests", dependencies: ["TunerModel"]),
        .testTarget(name: "SubsonicClientTests", dependencies: ["SubsonicClient"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RadioBrowserClientTests", dependencies: ["RadioBrowserClient"]),
        .testTarget(name: "TunerStoreTests", dependencies: ["TunerStore"]),
        .testTarget(name: "TunerPlaybackTests", dependencies: ["TunerPlayback"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TunerRadioTests", dependencies: ["TunerRadio"]),
        .testTarget(name: "TunerDownloadsTests", dependencies: ["TunerDownloads", "TunerStore", "SubsonicClient"]),
        .testTarget(name: "TunerDiscoveryTests", dependencies: ["TunerDiscovery"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TunerSyncTests", dependencies: ["TunerSync", "TunerStore"]),
        // Runs against a real Navidrome. Skipped unless TUNER_IT_URL is set (see Tests/IntegrationTests).
        .testTarget(name: "IntegrationTests", dependencies: ["SubsonicClient", "TunerStore", "TunerPlayback"]),
    ],
    swiftLanguageModes: [.v6]
)
