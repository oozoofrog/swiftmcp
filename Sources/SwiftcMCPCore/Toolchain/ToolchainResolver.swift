import Foundation

/// Resolves the path to `swiftc` and reads its version. Result is cached per instance.
///
/// Resolution order:
/// 1. `TOOLCHAINS` environment variable → `xcrun --toolchain $TOOLCHAINS -f swiftc`.
/// 2. `xcrun -f swiftc`.
/// 3. `which swiftc` (PATH lookup).
public actor ToolchainResolver {
    public struct Resolved: Sendable, Equatable {
        public let swiftcPath: String
        public let version: String
    }

    private var cached: Resolved?
    private var cachedSDKPath: String??

    public init() {}

    public func resolve() async throws -> Resolved {
        if let cached {
            return cached
        }
        let path = try await locateSwiftc()
        let version = try await readVersion(swiftcPath: path)
        let resolved = Resolved(swiftcPath: path, version: version)
        cached = resolved
        return resolved
    }

    /// Resolves the macOS SDK path via `xcrun --sdk macosx --show-sdk-path`. Result is
    /// cached — including the legitimate "no SDK available" outcome as `nil` — so the
    /// xcrun probe runs at most once per resolver. Used by `SwiftcInvocation` to seed
    /// `SDKROOT` in the child's environment when the host shell hasn't set it — the
    /// scenario when `mcpswx` runs as a CLI outside `swift test` / Xcode.
    ///
    /// Cancellation does *not* poison the cache: `firstNonEmptyPath` swallows
    /// `CancellationError` from `runProcess` into `nil`, so a cancelled-mid-probe
    /// resolution would otherwise be cached as a permanent fallback. We re-check
    /// `Task.isCancelled` after the call and skip caching in that case so a subsequent
    /// uncancelled call retries the probe.
    public func sdkPath() async -> String? {
        if let cachedSDKPath {
            return cachedSDKPath
        }
        let resolved = try? await firstNonEmptyPath(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "macosx", "--show-sdk-path"]
        )
        if Task.isCancelled { return resolved }
        cachedSDKPath = .some(resolved)
        return resolved
    }

    private func locateSwiftc() async throws -> String {
        if let toolchain = ProcessInfo.processInfo.environment["TOOLCHAINS"], !toolchain.isEmpty {
            if let path = try await firstNonEmptyPath(
                executable: "/usr/bin/xcrun",
                arguments: ["--toolchain", toolchain, "-f", "swiftc"]
            ) {
                return path
            }
        }
        if let path = try await firstNonEmptyPath(
            executable: "/usr/bin/xcrun",
            arguments: ["-f", "swiftc"]
        ) {
            return path
        }
        if let path = try await firstNonEmptyPath(
            executable: "/usr/bin/which",
            arguments: ["swiftc"]
        ) {
            return path
        }
        throw MCPError.internalError("swiftc not found via TOOLCHAINS env, xcrun, or PATH")
    }

    private func firstNonEmptyPath(executable: String, arguments: [String]) async throws -> String? {
        let result: ProcessResult
        do {
            result = try await runProcess(executable: executable, arguments: arguments)
        } catch {
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.standardOutputTrimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readVersion(swiftcPath: String) async throws -> String {
        let result = try await runProcess(executable: swiftcPath, arguments: ["--version"])
        guard result.exitCode == 0 else {
            throw MCPError.internalError("swiftc --version failed: \(result.standardError)")
        }
        let firstLine = result.standardOutputTrimmed.split(separator: "\n").first.map(String.init)
        return firstLine ?? "unknown"
    }
}
