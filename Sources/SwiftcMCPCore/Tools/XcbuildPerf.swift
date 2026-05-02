import Foundation

/// `xcbuild_perf`: run a clean `xcodebuild build` against an `xcodeProject` /
/// `xcodeWorkspace` BuildInput and return parsed performance breakdowns.
///
/// Two channels feed the response:
///   1. **`xcodebuild -showBuildTimingSummary`** stdout (always emitted) →
///      per-command-class wall-clock (CompileSwiftSources, Ld, CompileC, …).
///      Stable text format. Parsed by `BuildTimingSummaryParser`.
///   2. **`xclogparser parse --reporter json`** (optional augmentation, fires
///      iff `xclogparser` resolves on PATH). Parses the `.xcactivitylog` Xcode
///      writes under DerivedData and yields per-target rollups with
///      compile-Swift / link breakdowns. Parsed by
///      `XclogparserOutputParser`. Absence is reported via
///      `xclogparserAvailable: false`; tool still succeeds with phases.
///
/// Each call lands in its own `PersistentScratch` so DerivedData is isolated —
/// every invocation is therefore a cold build, by construction. Sharing
/// DerivedData across calls (for incremental measurement) is a future
/// milestone; the response paths give the caller everything they need to
/// inspect the build manually.
public struct XcbuildPerfTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let phases: [BuildTimingSummaryParser.Phase]
        public let totalWallClockSec: Double
        public let buildSucceeded: Bool
        public let xcodebuildExitCode: Int32
        public let xcodebuildTimedOut: Bool
        public let buildLogPath: String
        public let resultBundlePath: String
        public let xclogparserAvailable: Bool
        public let xcactivitylogPath: String?
        public let targetTimings: [XclogparserOutputParser.TargetTiming]?
    }

    private let toolchain: ToolchainResolver

    /// xcbuild_perf does not take a `BuildArgsResolver` — the perf measurement
    /// runs xcodebuild itself with its own derived data + result bundle, and
    /// going through the shared resolver would add a redundant xcodebuild
    /// invocation just to read the SwiftFileList (which we don't use). The
    /// `resolver` parameter exists only to match the registration shape in
    /// Mcpswx; it's intentionally ignored.
    public init(
        toolchain: ToolchainResolver,
        resolver: BuildArgsResolver = DefaultBuildArgsResolver()
    ) {
        self.toolchain = toolchain
        _ = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "xcbuild_perf",
            title: "Xcode Build Performance",
            description: """
            Run a cold `xcodebuild build` against an Xcode project or workspace and \
            report per-command-class wall-clock (CompileSwiftSources, Ld, CompileC, …) \
            from `-showBuildTimingSummary`. If `xclogparser` is on PATH, additionally \
            extract per-target timings from the build's `.xcactivitylog`. Each call \
            uses an isolated DerivedData/SYMROOT/OBJROOT; the result includes paths \
            to the build log and `.xcresult` bundle for follow-up analysis. Best \
            used on an otherwise idle host — concurrent xcodebuild jobs introduce \
            measurement noise the tool can't see.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty
                ]),
                "required": .array([.string("input")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments else {
            throw MCPError.invalidParams("arguments must be an object")
        }
        let input = try BuildInput.decode(dict["input"])
        switch input {
        case .xcodeProject, .xcodeWorkspace:
            break
        case .file, .directory, .swiftPMPackage:
            throw MCPError.invalidParams("xcbuild_perf only supports `xcode_project` and `xcode_workspace` inputs.")
        }

        // We deliberately skip `BuildArgsResolver.resolveArgs` for this tool.
        // The shared resolver path runs its own xcodebuild build to materialize
        // the SwiftFileList and is the slow channel observed wedging on
        // macOS 26.x under contention; for perf measurement we don't need the
        // file list at all — we just need to run xcodebuild ourselves with
        // `-showBuildTimingSummary` and parse stdout. The BuildInput already
        // carries the project/scheme/target identity we need.
        let toolchainResolved = try await toolchain.resolve()

        let scratch = try PersistentScratch(prefix: "swiftmcp-xcbuildperf")
        let buildLogURL = scratch.directory.appending(path: "build.log", directoryHint: .notDirectory)
        let derivedDataURL = scratch.directory.appending(path: "dd", directoryHint: .isDirectory)
        let objrootURL = scratch.directory.appending(path: "obj", directoryHint: .isDirectory)
        let symrootURL = scratch.directory.appending(path: "sym", directoryHint: .isDirectory)
        let resultBundleURL = scratch.directory.appending(path: "result.xcresult", directoryHint: .notDirectory)

        let start = Date()
        let arguments = makeXcodebuildArguments(
            input: input,
            derivedDataPath: derivedDataURL.path,
            objroot: objrootURL.path,
            symroot: symrootURL.path,
            resultBundlePath: resultBundleURL.path
        )

        let buildOutcome = try await runProcessWithTimeoutLoggingTo(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            logURL: buildLogURL,
            timeout: 600
        )

        // Read what xcodebuild actually printed; the timing summary lives at the tail.
        // Tolerate read failures — tool still reports timings as empty in that case.
        let logText = (try? String(contentsOf: buildLogURL, encoding: .utf8)) ?? ""
        let summary = BuildTimingSummaryParser.parse(logText)
        let totalWall = summary.phases.reduce(0.0) { $0 + $1.wallClockSec }

        // xclogparser augmentation. Best-effort: any failure (binary missing,
        // log not findable, parse error) is a downgrade to nil targetTimings,
        // not a tool failure — the user's build still succeeded.
        var xclogAvailable = false
        var xcactivitylogPath: String? = nil
        var targetTimings: [XclogparserOutputParser.TargetTiming]? = nil
        if let xclogparserBinary = await locateXclogparser() {
            xclogAvailable = true
            if let activityLog = findLatestActivityLog(under: derivedDataURL) {
                xcactivitylogPath = activityLog.path
                targetTimings = await runXclogparser(binary: xclogparserBinary, activityLog: activityLog)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let result = Result(
            meta: .init(
                toolchain: .init(path: toolchainResolved.swiftcPath, version: toolchainResolved.version),
                target: targetTriple(of: input),
                durationMs: durationMs
            ),
            phases: summary.phases,
            totalWallClockSec: totalWall,
            buildSucceeded: summary.buildSucceeded,
            xcodebuildExitCode: buildOutcome.exitCode,
            xcodebuildTimedOut: buildOutcome.timedOut,
            buildLogPath: buildLogURL.path,
            resultBundlePath: resultBundleURL.path,
            xclogparserAvailable: xclogAvailable,
            xcactivitylogPath: xcactivitylogPath,
            targetTimings: targetTimings
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }

    // MARK: - xcodebuild argument assembly

    private func makeXcodebuildArguments(
        input: BuildInput,
        derivedDataPath: String,
        objroot: String,
        symroot: String,
        resultBundlePath: String
    ) -> [String] {
        var args: [String] = []
        switch input {
        case .xcodeProject(let path, let target, let configuration, _):
            // `-derivedDataPath` requires a `-scheme` (xcodebuild errors out
            // with `-target` alone). The dominant convention for Xcode
            // projects is that the auto-generated scheme name matches the
            // build target name, so we treat `target_name` as the scheme
            // name here. Projects whose schemes diverge from target names
            // can use `xcode_workspace` input or be enhanced with a separate
            // scheme field in a follow-up.
            args.append(contentsOf: ["-project", absolutize(path)])
            args.append(contentsOf: ["-scheme", target])
            args.append(contentsOf: ["-configuration", configuration ?? "Debug"])
        case .xcodeWorkspace(let path, let scheme, _, let configuration, _):
            args.append(contentsOf: ["-workspace", absolutize(path)])
            args.append(contentsOf: ["-scheme", scheme])
            args.append(contentsOf: ["-configuration", configuration ?? "Debug"])
        default:
            // Already gated above; defensive default keeps the switch exhaustive.
            break
        }
        args.append("-showBuildTimingSummary")
        args.append(contentsOf: ["-derivedDataPath", derivedDataPath])
        args.append(contentsOf: ["-resultBundlePath", resultBundlePath])
        // Clean + build to guarantee a cold measurement under the isolated
        // DerivedData. Without `clean` the build system can short-circuit
        // when DerivedData has any cached intermediate, which would zero
        // the timing for the user's real change set.
        args.append(contentsOf: ["clean", "build"])
        args.append("CODE_SIGNING_ALLOWED=NO")
        args.append("GENERATE_INFOPLIST_FILE=YES")
        args.append("ARCHS=\(currentArch())")
        args.append("OBJROOT=\(objroot)")
        args.append("SYMROOT=\(symroot)")
        return args
    }

    /// Pull the optional triple parameter out of either xcode BuildInput
    /// case so we can echo it in `meta.target` without going through the
    /// resolver.
    private func targetTriple(of input: BuildInput) -> String? {
        switch input {
        case .xcodeProject(_, _, _, let target): return target
        case .xcodeWorkspace(_, _, _, _, let target): return target
        default: return nil
        }
    }

    private func absolutize(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path
    }

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    // MARK: - xclogparser augmentation

    /// Probe PATH for an `xclogparser` binary. Returns the absolute path if
    /// found, nil otherwise — we use `/usr/bin/env which xclogparser` so the
    /// lookup respects the user's shell PATH (Homebrew formulas typically
    /// install under `/opt/homebrew/bin`).
    private func locateXclogparser() async -> String? {
        do {
            let result = try await runProcess(
                executable: "/usr/bin/env",
                arguments: ["which", "xclogparser"]
            )
            guard result.exitCode == 0 else { return nil }
            let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    /// Walk `<derivedDataPath>/Logs/Build` and return the newest
    /// `.xcactivitylog` by mtime. xcodebuild can produce multiple per build
    /// when sub-targets fail and retry; the latest wall-clock is the one the
    /// caller actually wants.
    private func findLatestActivityLog(under derivedData: URL) -> URL? {
        let logDir = derivedData.appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "Build", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let logs = contents.filter { $0.pathExtension == "xcactivitylog" }
        return logs
            .map { url -> (URL, Date) in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
    }

    /// Spawn `xclogparser parse --file <log> --reporter json` and parse the
    /// output. Anything other than a successful run + clean parse downgrades
    /// to nil — the perf tool is allowed to lose the per-target detail
    /// silently, but its own response must still succeed.
    private func runXclogparser(binary: String, activityLog: URL) async -> [XclogparserOutputParser.TargetTiming]? {
        do {
            let result = try await runProcess(
                executable: binary,
                arguments: ["parse", "--file", activityLog.path, "--reporter", "json"]
            )
            guard result.exitCode == 0 else { return nil }
            let parsed = try XclogparserOutputParser.parse(jsonText: result.standardOutput)
            return parsed.targets
        } catch {
            return nil
        }
    }
}
