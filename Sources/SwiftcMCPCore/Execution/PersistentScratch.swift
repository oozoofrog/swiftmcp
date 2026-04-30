import Foundation

/// A scratch directory whose contents are intended to outlive the tool call —
/// for tools that return a *path* in their result so a client can open the
/// produced artifact afterwards.
///
/// No deinit-driven cleanup. The directory is left in `$TMPDIR` for the OS to
/// reclaim on its normal temp-file rotation.
public final class PersistentScratch: Sendable {
    public let directory: URL

    public init(prefix: String = "swiftmcp-out") throws {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "\(prefix)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }
}
