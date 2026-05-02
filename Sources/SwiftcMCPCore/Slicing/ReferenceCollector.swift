import Foundation

/// Walks an AST text and pulls out the names of identifiers that a given declaration
/// *references* (as opposed to *declares*). The slicer feeds these names back into
/// `DeclIndex` to discover transitive dependencies.
///
/// Two AST node forms carry the most useful signal:
/// - `(declref_expr … decl="<module>.(file).<chain>.<name>(…)?@<file>:<line>:<col>" …)`
///   — value/function references. We strip the dotted prefix and the location suffix
///   to recover the base name.
/// - `(type_unqualified_ident id="X" …)` — type references in annotations or generic
///   arguments.
///
/// Locality filter: a reference whose *declaration site* (`@file:line:col`) lies
/// inside the same decl's source range is a local binding (parameter, let, inner
/// function) and is excluded so we don't follow ourselves around.
public enum ReferenceCollector {
    public struct Reference: Sendable, Hashable {
        public let name: String
        public let kind: Kind
        public enum Kind: String, Sendable, Hashable {
            case value
            case type
        }
    }

    // The chain inside `decl="…"` itself contains parens (e.g. `(file)`,
    // `formatLabel(_:)`), so we can't anchor with `[^)]*?`. Match anything
    // non-quote up to the `@` delimiter that introduces the location suffix.
    nonisolated(unsafe) private static let declWithLocationPattern = #/decl="([^"]+?)@([^":]+):(\d+):(\d+)"/#
    nonisolated(unsafe) private static let typeIdentPattern = #/\(type_unqualified_ident\b.*?id="([^"]+)"/#
    /// Captures the source file plus start line from any `range=[…]` attribute.
    /// Multi-file dump-ast emits `range=[/abs/path/file.swift:sl:sc - line:el:ec]`,
    /// so the file path is the leading non-`:` run.
    nonisolated(unsafe) private static let nodeRangePattern = #/range=\[([^:]+):(\d+):\d+ - line:(\d+):\d+\]/#

    /// Collect references from AST nodes whose own range starts inside `enclosing`
    /// AND whose source file matches `enclosingFile`. The file filter is what makes
    /// multi-file slicing safe — without it, line 5 in `A.swift` and line 5 in
    /// `B.swift` would both match the same line range and references from the
    /// other file would leak into the closure.
    public static func collect(
        astText: String,
        enclosing: ClosedRange<Int>,
        enclosingFile: String
    ) -> Set<Reference> {
        var refs: Set<Reference> = []
        // Many AST nodes (e.g. `type_unqualified_ident`, `pattern_named`) carry no
        // range= of their own — they belong to whichever parent node was opened most
        // recently. We track that by remembering the (file, startLine) pair of the
        // last node whose range= we did parse, and inheriting it as the "current
        // anchor" for subsequent unanchored siblings.
        var currentAnchor: (file: String, line: Int)? = nil

        for rawLine in astText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let parsed = parseNodeStartAnchor(line) {
                currentAnchor = parsed
            }
            // Filter: skip lines whose effective anchor is outside the slice. We
            // require both the file path and the line range to match — anchors
            // from other files in the same multi-file dump are off-topic. If we
            // have no anchor at all (very early in the AST text), we play it safe
            // and skip.
            guard let anchor = currentAnchor,
                  anchor.file == enclosingFile,
                  enclosing.contains(anchor.line)
            else { continue }

            // Any decl="…@file:line:col" attribute — picks up declref_expr,
            // member_ref_expr, dynamic_member_ref_expr, etc. uniformly.
            for match in line.matches(of: declWithLocationPattern) {
                let mangledChain = String(match.output.1)
                let declFile = String(match.output.2)
                let declFileLine = Int(match.output.3) ?? 0
                // Skip references whose declaration site is itself inside the slice
                // — those are local bindings (parameters, let, inner func). Only
                // skip when the decl site lives in the *same* file as the slice; a
                // peer-file decl on a coincidentally-overlapping line is a
                // legitimate cross-file dependency we still need to follow.
                if declFile == enclosingFile, enclosing.contains(declFileLine) { continue }
                let extracted = baseName(fromDeclChain: mangledChain)
                if !extracted.isEmpty {
                    refs.insert(.init(name: extracted, kind: .value))
                }
            }

            // type_unqualified_ident — type references in annotations.
            for match in line.matches(of: typeIdentPattern) {
                let typeName = String(match.output.1)
                if !typeName.isEmpty {
                    refs.insert(.init(name: typeName, kind: .type))
                }
            }
        }
        return refs
    }

    private static func parseNodeStartAnchor(_ line: String) -> (file: String, line: Int)? {
        guard let match = try? nodeRangePattern.firstMatch(in: line),
              let start = Int(match.output.2)
        else { return nil }
        return (file: String(match.output.1), line: start)
    }

    /// Extract the base name from a swiftc decl chain. Examples:
    ///   "sample.(file).formatLabel(_:)" → "formatLabel"
    ///   "sample.(file).Counter.init(value:)" → "Counter" (the type) + the call resolves
    ///       to Counter. We return the *first* non-`(file)` segment when the chain leads
    ///       into a member, otherwise the last identifier-like segment.
    /// We deliberately keep this simple: the slicer cares about top-level names that
    /// `DeclIndex` could find. Dotted chains where the *type* is at top level resolve
    /// correctly; member-only chains (e.g. nested types) are best-effort.
    static func baseName(fromDeclChain chain: String) -> String {
        // Step 1: trim a *trailing* argument-label parenthetical (e.g. `(_:)`,
        // `(value:)`) — the swiftc-internal `(file)` segment lives mid-chain and is
        // never the last token, so this is unambiguous.
        var trimmed = chain
        if trimmed.hasSuffix(")"),
           let lastOpen = trimmed.lastIndex(of: "(") {
            trimmed = String(trimmed[..<lastOpen])
        }
        // Step 2: drop the `(file)` synthetic segment. The remaining segments are
        // [module, top-level-name, …optional members]. We want the first user
        // segment — that's whatever DeclIndex is most likely to know about.
        let segments = trimmed
            .split(separator: ".")
            .map(String.init)
            .filter { $0 != "(file)" }
        guard segments.count >= 2 else { return "" }
        return segments[1]
    }
}
