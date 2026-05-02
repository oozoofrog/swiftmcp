import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("BuildTimingSummaryParser")
struct BuildTimingSummaryParserTests {
    @Test
    func parsesCanonicalSucceededOutput() {
        let text = """
        Some unrelated stdout above…

        ** BUILD SUCCEEDED **

        Build Timing Summary

        CompileSwiftSources (42 tasks) | 8.213 seconds
        Ld (3 tasks) | 1.04 seconds
        CompileC (12 tasks) | 0.85 seconds
        """
        let output = BuildTimingSummaryParser.parse(text)
        #expect(output.buildSucceeded == true)
        #expect(output.phases.count == 3)
        #expect(output.phases[0] == .init(name: "CompileSwiftSources", taskCount: 42, wallClockSec: 8.213))
        #expect(output.phases[1] == .init(name: "Ld", taskCount: 3, wallClockSec: 1.04))
        #expect(output.phases[2] == .init(name: "CompileC", taskCount: 12, wallClockSec: 0.85))
    }

    @Test
    func parsesCompactSecondSuffix() {
        // Some xcodebuild versions emit `1.5s` instead of `1.5 seconds`.
        // Both forms must produce the same Phase.
        let text = """
        Build Timing Summary

        CompileSwiftSources (1 task) | 1.5s
        """
        let output = BuildTimingSummaryParser.parse(text)
        #expect(output.phases == [
            .init(name: "CompileSwiftSources", taskCount: 1, wallClockSec: 1.5)
        ])
    }

    @Test
    func reportsBuildFailedWithoutSucceededMarker() {
        // BUILD FAILED still emits the timing summary; we capture phases
        // but report buildSucceeded == false so callers can branch.
        let text = """
        ** BUILD FAILED **

        Build Timing Summary

        CompileSwiftSources (5 tasks) | 0.42 seconds
        """
        let output = BuildTimingSummaryParser.parse(text)
        #expect(output.buildSucceeded == false)
        #expect(output.phases.count == 1)
    }

    @Test
    func emptyTextProducesEmptyOutput() {
        let output = BuildTimingSummaryParser.parse("")
        #expect(output.buildSucceeded == false)
        #expect(output.phases.isEmpty)
    }

    @Test
    func headerWithoutPhasesReturnsEmptyPhases() {
        // The header showed up but the summary body was missing — toolchain
        // upgrade dropped the section formatting? We don't error out;
        // empty phases is a valid observable state.
        let text = """
        ** BUILD SUCCEEDED **

        Build Timing Summary

        ** Some other final banner **
        """
        let output = BuildTimingSummaryParser.parse(text)
        #expect(output.buildSucceeded == true)
        #expect(output.phases.isEmpty)
    }

    @Test
    func zeroTaskPhaseStillCounts() {
        // A phase with zero tasks (rare but legal) should still parse
        // without throwing.
        let text = """
        Build Timing Summary

        SwiftDriverJobDiscovery (0 tasks) | 0.0 seconds
        Ld (1 task) | 0.5 seconds
        """
        let output = BuildTimingSummaryParser.parse(text)
        #expect(output.phases.count == 2)
        #expect(output.phases[0].taskCount == 0)
        #expect(output.phases[0].wallClockSec == 0.0)
    }

    @Test
    func stopsAtNextSectionMarker() {
        // After the timing summary xcodebuild prints another `** … **`
        // banner. Parse must stop there so we don't sweep up unrelated
        // content as phases.
        let text = """
        Build Timing Summary

        CompileSwiftSources (1 task) | 1.0 seconds

        ** BUILD SUCCEEDED **

        Some-Looking-Phase (99 tasks) | 99.0 seconds
        """
        let output = BuildTimingSummaryParser.parse(text)
        #expect(output.buildSucceeded == true)
        // Only the phase BEFORE the SUCCEEDED banner counts.
        #expect(output.phases == [
            .init(name: "CompileSwiftSources", taskCount: 1, wallClockSec: 1.0)
        ])
    }

    @Test
    func toleratesSingleStraylineBetweenPhases() {
        // Indented or otherwise unrelated lines appear inside the summary
        // in some xcodebuild builds. A single non-matching line should be
        // skipped, not terminate parsing.
        let text = """
        Build Timing Summary

        CompileSwiftSources (5 tasks) | 0.5 seconds
            (some annotation we don't understand)
        Ld (1 task) | 0.1 seconds
        """
        let output = BuildTimingSummaryParser.parse(text)
        #expect(output.phases.map(\.name) == ["CompileSwiftSources", "Ld"])
    }
}
