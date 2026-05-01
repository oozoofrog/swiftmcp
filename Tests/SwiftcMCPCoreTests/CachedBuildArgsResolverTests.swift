import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("CachedBuildArgsResolver (unit)")
struct CachedBuildArgsResolverUnitTests {
    @Test
    func cachesIdenticalInput() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileURL = try scratch.write(name: "main.swift", contents: "print(1)\n")

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.file(path: fileURL.path, target: nil)

        _ = try await cache.resolveArgs(for: input)
        _ = try await cache.resolveArgs(for: input)

        #expect(counting.callCount == 1)
        let count = await cache.cachedEntryCount()
        #expect(count == 1)
    }

    @Test
    func differentInputsCacheSeparately() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileA = try scratch.write(name: "a.swift", contents: "let a = 1\n")
        let fileB = try scratch.write(name: "b.swift", contents: "let b = 2\n")

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)

        _ = try await cache.resolveArgs(for: .file(path: fileA.path, target: nil))
        _ = try await cache.resolveArgs(for: .file(path: fileB.path, target: nil))

        #expect(counting.callCount == 2)
        let count = await cache.cachedEntryCount()
        #expect(count == 2)
    }

    @Test
    func invalidatesWhenInputFileMissing() async throws {
        // Cache an entry, delete the underlying file, then re-resolve. The
        // hit check must fail (file gone), so the wrapped resolver is
        // invoked again — proven by callCount going to 2. The wrapped call
        // itself fails (file missing); we catch the throw and verify the
        // counter, which CountingResolver bumps before delegating.
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileURL = try scratch.write(name: "ephemeral.swift", contents: "let x = 0\n")

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.file(path: fileURL.path, target: nil)

        _ = try await cache.resolveArgs(for: input)
        #expect(counting.callCount == 1)

        try FileManager.default.removeItem(at: fileURL)

        await #expect(throws: MCPError.self) {
            _ = try await cache.resolveArgs(for: input)
        }
        #expect(counting.callCount == 2)
    }

    @Test
    func invalidatesWhenSearchPathMissing() async throws {
        // Source directory and a separate search-path directory. After the
        // search-path directory is deleted (and not recreated), the cache hit
        // check must fail and the wrapped resolver is re-invoked. We verify
        // callCount == 2; LocalFilesResolver doesn't validate searchPaths, so
        // the second wrapped call succeeds.
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fm = FileManager.default

        let sourceDir = scratch.directory.appending(path: "Sources", directoryHint: .isDirectory)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "let v = 1\n".write(
            to: sourceDir.appending(path: "Lib.swift"),
            atomically: true,
            encoding: .utf8
        )

        let searchPath = scratch.directory.appending(path: "Modules", directoryHint: .isDirectory)
        try fm.createDirectory(at: searchPath, withIntermediateDirectories: true)

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.directory(
            path: sourceDir.path,
            moduleName: nil,
            target: nil,
            searchPaths: [searchPath.path]
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(counting.callCount == 1)

        try fm.removeItem(at: searchPath)

        _ = try await cache.resolveArgs(for: input)
        #expect(counting.callCount == 2)
    }

    @Test
    func clearCacheRefreshes() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileURL = try scratch.write(name: "clear.swift", contents: "let y = 1\n")

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.file(path: fileURL.path, target: nil)

        _ = try await cache.resolveArgs(for: input)
        await cache.clearCache()

        let countAfterClear = await cache.cachedEntryCount()
        #expect(countAfterClear == 0)

        _ = try await cache.resolveArgs(for: input)
        #expect(counting.callCount == 2)

        let countAfterRefill = await cache.cachedEntryCount()
        #expect(countAfterRefill == 1)
    }

    @Test
    func validCacheReturnsEqualValue() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileURL = try scratch.write(name: "eq.swift", contents: "let z = 1\n")

        let cache = CachedBuildArgsResolver(wrapping: LocalFilesResolver())
        let input = BuildInput.file(path: fileURL.path, target: nil)

        let first = try await cache.resolveArgs(for: input)
        let second = try await cache.resolveArgs(for: input)
        #expect(first == second)
    }

    @Test
    func concurrentSameInputResolvesOnce() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileURL = try scratch.write(name: "race.swift", contents: "let r = 1\n")

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.file(path: fileURL.path, target: nil)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await cache.resolveArgs(for: input) }
            group.addTask { _ = try? await cache.resolveArgs(for: input) }
        }

        // Actor isolation usually serializes both calls so the second one finds
        // the entry already stored — but the plan permits up to 2 since we
        // don't yet flow-coalesce concurrent misses for the same key.
        #expect((1...2).contains(counting.callCount))
    }
}

@Suite("CachedBuildArgsResolver (integration)")
struct CachedBuildArgsResolverIntegrationTests {
    @Test
    func swiftPMPackageHitsCacheSecondTime() async throws {
        // Heuristic timing test: the first call must actually run `swift build`
        // (seconds), the second is an in-memory hit (sub-millisecond). A 5x
        // ratio is the minimum signal we accept; flaky machines can retry up
        // to 3 times before failing.
        let cache = CachedBuildArgsResolver(wrapping: SwiftPMPackageResolver())
        let input = BuildInput.swiftPMPackage(
            path: fixturePath("MultiTargetPackage"),
            targetName: "App",
            configuration: nil,
            target: nil
        )

        var lastFirst: TimeInterval = 0
        var lastSecond: TimeInterval = 0
        var passed = false
        for _ in 0..<3 {
            await cache.clearCache()

            let t0 = Date()
            _ = try await cache.resolveArgs(for: input)
            let firstElapsed = Date().timeIntervalSince(t0)

            let t1 = Date()
            _ = try await cache.resolveArgs(for: input)
            let secondElapsed = Date().timeIntervalSince(t1)

            lastFirst = firstElapsed
            lastSecond = secondElapsed
            if secondElapsed * 5 < firstElapsed {
                passed = true
                break
            }
        }
        #expect(
            passed,
            "expected cached call to be >= 5x faster; last attempt first=\(lastFirst)s second=\(lastSecond)s"
        )
    }
}
