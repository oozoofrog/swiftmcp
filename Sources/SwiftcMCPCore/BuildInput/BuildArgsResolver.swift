import Foundation

/// Resolves a `BuildInput` to a flat `ResolvedBuildArgs` for swiftc. Stage 3.A wires
/// `LocalFilesResolver`; Stage 3.C adds `SwiftPMPackageResolver`; Stage 3.D adds
/// `XcodebuildResolver`. Later sub-stages plug in additional resolvers behind the
/// same protocol.
public protocol BuildArgsResolver: Sendable {
    func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs
}

/// Default dispatcher. Each `BuildInput` case is routed to the resolver that
/// understands that case. Resolvers are stateless; this struct is `Sendable`.
public struct DefaultBuildArgsResolver: BuildArgsResolver {
    private let localFiles: LocalFilesResolver
    private let swiftPM: SwiftPMPackageResolver
    private let xcodebuild: XcodebuildResolver

    public init(
        localFiles: LocalFilesResolver = LocalFilesResolver(),
        swiftPM: SwiftPMPackageResolver = SwiftPMPackageResolver(),
        xcodebuild: XcodebuildResolver = XcodebuildResolver()
    ) {
        self.localFiles = localFiles
        self.swiftPM = swiftPM
        self.xcodebuild = xcodebuild
    }

    public func resolveArgs(for input: BuildInput) async throws -> ResolvedBuildArgs {
        switch input {
        case .file, .directory:
            return try await localFiles.resolveArgs(for: input)
        case .swiftPMPackage:
            return try await swiftPM.resolveArgs(for: input)
        case .xcodeProject, .xcodeWorkspace:
            return try await xcodebuild.resolveArgs(for: input)
        }
    }
}
