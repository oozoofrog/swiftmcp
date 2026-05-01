import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("BuildInput xcodeProject decoding")
struct BuildInputXcodeProjectDecodingTests {
    @Test
    func projectAndTargetNameRequired() throws {
        let value = JSONValue.object([
            "project": .string("/abs/Some.xcodeproj"),
            "target_name": .string("Sample")
        ])
        let input = try BuildInput.decode(value)
        guard case .xcodeProject(let path, let targetName, let configuration, let target) = input else {
            Issue.record("expected .xcodeProject"); return
        }
        #expect(path == "/abs/Some.xcodeproj")
        #expect(targetName == "Sample")
        #expect(configuration == nil)
        #expect(target == nil)
    }

    @Test
    func projectWithAllFieldsDecodes() throws {
        let value = JSONValue.object([
            "project": .string("/abs/X.xcodeproj"),
            "target_name": .string("App"),
            "configuration": .string("Release"),
            "target": .string("arm64-apple-macos14")
        ])
        let input = try BuildInput.decode(value)
        guard case .xcodeProject(let path, let targetName, let configuration, let target) = input else {
            Issue.record("expected .xcodeProject"); return
        }
        #expect(path == "/abs/X.xcodeproj")
        #expect(targetName == "App")
        #expect(configuration == "Release")
        #expect(target == "arm64-apple-macos14")
    }

    @Test
    func projectMissingTargetNameRejected() throws {
        let value = JSONValue.object(["project": .string("/abs/Some.xcodeproj")])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func projectEmptyTargetNameRejected() throws {
        let value = JSONValue.object([
            "project": .string("/abs/Some.xcodeproj"),
            "target_name": .string("")
        ])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func projectAndPackageBothRejected() throws {
        let value = JSONValue.object([
            "project": .string("/abs/X.xcodeproj"),
            "target_name": .string("App"),
            "package": .string("/abs/pkg")
        ])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }
}

@Suite("BuildInput xcodeWorkspace decoding")
struct BuildInputXcodeWorkspaceDecodingTests {
    @Test
    func workspaceAndSchemeRequired() throws {
        let value = JSONValue.object([
            "workspace": .string("/abs/Some.xcworkspace"),
            "scheme": .string("Sample")
        ])
        let input = try BuildInput.decode(value)
        guard case .xcodeWorkspace(let path, let scheme, let targetName, let configuration, let target) = input else {
            Issue.record("expected .xcodeWorkspace"); return
        }
        #expect(path == "/abs/Some.xcworkspace")
        #expect(scheme == "Sample")
        #expect(targetName == nil)
        #expect(configuration == nil)
        #expect(target == nil)
    }

    @Test
    func workspaceWithAllFieldsDecodes() throws {
        let value = JSONValue.object([
            "workspace": .string("/abs/X.xcworkspace"),
            "scheme": .string("App"),
            "target_name": .string("App"),
            "configuration": .string("Release"),
            "target": .string("arm64-apple-macos14")
        ])
        let input = try BuildInput.decode(value)
        guard case .xcodeWorkspace(let path, let scheme, let targetName, let configuration, let target) = input else {
            Issue.record("expected .xcodeWorkspace"); return
        }
        #expect(path == "/abs/X.xcworkspace")
        #expect(scheme == "App")
        #expect(targetName == "App")
        #expect(configuration == "Release")
        #expect(target == "arm64-apple-macos14")
    }

    @Test
    func workspaceMissingSchemeRejected() throws {
        let value = JSONValue.object(["workspace": .string("/abs/Some.xcworkspace")])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func workspaceEmptySchemeRejected() throws {
        let value = JSONValue.object([
            "workspace": .string("/abs/Some.xcworkspace"),
            "scheme": .string("")
        ])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }

    @Test
    func workspaceAndProjectBothRejected() throws {
        let value = JSONValue.object([
            "workspace": .string("/abs/W.xcworkspace"),
            "scheme": .string("App"),
            "project": .string("/abs/P.xcodeproj"),
            "target_name": .string("App")
        ])
        #expect(throws: MCPError.self) {
            try BuildInput.decode(value)
        }
    }
}

@Suite("XcodebuildResolver workspace mode (integration)")
struct XcodebuildResolverWorkspaceIntegrationTests {
    @Test
    func resolverProducesInputFilesForSampleWorkspace() async throws {
        let resolver = XcodebuildResolver()
        let resolved = try await resolver.resolveArgs(for: .xcodeWorkspace(
            path: fixturePath("SampleWorkspace.xcworkspace"),
            scheme: "Sample",
            configuration: nil,
            target: nil
        ))

        #expect(resolved.moduleName == "Sample")
        #expect(resolved.inputFiles.count == 1)
        let firstInput = try #require(resolved.inputFiles.first)
        #expect(firstInput.hasSuffix("/Sample.swift"))
        #expect(FileManager.default.fileExists(atPath: firstInput))

        #expect(resolved.extraSwiftcArgs.contains("-sdk"))
        #expect(resolved.extraSwiftcArgs.contains("-swift-version"))
    }

    @Test
    func unknownSchemeSurfacesAsToolExecutionFailure() async throws {
        let resolver = XcodebuildResolver()
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .xcodeWorkspace(
                path: fixturePath("SampleWorkspace.xcworkspace"),
                scheme: "DoesNotExist",
                configuration: nil,
                target: nil
            ))
        }
    }

    @Test
    func nonXcworkspaceDirectoryRejected() async throws {
        let resolver = XcodebuildResolver()
        // SampleProject.xcodeproj is a `.xcodeproj`, not a workspace.
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .xcodeWorkspace(
                path: fixturePath("SampleProject.xcodeproj"),
                scheme: "Sample",
                configuration: nil,
                target: nil
            ))
        }
    }

    @Test
    func compileStatsEndToEndOnXcodeWorkspace() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object([
                "workspace": .string(fixturePath("SampleWorkspace.xcworkspace")),
                "scheme": .string("Sample")
            ])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.totalCounters > 0)
        let stderr = result.compilerStderr ?? ""
        #expect(stderr.contains("error:") == false)
    }

    /// Per Codex stop-time review: a workspace whose scheme builds multiple targets
    /// (e.g. an explicit shared scheme with two BuildableReference entries) emits
    /// per-target settings blocks from `xcodebuild -showBuildSettings`. Picking the
    /// last block — the previous behavior — silently returned the wrong target's
    /// SwiftFileList. The resolver must now refuse without `target_name` and pick
    /// the correct block when one is supplied.
    @Test
    func multiBuildableSchemeRefusesWithoutTargetName() async throws {
        let resolver = XcodebuildResolver()
        do {
            _ = try await resolver.resolveArgs(for: .xcodeWorkspace(
                path: fixturePath("MultiBuildableWorkspace.xcworkspace"),
                scheme: "All",
                targetName: nil,
                configuration: nil,
                target: nil
            ))
            Issue.record("expected throw")
        } catch let error as MCPError {
            guard case .invalidParams(let message) = error else {
                Issue.record("expected invalidParams, got \(error)"); return
            }
            #expect(message.contains("target_name"))
            #expect(message.contains("Lib") || message.contains("App"))
        }
    }

    @Test
    func multiBuildableSchemeSelectsTargetByExplicitName() async throws {
        let resolver = XcodebuildResolver()
        let resolvedLib = try await resolver.resolveArgs(for: .xcodeWorkspace(
            path: fixturePath("MultiBuildableWorkspace.xcworkspace"),
            scheme: "All",
            targetName: "Lib",
            configuration: nil,
            target: nil
        ))
        #expect(resolvedLib.moduleName == "Lib")
        #expect(resolvedLib.inputFiles.first?.hasSuffix("/Lib.swift") == true)

        let resolvedApp = try await resolver.resolveArgs(for: .xcodeWorkspace(
            path: fixturePath("MultiBuildableWorkspace.xcworkspace"),
            scheme: "All",
            targetName: "App",
            configuration: nil,
            target: nil
        ))
        #expect(resolvedApp.moduleName == "App")
        #expect(resolvedApp.inputFiles.first?.hasSuffix("/App.swift") == true)

        // Sanity: Lib and App resolve to *different* SwiftFileLists. Without the
        // target-aware parser they would have collapsed to the same path (the last
        // block xcodebuild emitted).
        #expect(resolvedLib.inputFiles != resolvedApp.inputFiles)
    }

    @Test
    func multiBuildableSchemeRejectsUnknownTargetName() async throws {
        let resolver = XcodebuildResolver()
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .xcodeWorkspace(
                path: fixturePath("MultiBuildableWorkspace.xcworkspace"),
                scheme: "All",
                targetName: "NoSuchTarget",
                configuration: nil,
                target: nil
            ))
        }
    }
}

@Suite("XcodebuildResolver unit")
struct XcodebuildResolverUnitTests {
    @Test
    func parseBuildSettingsExtractsKeyValuePairs() {
        let resolver = XcodebuildResolver()
        let sample = """
        Build settings for action build and target Sample:

            ARCHS = arm64
            SDKROOT = /Developer/Platforms/MacOSX.sdk
            SWIFT_VERSION = 6.0
            PRODUCT_NAME = Sample
            FRAMEWORK_SEARCH_PATHS = /a /b
        """
        let blocks = resolver.parseBuildSettings(sample)
        #expect(blocks.count == 1)
        let parsed = blocks[0].settings
        #expect(blocks[0].target == "Sample")
        #expect(parsed["ARCHS"] == "arm64")
        #expect(parsed["SDKROOT"] == "/Developer/Platforms/MacOSX.sdk")
        #expect(parsed["SWIFT_VERSION"] == "6.0")
        #expect(parsed["PRODUCT_NAME"] == "Sample")
        #expect(parsed["FRAMEWORK_SEARCH_PATHS"] == "/a /b")
    }

    @Test
    func parseBuildSettingsIgnoresHeaderAndBlankLines() {
        let resolver = XcodebuildResolver()
        let blocks = resolver.parseBuildSettings("""
        Build settings for action build and target Sample:

            KEY = value
        not a build setting line
            ANOTHER = thing
        """)
        #expect(blocks.count == 1)
        let parsed = blocks[0].settings
        #expect(parsed["KEY"] == "value")
        #expect(parsed["ANOTHER"] == "thing")
        #expect(parsed["Build settings for action build and target Sample"] == nil)
    }

    @Test
    func parseBuildSettingsSplitsMultipleTargetBlocks() {
        let resolver = XcodebuildResolver()
        let blocks = resolver.parseBuildSettings("""
        Build settings for action build and target Lib:
            TARGET_NAME = Lib
            SWIFT_RESPONSE_FILE_PATH_normal_arm64 = /tmp/Lib.SwiftFileList
        Build settings for action build and target App:
            TARGET_NAME = App
            SWIFT_RESPONSE_FILE_PATH_normal_arm64 = /tmp/App.SwiftFileList
        """)
        #expect(blocks.count == 2)
        #expect(blocks[0].target == "Lib")
        #expect(blocks[0].settings["SWIFT_RESPONSE_FILE_PATH_normal_arm64"] == "/tmp/Lib.SwiftFileList")
        #expect(blocks[1].target == "App")
        #expect(blocks[1].settings["SWIFT_RESPONSE_FILE_PATH_normal_arm64"] == "/tmp/App.SwiftFileList")
    }

    @Test
    func chooseSettingsBlockRequiresTargetNameForMultiTarget() throws {
        let resolver = XcodebuildResolver()
        let blocks: [XcodebuildResolver.SettingsBlock] = [
            .init(target: "Lib", settings: ["TARGET_NAME": "Lib"]),
            .init(target: "App", settings: ["TARGET_NAME": "App"])
        ]
        // Single block (project mode) — accepted regardless of explicitTargetName.
        _ = try resolver.chooseSettingsBlock(
            blocks: [blocks[0]],
            explicitTargetName: nil,
            identifier: "target 'Lib'"
        )
        // Multi block + no name → invalidParams.
        #expect(throws: MCPError.self) {
            _ = try resolver.chooseSettingsBlock(
                blocks: blocks,
                explicitTargetName: nil,
                identifier: "scheme 'All'"
            )
        }
        // Multi block + matching name → that block.
        let chosen = try resolver.chooseSettingsBlock(
            blocks: blocks,
            explicitTargetName: "App",
            identifier: "scheme 'All'"
        )
        #expect(chosen.target == "App")
        // Multi block + unknown name → invalidParams.
        #expect(throws: MCPError.self) {
            _ = try resolver.chooseSettingsBlock(
                blocks: blocks,
                explicitTargetName: "Missing",
                identifier: "scheme 'All'"
            )
        }
    }

    @Test
    func normalizeSwiftVersionStripsTrailingZero() {
        let resolver = XcodebuildResolver()
        #expect(resolver.normalizeSwiftVersion("6.0") == "6")
        #expect(resolver.normalizeSwiftVersion("5.0") == "5")
        #expect(resolver.normalizeSwiftVersion("4.2") == "4.2")
        #expect(resolver.normalizeSwiftVersion("6") == "6")
        #expect(resolver.normalizeSwiftVersion("") == nil)
        #expect(resolver.normalizeSwiftVersion("  5.0  ") == "5")
    }
}

@Suite("XcodebuildResolver (integration)")
struct XcodebuildResolverIntegrationTests {
    @Test
    func resolverProducesInputFilesAndModuleNameForSampleProject() async throws {
        let resolver = XcodebuildResolver()
        let resolved = try await resolver.resolveArgs(for: .xcodeProject(
            path: fixturePath("SampleProject.xcodeproj"),
            targetName: "Sample",
            configuration: nil,
            target: nil
        ))

        #expect(resolved.moduleName == "Sample")
        #expect(resolved.inputFiles.count == 1)
        let firstInput = try #require(resolved.inputFiles.first)
        #expect(firstInput.hasSuffix("/Sample.swift"))
        #expect(FileManager.default.fileExists(atPath: firstInput))

        // -sdk + -swift-version (normalized to drop trailing .0) should be threaded
        // through extraSwiftcArgs.
        #expect(resolved.extraSwiftcArgs.contains("-sdk"))
        #expect(resolved.extraSwiftcArgs.contains("-swift-version"))
        if let idx = resolved.extraSwiftcArgs.firstIndex(of: "-swift-version") {
            #expect(idx + 1 < resolved.extraSwiftcArgs.count)
            let value = resolved.extraSwiftcArgs[idx + 1]
            #expect(!value.hasSuffix(".0"))
        }
    }

    @Test
    func unknownTargetNameSurfacesAsToolExecutionFailure() async throws {
        let resolver = XcodebuildResolver()
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .xcodeProject(
                path: fixturePath("SampleProject.xcodeproj"),
                targetName: "DoesNotExist",
                configuration: nil,
                target: nil
            ))
        }
    }

    @Test
    func nonXcodeprojDirectoryRejected() async throws {
        let resolver = XcodebuildResolver()
        // MultiFileSources is just a Swift source dir from Stage 3.A.
        await #expect(throws: MCPError.self) {
            _ = try await resolver.resolveArgs(for: .xcodeProject(
                path: fixturePath("MultiFileSources"),
                targetName: "Sample",
                configuration: nil,
                target: nil
            ))
        }
    }

    @Test
    func compileStatsEndToEndOnXcodeProject() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object([
                "project": .string(fixturePath("SampleProject.xcodeproj")),
                "target_name": .string("Sample")
            ])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.totalCounters > 0)
        let stderr = result.compilerStderr ?? ""
        #expect(stderr.contains("error:") == false)
    }

    /// Per PLAN §0.3, compiler diagnostics on the user's own Swift code are part of
    /// the analysis output, not a tool-execution error. The resolver must therefore
    /// keep going when xcodebuild's build action fails because the target's sources
    /// don't compile — xcodebuild still materializes the SwiftFileList before the
    /// compile step, and downstream swiftc will surface the same error as a
    /// diagnostic the tool returns to the caller.
    @Test
    func resolverContinuesWhenTargetSourcesFailToCompile() async throws {
        let resolver = XcodebuildResolver()
        let resolved = try await resolver.resolveArgs(for: .xcodeProject(
            path: fixturePath("BrokenProject.xcodeproj"),
            targetName: "Broken",
            configuration: nil,
            target: nil
        ))
        #expect(resolved.moduleName == "Broken")
        #expect(resolved.inputFiles.count == 1)
        #expect(resolved.inputFiles.first?.hasSuffix("/Broken.swift") == true)
    }

    @Test
    func compileStatsSurfacesCompilerErrorAsDiagnostic() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object([
                "project": .string(fixturePath("BrokenProject.xcodeproj")),
                "target_name": .string("Broken")
            ])
        ]))

        // Tool must succeed structurally — diagnostics are the analysis output.
        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        // swiftc fails to type-check the broken source, surfaced as compilerExitCode.
        #expect(result.compilerExitCode != 0)
        let stderr = result.compilerStderr ?? ""
        #expect(stderr.contains("error:"))
    }
}
