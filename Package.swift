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
    name: "displaylink-lite",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dlprobe", targets: ["dlprobe"]),
        .executable(name: "DisplayLinkLite", targets: ["DisplayLinkLite"])
    ],
    targets: [
        .target(name: "DLProbeCore"),
        .executableTarget(
            name: "dlprobe",
            dependencies: ["DLProbeCore"]
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
            name: "DisplayLinkLite",
            dependencies: ["CDLLite"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "DLProbeCoreTests",
            dependencies: ["DLProbeCore"]
        )
    ]
)
