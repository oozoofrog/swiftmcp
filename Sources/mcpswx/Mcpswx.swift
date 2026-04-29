import Foundation
import SwiftcMCPCore

@main
struct Mcpswx {
    static func main() async throws {
        // MCP server bootstrap (stdio JSON-RPC) is added in subsequent Stage 0 commits.
        // Until then, the executable links cleanly and exits without touching stdout
        // (which is reserved for the protocol channel).
        FileHandle.standardError.write(Data("mcpswx \(SwiftcMCPCore.version)\n".utf8))
    }
}
