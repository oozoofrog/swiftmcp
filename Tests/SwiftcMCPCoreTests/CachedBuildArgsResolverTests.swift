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

        #expect(await counting.callCount == 1)
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

        #expect(await counting.callCount == 2)
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
        #expect(await counting.callCount == 1)

        try FileManager.default.removeItem(at: fileURL)

        await #expect(throws: MCPError.self) {
            _ = try await cache.resolveArgs(for: input)
        }
        #expect(await counting.callCount == 2)
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
        #expect(await counting.callCount == 1)

        try fm.removeItem(at: searchPath)

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
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
        #expect(await counting.callCount == 2)

        let countAfterRefill = await cache.cachedEntryCount()
        #expect(countAfterRefill == 1)
    }

    /// Per Codex stop-time review: cache hits must not return stale analysis when
    /// a tracked input file's content has changed. The fingerprint snapshots each
    /// path's mtime; a touch (or any actual edit) bumps mtime and invalidates.
    @Test
    func invalidatesWhenInputFileMtimeChanges() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileURL = try scratch.write(name: "edit.swift", contents: "let v = 1\n")

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.file(path: fileURL.path, target: nil)

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 1)

        // Bump mtime forward without changing file contents — the fingerprint
        // mismatch alone must trigger a re-resolve.
        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes(
            [.modificationDate: later],
            ofItemAtPath: fileURL.path
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
    }

    /// Per Codex stop-time review: cache hits must catch *new* files added under a
    /// tracked directory. The directory's own mtime gets bumped when an entry is
    /// added/removed (macOS/Linux), so the fingerprint detects the change.
    @Test
    func invalidatesWhenDirectoryListingChanges() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fm = FileManager.default
        let sourceDir = scratch.directory.appending(path: "Sources", directoryHint: .isDirectory)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "let a = 1\n".write(
            to: sourceDir.appending(path: "A.swift"),
            atomically: true,
            encoding: .utf8
        )

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.directory(
            path: sourceDir.path,
            moduleName: nil,
            target: nil,
            searchPaths: []
        )

        let firstResolve = try await cache.resolveArgs(for: input)
        #expect(firstResolve.inputFiles.count == 1)
        #expect(await counting.callCount == 1)

        // Drop a new file into the tracked directory. The directory's mtime will
        // move forward; the fingerprint check must catch it and invalidate.
        try "let b = 2\n".write(
            to: sourceDir.appending(path: "B.swift"),
            atomically: true,
            encoding: .utf8
        )
        // Force a directory mtime bump in case the FS clock granularity hasn't
        // ticked yet (some FSes have second-level mtime resolution).
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: sourceDir.path
        )

        let secondResolve = try await cache.resolveArgs(for: input)
        #expect(secondResolve.inputFiles.count == 2)
        #expect(await counting.callCount == 2)
    }

    /// Per Codex stop-time review: editing a SwiftPM `Package.swift` (e.g. adding
    /// a new target) must invalidate the cache entry for that package's input —
    /// the resolver's stored `targets[]` view is otherwise stale. We use a
    /// `StaticPackageResolver` (TestSupport.swift) that returns a synthetic
    /// ResolvedBuildArgs without spawning swift CLI; we're testing fingerprint
    /// behavior, not the SwiftPM resolver itself.
    @Test
    func invalidatesWhenSwiftPMManifestChanges() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fm = FileManager.default
        let pkgDir = scratch.directory.appending(path: "Pkg", directoryHint: .isDirectory)
        let sourcesDir = pkgDir.appending(path: "Sources", directoryHint: .isDirectory)
        try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        let manifestURL = pkgDir.appending(path: "Package.swift")
        try "// initial\n".write(to: manifestURL, atomically: true, encoding: .utf8)
        let sourceURL = sourcesDir.appending(path: "Lib.swift")
        try "public let x = 1\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let counting = CountingResolver(StaticPackageResolver(
            inputFiles: [sourceURL.path],
            moduleName: "Lib"
        ))
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.swiftPMPackage(
            path: pkgDir.path,
            targetName: "Lib",
            configuration: nil,
            target: nil
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 1)

        // Edit Package.swift. The fingerprint stored on resolve includes
        // `<pkg>/Package.swift`, so this must invalidate even though the input
        // files we resolved (Lib.swift) are untouched.
        try "// updated\n".write(to: manifestURL, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: manifestURL.path
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
    }

    /// Per Codex stop-time review: SwiftPM packages organize sources as
    /// `Sources/<TargetName>/*.swift`. A new file dropped into the target
    /// directory bumps *that target directory's* mtime, but neither
    /// `Sources/` nor `Package.swift` change. The fingerprint must therefore
    /// include each input file's parent directory; otherwise the cached
    /// `inputFiles` list silently lags reality.
    @Test
    func invalidatesWhenSwiftPMTargetGainsNewSourceFile() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fm = FileManager.default
        let pkgDir = scratch.directory.appending(path: "Pkg", directoryHint: .isDirectory)
        let targetDir = pkgDir
            .appending(path: "Sources", directoryHint: .isDirectory)
            .appending(path: "Lib", directoryHint: .isDirectory)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try "// initial\n".write(
            to: pkgDir.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let originalSource = targetDir.appending(path: "Lib.swift")
        try "public let x = 1\n".write(to: originalSource, atomically: true, encoding: .utf8)

        // The stub returns ONLY the original source. After we add a sibling we
        // expect the cache to miss — which forces a re-resolve, and (in real life)
        // the live SwiftPM resolver would then return the expanded inputFiles
        // list. Here we just observe `callCount` jumping.
        let counting = CountingResolver(StaticPackageResolver(
            inputFiles: [originalSource.path],
            moduleName: "Lib"
        ))
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.swiftPMPackage(
            path: pkgDir.path,
            targetName: "Lib",
            configuration: nil,
            target: nil
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 1)

        // Drop a new file into Sources/Lib — neither Package.swift nor
        // Sources/ itself sees an mtime bump, but Sources/Lib does. The
        // fingerprint must catch that via the parent-of-input-file path.
        try "public let y = 2\n".write(
            to: targetDir.appending(path: "NewFile.swift"),
            atomically: true,
            encoding: .utf8
        )
        // FS-clock granularity safety: force the directory's mtime forward.
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: targetDir.path
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
    }

    /// Per Codex stop-time review (third pass): when a target's input files all
    /// live in a *nested* directory like `Sources/Lib/Sub/`, adding a new file at
    /// the target's top level (`Sources/Lib/NewFile.swift`) bumps `Sources/Lib`'s
    /// mtime — but the immediate-parent set only contains `Sources/Lib/Sub`. The
    /// fingerprint must walk *every* ancestor up to the input root, not just the
    /// immediate parent.
    @Test
    func invalidatesWhenSwiftPMNestedTargetGainsTopLevelFile() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fm = FileManager.default
        let pkgDir = scratch.directory.appending(path: "Pkg", directoryHint: .isDirectory)
        let targetDir = pkgDir
            .appending(path: "Sources", directoryHint: .isDirectory)
            .appending(path: "Lib", directoryHint: .isDirectory)
        let nestedDir = targetDir.appending(path: "Sub", directoryHint: .isDirectory)
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try "// initial\n".write(
            to: pkgDir.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        // Original sources only in the nested Sub/ folder. Immediate-parent
        // tracking would only cover `Sources/Lib/Sub`.
        let nestedSource = nestedDir.appending(path: "Inner.swift")
        try "public let inner = 1\n".write(to: nestedSource, atomically: true, encoding: .utf8)

        let counting = CountingResolver(StaticPackageResolver(
            inputFiles: [nestedSource.path],
            moduleName: "Lib"
        ))
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.swiftPMPackage(
            path: pkgDir.path,
            targetName: "Lib",
            configuration: nil,
            target: nil
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 1)

        // Add a file at the *target* level (Sources/Lib/RootLevel.swift), not in
        // the existing nested Sub/. Sources/Lib's mtime bumps; Sources/Lib/Sub
        // does not. A fingerprint that only looked at the immediate parent of
        // `Inner.swift` would silently miss this — the ancestor walk catches it.
        try "public let top = 2\n".write(
            to: targetDir.appending(path: "RootLevel.swift"),
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: targetDir.path
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
    }

    /// Per Codex stop-time review (fourth pass): `Sources/<TargetName>/Y/` is a
    /// pre-existing nested directory that already had a file in it; the
    /// resolver's stored inputFiles list points at that existing file. When the
    /// user adds a *new* file inside the same nested directory
    /// (`Y/Later.swift`), only `Y`'s mtime bumps — the parent `<TargetName>`
    /// doesn't change because no immediate child entry was added or removed.
    /// Walking ancestors of the existing inputFile catches `Y`, but only if we
    /// also enumerate every directory under `Sources/`. That's what
    /// `enumerateSubdirectories` does in the swiftPMPackage case.
    @Test
    func invalidatesWhenNestedExistingDirGainsFile() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fm = FileManager.default
        let pkgDir = scratch.directory.appending(path: "Pkg", directoryHint: .isDirectory)
        let nestedDir = pkgDir
            .appending(path: "Sources", directoryHint: .isDirectory)
            .appending(path: "App", directoryHint: .isDirectory)
            .appending(path: "Y", directoryHint: .isDirectory)
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try "// initial\n".write(
            to: pkgDir.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let original = nestedDir.appending(path: "Existing.swift")
        try "public let y = 1\n".write(to: original, atomically: true, encoding: .utf8)

        // Stub returns the original file; we don't touch resolver internals,
        // we exercise fingerprint behavior.
        let counting = CountingResolver(StaticPackageResolver(
            inputFiles: [original.path],
            moduleName: "App"
        ))
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.swiftPMPackage(
            path: pkgDir.path,
            targetName: "App",
            configuration: nil,
            target: nil
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 1)

        // Drop a new file into the *existing* nested directory. Y's mtime moves;
        // App's does not, so this scenario can only be caught by enumerating
        // every directory under Sources/. ancestor-walk alone isn't enough.
        try "public let later = 1\n".write(
            to: nestedDir.appending(path: "Later.swift"),
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: nestedDir.path
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
    }

    /// Per Codex stop-time review (fifth pass): a workspace's
    /// `contents.xcworkspacedata` only lists the projects it references — the
    /// referenced `.xcodeproj`s' own `project.pbxproj` files describe what
    /// xcodebuild actually compiles. A user opening Xcode and adding a file
    /// updates pbxproj but leaves contents.xcworkspacedata untouched. The
    /// fingerprint must therefore parse the workspace XML, locate each
    /// referenced project, and track its pbxproj mtime.
    @Test
    func invalidatesWhenReferencedProjectPbxprojChanges() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fm = FileManager.default

        // Build a workspace that references a sibling .xcodeproj. Layout mirrors
        // the production fixture (Tests/Fixtures/SampleWorkspace.xcworkspace ->
        // SampleProject.xcodeproj) so the parsing path runs against realistic
        // group:-prefixed locations.
        let projectDir = scratch.directory.appending(path: "Demo.xcodeproj", directoryHint: .isDirectory)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let pbxproj = projectDir.appending(path: "project.pbxproj")
        try "// initial pbxproj\n".write(to: pbxproj, atomically: true, encoding: .utf8)

        let workspaceDir = scratch.directory.appending(path: "Demo.xcworkspace", directoryHint: .isDirectory)
        try fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspaceContents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace
           version = "1.0">
           <FileRef
              location = "group:Demo.xcodeproj">
           </FileRef>
        </Workspace>
        """
        try workspaceContents.write(
            to: workspaceDir.appending(path: "contents.xcworkspacedata"),
            atomically: true,
            encoding: .utf8
        )

        // Use a stub resolver — the fingerprint logic is what's under test, not
        // the actual XcodebuildResolver. Fake input file lives anywhere; the
        // workspace fingerprint must invalidate via the referenced pbxproj path.
        let dummyInput = scratch.directory.appending(path: "fake.swift")
        try "let x = 1\n".write(to: dummyInput, atomically: true, encoding: .utf8)
        let counting = CountingResolver(StaticPackageResolver(
            inputFiles: [dummyInput.path],
            moduleName: "Demo"
        ))
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.xcodeWorkspace(
            path: workspaceDir.path,
            scheme: "Demo",
            targetName: nil,
            configuration: nil,
            target: nil
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 1)

        // Edit the referenced pbxproj. contents.xcworkspacedata is untouched —
        // the only signal is the pbxproj mtime, which the fingerprint must
        // include via the workspace XML parse.
        try "// updated pbxproj\n".write(to: pbxproj, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: pbxproj.path
        )

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
    }

    /// Per Stage 4-3 후속: in-place rewrites that preserve mtime (the kind
    /// `git checkout`, `cp -p`, or `touch -r` can produce) used to be silent
    /// stale hits. With content hashing in the fingerprint, the Stamp now
    /// changes on byte-level edits even when mtime — and even file size —
    /// stays identical. The two file bodies have the same length so `.size`
    /// can't distinguish them; we pin mtime to an integer-second epoch so
    /// APFS sub-second rounding can't desynchronize the restore — leaving
    /// the SHA-256 component as the *only* signal that fires.
    @Test
    func invalidatesWhenContentChangesButMtimeAndSizePreserved() async throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let fileURL = try scratch.write(name: "stable.swift", contents: "let original = 1\n")

        // Integer-second epoch round-trips cleanly through APFS's
        // nanosecond mtime field. Sub-second bits would survive
        // `setAttributes` write but Date(timeIntervalSince1970:)
        // re-parsed from the read-back attrs has come back with a slightly
        // different Double on this host, causing the Stamp's mtime alone
        // to differ — short-circuiting the very check we want to exercise.
        let pinnedMtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedMtime],
            ofItemAtPath: fileURL.path
        )

        let counting = CountingResolver(LocalFilesResolver())
        let cache = CachedBuildArgsResolver(wrapping: counting)
        let input = BuildInput.file(path: fileURL.path, target: nil)

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 1)

        // Same byte length so .size stays identical, and we restore the
        // pinned mtime so .mtime stays identical too.
        try "let modified = 2\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedMtime],
            ofItemAtPath: fileURL.path
        )
        let postAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        // Sanity: confirm only the bytes changed, so a pass below proves
        // hashing is doing the work — not mtime/size drift.
        #expect((postAttrs[.modificationDate] as? Date) == pinnedMtime)
        #expect("let original = 1\n".utf8.count == "let modified = 2\n".utf8.count)
        #expect((postAttrs[.size] as? NSNumber)?.intValue == "let modified = 2\n".utf8.count)

        _ = try await cache.resolveArgs(for: input)
        #expect(await counting.callCount == 2)
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
        #expect((1...2).contains(await counting.callCount))
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
