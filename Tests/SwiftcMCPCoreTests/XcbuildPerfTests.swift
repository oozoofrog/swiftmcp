import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("XcbuildPerf")
struct XcbuildPerfTests {
    @Test
    func rejectsFileInput() async throws {
        let tool = XcbuildPerfTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            _ = try await tool.call(arguments: .object([
                "input": .object(["file": .string("/tmp/anything.swift")])
            ]))
        }
    }

    @Test
    func rejectsDirectoryInput() async throws {
        let tool = XcbuildPerfTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            _ = try await tool.call(arguments: .object([
                "input": .object(["directory": .string("/tmp/anywhere")])
            ]))
        }
    }

    @Test
    func rejectsSwiftPMPackageInput() async throws {
        let tool = XcbuildPerfTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            _ = try await tool.call(arguments: .object([
                "input": .object([
                    "package": .string("/tmp/SomePkg"),
                    "target_name": .string("Lib")
                ])
            ]))
        }
    }

    @Test
    func rejectsMissingArguments() async throws {
        let tool = XcbuildPerfTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            _ = try await tool.call(arguments: nil)
        }
    }
}

/// Integration smoke test against the SampleProject xcodeproj fixture.
/// Disabled by default: macOS 26.x exhibits SWBBuildService contention with
/// any concurrent xcodebuild on the host and the SDK-probe phase
/// (`ExecuteExternalTool clang`) routinely stalls past 10 minutes — this
/// test ran successfully against an idle host but flakes when other
/// xcodebuild jobs are alive in the user's session. Re-enable manually
/// (`@Test`) for one-off validation in a clean environment.
@Suite("XcbuildPerf (integration)")
struct XcbuildPerfIntegrationTests {
    @Test(.disabled("xcodebuild SWBBuildService contention on macOS 26.x; run manually on idle host"))
    func buildsSampleProjectAndReturnsTimings() async throws {
        let cache = CachedBuildArgsResolver(wrapping: DefaultBuildArgsResolver())
        let tool = XcbuildPerfTool(toolchain: ToolchainResolver(), resolver: cache)
        let response = try await tool.call(arguments: .object([
            "input": .object([
                "project": .string(fixturePath("SampleProject.xcodeproj")),
                "target_name": .string("Sample")
            ])
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(XcbuildPerfTool.Result.self, response)
        // The Sample target has one Swift source. xcodebuild should at
        // least invoke a Swift compile + a static-lib emit, so phases
        // can't be empty if the build actually ran. Empty phases means
        // either xcodebuild failed before printing the summary or the
        // toolchain dropped the section format — both worth flagging.
        #expect(result.phases.isEmpty == false)
        #expect(result.buildSucceeded == true)
        #expect(result.totalWallClockSec >= 0)
        // Both scratch artifacts must exist on disk for the client to
        // open. xcresult always lands when -resultBundlePath is set;
        // build.log is our own redirected stdio.
        #expect(FileManager.default.fileExists(atPath: result.buildLogPath))
        #expect(FileManager.default.fileExists(atPath: result.resultBundlePath))
        // xclogparser availability is host-dependent; we only assert the
        // contract holds (boolean reflects whether targetTimings was
        // populated on a best-effort basis).
        if result.xclogparserAvailable {
            #expect(result.targetTimings != nil)
        } else {
            #expect(result.targetTimings == nil)
        }
    }
}
