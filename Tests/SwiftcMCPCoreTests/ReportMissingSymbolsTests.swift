import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ReportMissingSymbols (integration)")
struct ReportMissingSymbolsTests {
    @Test
    func cleanCodeReportsNoMissing() async throws {
        let tool = ReportMissingSymbolsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("""
            func add(_ a: Int, _ b: Int) -> Int { a + b }
            let _ = add(1, 2)
            """)
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(ReportMissingSymbolsTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.missingSymbols.isEmpty)
        #expect(result.declaredIdentifiers.contains("add"))
    }

    @Test
    func reportsMissingValueAndType() async throws {
        let tool = ReportMissingSymbolsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("""
            func wrap() {
                let result = unknownThing(1, 2)
                let typed: NotDefined = .init()
                _ = result
                _ = typed
            }
            """)
        ]))

        let result = try decodeResult(ReportMissingSymbolsTool.Result.self, response)
        #expect(result.compilerExitCode != 0)
        let names = Set(result.missingSymbols.map(\.name))
        #expect(names.contains("unknownThing"))
        #expect(names.contains("NotDefined"))

        if let unknownThing = result.missingSymbols.first(where: { $0.name == "unknownThing" }) {
            #expect(unknownThing.kind == .value)
            #expect(unknownThing.usagePattern == .call)
        } else {
            Issue.record("missing 'unknownThing' symbol")
        }
        if let notDefined = result.missingSymbols.first(where: { $0.name == "NotDefined" }) {
            #expect(notDefined.kind == .type)
        } else {
            Issue.record("missing 'NotDefined' symbol")
        }
    }

    @Test
    func reportsMissingModule() async throws {
        let tool = ReportMissingSymbolsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("import NoSuchSwiftMcpModule\n")
        ]))

        let result = try decodeResult(ReportMissingSymbolsTool.Result.self, response)
        #expect(result.missingSymbols.contains(where: { $0.name == "NoSuchSwiftMcpModule" && $0.kind == .module }))
    }

    @Test
    func emptyCodeRejected() async throws {
        let tool = ReportMissingSymbolsTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object(["code": .string("")]))
        }
    }
}

@Suite("SuggestStubs (integration)")
struct SuggestStubsTests {
    @Test
    func stubsForCallSiteWithArguments() async throws {
        let tool = SuggestStubsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("""
            func wrap() { _ = unknownThing(1, 2, 3) }
            """)
        ]))

        let result = try decodeResult(SuggestStubsTool.Result.self, response)
        #expect(result.resolvedFromCompiler == true)
        let stub = try #require(result.stubs.first(where: { $0.name == "unknownThing" }))
        #expect(stub.kind == .value)
        #expect(stub.swift.contains("func unknownThing"))
        #expect(stub.swift.contains("a0"))
        #expect(stub.swift.contains("a2"))
        #expect(stub.swift.contains("-> Any"))
    }

    @Test
    func stubsForTypeReference() async throws {
        let tool = SuggestStubsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("""
            func wrap() { let _: NotDefined = .init() }
            """)
        ]))

        let result = try decodeResult(SuggestStubsTool.Result.self, response)
        let stub = try #require(result.stubs.first(where: { $0.name == "NotDefined" }))
        #expect(stub.kind == .type)
        #expect(stub.swift.contains("struct NotDefined"))
        #expect(stub.swift.contains("public init()"))
    }

    @Test
    func skipsModuleImports() async throws {
        let tool = SuggestStubsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("import NoSuchSwiftMcpModule\n")
        ]))

        let result = try decodeResult(SuggestStubsTool.Result.self, response)
        #expect(result.stubs.contains(where: { $0.name == "NoSuchSwiftMcpModule" }) == false)
        #expect(result.skipped.contains(where: { $0.name == "NoSuchSwiftMcpModule" }))
    }

    @Test
    func acceptsExternallyProvidedMissingSymbolList() async throws {
        let tool = SuggestStubsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("let _ = explicitName(1)"),
            "missing_symbols": .array([
                .object([
                    "name": .string("explicitName"),
                    "kind": .string("value"),
                    "locations": .array([
                        .object(["line": .integer(1), "column": .integer(9)])
                    ]),
                    "usagePattern": .string("call"),
                    "falsePositive": .bool(false)
                ])
            ])
        ]))

        let result = try decodeResult(SuggestStubsTool.Result.self, response)
        #expect(result.resolvedFromCompiler == false)
        let stub = try #require(result.stubs.first(where: { $0.name == "explicitName" }))
        #expect(stub.swift.contains("func explicitName"))
        #expect(stub.swift.contains("a0"))
    }

    /// End-to-end: report → suggest → prepend stubs → build_isolated_snippet succeeds.
    /// This is the workflow the LLM is expected to drive, exercised once in the test
    /// suite as a smoke check.
    @Test
    func reportSuggestBuildPipeline() async throws {
        let originalCode = """
        let value = unknownDouble(7)
        print(value)
        """

        let report = ReportMissingSymbolsTool(toolchain: ToolchainResolver())
        let reportResponse = try await report.call(arguments: .object([
            "code": .string(originalCode)
        ]))
        let reportResult = try decodeResult(ReportMissingSymbolsTool.Result.self, reportResponse)
        #expect(reportResult.compilerExitCode != 0)
        #expect(reportResult.missingSymbols.contains(where: { $0.name == "unknownDouble" }))

        let suggest = SuggestStubsTool(toolchain: ToolchainResolver())
        let suggestResponse = try await suggest.call(arguments: .object([
            "code": .string(originalCode)
        ]))
        let suggestResult = try decodeResult(SuggestStubsTool.Result.self, suggestResponse)
        #expect(suggestResult.stubsSwift.isEmpty == false)

        // The LLM in real life would refine the stubs. Here we replace `Any`/`fatalError`
        // with a working body so the resulting program type-checks and runs.
        let workingStub = """
        func unknownDouble(_ a0: Int) -> Int { a0 * 2 }

        """
        let stitched = workingStub + originalCode

        let build = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())
        let buildResponse = try await build.call(arguments: .object([
            "code": .string(stitched)
        ]))
        #expect(buildResponse.isError == false)
        let buildResult = try decodeResult(BuildIsolatedSnippetTool.Result.self, buildResponse)
        #expect(buildResult.buildExitCode == 0)
        #expect(buildResult.runStdout?.contains("14") == true)
    }
}
