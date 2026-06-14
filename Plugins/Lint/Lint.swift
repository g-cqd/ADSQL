import Foundation
import PackagePlugin

/// `swift package lint` — the project's formatting gate via `swift format lint --strict`, the same
/// command CI and the pre-commit hook run, so local and CI rules can't drift. (ADSQL's
/// shipped-library discipline — every unsafe construct explicitly `unsafe` or `@safe`-encapsulated —
/// is enforced by the compiler under `.strictMemorySafety()`, so it needs no lint regex.)
@main
struct LintPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let paths = ["Sources", "Tests", "Plugins", "Package.swift"].map { root.appending(path: $0).path }

        let swift = try context.tool(named: "swift")
        let format = Process()
        format.executableURL = swift.url
        format.arguments = ["format", "lint", "--strict", "--recursive"] + paths
        try format.run()
        format.waitUntilExit()

        if format.terminationStatus != 0 {
            Diagnostics.error("lint failed")
        } else {
            print("lint clean")
        }
    }
}
