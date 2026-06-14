import Foundation
import PackagePlugin

/// Build-tool plugin that enforces formatting during the build: it runs `swift format lint
/// --strict` over a target's Swift sources as a prebuild step, so a non-zero exit fails the build.
/// Attached to `ADSQL` only when `ADSQL_DEV` is set (see Package.swift), so it never runs for
/// packages that merely depend on ADSQL.
@main
struct LintBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target.sourceModule else { return [] }
        let swiftFiles = module.sourceFiles(withSuffix: "swift").map(\.url.path)
        guard !swiftFiles.isEmpty else { return [] }

        let swift = try context.tool(named: "swift")
        return [
            .prebuildCommand(
                displayName: "swift format lint (\(target.name))",
                executable: swift.url,
                arguments: ["format", "lint", "--strict"] + swiftFiles,
                outputFilesDirectory: context.pluginWorkDirectoryURL)
        ]
    }
}
