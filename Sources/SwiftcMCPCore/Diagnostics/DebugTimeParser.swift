import Foundation

/// Extracts `DebugTimeEntry` values from raw stderr text produced by a swiftc run with
/// `-debug-time-function-bodies` / `-debug-time-expression-type-checking`. Lines that
/// do not match the timing pattern are silently dropped (compiler context, regular
/// diagnostics, etc.).
public struct DebugTimeParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> [DebugTimeEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { DebugTimeEntry(line: String($0)) }
    }
}
