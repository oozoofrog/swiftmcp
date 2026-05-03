import Foundation

/// A single per-function or per-expression timing line emitted by swiftc when one of
/// `-Xfrontend -debug-time-function-bodies` / `-Xfrontend -debug-time-expression-type-checking`
/// is set. Three distinct stderr shapes are produced:
///
/// ```
/// <duration>ms\t<file>:<line>:<column>\t<subject>   // located function-body timing
/// <duration>ms\t<file>:<line>:<column>              // located expression timing
/// <duration>ms\t<invalid loc>\t<subject>            // synthesized/framework symbols
/// ```
///
/// Compiler-synthesized members (e.g. `Codable` derived enums, framework-internal
/// extension methods like `View.controlSize`) carry no source location and emit
/// `<invalid loc>` in the location field. They are still real timing entries — dropping
/// them silently would distort `totalMs` and per-kind counts, so they are surfaced with
/// `file = "<invalid loc>"` and `line = column = 0`. For function lines, `subject`
/// carries the declaration kind plus a mangled-style locator
/// (e.g. `global function Foo.(file).bar()@/path:line:col`); for expression lines, no
/// trailing field exists and `subject` is stored as the empty string.
///
/// `kind` is structural: a non-empty subject containing the canonical `(file).` module
/// locator — present in every function-declaration timing — maps to `function`. Empty
/// subjects (expression timings) and any other shape map to `expression`.
public struct DebugTimeEntry: Sendable, Equatable, Codable {
    public let kind: String
    public let file: String
    public let line: Int
    public let column: Int
    public let subject: String
    public let durationMs: Double

    public init(
        kind: String,
        file: String,
        line: Int,
        column: Int,
        subject: String,
        durationMs: Double
    ) {
        self.kind = kind
        self.file = file
        self.line = line
        self.column = column
        self.subject = subject
        self.durationMs = durationMs
    }
}

extension DebugTimeEntry {
    // Located timings: `<ms>ms\t<file>:<line>:<col>` with optional trailing `\t<subject>`.
    nonisolated(unsafe) private static let locatedPattern = #/^([0-9]+(?:\.[0-9]+)?)ms\t([^\t]+):([0-9]+):([0-9]+)(?:\t(.*))?$/#

    // Synthesized timings without source location:
    // `<ms>ms\t<invalid loc>` with optional trailing `\t<subject>`. Emitted for
    // compiler-derived members (Codable derived equals/hash, accessor synthesis) and
    // framework extension methods. Dropping these would understate aggregate timing.
    nonisolated(unsafe) private static let invalidLocPattern = #/^([0-9]+(?:\.[0-9]+)?)ms\t<invalid loc>(?:\t(.*))?$/#

    /// Canonical locator embedded in every swiftc decl-timing subject (e.g.
    /// `global function MyMod.(file).foo()@/path:line:col`). Lines without it are either
    /// expression timings (empty subject) or other shapes we conservatively call expressions.
    private static let declLocator = "(file)."

    /// Parse a single stderr line. Returns nil for any non-timing line.
    public init?(line: String) {
        let parsed = Self.parseLine(line)
        guard let parsed else { return nil }
        let isFunction = !parsed.subject.isEmpty && parsed.subject.contains(Self.declLocator)
        self.init(
            kind: isFunction ? "function" : "expression",
            file: parsed.file,
            line: parsed.line,
            column: parsed.column,
            subject: parsed.subject,
            durationMs: parsed.durationMs
        )
    }

    private static func parseLine(_ line: String) -> (file: String, line: Int, column: Int, subject: String, durationMs: Double)? {
        if let match = try? locatedPattern.wholeMatch(in: line) {
            let (_, msString, file, lineString, columnString, subjectOpt) = match.output
            guard let durationMs = Double(msString),
                  let lineNumber = Int(lineString),
                  let column = Int(columnString)
            else { return nil }
            return (String(file), lineNumber, column, subjectOpt.map(String.init) ?? "", durationMs)
        }
        if let match = try? invalidLocPattern.wholeMatch(in: line) {
            let (_, msString, subjectOpt) = match.output
            guard let durationMs = Double(msString) else { return nil }
            return ("<invalid loc>", 0, 0, subjectOpt.map(String.init) ?? "", durationMs)
        }
        return nil
    }
}
