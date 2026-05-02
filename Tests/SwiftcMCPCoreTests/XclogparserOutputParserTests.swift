import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("XclogparserOutputParser")
struct XclogparserOutputParserTests {
    @Test
    func extractsTargetsFromBuildTree() throws {
        // Synthetic xclogparser-style JSON with two targets, the second
        // depending on the first. Sub-steps name CompileSwift and Ld so
        // the bucket sums fire on both targets.
        let json = """
        {
          "type": "buildLog",
          "buildStatus": "succeeded",
          "subSteps": [
            {
              "type": "target",
              "targetName": "Core",
              "startTimestamp": 1000.0,
              "endTimestamp": 1003.0,
              "duration": 3.0,
              "subSteps": [
                { "type": "task", "title": "CompileSwiftSources normal arm64", "duration": 2.5 },
                { "type": "task", "title": "Ld /tmp/Core.a", "duration": 0.4 }
              ]
            },
            {
              "type": "target",
              "targetName": "App",
              "startTimestamp": 1003.5,
              "endTimestamp": 1010.0,
              "duration": 6.5,
              "subSteps": [
                { "type": "task", "title": "CompileSwiftSources normal arm64", "duration": 5.5 },
                { "type": "task", "title": "Ld /tmp/App", "duration": 0.8 }
              ]
            }
          ]
        }
        """
        let output = try XclogparserOutputParser.parse(jsonText: json)
        #expect(output.buildStatus == "succeeded")
        #expect(output.targets.count == 2)

        // Sorted by start time → Core first, App second.
        let core = output.targets[0]
        #expect(core.name == "Core")
        // Earliest target's start offset is 0; later target's offset is the delta.
        #expect(core.buildStartSec == 0)
        #expect(core.buildEndSec == 3.0)
        #expect(core.wallClockSec == 3.0)
        #expect(core.compileSwiftSec == 2.5)
        #expect(core.linkSec == 0.4)
        #expect(core.subStepCount == 2)

        let app = output.targets[1]
        #expect(app.name == "App")
        #expect(app.buildStartSec == 3.5)
        #expect(app.buildEndSec == 10.0)
        #expect(app.wallClockSec == 6.5)
        #expect(app.compileSwiftSec == 5.5)
        #expect(app.linkSec == 0.8)
    }

    @Test
    func walksNestedSubStepsToFindTargets() throws {
        // xclogparser sometimes wraps targets inside parallelStep nodes
        // depending on the build configuration. The collector must recurse
        // through any subSteps key, not just the buildLog root.
        let json = """
        {
          "type": "buildLog",
          "subSteps": [
            {
              "type": "parallelStep",
              "subSteps": [
                {
                  "type": "target",
                  "targetName": "Nested",
                  "startTimestamp": 0.0,
                  "endTimestamp": 1.0,
                  "duration": 1.0,
                  "subSteps": []
                }
              ]
            }
          ]
        }
        """
        let output = try XclogparserOutputParser.parse(jsonText: json)
        #expect(output.targets.map(\.name) == ["Nested"])
    }

    @Test
    func fallsBackToTitleWithBuildTargetPrefix() throws {
        // Older xclogparser versions don't emit `targetName`; they use
        // `title` like "Build target <Name>".
        let json = """
        {
          "type": "buildLog",
          "subSteps": [
            {
              "type": "target",
              "title": "Build target Legacy",
              "startTimestamp": 0.0,
              "endTimestamp": 0.5,
              "duration": 0.5,
              "subSteps": []
            }
          ]
        }
        """
        let output = try XclogparserOutputParser.parse(jsonText: json)
        #expect(output.targets.first?.name == "Legacy")
    }

    @Test
    func emptyBuildProducesEmptyTargets() throws {
        let json = """
        { "type": "buildLog", "buildStatus": "succeeded", "subSteps": [] }
        """
        let output = try XclogparserOutputParser.parse(jsonText: json)
        #expect(output.targets.isEmpty)
        #expect(output.buildStatus == "succeeded")
    }

    @Test
    func malformedJSONThrows() {
        #expect(throws: XclogparserOutputParser.ParseError.self) {
            _ = try XclogparserOutputParser.parse(jsonText: "{ not valid json")
        }
    }

    /// Per Codex stop-time review: tighten the target filter. Three
    /// scenarios this catches:
    ///   1. A node with `type == "target"` but no `targetName` and a
    ///      `title` that doesn't start with `Build target ` — we don't
    ///      know what it is, surfacing it would silently inflate
    ///      `targetTimings` with a phantom entry.
    ///   2. Nested targets inside a parent target's subSteps — older
    ///      xclogparser variants sometimes re-emit a target wrapper
    ///      under a parent for aggregate targets; descending into target
    ///      subSteps would double-count.
    ///   3. Non-target step types (`task`, `parallelStep`) that happen
    ///      to carry a title.
    @Test
    func ignoresNonTargetNodesAndNestedRewrappers() throws {
        let json = """
        {
          "type": "buildLog",
          "subSteps": [
            {
              "type": "target",
              "title": "Some weird heading without prefix",
              "duration": 1.0,
              "subSteps": []
            },
            {
              "type": "target",
              "targetName": "Outer",
              "duration": 5.0,
              "subSteps": [
                {
                  "type": "target",
                  "targetName": "InnerWrapped",
                  "duration": 2.0,
                  "subSteps": []
                },
                { "type": "task", "title": "Build target Phantom", "duration": 0.5 }
              ]
            }
          ]
        }
        """
        let output = try XclogparserOutputParser.parse(jsonText: json)
        // Only the legitimately-named outer target counts. The
        // unnamed "weird heading" target, the nested wrapper inside
        // Outer, and the type=task with target-shaped title all get
        // filtered out.
        #expect(output.targets.map(\.name) == ["Outer"])
    }

    @Test
    func unrecognizedTaskTitlesGoIntoNeitherBucket() throws {
        // A target with sub-steps that don't match Swift / link prefixes
        // — those are still counted in subStepCount but contribute 0 to
        // both bucket sums. wallClockSec stays the duration the target
        // node reported.
        let json = """
        {
          "type": "buildLog",
          "subSteps": [
            {
              "type": "target",
              "targetName": "Mystery",
              "startTimestamp": 0.0,
              "endTimestamp": 1.0,
              "duration": 1.0,
              "subSteps": [
                { "type": "task", "title": "ProcessInfoPlistFile", "duration": 0.1 },
                { "type": "task", "title": "CodeSign /tmp/x", "duration": 0.2 }
              ]
            }
          ]
        }
        """
        let output = try XclogparserOutputParser.parse(jsonText: json)
        let target = try #require(output.targets.first)
        #expect(target.name == "Mystery")
        #expect(target.compileSwiftSec == 0)
        #expect(target.linkSec == 0)
        #expect(target.subStepCount == 2)
        #expect(target.wallClockSec == 1.0)
    }
}
