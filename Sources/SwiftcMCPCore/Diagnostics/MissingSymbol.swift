import Foundation

/// A symbol that the compiler reported as undeclared in the user's snippet, classified
/// by kind and the way it's referenced in the source. Produced by
/// `MissingSymbolClassifier` from `[CompilerDiagnostic]` plus the original source.
///
/// `falsePositive` means the symbol's name *also* appears in the AST's declared
/// identifier pool — typically because the user typoed against another in-scope name.
/// Reporting still includes it (so the LLM sees the diagnostic) but stub generators
/// should skip it.
public struct MissingSymbol: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case value           // expression/function/variable referenced
        case type            // referenced as a type annotation or generic argument
        case module          // `import X` where module isn't found
    }

    public enum UsagePattern: String, Sendable, Codable, Equatable {
        case call            // `X(...)` — looks like a function/initializer call
        case memberAccess    // `X.foo` — looks like a type or value with a member
        case typeAnnotation  // `: X` or `<X>` in type position
        case importStatement // `import X`
        case unknown         // bare reference, can't disambiguate from snippet alone
    }

    public struct Location: Sendable, Codable, Equatable {
        public let line: Int
        public let column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    public let name: String
    public let kind: Kind
    public let locations: [Location]
    public let usagePattern: UsagePattern
    public let falsePositive: Bool

    public init(
        name: String,
        kind: Kind,
        locations: [Location],
        usagePattern: UsagePattern,
        falsePositive: Bool
    ) {
        self.name = name
        self.kind = kind
        self.locations = locations
        self.usagePattern = usagePattern
        self.falsePositive = falsePositive
    }
}

/// Classifies swiftc diagnostics into structured `MissingSymbol`s.
///
/// Diagnostic patterns supported (Swift 6.x wording, verified via probe):
/// - `cannot find '<name>' in scope` → `.value`
/// - `cannot find type '<name>' in scope` → `.type`
/// - `no such module '<name>'` → `.module`
/// - `use of unresolved identifier '<name>'` → `.value` (older toolchains, kept for
///   resilience even though Swift 6 prefers the "cannot find" wording).
///
/// Diagnostics that don't match any of these patterns are returned separately as
/// `unclassified` so the caller can still surface them via the raw diagnostic list.
public enum MissingSymbolClassifier {
    public struct Output: Sendable, Equatable {
        public let symbols: [MissingSymbol]
        public let unclassified: [CompilerDiagnostic]
    }

    nonisolated(unsafe) private static let valuePattern = #/^cannot find '([^']+)' in scope$/#
    nonisolated(unsafe) private static let typePattern = #/^cannot find type '([^']+)' in scope$/#
    nonisolated(unsafe) private static let modulePattern = #/^no such module '([^']+)'$/#
    nonisolated(unsafe) private static let legacyValuePattern = #/^use of unresolved identifier '([^']+)'$/#

    /// Classify `diagnostics` against the original `sourceCode`. Diagnostics that are
    /// not "missing symbol" forms are returned in `unclassified`.
    public static func classify(
        diagnostics: [CompilerDiagnostic],
        sourceCode: String,
        declaredIdentifiers: Set<String> = []
    ) -> Output {
        let lines = sourceCode.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Collapse duplicate findings for the same (name, kind) into a single
        // MissingSymbol with multiple locations.
        var bucket: [String: (kind: MissingSymbol.Kind, locations: [MissingSymbol.Location], usages: [MissingSymbol.UsagePattern])] = [:]
        var unclassified: [CompilerDiagnostic] = []

        for diagnostic in diagnostics where diagnostic.severity == "error" {
            let kind: MissingSymbol.Kind
            let name: String
            let usage: MissingSymbol.UsagePattern

            if let match = try? typePattern.wholeMatch(in: diagnostic.message) {
                kind = .type
                name = String(match.output.1)
                usage = .typeAnnotation
            } else if let match = try? modulePattern.wholeMatch(in: diagnostic.message) {
                kind = .module
                name = String(match.output.1)
                usage = .importStatement
            } else if let match = try? valuePattern.wholeMatch(in: diagnostic.message) {
                kind = .value
                name = String(match.output.1)
                usage = inferValueUsage(name: name, line: diagnostic.line, column: diagnostic.column, lines: lines)
            } else if let match = try? legacyValuePattern.wholeMatch(in: diagnostic.message) {
                kind = .value
                name = String(match.output.1)
                usage = inferValueUsage(name: name, line: diagnostic.line, column: diagnostic.column, lines: lines)
            } else {
                continue  // not a missing-symbol diagnostic — falls through to unclassified.
            }

            let key = "\(kind.rawValue):\(name)"
            let location = MissingSymbol.Location(line: diagnostic.line, column: diagnostic.column)
            if var entry = bucket[key] {
                entry.locations.append(location)
                entry.usages.append(usage)
                bucket[key] = entry
            } else {
                bucket[key] = (kind: kind, locations: [location], usages: [usage])
            }
        }

        // Anything we didn't classify above (and that wasn't an error severity) is
        // returned verbatim. Notes/warnings/remarks always pass through here.
        for diagnostic in diagnostics {
            if diagnostic.severity == "error",
               (try? valuePattern.wholeMatch(in: diagnostic.message)) != nil
                || (try? typePattern.wholeMatch(in: diagnostic.message)) != nil
                || (try? modulePattern.wholeMatch(in: diagnostic.message)) != nil
                || (try? legacyValuePattern.wholeMatch(in: diagnostic.message)) != nil
            {
                continue
            }
            unclassified.append(diagnostic)
        }

        let symbols = bucket.map { (key, value) -> MissingSymbol in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts.count == 2 ? parts[1] : key
            // Pick the most specific usage pattern across duplicates: typeAnnotation
            // wins, then memberAccess, then call, then unknown.
            let priority: [MissingSymbol.UsagePattern] = [.typeAnnotation, .memberAccess, .call, .importStatement, .unknown]
            let usage = priority.first(where: { value.usages.contains($0) }) ?? .unknown
            // Cross-check only applies to value/type kinds. `(import_decl module="X")`
            // appears in the AST even when the module is unresolved, so applying the
            // pool check to modules would mask a real missing-module error.
            let crossCheckable = value.kind != .module
            return MissingSymbol(
                name: name,
                kind: value.kind,
                locations: value.locations.sorted { $0.line == $1.line ? $0.column < $1.column : $0.line < $1.line },
                usagePattern: usage,
                falsePositive: crossCheckable && declaredIdentifiers.contains(name)
            )
        }
        // Stable sort: by kind then name.
        let sortedSymbols = symbols.sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.name < rhs.name }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return Output(symbols: sortedSymbols, unclassified: unclassified)
    }

    /// Look at the source line where a `cannot find 'X'` error originated and decide
    /// whether the reference looks like `X(`, `X.`, or just bare `X`.
    private static func inferValueUsage(
        name: String,
        line: Int,
        column: Int,
        lines: [String]
    ) -> MissingSymbol.UsagePattern {
        guard line >= 1, line <= lines.count else { return .unknown }
        let sourceLine = lines[line - 1]
        // column is 1-based byte column; convert to character offset best-effort.
        let chars = Array(sourceLine)
        let startIndex = max(0, min(column - 1, chars.count))
        // Find the end of the symbol token starting at startIndex.
        var endIndex = startIndex
        while endIndex < chars.count, chars[endIndex].isLetter || chars[endIndex].isNumber || chars[endIndex] == "_" {
            endIndex += 1
        }
        guard endIndex < chars.count else { return .unknown }
        let next = chars[endIndex]
        if next == "(" { return .call }
        if next == "." { return .memberAccess }
        // Heuristic fallback: scan the whole line for `<name>(` or `<name>.` anywhere.
        if sourceLine.contains("\(name)(") { return .call }
        if sourceLine.contains("\(name).") { return .memberAccess }
        return .unknown
    }
}
