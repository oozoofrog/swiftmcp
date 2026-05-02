import Foundation
import CryptoKit

/// Wraps another `BuildArgsResolver` and memoizes its results in-memory, keyed on
/// the full `BuildInput` value. Each cached entry carries a *fingerprint* — a
/// snapshot of `(mtime, size, contentHash?)` for the manifests + every resolved
/// input file. On every cache hit the resolver re-stamps those paths and
/// compares; any change (Package.swift edited, project.pbxproj touched, source
/// file modified — even if mtime was restored, directory listing changed
/// because a file was added/removed, or any path missing entirely) invalidates
/// the entry and forces a re-resolve.
///
/// What the stamp actually catches:
/// - **mtime change**: ordinary edits and saves bump it.
/// - **size change**: most edits change file length too, redundant signal that's
///   cheap to capture from `attributesOfItem`.
/// - **content hash change** (every tracked regular file): catches in-place
///   rewrites that preserve mtime — `git checkout`, `cp -p`, `touch -r`, or
///   any tool that restores the original timestamp after writing new bytes.
///   This applies uniformly to `resolved.inputFiles`, manifests
///   (`Package.swift`, `Package.resolved`, `project.pbxproj`,
///   `contents.xcworkspacedata`), and any other regular file we track —
///   editing a manifest in place silently used to hit stale cache too.
///   Directories aren't hashed (mtime covers add/remove there); the
///   regular-file check happens at stamp time, so the path set can mix
///   files and directories without per-case branching.
/// - **Path missing**: handled via a sentinel mtime so missing-then-missing
///   still differs from missing-then-present.
///
/// Why CryptoKit: SHA-256 is a system framework on every supported host
/// (macOS 13+ / Swift 6.0+) and adds no third-party dependency. The resolver's
/// "Foundation only" rule covers the MCP wire layer — local file integrity
/// uses whatever the platform ships.
///
/// What the cache still does *not* catch:
/// - Changes to files swiftc reaches via search-paths but that aren't part of
///   the resolver's `inputFiles` (e.g. a transitive `.swiftmodule` rebuilt
///   elsewhere). Out of scope for the resolver's contract — that lives in the
///   consuming tool.
///
/// Concurrency: actor isolation serializes cache access. The wrapped resolver may
/// still be invoked twice for the same input if two callers race past the cache
/// check before either has stored a result — accepted for now; flow-coalescing
/// is a future milestone.
///
/// Errors thrown by the wrapped resolver propagate verbatim. The cache itself
/// never throws.
public actor CachedBuildArgsResolver: BuildArgsResolver {
    /// Per-path stamp: `(mtime, size, contentHash?)`. `contentHash` is `nil` for
    /// non-regular-files (directories, symlinks, missing paths) and for
    /// regular files we *don't* hash (anything other than `resolved.inputFiles`).
    /// All three fields participate in equality, so any change forces a miss.
    /// A missing path is encoded as `(mtime: -1, size: nil, contentHash: nil)`
    /// — distinguishable from a real file with epoch-zero mtime.
    struct Stamp: Equatable, Hashable {
        let mtime: TimeInterval
        let size: Int64?
        let contentHash: Data?
    }

    typealias Fingerprint = [String: Stamp]

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

        // Hash every regular file we track — inputFiles AND manifests
        // (Package.swift, project.pbxproj, contents.xcworkspacedata, ...)
        // — because all of them can be rewritten in place with mtime
        // restored, and only the hash distinguishes equal-length rewrites.
        // The regular-file check inside `stamp` skips directories
        // automatically, so we can throw the whole `paths` set at it.
        var fingerprint: Fingerprint = [:]
        for path in paths {
            fingerprint[path] = stamp(at: path)
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
            // contents.xcworkspacedata describes which projects the workspace
            // references; each referenced .xcodeproj's project.pbxproj is what
            // actually decides what xcodebuild compiles. Tracking only the
            // workspace XML misses the case where a user opens Xcode and adds a
            // file to one of the referenced projects — pbxproj is updated, but
            // contents.xcworkspacedata isn't touched. Parse the XML to locate
            // every referenced .xcodeproj and fingerprint each project.pbxproj.
            var paths = [path, path + "/contents.xcworkspacedata"]
            if let xml = try? String(
                contentsOfFile: path + "/contents.xcworkspacedata",
                encoding: .utf8
            ) {
                for projectPath in referencedProjectPaths(workspaceXML: xml, workspaceDir: path) {
                    paths.append(projectPath)
                    paths.append(projectPath + "/project.pbxproj")
                }
            }
            return paths
        }
    }

    /// Parse a workspace's `contents.xcworkspacedata` XML for every `<FileRef
    /// location="…"/>` that points at an `.xcodeproj`. Resolves the location
    /// prefix against the workspace's directory (`group:` → workspace's parent
    /// dir, `container:` → workspace itself, `absolute:` → as-is). Returns
    /// absolute paths.
    nonisolated(unsafe) private static let fileRefLocationPattern = #/<FileRef\b[^>]*?\blocation\s*=\s*"([^"]+)"/#

    private func referencedProjectPaths(
        workspaceXML xml: String,
        workspaceDir: String
    ) -> [String] {
        var projects: [String] = []
        for match in xml.matches(of: Self.fileRefLocationPattern) {
            let location = String(match.output.1)
            guard let resolved = resolveWorkspaceLocation(location, workspaceDir: workspaceDir),
                  resolved.hasSuffix(".xcodeproj")
            else { continue }
            projects.append(resolved)
        }
        return projects
    }

    private func resolveWorkspaceLocation(_ location: String, workspaceDir: String) -> String? {
        // Apple's workspace format encodes `prefix:relative-path`. Common prefixes:
        //   group:    — relative to the workspace's *containing* directory.
        //   container: — relative to the workspace bundle itself.
        //   absolute: — absolute path.
        //   self:     — the workspace bundle itself (rare).
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let prefix = String(parts[0])
        let relative = String(parts[1])
        switch prefix {
        case "group":
            let parent = (workspaceDir as NSString).deletingLastPathComponent
            return (parent as NSString).appendingPathComponent(relative)
        case "container":
            return (workspaceDir as NSString).appendingPathComponent(relative)
        case "absolute":
            return relative
        case "self":
            return workspaceDir
        default:
            return nil
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

    /// Build a `Stamp` for a path. Missing paths get the `(-1, nil, nil)`
    /// sentinel. Regular files get `size` plus SHA-256 of their bytes.
    /// Directories get only `mtime + size` (size is platform-defined for
    /// dirs but stable enough to participate in the signal); hashing a
    /// directory has no defined meaning, so the regular-file gate skips it.
    ///
    /// Hash failures (e.g. permission denied mid-read) fall back to
    /// `contentHash: nil`. That still differs from a successful hash on the
    /// next call, so the entry will invalidate — false misses cost a
    /// re-resolve, never staleness.
    private func stamp(at path: String) -> Stamp {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            return Stamp(mtime: -1, size: nil, contentHash: nil)
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let size = (attrs[.size] as? NSNumber)?.int64Value
        let isRegularFile = (attrs[.type] as? FileAttributeType) == .typeRegular
        var contentHash: Data? = nil
        if isRegularFile,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            contentHash = Data(SHA256.hash(data: data))
        }
        return Stamp(mtime: mtime, size: size, contentHash: contentHash)
    }
}
