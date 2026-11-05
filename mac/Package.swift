// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacScreen",
    platforms: [.macOS(.v13)],
    targets: [
        // Declares Apple's private CGVirtualDisplay classes (they live in CoreGraphics).
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .executableTarget(
            name: "MacScreen",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/MacScreen",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
    ]
)
