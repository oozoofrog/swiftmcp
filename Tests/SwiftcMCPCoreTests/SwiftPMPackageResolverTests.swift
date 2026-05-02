import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("BuildInput swiftPMPackage decoding")
struct BuildInputSwiftPMDecodingTests {
    @Test
    func packageOnlyDecodes() throws {
        let value = JSONValue.object(["package": .string("/abs/pkg")])
        let input = try BuildInput.decode(value)
        guard case .swiftPMPackage(let path, let targetName, let configuration, let target) = input else {
            Issue.record("expected .swiftPMPackage, got \(input)"); return
        }
        #expect(path == "/abs/pkg")
        #expect(targetName == nil)
        #expect(configuration == nil)
        #expect(target == nil)
    }

    @Test
    func packageWithAllFieldsDecodes() throws {
        let value = JSONValue.object([
            "package": .string("/abs/pkg"),
            "target_name": .string("App"),
            "configuration": .string("release"),
            "target": .string("arm64-apple-macos14")
        ])
        let input = try BuildInput.decode(value)
        guard case .swiftPMPackage(let path, let targetName, let configuration, let target) = input else {
            Issue.record("expected .swiftPMPackage"); return
        }
        #expect(path == "/abs/pkg")
        #expect(targetName == "App")
        #expect(configuration == "release")
        #expect(target == "arm64-apple-macos14")
    }

    @Test
    func packageEmptyPathRejected() throws {
        let value = JSONValue.object(["package": .string("")])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func packageAndFileBothPresentRejected() throws {
        let value = JSONValue.object([
            "package": .string("/p"),
            "file": .string("/f.swift")
        ])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func packageTargetIsExposedViaComputedProp() throws {
        let value = JSONValue.object([
            "package": .string("/abs/pkg"),
            "target": .string("arm64-apple-macos14")
        ])
        let input = try BuildInput.decode(value)
        #expect(input.target == "arm64-apple-macos14")
    }
}

@Suite("SwiftPMPackageResolver (integration)")
struct SwiftPMPackageResolverIntegrationTests {
    @Test
    func zeroDepPackageAutoSelectsFirstLibraryTarget() async throws {
        let resolver = SwiftPMPackageResolver()
        let resolved = try await resolver.resolveArgs(for: .swiftPMPackage(
            path: fixturePath("SamplePackage"),
            targetName: nil,
            configuration: nil,
            target: nil
        ))

        #expect(resolved.moduleName == "Lib")
        #expect(resolved.inputFiles.count == 1)
        #expect(resolved.inputFiles.first?.hasSuffix("Lib.swift") == true)
        #expect(resolved.inputFiles.allSatisfy { $0.hasPrefix("/") })
        #expect(resolved.searchPaths.isEmpty)
    }

    @Test
    func zeroDepPackageWithExplicitTargetName() async throws {
        let resolver = SwiftPMPackageResolver()
        let resolved = try await resolver.resolveArgs(for: .swiftPMPackage(
            path: fixturePath("SamplePackage"),
            targetName: "Lib",
            configuration: nil,
            target: nil
        ))
        #expect(resolved.moduleName == "Lib")
    }

    @Test
    func multiTargetWithInternalDepBuildsAndExposesSearchPath() async throws {
        let resolver = SwiftPMPackageResolver()
        let resolved = try await resolver.resolveArgs(for: .swiftPMPackage(
            path: fixturePath("MultiTargetPackage"),
            targetName: "App",
            configuration: nil,
            target: nil
        ))

        #expect(resolved.moduleName == "App")
        #expect(resolved.inputFiles.count == 1)
        #expect(resolved.inputFiles.first?.hasSuffix("App.swift") == true)
        #expect(resolved.searchPaths.count == 1)

        let modulesDir = try #require(resolved.searchPaths.first)
        // The search path must point at a directory that actually contains
        // Core.swiftmodule, otherwise downstream type-check would fail with
        // "no such module 'Core'".
        let coreModule = modulesDir + "/Core.swiftmodule"
        #expect(FileManager.default.fileExists(atPath: coreModule))
    }

    @Test
    func unknownTargetNameRejected() async throws {
        let resolver = SwiftPMPackageResolver()
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .swiftPMPackage(
                path: fixturePath("SamplePackage"),
                targetName: "DoesNotExist",
                configuration: nil,
                target: nil
            ))
        }
    }

    @Test
    func packagePathWithoutManifestRejected() async throws {
        let resolver = SwiftPMPackageResolver()
        // MultiFileSources is a plain directory of .swift files (Stage 3.A fixture),
        // with no Package.swift — the resolver should reject it at the manifest check
        // before invoking `swift package describe`.
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .swiftPMPackage(
                path: fixturePath("MultiFileSources"),
                targetName: nil,
                configuration: nil,
                target: nil
            ))
        }
    }

    @Test
    func compileStatsEndToEndOnZeroDepPackage() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["package": .string(fixturePath("SamplePackage"))])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.totalCounters > 0)
    }

    @Test
    func compileStatsEndToEndOnMultiTargetResolvesInternalImport() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object([
                "package": .string(fixturePath("MultiTargetPackage")),
                "target_name": .string("App")
            ])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        let stderr = result.compilerStderr ?? ""
        #expect(stderr.contains("no such module") == false)
    }
}
