import Foundation

/// Maps swiftc-style 1-based UTF-8 byte coordinates (`line:column`) to `String.Index`
/// positions in a Swift source string. Used by the slicer to slice declarations out
/// of a file given their AST-reported `range=[file:sl:sc - line:el:ec]` extents.
///
/// Why explicit UTF-8: swiftc reports columns in *bytes*, not characters. Source files
/// containing multi-byte runes (e.g. Korean comments, emoji string literals) shift
/// `String.Index` and `utf8` offsets apart. Working from the byte view keeps the
/// mapping faithful to what the compiler reported. The publicly exposed methods then
/// convert back to a `String.Index` via `utf8` so callers get a substring view that
/// preserves graphemes.
public struct SourceRangeMapper: Sendable {
    private let source: String
    /// `lineStartUTF8Offsets[i]` is the UTF-8 byte offset (from the start of `source`)
    /// at which line `i + 1` begins. `endIndex.utf8Offset` is appended last so a caller
    /// asking for a `column` past the final newline still gets a clamped index.
    private let lineStartUTF8Offsets: [Int]

    public init(source: String) {
        self.source = source
        var offsets: [Int] = [0]
        var i = 0
        for byte in source.utf8 {
            i += 1
            if byte == 0x0A {  // '\n'. We treat '\r\n' as a normal line break by virtue
                                // of the leading byte being either 0x0D (handled implicitly
                                // by the column calculation absorbing the carriage return)
                                // or '\n'. Pure '\r' line endings aren't common in Swift.
                offsets.append(i)
            }
        }
        // Sentinel for "end of file" — lets index(line:end+1) clamp instead of throwing.
        offsets.append(source.utf8.count)
        self.lineStartUTF8Offsets = offsets
    }

    /// Convert a 1-based (line, column) byte coordinate to a `String.Index`. Returns
    /// `nil` when `line` is non-positive or beyond the file. Columns past the end of
    /// the line are clamped to the line's end (mirrors swiftc's "end column past EOL"
    /// reports for trailing newlines).
    public func index(line: Int, column: Int) -> String.Index? {
        guard line >= 1, line <= lineStartUTF8Offsets.count - 1 else { return nil }
        let lineStart = lineStartUTF8Offsets[line - 1]
        let lineEnd = lineStartUTF8Offsets[line]  // exclusive — start of next line.
        let target = lineStart + max(0, column - 1)
        let clamped = min(target, lineEnd)
        return source.utf8.index(source.utf8.startIndex, offsetBy: clamped, limitedBy: source.utf8.endIndex)
            .flatMap { $0.samePosition(in: source) }
    }

    /// Substring from the start of `startLine` to the end of `endLine` (i.e. line-level
    /// slicing — column is ignored). Trailing newline of `endLine` is excluded so the
    /// caller can join multiple slices with `\n\n` cleanly.
    public func substringForLines(startLine: Int, endLine: Int) -> String? {
        guard startLine >= 1,
              endLine >= startLine,
              startLine <= lineStartUTF8Offsets.count - 1,
              endLine <= lineStartUTF8Offsets.count - 1
        else { return nil }
        let startUTF8 = lineStartUTF8Offsets[startLine - 1]
        let nextLineStartUTF8 = lineStartUTF8Offsets[endLine]  // sentinel covers EOF case.
        // Drop the trailing newline if present so joins behave predictably.
        let endUTF8: Int
        if nextLineStartUTF8 > startUTF8 {
            let lastByteOffset = nextLineStartUTF8 - 1
            let utf8 = source.utf8
            let lastByteIndex = utf8.index(utf8.startIndex, offsetBy: lastByteOffset)
            let lastByte = lastByteIndex < utf8.endIndex ? utf8[lastByteIndex] : 0
            endUTF8 = (lastByte == 0x0A) ? nextLineStartUTF8 - 1 : nextLineStartUTF8
        } else {
            endUTF8 = nextLineStartUTF8
        }
        let utf8 = source.utf8
        guard let startIdx = utf8.index(utf8.startIndex, offsetBy: startUTF8, limitedBy: utf8.endIndex)?
                .samePosition(in: source),
              let endIdx = utf8.index(utf8.startIndex, offsetBy: endUTF8, limitedBy: utf8.endIndex)?
                .samePosition(in: source)
        else { return nil }
        return String(source[startIdx..<endIdx])
    }

    /// Total line count. Useful for tests that want to assert "endLine is the last
    /// line" without recomputing.
    public var lineCount: Int { lineStartUTF8Offsets.count - 1 }
}
