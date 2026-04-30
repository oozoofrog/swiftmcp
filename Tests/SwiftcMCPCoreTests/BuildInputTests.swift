import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("BuildInput decoding")
struct BuildInputDecodingTests {
    @Test
    func fileCaseDecodesPath() throws {
        let value = JSONValue.object(["file": .string("/abs/path/x.swift")])
        let input = try BuildInput.decode(value)
        guard case .file(let path, let target) = input else {
            Issue.record("expected .file case, got \(input)"); return
        }
        #expect(path == "/abs/path/x.swift")
        #expect(target == nil)
    }

    @Test
    func fileCaseCarriesTarget() throws {
        let value = JSONValue.object([
            "file": .string("/abs/path/x.swift"),
            "target": .string("arm64-apple-macos14")
        ])
        let input = try BuildInput.decode(value)
        #expect(input.target == "arm64-apple-macos14")
    }

    @Test
    func directoryCaseDecodesAllFields() throws {
        let value = JSONValue.object([
            "directory": .string("/abs/dir"),
            "module_name": .string("MyLib"),
            "search_paths": .array([.string("/a"), .string("/b")]),
            "target": .string("arm64-apple-macos14")
        ])
        let input = try BuildInput.decode(value)
        guard case .directory(let path, let moduleName, let target, let searchPaths) = input else {
            Issue.record("expected .directory case"); return
        }
        #expect(path == "/abs/dir")
        #expect(moduleName == "MyLib")
        #expect(target == "arm64-apple-macos14")
        #expect(searchPaths == ["/a", "/b"])
    }

    @Test
    func multipleCaseKeysRejected() throws {
        let value = JSONValue.object([
            "file": .string("/x"),
            "directory": .string("/y")
        ])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func missingCaseKeyRejected() throws {
        let value = JSONValue.object(["target": .string("arm64-apple-macos14")])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func emptyPathRejected() throws {
        let value = JSONValue.object(["file": .string("")])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func nonObjectRejected() throws {
        let value = JSONValue.string("nope")
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }
}

@Suite("LocalFilesResolver")
struct LocalFilesResolverTests {
    @Test
    func fileCaseAbsolutizesAndReturnsSingleFile() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let url = try scratch.write(name: "x.swift", contents: "let x = 1\n")

        let resolver = LocalFilesResolver()
        let resolved = try await resolver.resolveArgs(for: .file(path: url.path, target: nil))

        #expect(resolved.inputFiles.count == 1)
        #expect(resolved.inputFiles.first == url.path)
        #expect(resolved.moduleName == nil)
    }

    @Test
    func directoryCaseGlobsTopLevelSwiftFiles() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        _ = try scratch.write(name: "A.swift", contents: "public let a = 1\n")
        _ = try scratch.write(name: "B.swift", contents: "public let b = 2\n")
        _ = try scratch.write(name: "ignore.txt", contents: "not swift\n")

        let resolver = LocalFilesResolver()
        let resolved = try await resolver.resolveArgs(for: .directory(
            path: scratch.directory.path,
            moduleName: nil,
            target: nil,
            searchPaths: []
        ))

        #expect(resolved.inputFiles.count == 2)
        #expect(resolved.inputFiles.allSatisfy { $0.hasSuffix(".swift") })
        #expect(resolved.moduleName != nil)
    }

    @Test
    func directoryCaseInfersModuleNameFromBasename() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let nested = scratch.directory.appending(path: "MyLib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "public let v = 0\n".write(to: nested.appending(path: "X.swift"), atomically: true, encoding: .utf8)

        let resolver = LocalFilesResolver()
        let resolved = try await resolver.resolveArgs(for: .directory(
            path: nested.path,
            moduleName: nil,
            target: nil,
            searchPaths: []
        ))
        #expect(resolved.moduleName == "MyLib")
    }

    @Test
    func directoryCaseAcceptsExplicitModuleName() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        _ = try scratch.write(name: "A.swift", contents: "public let a = 1\n")

        let resolver = LocalFilesResolver()
        let resolved = try await resolver.resolveArgs(for: .directory(
            path: scratch.directory.path,
            moduleName: "Override",
            target: nil,
            searchPaths: []
        ))
        #expect(resolved.moduleName == "Override")
    }

    @Test
    func emptyDirectoryRejected() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }

        let resolver = LocalFilesResolver()
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .directory(
                path: scratch.directory.path,
                moduleName: nil,
                target: nil,
                searchPaths: []
            ))
        }
    }

    @Test
    func nonexistentFileRejected() async throws {
        let resolver = LocalFilesResolver()
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .file(
                path: "/tmp/swiftmcp-missing-\(UUID().uuidString).swift",
                target: nil
            ))
        }
    }
}

@Suite("Directory input (integration)")
struct DirectoryInputIntegrationTests {
    @Test
    func emitASTOverDirectoryProducesArtifact() async throws {
        let dir = fixturePath("MultiFileSources")
        let tool = EmitASTTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["directory": .string(dir)])
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(EmitASTTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.bytes > 0)

        let body = try String(contentsOfFile: result.path, encoding: .utf8)
        // Both files contributed declarations to the AST.
        #expect(body.contains("Greeter"))
        #expect(body.contains("describe"))
    }

    @Test
    func compileStatsOverDirectoryReturnsCounters() async throws {
        let dir = fixturePath("MultiFileSources")
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["directory": .string(dir)])
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.totalCounters > 0)
        // Both Sema and AST counters should still appear when multiple files compile.
        #expect(result.byCategory["Sema"] != nil)
        #expect(result.byCategory["AST"] != nil)
    }

    @Test
    func apiSurfaceOverDirectoryUsesInferredModuleName() async throws {
        let dir = fixturePath("MultiFileSources")
        let tool = ApiSurfaceTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["directory": .string(dir)])
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(ApiSurfaceTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.moduleName == "MultiFileSources")
        #expect(result.totalSymbols > 0)
        let kinds = Set(result.symbolKinds.keys)
        #expect(kinds.contains("swift.struct"))
    }
}
