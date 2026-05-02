# swiftmcp

A Model Context Protocol (MCP) server exposing Swift compiler capabilities to LLM clients.

## Install

The installer covers build + copy + MCP-client registration in one shot. It auto-detects two scenarios:

- **Remote** — piped from `curl`, no checkout in cwd. Shallow-clones into a temp dir and builds there.
- **Local** — invoked from inside an existing checkout (`Package.swift` with the `mcpswx` target reachable by walking up from cwd). Builds the source tree as-is, no clone, picks up any uncommitted edits.

### One-line install (remote)

```sh
curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | sh
```

Builds, copies `mcpswx` into `~/.local/bin/`, and (if the `claude` / `codex` CLIs are on `PATH`) auto-registers the server. Override the destination or pin a specific ref:

```sh
curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | INSTALL_DIR=/usr/local/bin sh
curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | SWIFTMCP_REF=v0.1.0 sh
```

Requires `swift`, `git` (remote mode only), and macOS. The script never invokes `sudo`; choose an `INSTALL_DIR` you can write to.

### From a local checkout

```sh
git clone git@github.com:oozoofrog/swiftmcp.git
cd swiftmcp
./scripts/install.sh
```

Same destinations and registration behavior as the remote one-liner. `INSTALL_DIR` overrides apply identically. Setting `SWIFTMCP_REF` or `SWIFTMCP_REPO` forces remote mode even from inside a checkout, which is useful for pinning a release tag without leaving your working directory.

### Manual build

```sh
git clone git@github.com:oozoofrog/swiftmcp.git
cd swiftmcp
swift build -c release
cp .build/release/mcpswx /usr/local/bin/
```

The release binary lands at `.build/release/mcpswx`. Copying to `/usr/local/bin/` (or anywhere on `$PATH`) is optional — every snippet below also works with the absolute build path.

## MCP client setup

The one-line installer auto-registers swiftmcp with Claude Code (user scope) and Codex CLI when those tools are present. The snippets below cover every supported client for manual installs.

### Claude Code

```sh
claude mcp add -s user swiftmcp /usr/local/bin/mcpswx
```

`-s user` makes the server visible across every project the user opens; without the flag, registration is project-local and only takes effect inside whatever cwd the command ran in.

### Codex CLI

```sh
codex mcp add swiftmcp -- /usr/local/bin/mcpswx
```

`codex mcp` owns the `[mcp_servers.<name>]` entries in `~/.codex/config.toml`; use `codex mcp list` to inspect and `codex mcp remove swiftmcp` to undo.

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
