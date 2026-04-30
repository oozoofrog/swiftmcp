import Foundation

/// Common builder/runner for swiftc invocations: resolves the toolchain, assembles
/// argument lists in a consistent order, runs the process, and returns the result
/// alongside resolved toolchain metadata.
///
/// Argument order:
/// `<mode-args> [-target <triple>] [<-Onone|-O|-Osize|-Ounchecked>]
///  [-module-name <name>] [-I <path>...] [-F <path>...] [<extraSwiftcArgs>]
///  [-o <output>] <input-files...>`
public struct SwiftcInvocation: Sendable {
    public struct Options: Sendable, Equatable {
        public let target: String?
        public let optimization: Optimization?
        public let moduleName: String?
        public let searchPaths: [String]
        public let frameworkSearchPaths: [String]
        public let extraSwiftcArgs: [String]

        public enum Optimization: String, Sendable, CaseIterable {
            case none
            case speed
            case size
            case unchecked

            public var flag: String {
                switch self {
                case .none: return "-Onone"
                case .speed: return "-O"
                case .size: return "-Osize"
                case .unchecked: return "-Ounchecked"
                }
            }

            public init?(string: String?) {
                guard let string else { return nil }
                guard let value = Self(rawValue: string) else { return nil }
                self = value
            }
        }

        public init(
            target: String? = nil,
            optimization: Optimization? = nil,
            moduleName: String? = nil,
            searchPaths: [String] = [],
            frameworkSearchPaths: [String] = [],
            extraSwiftcArgs: [String] = []
        ) {
            self.target = target
            self.optimization = optimization
            self.moduleName = moduleName
            self.searchPaths = searchPaths
            self.frameworkSearchPaths = frameworkSearchPaths
            self.extraSwiftcArgs = extraSwiftcArgs
        }
    }

    public struct Outcome: Sendable {
        public let process: ProcessResult
        public let toolchain: ToolchainResolver.Resolved
    }

    private let resolver: ToolchainResolver

    public init(resolver: ToolchainResolver) {
        self.resolver = resolver
    }

    public func run(
        modeArgs: [String],
        inputFiles: [String],
        outputFile: URL?,
        options: Options
    ) async throws -> Outcome {
        let resolved = try await resolver.resolve()
        var args = modeArgs
        // swiftc rejects `-o` with multiple input files unless whole-module mode is on
        // (e.g. `-dump-ast -o foo.txt a.swift b.swift` errors out). Inject `-wmo` once
        // the caller is asking for a single combined output across multiple inputs.
        if outputFile != nil
            && inputFiles.count > 1
            && !modeArgs.contains("-wmo")
            && !modeArgs.contains("-whole-module-optimization")
            && !options.extraSwiftcArgs.contains("-wmo")
            && !options.extraSwiftcArgs.contains("-whole-module-optimization")
        {
            args.append("-wmo")
        }
        if let target = options.target {
            args.append(contentsOf: ["-target", target])
        }
        if let optimization = options.optimization {
            args.append(optimization.flag)
        }
        if let moduleName = options.moduleName {
            args.append(contentsOf: ["-module-name", moduleName])
        }
        for path in options.searchPaths {
            args.append(contentsOf: ["-I", path])
        }
        for path in options.frameworkSearchPaths {
            args.append(contentsOf: ["-F", path])
        }
        args.append(contentsOf: options.extraSwiftcArgs)
        if let outputFile {
            args.append(contentsOf: ["-o", outputFile.path])
        }
        args.append(contentsOf: inputFiles)
        let processResult = try await runProcess(
            executable: resolved.swiftcPath,
            arguments: args
        )
        return Outcome(process: processResult, toolchain: resolved)
    }
}

public extension SwiftcInvocation.Options {
    /// Build options from a resolved `BuildInput`, copying over target/moduleName/searchPaths.
    /// Tools layer their own knobs (optimization, extra mode args) on top via the regular init.
    init(resolved: ResolvedBuildArgs, optimization: Optimization? = nil) {
        self.init(
            target: resolved.target,
            optimization: optimization,
            moduleName: resolved.moduleName,
            searchPaths: resolved.searchPaths,
            frameworkSearchPaths: resolved.frameworkSearchPaths,
            extraSwiftcArgs: resolved.extraSwiftcArgs
        )
    }
}
