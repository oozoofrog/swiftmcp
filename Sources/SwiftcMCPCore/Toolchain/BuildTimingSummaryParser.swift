import Foundation

/// Parses the `Build Timing Summary` section that `xcodebuild` prints to
/// stdout when invoked with `-showBuildTimingSummary`. Output channel + format
/// have been stable since Xcode 10 and remain so on Xcode 26.4.x; the section
/// is aggregate by *command class* (e.g. `CompileSwiftSources`, `Ld`,
/// `CompileC`), not per-target — for per-target rollups the caller layers
/// xclogparser on top.
///
/// Sample stdout fragment we accept:
/// ```
/// ** BUILD SUCCEEDED **
///
/// Build Timing Summary
///
/// CompileSwiftSources (42 tasks) | 8.213 seconds
/// Ld (3 tasks) | 1.04 seconds
/// ```
public enum BuildTimingSummaryParser {
    public struct Phase: Sendable, Codable, Equatable {
        public let name: String
        public let taskCount: Int
        public let wallClockSec: Double
    }

    public struct Output: Sendable, Codable, Equatable {
        /// `true` iff a `** BUILD SUCCEEDED **` marker appeared in the input.
        /// `** BUILD FAILED **` (or absence of either marker) maps to false.
        public let buildSucceeded: Bool
        public let phases: [Phase]
    }

    /// Capture the phase-line shape: leading name, `(<n> tasks)`, `|`, wall
    /// time, suffix `seconds` (full word) or `s` (compact). swiftc and the
    /// xcodebuild build system have used both spellings across versions; we
    /// accept either so a future toolchain shift doesn't silently zero the
    /// parsed phases.
    nonisolated(unsafe) private static let phasePattern = #/^([A-Za-z][A-Za-z0-9_]*)\s*\((\d+)\s+tasks?\)\s*\|\s*([\d.]+)\s*(?:seconds?|s)\s*$/#

    public static func parse(_ text: String) -> Output {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let succeeded = lines.contains { $0.contains("** BUILD SUCCEEDED **") }

        // Locate the section header. If absent we return an empty phases
        // list — the build may have failed before the summary printed, or
        // the toolchain dropped the section entirely. Empty phases is a
        // legitimate observable state, not an error.
        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Build Timing Summary" }) else {
            return Output(buildSucceeded: succeeded, phases: [])
        }

        // Walk forward from the header. Stop on a `** BUILD ` marker (the
        // build finalization banner appears after the summary in some
        // builds), or on the first line that's neither blank nor a phase
        // line — that means the summary has ended and the next section
        // started. Blank lines inside the summary are tolerated; xcodebuild
        // sometimes prints a leading blank between header and first phase.
        var phases: [Phase] = []
        var consecutiveNonMatches = 0
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("** ") {
                break
            }
            if let match = try? phasePattern.firstMatch(in: trimmed),
               let count = Int(match.output.2),
               let wall = Double(match.output.3) {
                phases.append(Phase(
                    name: String(match.output.1),
                    taskCount: count,
                    wallClockSec: wall
                ))
                consecutiveNonMatches = 0
            } else {
                // Tolerate one stray non-matching line (e.g. an indented
                // sub-detail xcodebuild adds for some phases) but treat two
                // in a row as the section ending. This is more conservative
                // than "first non-match wins" because we've seen variants
                // that emit a stray blank-content line between phase rows.
                consecutiveNonMatches += 1
                if consecutiveNonMatches >= 2 {
                    break
                }
            }
        }

        return Output(buildSucceeded: succeeded, phases: phases)
    }
}
