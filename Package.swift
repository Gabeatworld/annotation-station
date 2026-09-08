// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnnotationStation",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates. Sparkle ships as a binary framework; Scripts/bundle.sh embeds and
        // re-signs it inside the .app (SwiftPM does not build app bundles for us).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AnnotationStation",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AnnotationStation",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                // Sparkle.framework is embedded in the .app by Scripts/bundle.sh; without this
                // rpath the executable looks for it beside the binary and dies at launch.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "AnnotationStationTests",
            dependencies: ["AnnotationStation"],
            path: "Tests/AnnotationStationTests"
        ),
    ]
)
