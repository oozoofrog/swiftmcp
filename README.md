# swiftmcp

A Model Context Protocol (MCP) server exposing Swift compiler capabilities to LLM clients.

## Install

```sh
git clone git@github.com:oozoofrog/swiftmcp.git
cd swiftmcp
swift build -c release
cp .build/release/mcpswx /usr/local/bin/
```

The release binary lands at `.build/release/mcpswx`. Copying to `/usr/local/bin/` (or anywhere on `$PATH`) is optional — every snippet below also works with the absolute build path.

## MCP client setup

### Claude Code

```sh
claude mcp add swiftmcp /usr/local/bin/mcpswx
```

### Claude Desktop

Add the server entry to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "swiftmcp": {
      "command": "/usr/local/bin/mcpswx"
    }
  }
}
```

Restart the client after editing the config so it picks up the new server.

## Status

Early development. See [`.claude/PLAN.md`](./.claude/PLAN.md) for the staged implementation roadmap.

## Capabilities (planned)

- **Static analysis** — type-check timing, dependency graphs, call graphs, API surface, breaking-change detection, concurrency/memory/availability audits
- **Compiler artifacts** — AST / SIL / IR / module interface / symbol graph emission
- **Isolated execution** — build and run code slices with external dependencies stripped, designed to be driven by an LLM client that fills in stubs interactively

## Architecture

- Externally invokes the locally installed Swift toolchain (`swiftc`, `swift-frontend`); not a compiler re-implementation, and not bound to any specific Swift source tree.
- Implements the [MCP 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25) stdio JSON-RPC server directly on Foundation. No external runtime dependencies.
- Layered: `SwiftcMCPCore` library + `mcpswx` executable (MCP server entry point).

## Requirements

- Swift 6.0+ / macOS 13+
- An Apple Swift toolchain installed (Xcode or a standalone toolchain)

## License

Copyright 2026 oozoofrog.
Licensed under [Apache-2.0](./LICENSE).

## Documentation

- [`CLAUDE.md`](./CLAUDE.md) — entry point for project decisions and policies
- [`.claude/PLAN.md`](./.claude/PLAN.md) — staged implementation plan
- [`.claude/references/`](./.claude/references) — Swift compiler options, static-analysis catalog, MCP SDK reference
