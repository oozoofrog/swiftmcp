import Foundation

/// Catalog of top-level declarations parsed out of a `swiftc -dump-ast` text. Built
/// once per slicing call and reused for the BFS traversal in `DependencyGraph`.
///
/// Top-level identification: swiftc indents each S-expression child by exactly two
/// spaces. We treat any line that begins with `"  ("` as a direct child of
/// `(source_file …)` — i.e. a top-level node. Inner functions/types nested inside
/// other declarations live at deeper indents and are excluded. This is a coarse but
/// stable heuristic; a sample-AST unit test guards regressions when the formatter
/// changes.
///
/// Multi-file dump-ast emits one `(source_file "PATH" …)` block per input file;
/// each top-level decl line carries its source path inline as
/// `range=[<absolute path>:<sl>:<sc> - line:<el>:<ec>]`, so every Entry can
/// independently identify which file it lives in without tracking ambient
/// source-file scope while parsing.
public struct DeclIndex: Sendable {
    public struct Entry: Sendable, Hashable {
        public enum Kind: String, Sendable, Codable, Hashable {
            case function
            case type            // struct / class / enum
            case protocolDecl    = "protocol"
            case typealiasDecl   = "typealias"
            case extensionDecl   = "extension"
            case variable        // top-level let/var
        }

        /// Absolute path of the source file this decl came from. Same path that
        /// appears inside `range=[<path>:…]` in the AST line.
        public let filePath: String
        public let name: String
        /// Full key for overload disambiguation. For functions this is the swiftc
        /// `"foo(_:_:)"` form; for types it's the bare name.
        public let signatureKey: String
        public let kind: Kind
        public let startLine: Int
        public let startColumn: Int
        public let endLine: Int
        public let endColumn: Int
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Build an index from `swiftc -dump-ast` stdout.
    public static func build(astText: String) -> DeclIndex {
        var entries: [Entry] = []
        for rawLine in astText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // Top-level filter: must start with exactly two spaces followed by `(`.
            guard line.hasPrefix("  (") && !line.hasPrefix("   ") else { continue }
            if let entry = parseTopLevelLine(line) {
                entries.append(entry)
            }
        }
        return DeclIndex(entries: entries)
    }

    public func find(name: String) -> [Entry] {
        entries.filter { $0.name == name }
    }

    public func find(signatureKey: String) -> Entry? {
        entries.first(where: { $0.signatureKey == signatureKey })
    }

    /// All entries whose source range covers `line` (inclusive) in `file`. The
    /// file filter is required for multi-file inputs — line numbers are not
    /// unique across `(source_file …)` blocks so a bare line query would match
    /// the wrong decl when two files happen to share a line.
    public func entry(containingLine line: Int, inFile file: String) -> Entry? {
        entries.first(where: { $0.filePath == file && $0.startLine <= line && line <= $0.endLine })
    }

    // MARK: - Parsing

    nonisolated(unsafe) private static let funcLine = #/^  \(func_decl[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let structLine = #/^  \(struct_decl[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let classLine = #/^  \(class_decl[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let enumLine = #/^  \(enum_decl[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let protocolLine = #/^  \(protocol[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\]\s+"([^"]+)"/#
    // swiftc emits `(typealias …)` not `(typealias_decl …)` — the trailing `_decl`
    // is missing for this one node kind. Match both for resilience across toolchain
    // versions.
    nonisolated(unsafe) private static let typealiasLine = #/^  \(typealias(?:_decl)?\b[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\][^"]*?"([^"]+)"/#
    nonisolated(unsafe) private static let extensionLine = #/^  \(extension_decl[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\][^"]*?"([^"]+)"/#
    nonisolated(unsafe) private static let varLine = #/^  \(var_decl[^)]*?range=\[[^\]]+ - line:(\d+):(\d+)\]\s+"([^"]+)"/#

    /// Pull the file path + start line/column out of
    /// `range=[<file>:<sl>:<sc> - line:…]`. Three capture groups: file, sl, sc.
    /// File path may contain almost anything except `:`; we accept everything up
    /// to the line/column delimiter.
    nonisolated(unsafe) private static let startCoords = #/range=\[([^:]+):(\d+):(\d+) - line:/#

    private static func parseTopLevelLine(_ line: String) -> Entry? {
        if let match = try? funcLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .function, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        if let match = try? structLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .type, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        if let match = try? classLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .type, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        if let match = try? enumLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .type, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        if let match = try? protocolLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .protocolDecl, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        if let match = try? typealiasLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .typealiasDecl, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        if let match = try? extensionLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .extensionDecl, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        if let match = try? varLine.firstMatch(in: line) {
            return makeEntry(line: line, kind: .variable, endLine: Int(match.output.1), endColumn: Int(match.output.2), name: String(match.output.3))
        }
        return nil
    }

    private static func makeEntry(
        line: String,
        kind: Entry.Kind,
        endLine: Int?,
        endColumn: Int?,
        name: String
    ) -> Entry? {
        guard let endLine, let endColumn else { return nil }
        guard let start = try? startCoords.firstMatch(in: line),
              let startLine = Int(start.output.2),
              let startColumn = Int(start.output.3)
        else { return nil }
        let filePath = String(start.output.1)
        // Functions in swiftc reports come as `"name(_:_:)"`. Strip the argument-label
        // suffix to get a base name suitable for user-facing lookup.
        let baseName: String
        if kind == .function, let openParen = name.firstIndex(of: "(") {
            baseName = String(name[..<openParen])
        } else {
            baseName = name
        }
        return Entry(
            filePath: filePath,
            name: baseName,
            signatureKey: name,
            kind: kind,
            startLine: startLine,
            startColumn: startColumn,
            endLine: endLine,
            endColumn: endColumn
        )
    }
}
