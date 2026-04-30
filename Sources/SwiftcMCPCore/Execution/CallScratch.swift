import Foundation

/// A per-call scratch directory under `$TMPDIR/swiftmcp-<uuid>/`. The directory is created
/// eagerly and removed when this object is disposed or deallocated.
///
/// Pattern:
/// ```swift
/// let scratch = try CallScratch()
/// defer { scratch.dispose() }
/// let url = try scratch.write(name: "main.swift", contents: code)
/// ```
public final class CallScratch: Sendable {
    public let directory: URL

    public init() throws {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appending(
            path: "swiftmcp-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    /// Write a file inside the scratch directory and return its URL.
    public func write(name: String, contents: Data) throws -> URL {
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try contents.write(to: url)
        return url
    }

    public func write(name: String, contents: String) throws -> URL {
        try write(name: name, contents: Data(contents.utf8))
    }

    /// Best-effort removal. Safe to call multiple times.
    public func dispose() {
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
