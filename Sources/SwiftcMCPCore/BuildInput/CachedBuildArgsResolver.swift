import Foundation

/// Wraps another `BuildArgsResolver` and memoizes its results in-memory, keyed on
/// the full `BuildInput` value. Each cached entry carries a *fingerprint* — a
/// snapshot of mtimes for the manifests + every resolved input file. On every cache
/// hit the resolver re-stats those paths and compares; any change (Package.swift
/// edited, project.pbxproj touched, source file modified, directory listing
/// changed because a file was added/removed, or any path missing entirely)
/// invalidates the entry and forces a re-resolve.
///
/// What `mtime` actually catches:
/// - **File mtime change**: source edits, manifest edits.
/// - **Directory mtime change**: macOS/Linux update the directory's mtime when a
///   child entry is added or removed. So a new `.swift` file dropped into a
///   `Sources/<target>` folder bumps that folder's mtime even before any file is
///   read.
/// - **Path missing**: PersistentScratch dirs reclaimed by the OS, files moved.
///
/// What it does *not* catch:
/// - In-place file rewrites that preserve mtime (rare; tools like `cp -p` or git
///   checkouts can do this). Acceptable trade-off for the in-memory tier; future
///   milestones can layer content hashing on top.
/// - Changes to files swiftc reaches via search-paths but that aren't part of the
///   resolver's `inputFiles` (e.g. a transitive `.swiftmodule` rebuilt elsewhere).
///   Out of scope for the resolver's contract — that lives in the consuming tool.
///
/// Concurrency: actor isolation serializes cache access. The wrapped resolver may
/// still be invoked twice for the same input if two callers race past the cache
/// check before either has stored a result — accepted for now; flow-coalescing
/// is a future milestone.
///
/// Errors thrown by the wrapped resolver propagate verbatim. The cache itself
/// never throws.
public actor CachedBuildArgsResolver: BuildArgsResolver {
    /// Path → modification time (epoch seconds). nil means "the path was missing
    /// when we last looked" — a missing-then-missing comparison still invalidates,
    /// because the resolver's success path implies the path was present.
    typealias Fingerprint = [String: TimeInterval]

    private struct Entry {
        let resolved: ResolvedBuildArgs
        let fingerprint: Fingerprint
    }

    private let wrapped: BuildArgsResolver
    private var cache: [BuildInput: Entry] = [:]

    public init(wrapping wrapped: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.wrapped = wrapped
    }

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        if let entry = cache[input], isStillValid(entry, for: input) {
            return entry.resolved
        }
        cache.removeValue(forKey: input)
        let resolved = try await wrapped.resolveArgs(for: input)
        let fingerprint = makeFingerprint(input: input, resolved: resolved)
        cache[input] = Entry(resolved: resolved, fingerprint: fingerprint)
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

    // MARK: - Validity

    private func isStillValid(_ entry: Entry, for input: BuildInput) -> Bool {
        // 1. Every previously-known path must still exist on disk.
        let trackedPaths = entry.resolved.inputFiles
            + entry.resolved.searchPaths
            + entry.resolved.frameworkSearchPaths
        for path in trackedPaths where !FileManager.default.fileExists(atPath: path) {
            return false
        }
        // 2. Every fingerprint entry must still match. A stored mtime that no
        //    longer matches the live mtime — or a path that's now missing —
        //    invalidates the entry.
        let current = makeFingerprint(input: input, resolved: entry.resolved)
        return current == entry.fingerprint
    }

    private func makeFingerprint(input: BuildInput, resolved: ResolvedBuildArgs) -> Fingerprint {
        var paths: Set<String> = []
        // Input-derived paths: these always belong in the fingerprint regardless of
        // case, because if any of them changes the analysis is on stale data.
        paths.formUnion(resolved.inputFiles)
        paths.formUnion(resolved.searchPaths)
        paths.formUnion(resolved.frameworkSearchPaths)
        // Every ancestor directory of every input file, walked up to the input's
        // declared root (Package path / Project path / etc.). macOS/Linux bump a
        // directory's mtime when entries are added or removed inside it. Tracking
        // *only* the immediate parent isn't enough for nested layouts: if all
        // current input files live at `Sources/Lib/Sub/*.swift`, a new file added
        // at `Sources/Lib/RootLevel.swift` bumps `Sources/Lib`'s mtime — but the
        // immediate-parent set only contains `Sources/Lib/Sub`. Walking ancestors
        // up to the input root catches that.
        //
        // `.file` inputs have no meaningful root — adding sibling files in the
        // host filesystem doesn't affect the analysis. Skip ancestor tracking
        // there so we don't fingerprint shared ancestors like `/var/folders/.../T`,
        // whose mtime moves whenever any other test or process writes nearby.
        if let inputRoot = rootPath(for: input) {
            for file in resolved.inputFiles {
                var current = (file as NSString).deletingLastPathComponent
                while !current.isEmpty {
                    paths.insert(current)
                    if current == inputRoot { break }
                    let parent = (current as NSString).deletingLastPathComponent
                    // Bail if `deletingLastPathComponent` is a fixed point (we've hit
                    // "/" or "."). Without this the loop would spin forever on root.
                    if parent == current { break }
                    current = parent
                }
            }
        }
        // Manifest-style paths: case-specific, drive cache invalidation when the
        // user edits the project descriptor or adds/removes a file from a tracked
        // directory.
        paths.formUnion(manifestPaths(for: input))

        var fingerprint: Fingerprint = [:]
        for path in paths {
            fingerprint[path] = mtimeOrSentinel(at: path)
        }
        return fingerprint
    }

    /// The path the caller treats as the "root" of this input. Ancestor walking
    /// stops here so we don't fingerprint `/`, `/Users`, etc.
    ///
    /// `nil` for cases where ancestor walking either doesn't apply or would
    /// over-include shared paths:
    /// - `.file`: a single file's analysis doesn't depend on its sibling layout.
    /// - `.xcodeProject` / `.xcodeWorkspace`: pbxproj / contents.xcworkspacedata
    ///   are the authoritative descriptors of what xcodebuild compiles. New
    ///   `.swift` files only enter the analysis once they're listed there, so
    ///   tracking those manifest mtimes is sufficient. Also, the input root is
    ///   `.xcodeproj` / `.xcworkspace` itself — but the source files live in
    ///   *sibling* directories under the parent, so an ancestor walk from the
    ///   inputFile would never meet the root and would climb into shared
    ///   filesystem ancestors instead.
    private func rootPath(for input: BuildInput) -> String? {
        switch input {
        case .file: return nil
        case .directory(let path, _, _, _): return path
        case .swiftPMPackage(let path, _, _, _): return path
        case .xcodeProject: return nil
        case .xcodeWorkspace: return nil
        }
    }

    /// Per-case paths whose mtime represents the *shape* of the input — the things
    /// that, if changed, could make `inputFiles`/`searchPaths` themselves stale.
    private func manifestPaths(for input: BuildInput) -> [String] {
        switch input {
        case .file(let path, _):
            return [path]
        case .directory(let path, _, _, let searchPaths):
            // Directory mtime catches add/remove inside the directory; search-path
            // directories are tracked the same way so a freshly-built dependency
            // module (mtime change on the modules dir) invalidates the slot.
            return [path] + searchPaths
        case .swiftPMPackage(let path, _, _, _):
            // SwiftPM recursively discovers `.swift` files under `Sources/<TargetName>`,
            // so a new file dropped into *any* existing nested directory must
            // invalidate the cache. Walking the entire `Sources/` tree picks up every
            // intermediate directory's mtime — a directory's mtime bumps when an
            // immediate child entry is added or removed, so deep additions are
            // caught at the directory they appear in.
            var paths = [
                path,
                path + "/Package.swift",
                path + "/Package.resolved",
                path + "/Sources"
            ]
            paths.append(contentsOf: enumerateSubdirectories(at: path + "/Sources"))
            return paths
        case .xcodeProject(let path, _, _, _):
            // pbxproj is the sole authority on which files Xcode will compile —
            // a new `.swift` file is invisible to xcodebuild until it's added to
            // the build phases. So pbxproj's mtime fully covers "the file set
            // changed". No ancestor walking needed (and `rootPath(for:)` returns
            // nil to skip it).
            return [path, path + "/project.pbxproj"]
        case .xcodeWorkspace(let path, _, _, _, _):
            // Same reasoning as xcodeProject. Workspace contents file describes
            // which projects are referenced; the referenced projects' pbxprojs
            // describe what's compiled. Tracking all referenced pbxprojs is a
            // future enhancement — for now contents.xcworkspacedata's mtime
            // catches workspace-level changes (project added/removed).
            return [path, path + "/contents.xcworkspacedata"]
        }
    }

    /// Walk the directory tree rooted at `root` and return every subdirectory
    /// (including `root` itself if it exists). Files are skipped — they're
    /// already covered by `inputFiles` plus the parent-mtime mechanism. If
    /// `root` doesn't exist or isn't readable, returns an empty list and the
    /// caller's separate `paths.append(path + "/Sources")` provides the missing
    /// signal via `mtimeOrSentinel`.
    private func enumerateSubdirectories(at root: String) -> [String] {
        var directories: [String] = []
        let fm = FileManager.default
        var rootIsDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &rootIsDir), rootIsDir.boolValue else {
            return directories
        }
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return directories
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                directories.append(url.path)
            }
        }
        return directories
    }

    /// `nil` when the path doesn't exist; otherwise the mtime in epoch seconds.
    /// Using `nil` (rather than 0) means "missing" and "epoch-zero mtime" are
    /// distinguishable — both still invalidate the cache, but for clearer reasons
    /// when debugging.
    private func mtimeOrSentinel(at path: String) -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date
        else {
            // -1 sentinel: definitely doesn't equal any real mtime, and avoids the
            // dictionary-key issue of storing `nil` in [String: TimeInterval].
            return -1
        }
        return date.timeIntervalSince1970
    }
}
