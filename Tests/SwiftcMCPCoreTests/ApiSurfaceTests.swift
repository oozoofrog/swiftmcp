import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ApiSurface (integration)")
struct ApiSurfaceTests {
    private func writeLib() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "Lib.swift", contents: """
        public struct Counter {
            public private(set) var value: Int = 0
            public init(start: Int = 0) { value = start }
            public mutating func increment() { value += 1 }
        }

        public protocol Renderable {
            func render() -> String
        }

        extension Counter: Renderable {
            public func render() -> String { "\\(value)" }
        }

        internal struct Hidden { var x: Int = 0 }
        """)
        return (scratch, url)
    }

    @Test
    func emitsSymbolGraphAndApiDescriptor() async throws {
        let (scratch, url) = try writeLib()
        defer { scratch.dispose() }

        let tool = ApiSurfaceTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "module_name": .string("Lib")
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(ApiSurfaceTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.moduleName == "Lib")
        #expect(result.minAccessLevel == "public")
        #expect(result.symbolGraphFiles.isEmpty == false)
        #expect(result.totalSymbols > 0)
        #expect(result.apiDescriptorBytes > 0)

        // The library exposes a struct, a protocol, and methods — kind set should include all three.
        let kinds = Set(result.symbolKinds.keys)
        #expect(kinds.contains("swift.struct"))
        #expect(kinds.contains("swift.protocol"))

        // Artifact files should actually exist on disk for clients to open.
        #expect(FileManager.default.fileExists(atPath: result.apiDescriptorPath))
        for graph in result.symbolGraphFiles {
            #expect(FileManager.default.fileExists(atPath: graph.path))
        }
    }

    @Test
    func defaultModuleNameDerivesFromBasename() async throws {
        let (scratch, url) = try writeLib()
        defer { scratch.dispose() }

        let tool = ApiSurfaceTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path)
        ]))
        let result = try decodeResult(ApiSurfaceTool.Result.self, response)
        #expect(result.moduleName == "Lib") // basename of Lib.swift
    }

    @Test
    func internalAccessLevelIncludesMoreSymbols() async throws {
        let (scratch, url) = try writeLib()
        defer { scratch.dispose() }

        let tool = ApiSurfaceTool(toolchain: ToolchainResolver())
        let publicCall = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "module_name": .string("Lib"),
            "min_access_level": .string("public")
        ]))
        let internalCall = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "module_name": .string("Lib"),
            "min_access_level": .string("internal")
        ]))

        let publicResult = try decodeResult(ApiSurfaceTool.Result.self, publicCall)
        let internalResult = try decodeResult(ApiSurfaceTool.Result.self, internalCall)
        #expect(internalResult.totalSymbols >= publicResult.totalSymbols)
    }

    @Test
    func unknownAccessLevelRaisesInvalidParams() async throws {
        let tool = ApiSurfaceTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "file": .string("/tmp/x.swift"),
                "min_access_level": .string("nope")
            ]))
        }
    }

    @Test
    func missingFileSurfacesAsCompilerError() async throws {
        let tool = ApiSurfaceTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string("/tmp/swiftmcp-does-not-exist-\(UUID().uuidString).swift"),
            "module_name": .string("Missing")
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(ApiSurfaceTool.Result.self, response)
        #expect(result.compilerExitCode != 0)
        #expect(result.totalSymbols == 0)
    }

    @Test
    func missingArgumentRaisesInvalidParams() async throws {
        let tool = ApiSurfaceTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([:]))
        }
    }
}
