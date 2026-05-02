import Foundation
import SwiftcMCPCore

@main
struct Mcpswx {
    static func main() async throws {
        let toolchain = ToolchainResolver()
        let cachedResolver = CachedBuildArgsResolver(wrapping: DefaultBuildArgsResolver())
        let registry = ToolRegistry()
        await registry.register(PrintTargetInfoTool(toolchain: toolchain))
        await registry.register(FindSlowTypecheckTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(EmitASTTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(EmitSILTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(EmitIRTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(BuildIsolatedSnippetTool(toolchain: toolchain))
        await registry.register(CompileStatsTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(CallGraphTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(ConcurrencyAuditTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(ApiSurfaceTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(ReportMissingSymbolsTool(toolchain: toolchain))
        await registry.register(SuggestStubsTool(toolchain: toolchain))
        await registry.register(SliceFunctionTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(ApiDiffTool(toolchain: toolchain, resolver: cachedResolver))
        await registry.register(XcbuildPerfTool(toolchain: toolchain, resolver: cachedResolver))

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
