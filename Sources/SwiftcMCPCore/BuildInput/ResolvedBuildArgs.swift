import Foundation

/// Flat, swiftc-ready view of a resolved `BuildInput`. All paths are absolute. The
/// `extraSwiftcArgs` slot lets resolvers contribute build-system-specific flags
/// (e.g. `-sdk`, deployment-target overrides) without touching `SwiftcInvocation`.
public struct ResolvedBuildArgs: Sendable, Equatable {
    public let inputFiles: [String]
    public let moduleName: String?
    public let target: String?
    public let searchPaths: [String]
    public let frameworkSearchPaths: [String]
    public let extraSwiftcArgs: [String]

    public init(
        inputFiles: [String],
        moduleName: String? = nil,
        target: String? = nil,
        searchPaths: [String] = [],
        frameworkSearchPaths: [String] = [],
        extraSwiftcArgs: [String] = []
    ) {
        self.inputFiles = inputFiles
        self.moduleName = moduleName
        self.target = target
        self.searchPaths = searchPaths
        self.frameworkSearchPaths = frameworkSearchPaths
        self.extraSwiftcArgs = extraSwiftcArgs
    }
}
