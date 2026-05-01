import Foundation
import SwiftcMCPCore

@main
struct Mcpswx {
    static func main() async throws {
        let toolchain = ToolchainResolver()
        let registry = ToolRegistry()
        await registry.register(PrintTargetInfoTool(toolchain: toolchain))
        await registry.register(FindSlowTypecheckTool(toolchain: toolchain))
        await registry.register(EmitASTTool(toolchain: toolchain))
        await registry.register(EmitSILTool(toolchain: toolchain))
        await registry.register(EmitIRTool(toolchain: toolchain))
        await registry.register(BuildIsolatedSnippetTool(toolchain: toolchain))
        await registry.register(CompileStatsTool(toolchain: toolchain))
        await registry.register(CallGraphTool(toolchain: toolchain))
        await registry.register(ConcurrencyAuditTool(toolchain: toolchain))
        await registry.register(ApiSurfaceTool(toolchain: toolchain))
        await registry.register(ReportMissingSymbolsTool(toolchain: toolchain))
        await registry.register(SuggestStubsTool(toolchain: toolchain))

        let server = Server(
            info: .init(
                name: "mcpswx",
                title: "swiftmcp",
                version: SwiftcMCPCore.version,
                instructions: "Swift compiler analysis MCP server."
            ),
            registry: registry
        )

        let loop = StdioLoop(server: server)
        await loop.run()
    }
}
