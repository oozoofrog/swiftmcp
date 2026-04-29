import Foundation

/// `print_target_info`: invokes `swiftc -print-target-info -target <triple>` and returns
/// the JSON document swiftc emits (SDK paths, runtime versions, link flags, etc).
public struct PrintTargetInfoTool: MCPTool {
    private let toolchain: ToolchainResolver

    public init(toolchain: ToolchainResolver) {
        self.toolchain = toolchain
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "print_target_info",
            title: "Print Target Info",
            description: """
            Run `swiftc -print-target-info -target <triple>` against the resolved Swift toolchain \
            and return the JSON document it emits. Useful for inspecting SDK paths, runtime \
            versions, and library link flags for a target triple.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Target triple, e.g. 'arm64-apple-macos14', 'x86_64-apple-ios18.0-simulator'."
                        )
                    ])
                ]),
                "required": .array([.string("target")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments,
              case .string(let target) = dict["target"], !target.isEmpty
        else {
            throw MCPError.invalidParams("`target` argument is required and must be a non-empty string")
        }

        let resolved = try await toolchain.resolve()
        let result = try await runProcess(
            executable: resolved.swiftcPath,
            arguments: ["-print-target-info", "-target", target]
        )

        if result.exitCode != 0 {
            let message = result.standardError.isEmpty
                ? "swiftc exited with code \(result.exitCode)"
                : result.standardError
            return CallToolResult(content: [.text(message)], isError: true)
        }

        return CallToolResult(content: [.text(result.standardOutput)], isError: false)
    }
}
