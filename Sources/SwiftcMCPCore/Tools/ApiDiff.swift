import Foundation

/// `api_diff`: compare two snapshots of a Swift module's API surface and report
/// breaking / additive changes by category.
///
/// Pipeline:
/// 1. Resolve `baseline` and `current` BuildInputs through `BuildArgsResolver`
///    (file/directory/swiftPMPackage). xcodeProject/xcodeWorkspace are deferred.
/// 2. For each side, materialize a `.swiftmodule` whose directory becomes the
///    `-I` search path for swift-api-digester. file/directory inputs go through
///    a fresh `swiftc -emit-module`; swiftPMPackage uses the modules folder the
///    SwiftPM resolver already populated.
/// 3. `swift-api-digester -dump-sdk -module <Name> -I <dir> -o <persistent>/X.json`
///    twice — one per side.
/// 4. `swift-api-digester -diagnose-sdk -input-paths a.json -input-paths b.json
///    [-abi] -compiler-style-diags -disable-fail-on-error` — combines the two
///    dumps into a flat text diff.
/// 5. `ApiDigesterParser.parse` turns the text into structured findings.
public struct ApiDiffTool: MCPTool {
    public struct SummarySection: Sendable, Codable, Equatable {
        public let totalFindings: Int
        public let byCategory: [String: Int]
    }

    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let moduleName: String
        public let abiMode: Bool
        public let baselineDumpPath: String
        public let currentDumpPath: String
        public let summary: SummarySection
        public let findings: ApiDigesterFindings
        public let rawDiagnoseOutput: String
        public let diagnoseExitCode: Int32
    }

    private let toolchain: ToolchainResolver
    private let resolver: BuildArgsResolver
    private let invocation: SwiftcInvocation

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.toolchain = toolchain
        self.resolver = resolver
        self.invocation = SwiftcInvocation(resolver: toolchain)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "api_diff",
            title: "API Diff",
            description: """
            Compare two snapshots of a Swift module's public API surface and report \
            removed / changed / added declarations. Wraps `swift-api-digester` \
            (`-dump-sdk` + `-diagnose-sdk`). `baseline` and `current` are full \
            BuildInput objects (file / directory / package). `module_name` must \
            match the module both sides emit. `abi: true` switches to the ABI \
            checker which also reports newly-added decls without `@available`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "baseline": BuildInput.jsonSchemaProperty,
                    "current": BuildInput.jsonSchemaProperty,
                    "module_name": .object([
                        "type": .string("string"),
                        "description": .string("Module name used for both dump-sdk passes. Must match the name the underlying compile uses for both sides.")
                    ]),
                    "abi": .object([
                        "type": .string("boolean"),
                        "description": .string("Pass `-abi` to swift-api-digester. Default false (API checker). True enables ABI checker which also reports new APIs missing `@available`."),
                        "default": .bool(false)
                    ])
                ]),
                "required": .array([.string("baseline"), .string("current"), .string("module_name")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments else {
            throw MCPError.invalidParams("arguments must be an object")
        }
        let baseline = try BuildInput.decode(dict["baseline"])
        let current = try BuildInput.decode(dict["current"])
        guard let moduleName = dict["module_name"]?.asString, !moduleName.isEmpty else {
            throw MCPError.invalidParams("`module_name` is required and must be non-empty")
        }
        let abiMode = dict["abi"]?.asBool ?? false

        let resolvedToolchain = try await toolchain.resolve()
        let digesterPath = swiftApiDigesterPath(swiftcPath: resolvedToolchain.swiftcPath)

        // Each side gets its own PersistentScratch so the dump JSONs stick around
        // for the response (clients can inspect them post-call) and the build
        // products don't collide between baseline and current.
        let baselineScratch = try PersistentScratch(prefix: "swiftmcp-apidiff-baseline")
        let currentScratch = try PersistentScratch(prefix: "swiftmcp-apidiff-current")

        let start = Date()

        let baselineModuleDir = try await materializeModule(
            input: baseline,
            moduleName: moduleName,
            scratch: baselineScratch
        )
        let currentModuleDir = try await materializeModule(
            input: current,
            moduleName: moduleName,
            scratch: currentScratch
        )

        let baselineDumpPath = baselineScratch.directory.appending(path: "dump.json", directoryHint: .notDirectory).path
        let currentDumpPath = currentScratch.directory.appending(path: "dump.json", directoryHint: .notDirectory).path

        try await runDump(
            digesterPath: digesterPath,
            moduleName: moduleName,
            includePath: baselineModuleDir,
            outputPath: baselineDumpPath,
            target: baseline.target
        )
        try await runDump(
            digesterPath: digesterPath,
            moduleName: moduleName,
            includePath: currentModuleDir,
            outputPath: currentDumpPath,
            target: current.target
        )

        let diagnoseOutcome = try await runDiagnose(
            digesterPath: digesterPath,
            baselineDump: baselineDumpPath,
            currentDump: currentDumpPath,
            abiMode: abiMode
        )

        // swift-api-digester routes its diagnostic report (the `/* Section */`
        // text) to *stderr*, not stdout — verified live in the Stage 4-4 probe.
        // stdout is empty for this tool; only stderr carries the findings.
        let findings = ApiDigesterParser.parse(diagnoseOutcome.standardError)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let result = Result(
            meta: .init(
                toolchain: .init(path: resolvedToolchain.swiftcPath, version: resolvedToolchain.version),
                target: baseline.target ?? current.target,
                durationMs: durationMs
            ),
            moduleName: moduleName,
            abiMode: abiMode,
            baselineDumpPath: baselineDumpPath,
            currentDumpPath: currentDumpPath,
            summary: SummarySection(
                totalFindings: findings.totalFindings,
                byCategory: findings.byCategory
            ),
            findings: findings,
            rawDiagnoseOutput: diagnoseOutcome.standardError,
            diagnoseExitCode: diagnoseOutcome.exitCode
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }

    // MARK: - .swiftmodule materialization

    /// Build (or locate) the `.swiftmodule` for a BuildInput and return the
    /// directory swift-api-digester should pass via `-I`. The directory must
    /// contain `<moduleName>.swiftmodule`.
    private func materializeModule(
        input: BuildInput,
        moduleName: String,
        scratch: PersistentScratch
    ) async throws -> String {
        switch input {
        case .file, .directory:
            let resolved = try await resolver.resolveArgs(for: input)
            let modulePath = scratch.directory.appending(
                path: "\(moduleName).swiftmodule",
                directoryHint: .notDirectory
            )
            let outcome = try await invocation.run(
                modeArgs: ["-emit-module", "-emit-module-path", modulePath.path],
                inputFiles: resolved.inputFiles,
                outputFile: nil,
                options: SwiftcInvocation.Options(
                    target: resolved.target,
                    optimization: nil,
                    moduleName: moduleName,
                    searchPaths: resolved.searchPaths,
                    frameworkSearchPaths: resolved.frameworkSearchPaths,
                    extraSwiftcArgs: resolved.extraSwiftcArgs
                )
            )
            guard outcome.process.exitCode == 0 else {
                throw MCPError.toolExecutionFailed(
                    "swiftc -emit-module failed (exit=\(outcome.process.exitCode)): \(truncate(outcome.process.standardError))"
                )
            }
            return scratch.directory.path

        case .swiftPMPackage:
            // The SwiftPM resolver runs `swift build` and exposes the modules
            // dir via `searchPaths`. The first entry is `<bin>/Modules` which
            // contains every target's `.swiftmodule`.
            let resolved = try await resolver.resolveArgs(for: input)
            guard let modulesDir = resolved.searchPaths.first else {
                throw MCPError.toolExecutionFailed(
                    "SwiftPM resolver returned no searchPaths; cannot locate `.swiftmodule` for api_diff."
                )
            }
            return modulesDir

        case .xcodeProject, .xcodeWorkspace:
            throw MCPError.invalidParams(
                "api_diff currently supports `file`, `directory`, and `package` inputs. Xcode project / workspace support is deferred to a follow-up milestone."
            )
        }
    }

    // MARK: - swift-api-digester invocations

    private func runDump(
        digesterPath: String,
        moduleName: String,
        includePath: String,
        outputPath: String,
        target: String?
    ) async throws {
        var arguments = [
            "-dump-sdk",
            "-module", moduleName,
            "-I", includePath,
            "-o", outputPath,
            "-avoid-tool-args",
            "-avoid-location"
        ]
        if let target {
            arguments.append(contentsOf: ["-target", target])
        }
        let result: ProcessResult
        do {
            result = try await runProcess(executable: digesterPath, arguments: arguments)
        } catch {
            throw MCPError.toolExecutionFailed("swift-api-digester -dump-sdk launch failed: \(error)")
        }
        guard result.exitCode == 0 else {
            throw MCPError.toolExecutionFailed(
                "swift-api-digester -dump-sdk failed (exit=\(result.exitCode)) for module '\(moduleName)' at \(includePath): \(truncate(result.standardError))"
            )
        }
    }

    private func runDiagnose(
        digesterPath: String,
        baselineDump: String,
        currentDump: String,
        abiMode: Bool
    ) async throws -> ProcessResult {
        var arguments = [
            "-diagnose-sdk",
            "-input-paths", baselineDump,
            "-input-paths", currentDump,
            "-compiler-style-diags",
            "-disable-fail-on-error"
        ]
        if abiMode {
            arguments.append("-abi")
        }
        let result: ProcessResult
        do {
            result = try await runProcess(executable: digesterPath, arguments: arguments)
        } catch {
            throw MCPError.toolExecutionFailed("swift-api-digester -diagnose-sdk launch failed: \(error)")
        }
        // `-disable-fail-on-error` makes a non-zero exit unusual but we don't
        // throw here either — the caller can inspect `diagnoseExitCode` and
        // `rawDiagnoseOutput` to decide what to do.
        return result
    }

    // MARK: - Helpers

    /// Sibling of `swiftc` in the toolchain. Same trick `SwiftPMPackageResolver`
    /// uses to find the `swift` driver.
    private func swiftApiDigesterPath(swiftcPath: String) -> String {
        URL(fileURLWithPath: swiftcPath)
            .deletingLastPathComponent()
            .appending(path: "swift-api-digester", directoryHint: .notDirectory).path
    }

    private func truncate(_ text: String, limit: Int = 800) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…(truncated)"
    }
}
