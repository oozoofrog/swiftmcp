import Foundation

/// Resolver for local-filesystem inputs (`.file` and `.directory`). For `.directory`,
/// globs the top level for `*.swift` files (no recursion — keeps the rule simple; nested
/// layouts can be added later if needed) and infers `moduleName` from the directory's
/// basename when not explicitly provided.
///
/// Paths are normalized to absolute form so swiftc receives cwd-independent inputs
/// (per §9 cwd-neutral policy).
public struct LocalFilesResolver: BuildArgsResolver {
    public init() {}

    private var fileManager: FileManager { .default }

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        switch input {
        case .file(let path, let target):
            let absolute = absolutize(path)
            try ensureExists(absolute, kind: "file")
            return ResolvedBuildArgs(
                inputFiles: [absolute],
                moduleName: nil,
                target: target,
                searchPaths: [],
                frameworkSearchPaths: [],
                extraSwiftcArgs: []
            )

        case .directory(let path, let moduleName, let target, let searchPaths):
            let absolute = absolutize(path)
            try ensureDirectory(absolute)
            let files = try collectSwiftFiles(in: absolute)
            guard !files.isEmpty else {
                throw MCPError.invalidParams(
                    "`input.directory` contains no .swift files: \(absolute)"
                )
            }
            let resolvedModuleName = moduleName ?? inferModuleName(from: absolute)
            let absoluteSearchPaths = searchPaths.map(absolutize)
            return ResolvedBuildArgs(
                inputFiles: files,
                moduleName: resolvedModuleName,
                target: target,
                searchPaths: absoluteSearchPaths,
                frameworkSearchPaths: [],
                extraSwiftcArgs: []
            )

        case .swiftPMPackage:
            throw MCPError.internalError(
                "LocalFilesResolver received a swiftPMPackage input — route through SwiftPMPackageResolver."
            )
        }
    }

    private func absolutize(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path
    }

    private func ensureExists(_ path: String, kind: String) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw MCPError.invalidParams("`input.\(kind)` does not exist: \(path)")
        }
    }

    private func ensureDirectory(_ path: String) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw MCPError.invalidParams("`input.directory` does not exist: \(path)")
        }
        guard isDir.boolValue else {
            throw MCPError.invalidParams("`input.directory` is not a directory: \(path)")
        }
    }

    private func collectSwiftFiles(in directory: String) throws -> [String] {
        let url = URL(fileURLWithPath: directory)
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw MCPError.invalidParams(
                "Failed to list `input.directory` (\(directory)): \(error.localizedDescription)"
            )
        }
        return entries
            .filter { $0.pathExtension == "swift" }
            .map { $0.standardizedFileURL.path }
            .sorted()
    }

    private func inferModuleName(from directory: String) -> String {
        let basename = URL(fileURLWithPath: directory).lastPathComponent
        guard !basename.isEmpty, basename != "/" else { return "Module" }
        let sanitized = basename.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        var name = String(sanitized)
        if let first = name.first, first.isNumber {
            name = "_" + name
        }
        return name.isEmpty ? "Module" : name
    }
}
