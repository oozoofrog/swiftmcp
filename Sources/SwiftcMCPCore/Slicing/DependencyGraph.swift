import Foundation

/// Closure builder for slicing. Given a starting decl, walks references via
/// `ReferenceCollector` and follows them through `DeclIndex` until no new in-file
/// dependencies remain. Names that don't resolve to a top-level decl (standard
/// library, imported modules) are reported separately so the slicer can list them
/// as `externalReferences` in the response.
public struct DependencyGraph: Sendable {
    public struct Output: Sendable, Equatable {
        public let closure: [DeclIndex.Entry]              // visited entries in source order
        public let externalReferences: [String]            // referenced names with no top-level decl
    }

    private let index: DeclIndex
    private let astText: String

    public init(index: DeclIndex, astText: String) {
        self.index = index
        self.astText = astText
    }

    /// BFS from `start`. Each visited entry expands to its references; references
    /// matching a top-level decl are queued, others recorded as external. For
    /// overloaded names (multiple `index.find(name:)` results), all overloads are
    /// included — overloads are typically used together. Type bodies and their
    /// extensions also share a `signatureKey` (both report the type's name), so
    /// uniqueness is keyed on `startLine` rather than `signatureKey`: each decl in a
    /// single file occupies a distinct starting line, and that lets the BFS pull in
    /// every extension of a referenced type alongside the body.
    public func transitiveClosure(startingAt start: DeclIndex.Entry) -> Output {
        var visitedLines = Set<Int>()
        var visitedOrder: [DeclIndex.Entry] = []
        var external = Set<String>()

        var queue: [DeclIndex.Entry] = [start]
        visitedLines.insert(start.startLine)

        while !queue.isEmpty {
            let entry = queue.removeFirst()
            visitedOrder.append(entry)

            let refs = ReferenceCollector.collect(
                astText: astText,
                enclosing: entry.startLine...entry.endLine
            )
            for ref in refs {
                let candidates = index.find(name: ref.name)
                if candidates.isEmpty {
                    // Don't record a decl's own name as external (e.g. `Counter` shows
                    // up as a value reference inside `Counter.value` member access — if
                    // Counter is also a top-level type, it'd already be a candidate).
                    external.insert(ref.name)
                    continue
                }
                for candidate in candidates {
                    if visitedLines.insert(candidate.startLine).inserted {
                        queue.append(candidate)
                    }
                }
            }
        }

        // Sort the closure by source order so the slicer can emit decls in their
        // original layout.
        let sorted = visitedOrder.sorted { lhs, rhs in
            if lhs.startLine == rhs.startLine { return lhs.startColumn < rhs.startColumn }
            return lhs.startLine < rhs.startLine
        }
        return Output(closure: sorted, externalReferences: external.sorted())
    }
}
