// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// The Rust engine (`cargo build --release --manifest-path engine/Cargo.toml`) builds
/// libdllite_engine.a here, with libusb linked in statically.
let engineLibDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("engine/target/release")
    .path

let package = Package(
    name: "linklite",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dlprobe", targets: ["dlprobe"]),
        .executable(name: "LinkLite", targets: ["LinkLite"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "DLProbeCore"),
        .target(name: "LinkLiteCore"),
        .executableTarget(
            name: "dlprobe",
            dependencies: ["DLProbeCore"]
        ),
        // Pure rules and the head controller (no AppKit, CoreGraphics or USB) so they can be tested without a dock.
        // The head runtime drives each head's captures through LinkLiteCore's StreamLifecycle.
        .target(
            name: "LinkLiteRotation",
            dependencies: ["LinkLiteCore"]
        ),
        .testTarget(
            name: "LinkLiteRotationTests",
            dependencies: ["LinkLiteRotation", "LinkLiteCore"]
        ),
        .target(
            name: "CDLLite",
            linkerSettings: [
                .unsafeFlags(["-L", engineLibDir]),
                .linkedLibrary("dllite_engine"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "LinkLite",
            dependencies: [
                "CDLLite",
                "LinkLiteCore",
                "LinkLiteRotation",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                // build-app.sh copies Sparkle.framework into LinkLite.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "DLProbeCoreTests",
            dependencies: ["DLProbeCore"]
        ),
        .testTarget(
            name: "LinkLiteCoreTests",
            dependencies: ["LinkLiteCore"]
        ),
        .testTarget(
            name: "LinkLiteTests",
            dependencies: ["LinkLite"]
        )
    ]
)
