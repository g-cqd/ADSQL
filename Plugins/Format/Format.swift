import Foundation
import PackagePlugin

/// `swift package format` — formats the package in place with the toolchain's bundled
/// `swift-format`, driven through the `swift format` subcommand. Configuration is read from the
/// repo's `.swift-format`.
@main
struct FormatPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let paths = ["Sources", "Tests", "Plugins", "Package.swift"].map { root.appending(path: $0).path }

        let swift = try context.tool(named: "swift")
        let process = Process()
        process.executableURL = swift.url
        process.arguments = ["format", "--in-place", "--recursive"] + paths
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("Formatted Sources, Tests, Plugins, and Package.swift.")
        } else {
            Diagnostics.error("swift format exited with status \(process.terminationStatus)")
        }
    }
}
