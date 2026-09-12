// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MediaEditor",
    defaultLocalization: "en",
    platforms: [
        // The turnkey editor UI is UIKit-based, so it ships on iOS and Mac
        // Catalyst. `MediaEditorCore` is UI-free and builds natively on macOS
        // too — macOS 14 is iOS 17's contemporary.
        .iOS(.v17),
        .macCatalyst(.v17),
        .macOS(.v14)
    ],
    products: [
        // Turnkey: a single umbrella module re-exporting the SwiftUI + UIKit
        // editors and the core, so `import MediaEditor` gets everything.
        .library(
            name: "MediaEditor",
            targets: ["MediaEditor"]
        ),
        // Headless: non-destructive model + renderers, no UI. Builds on every
        // supported platform, macOS included.
        .library(
            name: "MediaEditorCore",
            targets: ["MediaEditorCore"]
        ),
    ],
    targets: [
        .target(
            name: "MediaEditor",
            dependencies: ["MediaEditorSwiftUI", "MediaEditorUIKit", "MediaEditorCore"]
        ),
        .target(
            name: "MediaEditorCore",
            // Its own privacy manifest, for apps that link only the headless
            // product. The UIKit target ships one in its Resources folder.
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "MediaEditorUIKit",
            dependencies: ["MediaEditorCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "MediaEditorSwiftUI",
            dependencies: ["MediaEditorUIKit", "MediaEditorCore"]
        ),
        .testTarget(
            name: "MediaEditorCoreTests",
            dependencies: ["MediaEditorCore"]
        ),
        .testTarget(
            name: "MediaEditorUIKitTests",
            dependencies: ["MediaEditorUIKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
