import Foundation
import Testing
@testable import SwiftcMCPCore

/// Stage 3.B: `directory` input with `search_paths` resolves cross-module imports.
/// Each test pre-builds ModuleA into a CallScratch via `swiftc -emit-module`, then
/// compiles ModuleB (which `import ModuleA`s) through `compile_stats`. The negative
/// case omits `search_paths` to prove the search path is what makes resolution work.
@Suite("Module search paths (integration)")
struct ModuleSearchPathTests {
    /// Build ModuleA's `.swiftmodule` into a fresh CallScratch and return both. Caller
    /// is responsible for `defer { scratch.dispose() }`.
    private func prebuildModuleA() async throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let resolved = try await ToolchainResolver().resolve()
        let modulePath = scratch.directory.appending(
            path: "ModuleA.swiftmodule",
            directoryHint: .notDirectory
        )
        let sourceA = fixturePath("ModuleA/A.swift")
        let result = try await runProcess(
            executable: resolved.swiftcPath,
            arguments: [
                "-emit-module",
                "-emit-module-path", modulePath.path,
                "-module-name", "ModuleA",
                "-parse-as-library",
                sourceA
            ]
        )
        guard result.exitCode == 0 else {
            scratch.dispose()
            throw MCPError.internalError(
                "ModuleA prebuild failed (exit=\(result.exitCode)): \(result.standardError)"
            )
        }
        return (scratch, modulePath)
    }

    @Test
    func compileStatsWithSearchPathResolvesImport() async throws {
        let (scratch, modulePath) = try await prebuildModuleA()
        defer { scratch.dispose() }

        // Sanity: the .swiftmodule actually exists where we'll point search_paths.
        #expect(FileManager.default.fileExists(atPath: modulePath.path))

        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object([
                "directory": .string(fixturePath("ModuleB")),
                "search_paths": .array([.string(scratch.directory.path)])
            ])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.totalCounters > 0)
        // stderr should be free of "no such module" when the search path works.
        let stderr = result.compilerStderr ?? ""
        #expect(stderr.contains("no such module") == false)
    }

    @Test
    func compileStatsWithoutSearchPathFailsToResolveImport() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object([
                "directory": .string(fixturePath("ModuleB"))
            ])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.compilerExitCode != 0)
        let stderr = result.compilerStderr ?? ""
        #expect(stderr.contains("no such module 'ModuleA'"))
    }
}
