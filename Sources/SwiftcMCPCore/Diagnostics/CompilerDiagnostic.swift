import Foundation

/// A single compiler diagnostic line of the form
/// `<file>:<line>:<col>: <severity>: <message> [#<group>]`.
///
/// `<group>` is the diagnostic group identifier when swiftc emits one (Swift 6.x emits
/// these by default for many groups; some diagnostics have no group). Context-only lines
/// (the `   |       `- note:` continuation lines that swiftc prints under each
/// finding, and `[#X]: <url>` footnotes) do not match and are skipped by the parser.
public struct CompilerDiagnostic: Sendable, Equatable, Codable {
    public let file: String
    public let line: Int
    public let column: Int
    /// `"warning"`, `"error"`, `"note"`, or `"remark"` as emitted by swiftc.
    public let severity: String
    public let group: String?
    public let message: String

    public init(
        file: String,
        line: Int,
        column: Int,
        severity: String,
        group: String?,
        message: String
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.group = group
        self.message = message
    }
}

extension CompilerDiagnostic {
    nonisolated(unsafe) private static let pattern = #/^(.+?):(\d+):(\d+): (warning|error|note|remark): (.+?)(?: \[#([^\]]+)\])?$/#

    /// Parse a single line. Returns nil if the line is not a top-level diagnostic.
    public init?(line: String) {
        guard let match = try? Self.pattern.wholeMatch(in: line) else { return nil }
        let (_, file, lineString, columnString, severity, message, group) = match.output
        guard let lineNumber = Int(lineString),
              let column = Int(columnString)
        else { return nil }
        self.init(
            file: String(file),
            line: lineNumber,
            column: column,
            severity: String(severity),
            group: group.map(String.init),
            message: String(message)
        )
    }
}

/// Parses swiftc stderr text into a list of `CompilerDiagnostic`s.
public struct DiagnosticParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> [CompilerDiagnostic] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { CompilerDiagnostic(line: String($0)) }
    }
}
