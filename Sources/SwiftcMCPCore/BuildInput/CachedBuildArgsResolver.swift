import Foundation

/// Wraps another `BuildArgsResolver` and memoizes its results in-memory, keyed on
/// the full `BuildInput` value. The stored entry is verified on each cache hit:
/// every `inputFiles` / `searchPaths` / `frameworkSearchPaths` path must still
/// exist on disk. Any missing path invalidates the entry (PersistentScratch dirs
/// can be cleaned by the OS days later, and a partial cache is worse than a
/// re-resolve).
///
/// Concurrency: actor isolation serializes cache access. The wrapped resolver may
/// still be invoked twice for the same input if two callers race past the cache
/// check before either has stored a result — accepted for now; flow-coalescing
/// is a future milestone.
///
/// Errors: thrown by the wrapped resolver propagate verbatim. The cache itself
/// never throws.
public actor CachedBuildArgsResolver: BuildArgsResolver {
    private let wrapped: BuildArgsResolver
    private var cache: [BuildInput: ResolvedBuildArgs] = [:]

    public init(wrapping wrapped: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.wrapped = wrapped
    }

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        if let cached = cache[input], isStillValid(cached) {
            return cached
        }
        cache.removeValue(forKey: input)
        let resolved = try await wrapped.resolveArgs(for: input)
        cache[input] = resolved
        return resolved
    }

    /// Drop every cached entry. Visible for tests and for future cache-reset tooling.
    public func clearCache() {
        cache.removeAll()
    }

    /// How many entries the cache currently holds. Visible for tests.
    public func cachedEntryCount() -> Int {
        cache.count
    }

    private func isStillValid(_ resolved: ResolvedBuildArgs) -> Bool {
        let paths = resolved.inputFiles + resolved.searchPaths + resolved.frameworkSearchPaths
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }
}
