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
    /// uniqueness is keyed on the full `Entry` value: name + signatureKey + kind +
    /// source range. That handles three failure modes simultaneously:
    /// 1. struct + extension on the same name (different startLine, same name).
    /// 2. multiple decls on a single physical line — e.g.
    ///    `typealias Foo = Int; typealias Bar = String` — which used to collide on
    ///    a startLine-only key.
    /// 3. ordinary overloads (different signatureKey, same name).
    public func transitiveClosure(startingAt start: DeclIndex.Entry) -> Output {
        var visited = Set<DeclIndex.Entry>()
        var visitedOrder: [DeclIndex.Entry] = []
        var external = Set<String>()

        var queue: [DeclIndex.Entry] = [start]
        visited.insert(start)

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
                    if visited.insert(candidate).inserted {
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
