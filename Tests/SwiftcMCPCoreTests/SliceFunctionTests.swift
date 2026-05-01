import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("SliceFunction (integration)")
struct SliceFunctionTests {
    private func libraryPath() -> String {
        fixturePath("SliceTargets/Library.swift")
    }

    @Test
    func slicesFunctionWithStructDependency() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(libraryPath())]),
            "function_name": .string("describe")
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(SliceFunctionTool.Result.self, response)

        let names = Set(result.includedSymbols.map(\.name))
        #expect(names.contains("describe"))
        #expect(names.contains("formatLabel"))
        #expect(names.contains("Counter"))
        // `unrelated` is independent of `describe` and must not be included.
        #expect(names.contains("unrelated") == false)
        // `useHelper` is also independent.
        #expect(names.contains("useHelper") == false)

        // The slice itself must contain the describe body verbatim.
        #expect(result.slicedCode.contains("public func describe(_ counter: Counter)"))
        #expect(result.slicedCode.contains("public struct Counter"))
        #expect(result.slicedCode.contains("public func formatLabel"))

        // Imports preserved.
        #expect(result.slicedCode.contains("import Foundation"))
    }

    @Test
    func slicedCodeSelfTypeChecks() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(libraryPath())]),
            "function_name": .string("describe")
        ]))
        let result = try decodeResult(SliceFunctionTool.Result.self, response)
        #expect(result.verification.compilerExitCode == 0)
        #expect(result.verification.unresolvedReferences.isEmpty)
    }

    @Test
    func unknownFunctionReturnsInvalidParams() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            _ = try await tool.call(arguments: .object([
                "input": .object(["file": .string(libraryPath())]),
                "function_name": .string("doesNotExist")
            ]))
        }
    }

    @Test
    func ambiguousOverloadIsRejectedWithoutSignatureKey() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        do {
            _ = try await tool.call(arguments: .object([
                "input": .object(["file": .string(libraryPath())]),
                "function_name": .string("helper")
            ]))
            Issue.record("expected ambiguous overload throw")
        } catch let error as MCPError {
            guard case .invalidParams(let message) = error else {
                Issue.record("expected invalidParams, got \(error)"); return
            }
            #expect(message.contains("overloaded"))
            #expect(message.contains("helper("))
        }
    }

    @Test
    func explicitSignatureKeyDisambiguatesOverload() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(libraryPath())]),
            "function_name": .string("helper(_:)")
        ]))
        let result = try decodeResult(SliceFunctionTool.Result.self, response)
        let signatureKeys = Set(result.includedSymbols.map(\.signatureKey))
        #expect(signatureKeys.contains("helper(_:)"))
        // `helper()` is unrelated to `helper(_:)`, so it must NOT be pulled in.
        #expect(signatureKeys.contains("helper()") == false)
    }

    /// End-to-end: slice → suggest_stubs (clean slice should produce no stubs) →
    /// build_isolated_snippet on the slice (succeeds because the slice is
    /// self-contained, no main entry point so we just check buildExitCode).
    @Test
    func slicePipesIntoSuggestStubsAndBuildSucceeds() async throws {
        let slicer = SliceFunctionTool(toolchain: ToolchainResolver())
        let sliceResponse = try await slicer.call(arguments: .object([
            "input": .object(["file": .string(libraryPath())]),
            "function_name": .string("describe")
        ]))
        let sliceResult = try decodeResult(SliceFunctionTool.Result.self, sliceResponse)
        let slicedCode = sliceResult.slicedCode

        let suggester = SuggestStubsTool(toolchain: ToolchainResolver())
        let suggestResponse = try await suggester.call(arguments: .object([
            "code": .string(slicedCode)
        ]))
        let suggestResult = try decodeResult(SuggestStubsTool.Result.self, suggestResponse)
        // A self-contained slice should yield no stubs.
        #expect(suggestResult.stubs.isEmpty)

        // build_isolated_snippet expects executable code with a top-level entry. We
        // append a tiny driver that exercises the slice so it actually links.
        let driver = """

        let result = describe(Counter(value: 5))
        print(result)
        """
        let runnable = slicedCode + driver

        let builder = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())
        let buildResponse = try await builder.call(arguments: .object([
            "code": .string(runnable)
        ]))
        #expect(buildResponse.isError == false)
        let buildResult = try decodeResult(BuildIsolatedSnippetTool.Result.self, buildResponse)
        #expect(buildResult.buildExitCode == 0)
        #expect(buildResult.runStdout?.contains("<6>") == true)
    }
}
