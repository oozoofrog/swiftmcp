import Foundation

/// Resolver for `BuildInput.xcodeProject`. Builds the named Xcode target once via
/// `xcodebuild build` (artifacts redirected into a `PersistentScratch` so the user's
/// tree stays untouched) so that the SwiftFileList swiftc would consume actually
/// exists, then re-queries `xcodebuild -showBuildSettings` to read its location plus
/// the small set of build settings the analysis tools care about.
///
/// Why build first instead of parsing pbxproj? The Build Phases section of pbxproj is
/// the authoritative source for "which Swift files belong to this target", but Xcode
/// only stages the resolved file list (deduped, conditioned by per-arch flags, etc.)
/// during a real build. Going through xcodebuild keeps the resolver's notion of the
/// target identical to what Xcode itself would compile — at the cost of one build per
/// resolver call. See PLAN §7.3.D for the user-confirmed decision.
///
/// Build overrides applied per call:
/// - `GENERATE_INFOPLIST_FILE=YES` — covers framework/app targets that would otherwise
///   fail before the SwiftFileList is materialized.
/// - `CODE_SIGNING_ALLOWED=NO` — skip codesigning for the analysis build.
/// - `ARCHS=<host>` — build a single arch so we get one SwiftFileList and avoid the
///   "no active architecture could be computed" ARCHS=arm64 x86_64 warning + dual work.
/// - `OBJROOT`/`SYMROOT` — redirect `.build`-equivalents into a `PersistentScratch`.
public struct XcodebuildResolver: BuildArgsResolver {
    public init() {}

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        guard case .xcodeProject(let path, let targetName, let configuration, let triple) = input else {
            throw MCPError.internalError("XcodebuildResolver received non-project input")
        }

        let absoluteProject = absolutize(path)
        try ensureXcodeProject(absoluteProject)

        let resolvedConfig = configuration ?? "Debug"
        let hostArch = currentArch()
        let scratch = try PersistentScratch(prefix: "swiftmcp-xcbuild")
        let objroot = scratch.directory.appending(path: "obj", directoryHint: .isDirectory).path
        let symroot = scratch.directory.appending(path: "sym", directoryHint: .isDirectory).path

        let overrides: [String] = [
            "GENERATE_INFOPLIST_FILE=YES",
            "CODE_SIGNING_ALLOWED=NO",
            "ARCHS=\(hostArch)",
            "OBJROOT=\(objroot)",
            "SYMROOT=\(symroot)"
        ]

        try await runXcodebuildBuild(
            project: absoluteProject,
            target: targetName,
            configuration: resolvedConfig,
            overrides: overrides
        )

        let settings = try await readBuildSettings(
            project: absoluteProject,
            target: targetName,
            configuration: resolvedConfig,
            overrides: overrides
        )

        let fileListKey = "SWIFT_RESPONSE_FILE_PATH_normal_\(hostArch)"
        guard let fileListPath = settings[fileListKey], !fileListPath.isEmpty else {
            throw MCPError.internalError(
                "xcodebuild did not report `\(fileListKey)` for target '\(targetName)'"
            )
        }
        let inputFiles = try readSwiftFileList(at: fileListPath)
        guard !inputFiles.isEmpty else {
            throw MCPError.internalError(
                "SwiftFileList at \(fileListPath) is empty — target '\(targetName)' has no Swift sources?"
            )
        }

        let moduleName = settings["PRODUCT_MODULE_NAME"]
            ?? settings["PRODUCT_NAME"]
            ?? settings["TARGET_NAME"]
            ?? targetName

        var extraSwiftcArgs: [String] = []
        if let sdk = settings["SDKROOT"], !sdk.isEmpty {
            extraSwiftcArgs.append(contentsOf: ["-sdk", sdk])
        }
        if let raw = settings["SWIFT_VERSION"], let normalized = normalizeSwiftVersion(raw) {
            extraSwiftcArgs.append(contentsOf: ["-swift-version", normalized])
        }

        return ResolvedBuildArgs(
            inputFiles: inputFiles,
            moduleName: moduleName,
            target: triple,
            searchPaths: [],
            frameworkSearchPaths: [],
            extraSwiftcArgs: extraSwiftcArgs
        )
    }

    // MARK: - xcodebuild invocations

    private func runXcodebuildBuild(
        project: String,
        target: String,
        configuration: String,
        overrides: [String]
    ) async throws {
        var arguments: [String] = [
            "build",
            "-project", project,
            "-target", target,
            "-configuration", configuration
        ]
        arguments.append(contentsOf: overrides)
        let result: ProcessResult
        do {
            result = try await runProcess(executable: "/usr/bin/xcodebuild", arguments: arguments)
        } catch {
            throw MCPError.toolExecutionFailed("xcodebuild build launch failed: \(error)")
        }
        guard result.exitCode == 0 else {
            throw MCPError.toolExecutionFailed(
                "`xcodebuild build` failed (exit=\(result.exitCode)) for target '\(target)' (configuration \(configuration)): \(truncateForDiagnostic(result.standardError.isEmpty ? result.standardOutput : result.standardError))"
            )
        }
    }

    private func readBuildSettings(
        project: String,
        target: String,
        configuration: String,
        overrides: [String]
    ) async throws -> [String: String] {
        var arguments: [String] = [
            "-project", project,
            "-target", target,
            "-configuration", configuration,
            "-showBuildSettings"
        ]
        arguments.append(contentsOf: overrides)
        let result: ProcessResult
        do {
            result = try await runProcess(executable: "/usr/bin/xcodebuild", arguments: arguments)
        } catch {
            throw MCPError.toolExecutionFailed("xcodebuild -showBuildSettings launch failed: \(error)")
        }
        guard result.exitCode == 0 else {
            throw MCPError.toolExecutionFailed(
                "`xcodebuild -showBuildSettings` failed (exit=\(result.exitCode)): \(truncateForDiagnostic(result.standardError))"
            )
        }
        return parseBuildSettings(result.standardOutput)
    }

    /// Parse xcodebuild -showBuildSettings stdout. Lines we care about look like
    /// `    KEY = VALUE` (4 spaces of indent, exactly one ` = ` separator). Other
    /// lines (empty, headers like `Build settings for action build and target X:`)
    /// are ignored.
    func parseBuildSettings(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Trim leading whitespace; xcodebuild uses 4 spaces, but be lenient.
            var s = line
            while let first = s.first, first == " " || first == "\t" {
                s.removeFirst()
            }
            guard let eq = s.range(of: " = ") else { continue }
            let key = String(s[..<eq.lowerBound])
            // Build setting keys are identifiers — letters, digits, underscores. xcodebuild
            // emits arch/variant-suffixed keys with lowercase parts (e.g.
            // SWIFT_RESPONSE_FILE_PATH_normal_arm64), so we cannot restrict to uppercase.
            guard !key.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else {
                continue
            }
            let value = String(s[eq.upperBound...])
            out[key] = value
        }
        return out
    }

    // MARK: - Helpers

    private func ensureXcodeProject(_ path: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw MCPError.invalidParams("`input.project` does not exist or is not a directory: \(path)")
        }
        guard path.hasSuffix(".xcodeproj") else {
            throw MCPError.invalidParams("`input.project` must end with `.xcodeproj`: \(path)")
        }
        let pbx = path + "/project.pbxproj"
        guard FileManager.default.fileExists(atPath: pbx) else {
            throw MCPError.invalidParams("`.xcodeproj` is missing project.pbxproj: \(pbx)")
        }
    }

    private func absolutize(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func currentArch() -> String {
        // Hosts running this MCP are macOS 13+ — Apple Silicon ("arm64") or Intel ("x86_64").
        // Reflect the real runtime arch rather than hardcoding so x86_64 hosts still work.
        var info = utsname()
        if uname(&info) == 0 {
            let machine = withUnsafePointer(to: &info.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                    String(cString: $0)
                }
            }
            if !machine.isEmpty { return machine }
        }
        return "arm64"
    }

    private func readSwiftFileList(at path: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.internalError("SwiftFileList not found at \(path)")
        }
        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw MCPError.internalError("Failed to read SwiftFileList \(path): \(error)")
        }
        return raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// swiftc's `-swift-version` accepts one of `4`, `4.2`, `5`, `6`. Xcode reports
    /// `SWIFT_VERSION` as e.g. `6.0`, `5.0`, `4.2`. Trim a trailing `.0` to match.
    func normalizeSwiftVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix(".0") {
            return String(trimmed.dropLast(2))
        }
        return trimmed
    }

    private func truncateForDiagnostic(_ text: String, limit: Int = 1200) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…(truncated)"
    }
}
