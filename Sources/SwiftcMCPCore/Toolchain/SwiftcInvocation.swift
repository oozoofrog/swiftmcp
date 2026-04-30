import Foundation

/// Common builder/runner for swiftc invocations: resolves the toolchain, assembles
/// argument lists in a consistent order, runs the process, and returns the result
/// alongside resolved toolchain metadata.
///
/// Argument order: `<mode-args> [-target <triple>] [<-Onone|-O|-Osize|-Ounchecked>] [-o <output>] <input>`
public struct SwiftcInvocation: Sendable {
    public struct Options: Sendable, Equatable {
        public let target: String?
        public let optimization: Optimization?

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

        public init(target: String? = nil, optimization: Optimization? = nil) {
            self.target = target
            self.optimization = optimization
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
        inputFile: String,
        outputFile: URL?,
        options: Options
    ) async throws -> Outcome {
        let resolved = try await resolver.resolve()
        var args = modeArgs
        if let target = options.target {
            args.append(contentsOf: ["-target", target])
        }
        if let optimization = options.optimization {
            args.append(optimization.flag)
        }
        if let outputFile {
            args.append(contentsOf: ["-o", outputFile.path])
        }
        args.append(inputFile)
        let processResult = try await runProcess(
            executable: resolved.swiftcPath,
            arguments: args
        )
        return Outcome(process: processResult, toolchain: resolved)
    }
}
