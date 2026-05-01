import Foundation

/// Extract a flat set of declared identifiers from `swiftc -dump-ast` text output.
///
/// The set is used as a *false-positive filter* by `MissingSymbolClassifier`: when a
/// missing-symbol diagnostic reports name `X` but the AST also records `X` as a
/// parameter / let-binding / type / etc. somewhere in the same compilation, the user
/// likely typoed against an in-scope name rather than referencing a truly undefined
/// symbol — so we shouldn't propose a stub for it.
///
/// We deliberately keep this best-effort. The AST text format isn't guaranteed stable
/// across toolchains (per PLAN §0 / §9), but the small set of node shapes we extract
/// from — parameter, pattern_named, func_decl, struct_decl, class_decl, enum_decl,
/// protocol_decl, typealias_decl, import_decl — has been stable for many releases.
public enum ASTIdentifierExtractor {
    nonisolated(unsafe) private static let parameterPattern = #/\(parameter "([^"]+)"/#
    nonisolated(unsafe) private static let patternNamedPattern = #/\(pattern_named [^)]*?"([^"]+)"\)/#
    nonisolated(unsafe) private static let funcDeclPattern = #/\(func_decl [^)]*?"([^("]+)\(/#
    nonisolated(unsafe) private static let structDeclPattern = #/\(struct_decl [^)]*?range=\[[^\]]+\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let classDeclPattern = #/\(class_decl [^)]*?range=\[[^\]]+\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let enumDeclPattern = #/\(enum_decl [^)]*?range=\[[^\]]+\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let protocolDeclPattern = #/\(protocol[^)]*?range=\[[^\]]+\]\s+"([^"]+)"/#
    nonisolated(unsafe) private static let typealiasDeclPattern = #/\(typealias_decl [^)]*?"([^"]+)"/#
    nonisolated(unsafe) private static let importDeclPattern = #/\(import_decl [^)]*?module="([^"]+)"/#

    /// Walk the AST text once and collect every declared identifier we recognize.
    /// The returned set is unordered; callers use it for membership checks only.
    public static func extractDeclaredIdentifiers(astText: String) -> Set<String> {
        var identifiers: Set<String> = []
        for line in astText.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            collect(parameterPattern, in: s, into: &identifiers)
            collect(patternNamedPattern, in: s, into: &identifiers)
            collect(funcDeclPattern, in: s, into: &identifiers)
            collect(structDeclPattern, in: s, into: &identifiers)
            collect(classDeclPattern, in: s, into: &identifiers)
            collect(enumDeclPattern, in: s, into: &identifiers)
            collect(protocolDeclPattern, in: s, into: &identifiers)
            collect(typealiasDeclPattern, in: s, into: &identifiers)
            collect(importDeclPattern, in: s, into: &identifiers)
        }
        return identifiers
    }

    private static func collect(
        _ regex: Regex<(Substring, Substring)>,
        in line: String,
        into set: inout Set<String>
    ) {
        for match in line.matches(of: regex) {
            let captured = String(match.output.1)
            if !captured.isEmpty {
                set.insert(captured)
            }
        }
    }
}
