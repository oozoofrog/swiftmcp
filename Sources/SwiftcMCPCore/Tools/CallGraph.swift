import Foundation

/// `call_graph`: emit SIL for a Swift source file and parse caller→callee edges + call-site
/// kind counts. Direct callees come from `function_ref @<mangled>` lines. Apply-class
/// instructions (`apply` / `try_apply` / `begin_apply`) and dynamic-dispatch lookups
/// (`witness_method`, `class_method`, `super_method`, `objc_method`) are counted per function.
public struct CallGraphTool: MCPTool {
    public struct Summary: Sendable, Codable, Equatable {
        public let totalFunctions: Int
        public let totalApplies: Int
        public let totalPartialApplies: Int
        public let totalDynamicDispatchSites: Int
        /// Dynamic-dispatch lookup sites divided by all call-site lookups
        /// (`function_ref` + dynamic-dispatch lookups). 0.0 when there are no calls.
        public let dynamicDispatchRatio: Double
    }

    public struct FunctionEntry: Sendable, Codable, Equatable {
        public let name: String
        public let directCallees: [String]
        public let apply: Int
        public let partialApply: Int
        public let witnessMethod: Int
        public let classMethod: Int
        public let superMethod: Int
        public let objcMethod: Int
    }

    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let summary: Summary
        public let functions: [FunctionEntry]
        public let compilerExitCode: Int32
        public let compilerStderr: String?
    }

    private let invocation: SwiftcInvocation
    private let resolver: BuildArgsResolver

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "call_graph",
            title: "Call Graph",
            description: """
            Emit canonical SIL for Swift inputs and extract a per-function summary of \
            direct callees (`function_ref` targets) and call-site instruction counts \
            (`apply`/`try_apply`/`begin_apply`, `partial_apply`, `witness_method`, \
            `class_method`, `super_method`, `objc_method`). Mangled names are reported \
            verbatim — clients can demangle externally if needed.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
                    "optimization": .object([
                        "type": .string("string"),
                        "description": .string("`none`, `speed`, `size`, or `unchecked`. Default `none` (raw call sites)."),
                        "default": .string("none")
                    ])
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
        let optimizationKey = dict["optimization"]?.asString ?? "none"
        guard let optimization = SwiftcInvocation.Options.Optimization(rawValue: optimizationKey) else {
            throw MCPError.invalidParams("`optimization` must be one of: none, speed, size, unchecked")
        }

        let resolved = try await resolver.resolveArgs(for: input)

        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let silURL = scratch.directory.appending(path: "out.sil", directoryHint: .notDirectory)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: ["-emit-sil"],
            inputFiles: resolved.inputFiles,
            outputFile: silURL,
            options: .init(resolved: resolved, optimization: optimization)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let silText = (try? String(contentsOf: silURL, encoding: .utf8)) ?? ""
        let parsed = SILCallGraphParser.parse(silText)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: input.target,
                durationMs: durationMs
            ),
            summary: parsed.summary,
            functions: parsed.functions,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}

/// Line-oriented SIL parser. Tracks function bodies via `sil … @<mangled> … {` headers
/// and `}` terminators, counting call-site instructions and `function_ref` targets within.
struct SILCallGraphParser {
    struct ParseOutput {
        let summary: CallGraphTool.Summary
        let functions: [CallGraphTool.FunctionEntry]
    }

    nonisolated(unsafe) static let funcStart = #/^sil [^@]*@([^ ]+)\s+:.*\{\s*$/#
    nonisolated(unsafe) static let funcEnd = #/^\}\s*$/#
    nonisolated(unsafe) static let directCall = #/=\s*function_ref\s+@([^ ]+)/#
    nonisolated(unsafe) static let applyKind = #/=\s*(apply|try_apply|begin_apply|partial_apply|witness_method|class_method|super_method|objc_method)\b/#

    static func parse(_ silText: String) -> ParseOutput {
        var functions: [CallGraphTool.FunctionEntry] = []
        var current: Accumulator?

        for rawLine in silText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let acc = current {
                if (try? Self.funcEnd.wholeMatch(in: line)) != nil {
                    functions.append(acc.build())
                    current = nil
                    continue
                }
                if let match = try? Self.directCall.firstMatch(in: line) {
                    acc.directCallees.insert(String(match.output.1))
                }
                if let match = try? Self.applyKind.firstMatch(in: line) {
                    switch String(match.output.1) {
                    case "apply", "try_apply", "begin_apply":
                        acc.apply += 1
                    case "partial_apply":
                        acc.partialApply += 1
                    case "witness_method":
                        acc.witnessMethod += 1
                    case "class_method":
                        acc.classMethod += 1
                    case "super_method":
                        acc.superMethod += 1
                    case "objc_method":
                        acc.objcMethod += 1
                    default:
                        break
                    }
                }
                current = acc
            } else if let match = try? Self.funcStart.firstMatch(in: line) {
                current = Accumulator(name: String(match.output.1))
            }
        }

        let totalApplies = functions.reduce(0) { $0 + $1.apply }
        let totalPartialApplies = functions.reduce(0) { $0 + $1.partialApply }
        let totalDynamicDispatch = functions.reduce(0) { $0 + $1.witnessMethod + $1.classMethod + $1.superMethod + $1.objcMethod }
        let totalDirectCallSites = functions.reduce(0) { $0 + $1.directCallees.count }
        let lookupTotal = totalDirectCallSites + totalDynamicDispatch
        let ratio = lookupTotal == 0 ? 0.0 : Double(totalDynamicDispatch) / Double(lookupTotal)

        return ParseOutput(
            summary: CallGraphTool.Summary(
                totalFunctions: functions.count,
                totalApplies: totalApplies,
                totalPartialApplies: totalPartialApplies,
                totalDynamicDispatchSites: totalDynamicDispatch,
                dynamicDispatchRatio: ratio
            ),
            functions: functions
        )
    }

    final class Accumulator {
        let name: String
        var directCallees: Set<String> = []
        var apply: Int = 0
        var partialApply: Int = 0
        var witnessMethod: Int = 0
        var classMethod: Int = 0
        var superMethod: Int = 0
        var objcMethod: Int = 0

        init(name: String) {
            self.name = name
        }

        func build() -> CallGraphTool.FunctionEntry {
            CallGraphTool.FunctionEntry(
                name: name,
                directCallees: directCallees.sorted(),
                apply: apply,
                partialApply: partialApply,
                witnessMethod: witnessMethod,
                classMethod: classMethod,
                superMethod: superMethod,
                objcMethod: objcMethod
            )
        }
    }
}
