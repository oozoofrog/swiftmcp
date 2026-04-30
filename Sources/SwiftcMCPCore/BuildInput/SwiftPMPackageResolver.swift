import Foundation

/// Resolver for `BuildInput.swiftPMPackage`. Calls `swift package describe --type json`
/// to enumerate targets, picks one (named or first library), assembles absolute source
/// paths, and — when the chosen target has internal `target_dependencies` — runs
/// `swift build` once into a `PersistentScratch` so the dependency `.swiftmodule` files
/// are materialized and reachable via `-I <bin>/Modules`.
///
/// External package dependencies (other Swift packages) are out of scope for this
/// stage; manifests with `dependencies` are still accepted, but the dependency check
/// happens at the *target* level (`target_dependencies`) — those name peer targets
/// inside the same package.
///
/// Process invocations are cwd-neutral: `--package-path <abs>` and `--scratch-path <abs>`
/// are passed explicitly so we never `chdir` into the user's tree.
public struct SwiftPMPackageResolver: BuildArgsResolver {
    private let toolchain: ToolchainResolver

    public init(toolchain: ToolchainResolver = ToolchainResolver()) {
        self.toolchain = toolchain
    }

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        guard case .swiftPMPackage(let path, let targetName, let configuration, let triple) = input else {
            throw MCPError.internalError("SwiftPMPackageResolver received non-package input")
        }

        let absolutePackage = absolutize(path)
        try ensureDirectory(absolutePackage, kind: "package")
        let manifestPath = absolutePackage + "/Package.swift"
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            throw MCPError.invalidParams(
                "`input.package` does not contain a Package.swift: \(absolutePackage)"
            )
        }

        let resolved = try await toolchain.resolve()
        let swiftPath = swiftBinaryPath(swiftcPath: resolved.swiftcPath)

        let description = try await runDescribe(swiftPath: swiftPath, packagePath: absolutePackage)
        let target = try selectTarget(description: description, targetName: targetName)

        let targetRoot = description.path + "/" + target.path
        let inputFiles = target.sources.map { source -> String in
            // Sources are listed relative to the target's `path`.
            URL(fileURLWithPath: targetRoot)
                .appending(path: source, directoryHint: .notDirectory)
                .standardizedFileURL.path
        }

        let resolvedConfiguration = configuration ?? "debug"
        let dependencyTargets = target.target_dependencies ?? []
        var searchPaths: [String] = []
        if !dependencyTargets.isEmpty {
            // Pre-build the whole package (multiple --target flags don't compose; a
            // single full build is simpler and correctly populates Modules/ for any
            // dep). The scratch outlives this call so the subsequent swiftc invocation
            // can read the .swiftmodules.
            let scratch = try PersistentScratch(prefix: "swiftmcp-pkgbuild")
            try await runBuild(
                swiftPath: swiftPath,
                packagePath: absolutePackage,
                scratchPath: scratch.directory.path,
                configuration: resolvedConfiguration
            )
            let binPath = try await readBinPath(
                swiftPath: swiftPath,
                packagePath: absolutePackage,
                scratchPath: scratch.directory.path,
                configuration: resolvedConfiguration
            )
            searchPaths = [binPath + "/Modules"]
        }

        return ResolvedBuildArgs(
            inputFiles: inputFiles,
            moduleName: target.name,
            target: triple,
            searchPaths: searchPaths,
            frameworkSearchPaths: [],
            extraSwiftcArgs: []
        )
    }

    // MARK: - swift CLI invocations

    private func runDescribe(swiftPath: String, packagePath: String) async throws -> PackageDescription {
        let result: ProcessResult
        do {
            // `swift package describe` doesn't accept `--package-path` after the
            // subcommand; the option has to land before `describe`.
            result = try await runProcess(
                executable: swiftPath,
                arguments: ["package", "--package-path", packagePath, "describe", "--type", "json"]
            )
        } catch {
            throw MCPError.toolExecutionFailed("swift package describe launch failed: \(error)")
        }
        guard result.exitCode == 0 else {
            throw MCPError.invalidParams(
                "`swift package describe` failed (exit=\(result.exitCode)): \(truncateForDiagnostic(result.standardError))"
            )
        }
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw MCPError.internalError("`swift package describe` produced non-UTF-8 output")
        }
        do {
            return try JSONDecoder().decode(PackageDescription.self, from: data)
        } catch {
            throw MCPError.internalError("Failed to parse `swift package describe` JSON: \(error)")
        }
    }

    private func runBuild(
        swiftPath: String,
        packagePath: String,
        scratchPath: String,
        configuration: String
    ) async throws {
        let result: ProcessResult
        do {
            result = try await runProcess(
                executable: swiftPath,
                arguments: [
                    "build",
                    "--package-path", packagePath,
                    "--scratch-path", scratchPath,
                    "--configuration", configuration
                ]
            )
        } catch {
            throw MCPError.toolExecutionFailed("swift build launch failed: \(error)")
        }
        guard result.exitCode == 0 else {
            throw MCPError.toolExecutionFailed(
                "`swift build` failed (exit=\(result.exitCode)): \(truncateForDiagnostic(result.standardError))"
            )
        }
    }

    private func readBinPath(
        swiftPath: String,
        packagePath: String,
        scratchPath: String,
        configuration: String
    ) async throws -> String {
        let result = try await runProcess(
            executable: swiftPath,
            arguments: [
                "build",
                "--package-path", packagePath,
                "--scratch-path", scratchPath,
                "--configuration", configuration,
                "--show-bin-path"
            ]
        )
        guard result.exitCode == 0 else {
            throw MCPError.toolExecutionFailed(
                "`swift build --show-bin-path` failed (exit=\(result.exitCode)): \(truncateForDiagnostic(result.standardError))"
            )
        }
        let path = result.standardOutputTrimmed
        guard !path.isEmpty else {
            throw MCPError.internalError("`swift build --show-bin-path` returned empty output")
        }
        return path
    }

    // MARK: - Target selection

    private func selectTarget(
        description: PackageDescription,
        targetName: String?
    ) throws -> PackageDescription.Target {
        let swiftTargets = description.targets.filter { ($0.module_type ?? "") == "SwiftTarget" }
        if let targetName {
            guard let match = swiftTargets.first(where: { $0.name == targetName }) else {
                let known = swiftTargets.map { $0.name }.joined(separator: ", ")
                throw MCPError.invalidParams(
                    "target_name '\(targetName)' not found in package '\(description.name)' (known SwiftTargets: \(known.isEmpty ? "<none>" : known))"
                )
            }
            return match
        }
        // Default: first library SwiftTarget.
        guard let first = swiftTargets.first(where: { $0.type == "library" }) else {
            throw MCPError.invalidParams(
                "Package '\(description.name)' has no library SwiftTarget. Provide `target_name` to pick another target type."
            )
        }
        return first
    }

    // MARK: - Helpers

    private func absolutize(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func ensureDirectory(_ path: String, kind: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw MCPError.invalidParams("`input.\(kind)` does not exist: \(path)")
        }
        guard isDir.boolValue else {
            throw MCPError.invalidParams("`input.\(kind)` is not a directory: \(path)")
        }
    }

    private func swiftBinaryPath(swiftcPath: String) -> String {
        URL(fileURLWithPath: swiftcPath)
            .deletingLastPathComponent()
            .appending(path: "swift", directoryHint: .notDirectory).path
    }

    private func truncateForDiagnostic(_ text: String, limit: Int = 800) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…(truncated)"
    }
}

// MARK: - swift package describe JSON shape (only the fields we use)

extension SwiftPMPackageResolver {
    struct PackageDescription: Decodable {
        let name: String
        let path: String
        let targets: [Target]

        struct Target: Decodable {
            let name: String
            let path: String
            let sources: [String]
            let type: String
            // swiftlint:disable:next identifier_name
            let module_type: String?
            // swiftlint:disable:next identifier_name
            let target_dependencies: [String]?
        }
    }
}
