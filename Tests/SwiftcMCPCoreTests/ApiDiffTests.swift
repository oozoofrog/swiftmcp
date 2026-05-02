import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ApiDiff (integration)")
struct ApiDiffTests {
    private func v1Path() -> String { fixturePath("ApiDiff/V1/Lib.swift") }
    private func v2Path() -> String { fixturePath("ApiDiff/V2/Lib.swift") }

    @Test
    func reportsRemovedFunctionAcrossVersions() async throws {
        let tool = ApiDiffTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "baseline": .object(["file": .string(v1Path())]),
            "current": .object(["file": .string(v2Path())]),
            "module_name": .string("Lib")
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(ApiDiffTool.Result.self, response)
        #expect(result.moduleName == "Lib")
        #expect(result.abiMode == false)
        // V1 had `helloAdd(_:_:)`; V2 dropped it. swift-api-digester reports
        // this as a Removed Decls breakage.
        #expect(result.findings.removedDecls.contains(where: { $0.contains("helloAdd") }))
        #expect(result.summary.byCategory["Removed Decls", default: 0] >= 1)
        // Default API checker (abi=false) does NOT report new decls — newApi /
        // doubled() should not show up in `removedDecls`.
        #expect(result.findings.removedDecls.contains(where: { $0.contains("newApi") }) == false)
        #expect(result.findings.removedDecls.contains(where: { $0.contains("doubled") }) == false)
        // Dump JSONs must exist on disk for clients that want to inspect them.
        #expect(FileManager.default.fileExists(atPath: result.baselineDumpPath))
        #expect(FileManager.default.fileExists(atPath: result.currentDumpPath))
    }

    @Test
    func abiModeAlsoReportsAddedDecls() async throws {
        let tool = ApiDiffTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "baseline": .object(["file": .string(v1Path())]),
            "current": .object(["file": .string(v2Path())]),
            "module_name": .string("Lib"),
            "abi": .bool(true)
        ]))

        let result = try decodeResult(ApiDiffTool.Result.self, response)
        #expect(result.abiMode == true)
        // ABI checker surfaces new APIs missing `@available` in the
        // "Decl Attribute changes" bucket. Either `doubled` or `newApi`
        // (or both) should appear there.
        let hasDoubled = result.findings.declAttributeChanges.contains(where: { $0.contains("doubled") })
        let hasNewApi = result.findings.declAttributeChanges.contains(where: { $0.contains("newApi") })
        #expect(hasDoubled || hasNewApi)
        // Removed-Decls signal still present.
        #expect(result.findings.removedDecls.contains(where: { $0.contains("helloAdd") }))
    }

    @Test
    func sameVersionProducesNoFindings() async throws {
        let tool = ApiDiffTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "baseline": .object(["file": .string(v1Path())]),
            "current": .object(["file": .string(v1Path())]),
            "module_name": .string("Lib")
        ]))
        let result = try decodeResult(ApiDiffTool.Result.self, response)
        #expect(result.summary.totalFindings == 0)
        #expect(result.findings.removedDecls.isEmpty)
    }

    @Test
    func missingModuleNameRejected() async throws {
        let tool = ApiDiffTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            _ = try await tool.call(arguments: .object([
                "baseline": .object(["file": .string(v1Path())]),
                "current": .object(["file": .string(v2Path())])
                // module_name missing.
            ]))
        }
    }

    /// Per Codex stop-time review: a plain SwiftPM package with no internal
    /// `target_dependencies` causes the resolver to skip its pre-build step,
    /// so `searchPaths` is empty. The earlier api_diff implementation pulled
    /// the module dir out of `searchPaths.first` and immediately failed for
    /// every dep-less package. The fix routes swiftPMPackage through the same
    /// `swiftc -emit-module` path that file/directory inputs use, so the tool
    /// works regardless of whether the package has internal deps.
    @Test
    func swiftPMPackageWithoutDependenciesSelfDiffsCleanly() async throws {
        let tool = ApiDiffTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "baseline": .object([
                "package": .string(fixturePath("SamplePackage")),
                "target_name": .string("Lib")
            ]),
            "current": .object([
                "package": .string(fixturePath("SamplePackage")),
                "target_name": .string("Lib")
            ]),
            "module_name": .string("Lib")
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(ApiDiffTool.Result.self, response)
        #expect(result.moduleName == "Lib")
        // Self-diff of an unchanged package must report nothing.
        #expect(result.summary.totalFindings == 0)
        // Both dump JSONs must exist on disk.
        #expect(FileManager.default.fileExists(atPath: result.baselineDumpPath))
        #expect(FileManager.default.fileExists(atPath: result.currentDumpPath))
    }

    @Test
    func xcodeInputCurrentlyRejected() async throws {
        let tool = ApiDiffTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            _ = try await tool.call(arguments: .object([
                "baseline": .object([
                    "project": .string(fixturePath("SampleProject.xcodeproj")),
                    "target_name": .string("Sample")
                ]),
                "current": .object(["file": .string(v2Path())]),
                "module_name": .string("Sample")
            ]))
        }
    }
}
