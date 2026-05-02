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
        let mode: Mode
        let configuration: String?
        let triple: String?
        let explicitTargetName: String?
        let identifier: String  // user-facing label for error messages
        switch input {
        case .xcodeProject(let path, let targetName, let cfg, let target):
            let absolute = absolutize(path)
            try ensureXcodeProject(absolute)
            mode = .project(path: absolute, target: targetName)
            configuration = cfg
            triple = target
            // For project mode `xcodebuild -target X` already restricts the output to
            // that target, but we still pass the name through for ambiguity tie-break
            // in case the scheme attached to the project also builds peers.
            explicitTargetName = targetName
            identifier = "target '\(targetName)'"
        case .xcodeWorkspace(let path, let scheme, let targetName, let cfg, let target):
            let absolute = absolutize(path)
            try ensureXcodeWorkspace(absolute)
            mode = .workspace(path: absolute, scheme: scheme)
            configuration = cfg
            triple = target
            explicitTargetName = targetName
            identifier = "scheme '\(scheme)'"
        default:
            throw MCPError.internalError("XcodebuildResolver received non-Xcode input")
        }

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
            mode: mode,
            configuration: resolvedConfig,
            overrides: overrides
        )

        let blocks = try await readBuildSettings(
            mode: mode,
            configuration: resolvedConfig,
            overrides: overrides
        )

        let chosen = try chooseSettingsBlock(
            blocks: blocks,
            explicitTargetName: explicitTargetName,
            identifier: identifier
        )
        let settings = chosen.settings

        let fileListKey = "SWIFT_RESPONSE_FILE_PATH_normal_\(hostArch)"
        guard let fileListPath = settings[fileListKey], !fileListPath.isEmpty else {
            throw MCPError.internalError(
                "xcodebuild did not report `\(fileListKey)` for \(identifier)"
            )
        }
        let inputFiles = try readSwiftFileList(at: fileListPath)
        guard !inputFiles.isEmpty else {
            throw MCPError.internalError(
                "SwiftFileList at \(fileListPath) is empty — \(identifier) has no Swift sources?"
            )
        }

        let fallbackModuleName: String
        switch mode {
        case .project(_, let targetName): fallbackModuleName = targetName
        case .workspace(_, let scheme): fallbackModuleName = chosen.target ?? scheme
        }
        let moduleName = settings["PRODUCT_MODULE_NAME"]
            ?? settings["PRODUCT_NAME"]
            ?? settings["TARGET_NAME"]
            ?? fallbackModuleName

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

    /// `xcodebuild -showBuildSettings` emits one block per build target. With
    /// `-project X -target Y` only Y's block appears, so the choice is unambiguous.
    /// With `-workspace X -scheme Y`, however, a multi-buildable scheme prints one
    /// block per buildable target — picking arbitrarily would silently return the
    /// wrong SwiftFileList. Resolution rules:
    /// - 0 blocks → tool execution error (xcodebuild emitted nothing usable).
    /// - 1 block + matching/absent `explicitTargetName` → use it.
    /// - 1 block + mismatched `explicitTargetName` → reject. Ignoring the mismatch
    ///   would silently analyze the wrong target while the caller believes they
    ///   selected another.
    /// - N blocks + explicit target_name → match by `TARGET_NAME` (or the parsed
    ///   header). Throw `invalidParams` on miss with the available names listed.
    /// - N blocks + no target_name → throw `invalidParams` asking for one.
    func chooseSettingsBlock(
        blocks: [SettingsBlock],
        explicitTargetName: String?,
        identifier: String
    ) throws -> SettingsBlock {
        guard !blocks.isEmpty else {
            throw MCPError.toolExecutionFailed(
                "xcodebuild produced no build-settings blocks for \(identifier)."
            )
        }
        let availableNames = blocks.compactMap { $0.target ?? $0.settings["TARGET_NAME"] }
        if blocks.count == 1 {
            let block = blocks[0]
            if let name = explicitTargetName,
               let actual = block.target ?? block.settings["TARGET_NAME"],
               actual != name
            {
                throw MCPError.invalidParams(
                    "target '\(name)' is not built by \(identifier) (available: \(actual))"
                )
            }
            return block
        }
        guard let name = explicitTargetName else {
            throw MCPError.invalidParams(
                "\(identifier) builds multiple targets (\(availableNames.joined(separator: ", "))). Specify `target_name` to disambiguate."
            )
        }
        if let match = blocks.first(where: { ($0.target ?? $0.settings["TARGET_NAME"]) == name }) {
            return match
        }
        throw MCPError.invalidParams(
            "target '\(name)' is not built by \(identifier) (available: \(availableNames.joined(separator: ", ")))"
        )
    }

    /// Internal mode marker so the build/showBuildSettings invocations can vary just
    /// the project/workspace argument pair while sharing everything else.
    enum Mode {
        case project(path: String, target: String)
        case workspace(path: String, scheme: String)

        var selectorArgs: [String] {
            switch self {
            case .project(let path, let target):
                return ["-project", path, "-target", target]
            case .workspace(let path, let scheme):
                return ["-workspace", path, "-scheme", scheme]
            }
        }
    }

    // MARK: - xcodebuild invocations

    private func runXcodebuildBuild(
        mode: Mode,
        configuration: String,
        overrides: [String]
    ) async throws {
        var arguments: [String] = ["build"]
        arguments.append(contentsOf: mode.selectorArgs)
        arguments.append(contentsOf: ["-configuration", configuration])
        arguments.append(contentsOf: overrides)
        // We only treat *launch* failures (xcodebuild itself can't be spawned, or the
        // path is wrong) as resolver errors. A non-zero exit from xcodebuild typically
        // means swift code in the target failed to compile — but xcodebuild still
        // materializes the SwiftFileList before swiftc's compile step, and the user's
        // analysis tool will surface the same diagnostics on its own swiftc call. Per
        // PLAN §0.3, compiler diagnostics are the analysis output, not a tool error.
        //
        // Why `runProcessWithTimeoutDiscardingOutput` instead of plain `runProcess`:
        // Xcode 26.2+ on macOS 26.x has a known bug
        // (react-native-community/cli#2768) where xcodebuild's SWBBuildService child
        // inherits the parent's stdout/stderr file descriptors and keeps them open
        // after `BUILD SUCCEEDED`. A reader using `readDataToEndOfFile()` on those
        // pipes never observes EOF and blocks forever — even after the xcodebuild
        // PID dies, because SWBBuildService still holds a writer-end copy of the FD.
        // Routing stdio to /dev/null sidesteps the read entirely, and the polling
        // loop with SIGTERM/SIGKILL escalation guarantees we return within the
        // timeout when xcodebuild itself wedges.
        //
        // The discarding variant uses the same `PIDHolder` + `withTaskCancellationHandler`
        // pattern as `runProcess`, so a parent-task cancel still tears the child down
        // — the resolver's cancellation contract (parent task cancelled → SIGTERM
        // delivered to xcodebuild within scheduling latency) survives this rerouting.
        // SwiftFileList is materialized well before BUILD SUCCEEDED, so the
        // downstream existence check still differentiates wedged-but-built from
        // genuinely failed.
        do {
            _ = try await runProcessWithTimeoutDiscardingOutput(
                executable: "/usr/bin/xcodebuild",
                arguments: arguments,
                timeout: 300
            )
        } catch {
            throw MCPError.toolExecutionFailed("xcodebuild build launch failed: \(error)")
        }
    }

    private func readBuildSettings(
        mode: Mode,
        configuration: String,
        overrides: [String]
    ) async throws -> [SettingsBlock] {
        var arguments: [String] = []
        arguments.append(contentsOf: mode.selectorArgs)
        arguments.append(contentsOf: ["-configuration", configuration, "-showBuildSettings"])
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

    /// One block of build settings from `xcodebuild -showBuildSettings` — output
    /// is grouped by target via `Build settings for action … and target X:` headers
    /// when xcodebuild builds more than one target (e.g. multi-buildable schemes).
    struct SettingsBlock: Equatable {
        let target: String?
        let settings: [String: String]
    }

    /// Parse xcodebuild -showBuildSettings stdout into per-target blocks.
    ///
    /// xcodebuild emits two kinds of headers:
    /// 1. `Build settings from command line:` — echoes the KEY=VALUE overrides we
    ///    passed (e.g. `OBJROOT=…`, `ARCHS=…`). We discard these blocks; they aren't
    ///    a real target's settings.
    /// 2. `Build settings for action <action> and target <name>:` — a real target's
    ///    resolved settings. These become entries in the returned array.
    ///
    /// Lines without a recognized header that contain `KEY = VALUE` belong to the
    /// most recently opened block. Anything else (blank lines, command echoes) is
    /// ignored.
    func parseBuildSettings(_ text: String) -> [SettingsBlock] {
        var blocks: [SettingsBlock] = []
        var currentTarget: String? = nil
        var currentSettings: [String: String] = [:]
        var inDiscardableBlock = false
        var hasOpenBlock = false

        func flush() {
            if hasOpenBlock && !inDiscardableBlock {
                blocks.append(SettingsBlock(target: currentTarget, settings: currentSettings))
            }
            currentTarget = nil
            currentSettings = [:]
            inDiscardableBlock = false
            hasOpenBlock = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            switch classifyHeader(line: line) {
            case .targetSettings(let name):
                flush()
                currentTarget = name
                currentSettings = [:]
                inDiscardableBlock = false
                hasOpenBlock = true
                continue
            case .commandLineEcho:
                flush()
                currentTarget = nil
                currentSettings = [:]
                inDiscardableBlock = true
                hasOpenBlock = true
                continue
            case .none:
                break
            }

            // KEY = VALUE inside the current block. xcodebuild indents these by 4
            // spaces; be lenient about whitespace.
            var s = line
            while let first = s.first, first == " " || first == "\t" {
                s.removeFirst()
            }
            guard let eq = s.range(of: " = ") else { continue }
            let key = String(s[..<eq.lowerBound])
            guard !key.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else {
                continue
            }
            let value = String(s[eq.upperBound...])
            // Open an implicit unnamed block when KEY=VALUE lines arrive before any
            // header (very old xcodebuild emitted settings without a header for
            // single-target invocations).
            if !hasOpenBlock {
                hasOpenBlock = true
            }
            if !inDiscardableBlock {
                currentSettings[key] = value
            }
        }
        flush()
        return blocks
    }

    private enum HeaderKind {
        case targetSettings(String)
        case commandLineEcho
        case none
    }

    private func classifyHeader(line: String) -> HeaderKind {
        // Anchored at start (no leading whitespace allowed; xcodebuild's headers are
        // flush-left).
        if line == "Build settings from command line:" {
            return .commandLineEcho
        }
        let prefix = "Build settings for action "
        guard line.hasPrefix(prefix) else { return .none }
        let rest = line.dropFirst(prefix.count)
        guard let separator = rest.range(of: " and target ") else { return .none }
        let after = rest[separator.upperBound...]
        guard after.hasSuffix(":") else { return .none }
        let target = after.dropLast()
        return target.isEmpty ? .none : .targetSettings(String(target))
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

    private func ensureXcodeWorkspace(_ path: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw MCPError.invalidParams("`input.workspace` does not exist or is not a directory: \(path)")
        }
        guard path.hasSuffix(".xcworkspace") else {
            throw MCPError.invalidParams("`input.workspace` must end with `.xcworkspace`: \(path)")
        }
        let contents = path + "/contents.xcworkspacedata"
        guard FileManager.default.fileExists(atPath: contents) else {
            throw MCPError.invalidParams("`.xcworkspace` is missing contents.xcworkspacedata: \(contents)")
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
        // Build failure on the user's Swift code still produces a SwiftFileList (the
        // build system materializes it before swiftc runs). If the file is genuinely
        // missing we're past the point where xcodebuild has produced its plan — that's
        // a tool-execution failure, not a compile-diagnostic-as-output situation.
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.toolExecutionFailed(
                "xcodebuild did not produce a SwiftFileList at \(path) — the target may have no Swift sources or the build never reached the compile stage."
            )
        }
        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw MCPError.toolExecutionFailed("Failed to read SwiftFileList \(path): \(error)")
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
