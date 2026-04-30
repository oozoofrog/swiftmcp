import Foundation

/// Extracts `CompilerWarning`s from raw stderr text produced by `swiftc -typecheck`.
/// Non-warning lines (compiler context, source excerpts, errors) are silently skipped.
public struct WarningParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> [CompilerWarning] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { CompilerWarning(line: String($0)) }
    }
}
