import Foundation

/// A single `... took Nms to type-check (limit: Mms)` warning emitted by swiftc when
/// `-Xfrontend -warn-long-expression-type-checking` or `-warn-long-function-bodies` is set.
///
/// `subject` preserves the verbatim warning subject (e.g. `"expression"`,
/// `"global function 'compute()'"`, `"instance method 'foo(_:)'"`). The compiler's
/// phrasing varies across declaration kinds; we keep the raw text rather than enumerating
/// every variant, since LLM clients can read the subject directly.
public struct CompilerWarning: Sendable, Equatable, Codable {
    public let file: String
    public let line: Int
    public let column: Int
    /// `"expression"` for the bare expression warning, `"function"` for any declaration variant.
    public let kind: String
    public let subject: String
    public let durationMs: Int
    public let limitMs: Int

    public init(
        file: String,
        line: Int,
        column: Int,
        kind: String,
        subject: String,
        durationMs: Int,
        limitMs: Int
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.kind = kind
        self.subject = subject
        self.durationMs = durationMs
        self.limitMs = limitMs
    }
}

extension CompilerWarning {
    // The compiled regex itself is immutable and stateless. Swift 6 requires this opt-out
    // because Regex<Output> is not declared Sendable.
    nonisolated(unsafe) private static let pattern = #/^(.+?):(\d+):(\d+): warning: (.+?) took (\d+)ms to type-check \(limit: (\d+)ms\)$/#

    /// Parse a single line. Returns nil if the line is not a long-typecheck warning.
    public init?(line: String) {
        guard let match = try? Self.pattern.wholeMatch(in: line) else { return nil }
        let (_, file, lineString, columnString, subject, msString, limitString) = match.output
        guard let lineNumber = Int(lineString),
              let column = Int(columnString),
              let durationMs = Int(msString),
              let limitMs = Int(limitString)
        else { return nil }
        self.init(
            file: String(file),
            line: lineNumber,
            column: column,
            kind: (subject == "expression") ? "expression" : "function",
            subject: String(subject),
            durationMs: durationMs,
            limitMs: limitMs
        )
    }
}
