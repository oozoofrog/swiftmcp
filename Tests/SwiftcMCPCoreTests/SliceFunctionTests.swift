import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("SliceFunction.mergeOverlappingRanges")
struct SliceFunctionMergeRangesTests {
    private func entry(_ start: Int, _ end: Int, name: String = "x") -> DeclIndex.Entry {
        DeclIndex.Entry(
            filePath: "/tmp/test.swift",
            name: name,
            signatureKey: name,
            kind: .function,
            startLine: start,
            startColumn: 1,
            endLine: end,
            endColumn: 1
        )
    }

    @Test
    func mergesIdenticalRanges() {
        let ranges = SliceFunctionTool.mergeOverlappingRanges([
            entry(1, 1, name: "a"),
            entry(1, 1, name: "b")
        ])
        #expect(ranges == [1...1])
    }

    @Test
    func unionsOverlappingRanges() {
        // (1, 1) inside (1, 3) — single decl on line 1 + multi-line decl starting on
        // line 1. Result is (1, 3), not (1, 1) + (1, 3) duplicating line 1.
        let ranges = SliceFunctionTool.mergeOverlappingRanges([
            entry(1, 1, name: "a"),
            entry(1, 3, name: "b")
        ])
        #expect(ranges == [1...3])
    }

    @Test
    func keepsDisjointRangesSeparate() {
        // Adjacent but non-overlapping (3 ends, 5 begins) — keep separate so the
        // join("\n\n") preserves the gap when the original source had a blank line.
        let ranges = SliceFunctionTool.mergeOverlappingRanges([
            entry(1, 3, name: "a"),
            entry(5, 7, name: "b")
        ])
        #expect(ranges == [1...3, 5...7])
    }

    @Test
    func handlesUnsortedInput() {
        let ranges = SliceFunctionTool.mergeOverlappingRanges([
            entry(10, 12, name: "c"),
            entry(1, 3, name: "a"),
            entry(2, 5, name: "b")
        ])
        #expect(ranges == [1...5, 10...12])
    }

    @Test
    func emptyInputReturnsEmpty() {
        #expect(SliceFunctionTool.mergeOverlappingRanges([]).isEmpty)
    }
}

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

    /// Per Codex stop-time review: two top-level decls on the same physical line
    /// must not cause the slicer to emit that line twice. The fixture has
    /// `typealias Foo = Int; typealias Bar = String` on a single line, and `use()`
    /// references both. The merge step in SliceFunctionTool collapses both
    /// startLine=1 entries into a single rendered range.
    @Test
    func sameLineMultiDeclsRenderAsSingleLine() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(fixturePath("SliceTargets/MultiDeclLine.swift"))]),
            "function_name": .string("use")
        ]))
        let result = try decodeResult(SliceFunctionTool.Result.self, response)

        // Both typealiases must be in includedSymbols — the BFS still tracks them
        // separately because Entry-keyed deduping kept them distinct.
        let names = Set(result.includedSymbols.filter { $0.kind == .typealiasDecl }.map(\.name))
        #expect(names == ["Foo", "Bar"])

        // The typealias line, however, must appear exactly once in the rendered
        // slice — that's the contract the merge step protects.
        let occurrences = result.slicedCode.components(
            separatedBy: "public typealias Foo = Int; public typealias Bar = String"
        ).count - 1
        #expect(occurrences == 1)

        // And the slice still type-checks (no spurious duplicate definition errors).
        #expect(result.verification.compilerExitCode == 0)
        #expect(result.verification.unresolvedReferences.isEmpty)
    }

    /// Per Codex stop-time review: a struct and its extension share a
    /// `signatureKey` (both report the type's name). The earlier visited-set
    /// keyed on signatureKey would have admitted only one of them and dropped
    /// the other — silently breaking slices that call extension methods.
    /// `describeWithExtension` exercises that path by calling `counter.doubled()`,
    /// which lives in the `extension Counter` block.
    @Test
    func slicesIncludeExtensionAlongsideTypeBody() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(libraryPath())]),
            "function_name": .string("describeWithExtension")
        ]))
        let result = try decodeResult(SliceFunctionTool.Result.self, response)

        // Both the struct body and the extension must be in the slice.
        let kinds = result.includedSymbols.filter { $0.name == "Counter" }.map(\.kind)
        #expect(kinds.contains(.type))
        #expect(kinds.contains(.extensionDecl))

        // The slice should contain the extension's `doubled()` declaration.
        #expect(result.slicedCode.contains("extension Counter"))
        #expect(result.slicedCode.contains("doubled()"))

        // And it must self-typecheck — the previous bug surfaced as
        // "value of type 'Counter' has no member 'doubled'" when the extension
        // was dropped.
        #expect(result.verification.compilerExitCode == 0)
        #expect(result.verification.unresolvedReferences.isEmpty)
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

    /// Stage 4-2 후속: directory input. MultiFileSources fixture splits a
    /// `Greeter` struct (A.swift) and a `describe` free function (B.swift)
    /// across two files. Slicing `describe` over the directory must:
    ///   - run dump-ast on both files together so cross-file references
    ///     resolve,
    ///   - tag each closure entry with its source file,
    ///   - render decls grouped per file, and
    ///   - produce a self-contained slice that type-checks.
    @Test
    func slicesAcrossDirectoryInputResolvesCrossFileReferences() async throws {
        let tool = SliceFunctionTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["directory": .string(fixturePath("MultiFileSources"))]),
            "function_name": .string("describe")
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(SliceFunctionTool.Result.self, response)

        let names = Set(result.includedSymbols.map(\.name))
        #expect(names.contains("describe"))
        #expect(names.contains("Greeter"))

        // includedSymbols must carry the source file path — that's the
        // distinguishing field for multi-file slices.
        let describeEntry = result.includedSymbols.first(where: { $0.name == "describe" })
        let greeterEntry = result.includedSymbols.first(where: { $0.name == "Greeter" })
        #expect(describeEntry?.filePath.hasSuffix("/B.swift") == true)
        #expect(greeterEntry?.filePath.hasSuffix("/A.swift") == true)

        // The rendered slice carries both decls verbatim.
        #expect(result.slicedCode.contains("public struct Greeter"))
        #expect(result.slicedCode.contains("public func describe(_ greeter: Greeter)"))

        // Self-typecheck succeeds — proves the multi-file slice merges
        // without dropping a referenced type.
        #expect(result.verification.compilerExitCode == 0)
        #expect(result.verification.unresolvedReferences.isEmpty)
    }
}
