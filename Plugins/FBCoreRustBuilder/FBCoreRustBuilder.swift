import PackagePlugin
import Foundation

// BuildToolPlugin: builds the fb_core Rust staticlib and stages it at a
// known relative path (rust/fb-core/dist/libfb_core.a) so the SwiftPM manifest
// can link it via `.unsafeFlags(["-L", "rust/fb-core/dist", "-lfb_core"])`.
//
// Cargo emits to <CARGO_TARGET_DIR>/<triple>/release/libfb_core.a — a nested
// path SPM's prebuildCommand outputFilesDirectory cannot consume directly, so
// we copy the artifact into a flat dist/ dir (the plan's verified fallback for
// the underspecified SPM plugin-output-path contract).
//
// "Build always, link always, call conditionally": the staticlib rebuilds on
// every swift build (cargo incremental cache persists in CARGO_TARGET_DIR) to
// catch Rust breakage early; links always (dead-stripped when useRustCore=false);
// Swift only calls FFI when the flag is on.
@main
struct FBCoreRustBuilder: BuildToolPlugin {
    let triple = "aarch64-apple-darwin"

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let pkgDir = context.package.directory
        let crateDir = pkgDir.appending("rust").appending("fb-core")
        let cargoToml = crateDir.appending("Cargo.toml")
        let cargo = findCargo()

        // Plugin sandbox permits writes under the outputFilesDirectory. Build
        // cargo there (CARGO_TARGET_DIR = dist) so all artifacts land in the one
        // writable area, then copy the nested .a flat into the same dir. The
        // manifest links against this flat dist/libfb_core.a.
        let distDir = crateDir.appending("dist")
        let cargoTargetDir = distDir
        let builtA = cargoTargetDir.appending(triple).appending("release").appending("libfb_core.a")
        let stagedA = distDir.appending("libfb_core.a")

        // Gather Rust source inputs so SPM only re-runs cargo when they change.
        let fm = FileManager.default
        let srcDir = crateDir.appending("src")
        var inputs: [Path] = [cargoToml]
        if fm.fileExists(atPath: srcDir.string) {
            if let entries = fm.enumerator(atPath: srcDir.string)?.allObjects as? [String] {
                for e in entries { inputs.append(srcDir.appending(e)) }
            }
        }

        // Plugin sandbox restricts PATH; cargo needs to find rustc + the linker.
        // Hand it a known-good PATH covering Homebrew rust + system toolchain.
        let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let env: [String: String] = [
            "CARGO_TARGET_DIR": cargoTargetDir.string,
            "CARGO_BUILD_TARGET": triple,
            "RUSTFLAGS": "-C link-arg=-fvisibility=hidden",
            "PATH": path,
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/var/root",
        ]

        // One shell command: cargo build, then mkdir dist + copy the artifact flat.
        // sh -c lets us chain build + stage in a single prebuildCommand.
        let shellArgs = [
            "-c",
            "\"\(cargo)\" build --release --manifest-path \"\(cargoToml.string)\" && /bin/mkdir -p \"\(distDir.string)\" && /bin/cp -f \"\(builtA.string)\" \"\(stagedA.string)\""
        ]

        return [
            .prebuildCommand(
                displayName: "cargo build --release + stage libfb_core.a (fb_core)",
                executable: Path("/bin/sh"),
                arguments: shellArgs,
                environment: env,
                outputFilesDirectory: distDir
            )
        ]
    }

    private func findCargo() -> String {
        for c in ["/opt/homebrew/bin/cargo", "/usr/local/bin/cargo"]
            where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "cargo"
    }
}
