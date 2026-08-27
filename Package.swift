// swift-tools-version: 6.0
import PackageDescription
import Foundation

// libfb_core.a staged flat at rust/fb-core/dist/ by the FBCoreRustBuilder plugin.
// Absolute -L: a relative path resolves from the linker's cwd, which differs
// between `swift build` (package root) and `swift test` (sandbox cwd), making
// the link brittle. SPM stages the manifest into a temp tree before evaluating
// it, so #file / currentDirectoryPath point at the staging copy, not the real
// package root. Walk up from cwd to the dir containing Sources/FusionBrowser.
func locatePackageRoot() -> String {
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<10 {
        let probe = url.appendingPathComponent("Sources/FusionBrowser")
        if FileManager.default.fileExists(atPath: probe.path) { return url.path }
        url = url.deletingLastPathComponent()
    }
    // Fall back to the relative form (works for `swift build` from package root).
    return "."
}
let libfbCoreDir = locatePackageRoot() + "/rust/fb-core/dist"
let libfbCoreLink: [LinkerSetting] = [.unsafeFlags(["-L", libfbCoreDir, "-lfb_core"])]

let package = Package(
    name: "fusion-browser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fusion-browser", targets: ["FusionBrowser"]),
    ],
    targets: [
        .executableTarget(
            name: "FusionBrowser",
            dependencies: ["FBCoreRust"],
            path: "Sources/FusionBrowser",
            linkerSettings: libfbCoreLink
        ),
        .target(
            name: "FBCoreRust",
            dependencies: ["FBCoreRustBuilder"],
            path: "Sources/FBCoreRust",
            publicHeadersPath: "include"
        ),
        .plugin(
            name: "FBCoreRustBuilder",
            capability: .buildTool(),
            path: "Plugins/FBCoreRustBuilder"
        ),
        .testTarget(
            name: "FusionBrowserTests",
            dependencies: ["FusionBrowser"],
            path: "Tests/FusionBrowserTests",
            linkerSettings: libfbCoreLink
        ),
    ],
    swiftLanguageModes: [.v5]
)
