// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnnotationStation",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AnnotationStation",
            path: "Sources/AnnotationStation",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .testTarget(
            name: "AnnotationStationTests",
            dependencies: ["AnnotationStation"],
            path: "Tests/AnnotationStationTests"
        ),
    ]
)
