import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("SourceRangeMapper")
struct SourceRangeMapperTests {
    @Test
    func mapsSimpleAsciiCoordinates() {
        let source = "let x = 1\nlet y = 2\n"
        let mapper = SourceRangeMapper(source: source)
        let idx = try? #require(mapper.index(line: 2, column: 1))
        #expect(idx == source.firstIndex(of: "l").flatMap { source.index($0, offsetBy: 10, limitedBy: source.endIndex) })
        // Reverse-check via substring. Line 2's content (without trailing newline)
        // should be "let y = 2".
        #expect(mapper.substringForLines(startLine: 2, endLine: 2) == "let y = 2")
    }

    @Test
    func multibyteSourceShiftsByteAndCharacterOffsets() {
        // "한" is 3 UTF-8 bytes ("\xED\x95\x9C"). swiftc reports columns in bytes, so
        // reaching the `+` operator on line 1 requires column 7 byte-wise (3 for "한"
        // + 1 space + 1 for "+" + ...). The mapper must translate that to the right
        // character index.
        let source = "let s = \"한\" + \"국\"\n"
        let mapper = SourceRangeMapper(source: source)
        // Byte column for the "+" operator: "let s = " is 8 ASCII bytes, then "\"한\"" is
        // 1 + 3 + 1 = 5 bytes (positions 9..13 in 1-based byte cols), then a space at 14,
        // then "+" at 15.
        let plusIdx = try? #require(mapper.index(line: 1, column: 15))
        #expect(plusIdx.map { source[$0] } == "+")
    }

    @Test
    func substringForLinesPreservesAttributesAtTopOfDecl() throws {
        let source = """
        public struct Counter {
            var value: Int = 0
        }
        public func formatLabel(_ s: String) -> String { s }
        """
        let mapper = SourceRangeMapper(source: source)
        let counterText = try #require(mapper.substringForLines(startLine: 1, endLine: 3))
        #expect(counterText.hasPrefix("public struct Counter"))
        #expect(counterText.hasSuffix("}"))
        #expect(counterText.contains("var value"))
    }

    @Test
    func indexRejectsOutOfRangeLines() {
        let mapper = SourceRangeMapper(source: "single line\n")
        #expect(mapper.index(line: 0, column: 1) == nil)
        #expect(mapper.index(line: 5, column: 1) == nil)
    }

    @Test
    func columnsBeyondLineEndClamp() {
        // Asking for column 999 on a 12-char line should return the index at the line
        // end rather than nil — swiftc occasionally emits end columns slightly past
        // the trailing newline.
        let source = "let x = 1\n"
        let mapper = SourceRangeMapper(source: source)
        let idx = try? #require(mapper.index(line: 1, column: 999))
        // The clamp lands at or just past the newline. Concretely: anywhere from the
        // newline position up to (and including) the start of line 2 / EOF — both are
        // valid String.Index positions. The contract is "no nil, no crash, no garbled
        // index", which is what we verify.
        #expect(idx != nil)
        if let idx {
            #expect(idx <= source.endIndex)
        }
    }

    @Test
    func substringWithoutTrailingNewlineAtEOF() {
        // No trailing newline on the last line — the helper still slices to EOF.
        let source = "first\nsecond"
        let mapper = SourceRangeMapper(source: source)
        #expect(mapper.substringForLines(startLine: 2, endLine: 2) == "second")
    }
}
