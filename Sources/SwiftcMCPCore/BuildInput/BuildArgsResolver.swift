import Foundation

/// Resolves a `BuildInput` to a flat `ResolvedBuildArgs` for swiftc. Stage 3.A wires
/// `LocalFilesResolver`; later sub-stages plug in additional resolvers (SwiftPM,
/// xcodebuild) behind the same protocol.
public protocol BuildArgsResolver: Sendable {
    func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs
}

/// Default dispatcher. Each `BuildInput` case is routed to the resolver that
/// understands that case. Resolvers are stateless; this struct is `Sendable`.
public struct DefaultBuildArgsResolver: BuildArgsResolver {
    private let localFiles: LocalFilesResolver

    public init(localFiles: LocalFilesResolver = LocalFilesResolver()) {
        self.localFiles = localFiles
    }

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        switch input {
        case .file, .directory:
            return try await localFiles.resolveArgs(for: input)
        }
    }
}
