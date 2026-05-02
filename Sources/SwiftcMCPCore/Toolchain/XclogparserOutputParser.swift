import Foundation

/// Parses the JSON tree that `xclogparser parse --reporter json` emits when
/// pointed at an `.xcactivitylog`. We don't bind to xclogparser's full
/// BuildStep schema — we only read the small set of fields we surface in
/// `xcbuild_perf` output, so an upstream schema add doesn't break us.
///
/// The tree is recursive `BuildStep` nodes. Top-level node has
/// `type == "buildLog"`; its `subSteps` contains per-target nodes
/// (`type == "target"`); each target's `subSteps` contains per-task nodes
/// for compile / link / codesign etc. We extract the per-target rollup with
/// a coarse-grained breakdown of compile-swift vs link sub-step durations
/// — that matches the level of detail callers usually need to point at a
/// hot target without drowning the response in step-level data.
public enum XclogparserOutputParser {
    public struct TargetTiming: Sendable, Codable, Equatable {
        public let name: String
        /// Relative offset (in seconds) from the build's earliest start
        /// timestamp. Absolute Unix epochs are noisy and not useful for
        /// the LLM consumer; relative offsets give a parallelism shape.
        public let buildStartSec: Double
        public let buildEndSec: Double
        public let wallClockSec: Double
        public let compileSwiftSec: Double
        public let linkSec: Double
        public let subStepCount: Int
    }

    public struct Output: Sendable, Codable, Equatable {
        public let targets: [TargetTiming]
        public let buildStatus: String?
    }

    public enum ParseError: Error, Sendable, Equatable {
        case malformedJSON(String)
    }

    public static func parse(jsonText: String) throws -> Output {
        guard let data = jsonText.data(using: .utf8) else {
            throw ParseError.malformedJSON("input is not valid UTF-8")
        }
        return try parse(jsonData: data)
    }

    public static func parse(jsonData: Data) throws -> Output {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw ParseError.malformedJSON("\(error)")
        }
        guard let root = raw as? [String: Any] else {
            throw ParseError.malformedJSON("root is not a JSON object")
        }

        // Collect every `type == "target"` node anywhere in the tree. xclogparser
        // sometimes nests targets inside `parallelStep` wrappers depending on
        // build configuration, so a flat tree-walk is more robust than assuming
        // one specific shape.
        var targets: [[String: Any]] = []
        collectTargets(in: root, into: &targets)

        // Compute the earliest start timestamp across all targets so we can
        // emit relative offsets (`buildStartSec`/`buildEndSec`). If xclogparser
        // didn't report timestamps for any node we leave offsets at 0.
        let earliestStart = targets
            .compactMap { ($0["startTimestamp"] as? NSNumber)?.doubleValue }
            .min() ?? 0

        let timings: [TargetTiming] = targets.compactMap { target in
            buildTiming(from: target, baseTimestamp: earliestStart)
        }

        let buildStatus = (root["buildStatus"] as? String)
        return Output(
            targets: timings.sorted(by: { $0.buildStartSec < $1.buildStartSec }),
            buildStatus: buildStatus
        )
    }

    // MARK: - Tree walking

    private static func collectTargets(in node: [String: Any], into bag: inout [[String: Any]]) {
        if (node["type"] as? String) == "target" {
            bag.append(node)
        }
        if let subSteps = node["subSteps"] as? [[String: Any]] {
            for child in subSteps {
                collectTargets(in: child, into: &bag)
            }
        }
    }

    /// Sum sub-step durations whose `title` matches a coarse command class.
    /// We deliberately don't read xclogparser's `detailStepType` enum — it
    /// has changed cases across releases and binding to it would shift
    /// every Xcode major. Title-prefix matching covers the four buckets
    /// LLMs ask about (swift, link) and ignores the rest into the catch-all
    /// `wallClockSec` total.
    private static func buildTiming(from target: [String: Any], baseTimestamp: Double) -> TargetTiming? {
        // Name source: prefer the human-readable target name from
        // xclogparser's `targetName` if present; otherwise fall back to
        // `title`, which xclogparser populates as `Build target <Name>`
        // in older versions. We strip that prefix when present.
        let name: String
        if let direct = target["targetName"] as? String, !direct.isEmpty {
            name = direct
        } else if let title = target["title"] as? String, !title.isEmpty {
            let prefix = "Build target "
            name = title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
        } else {
            return nil
        }

        let start = (target["startTimestamp"] as? NSNumber)?.doubleValue ?? baseTimestamp
        let end = (target["endTimestamp"] as? NSNumber)?.doubleValue ?? start
        let wall = (target["duration"] as? NSNumber)?.doubleValue ?? max(0, end - start)

        var compileSwift = 0.0
        var link = 0.0
        var subStepCount = 0
        if let subSteps = target["subSteps"] as? [[String: Any]] {
            subStepCount = subSteps.count
            for step in subSteps {
                let duration = (step["duration"] as? NSNumber)?.doubleValue ?? 0
                let title = (step["title"] as? String) ?? ""
                if title.hasPrefix("CompileSwift") || title.hasPrefix("SwiftCompile") {
                    compileSwift += duration
                } else if title.hasPrefix("Ld") || title.hasPrefix("Link") {
                    link += duration
                }
            }
        }

        return TargetTiming(
            name: name,
            buildStartSec: max(0, start - baseTimestamp),
            buildEndSec: max(0, end - baseTimestamp),
            wallClockSec: wall,
            compileSwiftSec: compileSwift,
            linkSec: link,
            subStepCount: subStepCount
        )
    }
}
