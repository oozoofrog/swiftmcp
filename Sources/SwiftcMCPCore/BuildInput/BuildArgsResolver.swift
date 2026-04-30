import Foundation

/// Resolves a `BuildInput` to a flat `ResolvedBuildArgs` for swiftc. Stage 3.A wires
/// `LocalFilesResolver`; Stage 3.C adds `SwiftPMPackageResolver`. Later sub-stages
/// plug in additional resolvers (xcodebuild) behind the same protocol.
public protocol BuildArgsResolver: Sendable {
    func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs
}

/// Default dispatcher. Each `BuildInput` case is routed to the resolver that
/// understands that case. Resolvers are stateless; this struct is `Sendable`.
public struct DefaultBuildArgsResolver: BuildArgsResolver {
    private let localFiles: LocalFilesResolver
    private let swiftPM: SwiftPMPackageResolver

    public init(
        localFiles: LocalFilesResolver = LocalFilesResolver(),
        swiftPM: SwiftPMPackageResolver = SwiftPMPackageResolver()
    ) {
        self.localFiles = localFiles
        self.swiftPM = swiftPM
    }

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        switch input {
        case .file, .directory:
            return try await localFiles.resolveArgs(for: input)
        case .swiftPMPackage:
            return try await swiftPM.resolveArgs(for: input)
        }
    }
}
