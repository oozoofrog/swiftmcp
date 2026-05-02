#!/usr/bin/env bash
# swiftmcp installer: clone, build, copy the `mcpswx` binary to a destination
# directory, then print MCP client wire-up snippets. Designed to be safe to
# pipe from `curl … | sh` — no sudo unless the user explicitly opted into a
# system path via INSTALL_DIR=/usr/local/bin.
#
# Usage (defaults: install to ~/.local/bin, ref = main):
#   curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | sh
#
# Override the install destination:
#   curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | INSTALL_DIR=/usr/local/bin sh
#
# Pin to a specific commit / tag / branch:
#   curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | SWIFTMCP_REF=v0.1.0 sh

set -euo pipefail

REPO_URL="${SWIFTMCP_REPO:-https://github.com/oozoofrog/swiftmcp.git}"
REF="${SWIFTMCP_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="mcpswx"

log() {
    printf '\033[1;34m[swiftmcp]\033[0m %s\n' "$*"
}

err() {
    printf '\033[1;31m[swiftmcp:error]\033[0m %s\n' "$*" >&2
    exit 1
}

# Preflight: macOS host + Swift toolchain reachable.
case "$(uname -s)" in
    Darwin) ;;
    *) err "swiftmcp currently targets macOS; uname reports $(uname -s)." ;;
esac

if ! command -v swift >/dev/null 2>&1; then
    err "swift not found on PATH. Install Xcode (https://developer.apple.com/xcode/) or a standalone toolchain (https://swift.org/install/), then re-run."
fi

if ! command -v git >/dev/null 2>&1; then
    err "git not found on PATH."
fi

SWIFT_VERSION="$(swift --version | head -1)"
log "swift: $SWIFT_VERSION"

# Build out of a temp clone so the script is safe to pipe from curl on any
# host, regardless of cwd. The clone is shallow + branch-pinned so the
# bandwidth + disk footprint stays small.
WORK_DIR="$(mktemp -d -t swiftmcp-install)"
trap 'rm -rf "$WORK_DIR"' EXIT

log "cloning $REPO_URL@$REF into $WORK_DIR"
git clone --depth 1 --branch "$REF" "$REPO_URL" "$WORK_DIR/swiftmcp" >/dev/null 2>&1 || \
    err "git clone failed. If you pinned a non-default ref via SWIFTMCP_REF, confirm it exists on origin."

cd "$WORK_DIR/swiftmcp"

log "swift build -c release (this builds the mcpswx executable; a few minutes on a first run)"
swift build -c release

BIN_PATH=".build/release/$BIN_NAME"
if [ ! -x "$BIN_PATH" ]; then
    err "build finished but $BIN_PATH is not executable; check the build log above for diagnostics."
fi

# Install destination. We default to ~/.local/bin to avoid sudo; users who
# want /usr/local/bin can override INSTALL_DIR explicitly.
mkdir -p "$INSTALL_DIR"
INSTALL_PATH="$INSTALL_DIR/$BIN_NAME"
cp "$BIN_PATH" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
log "installed: $INSTALL_PATH"

# PATH sanity check — many users have ~/.local/bin missing from PATH on a
# fresh shell. We don't try to edit shell rc files (too many variants); we
# just print the explicit warning so the user can fix it themselves.
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        log "note: $INSTALL_DIR is not on your \$PATH. Add it (e.g. echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc) or invoke mcpswx with its absolute path: $INSTALL_PATH"
        ;;
esac

# Optional convenience: register with Claude Code automatically if the CLI
# is available. We use `-s user` so the entry persists across every project
# the user opens — `claude mcp add` without -s defaults to local (project)
# scope, which would only register the server inside whatever cwd the
# install script happened to run in (typically a temp dir). Skipped
# silently otherwise so the script stays idempotent on hosts that don't
# run Claude.
if command -v claude >/dev/null 2>&1; then
    if claude mcp list -s user 2>/dev/null | grep -q '^swiftmcp\b'; then
        log "Claude Code already has a user-scoped 'swiftmcp' entry; skipping registration. Re-register with: claude mcp remove -s user swiftmcp && claude mcp add -s user swiftmcp $INSTALL_PATH"
    else
        log "registering with Claude Code (user scope)"
        if ! claude mcp add -s user swiftmcp "$INSTALL_PATH"; then
            log "claude mcp add failed; register manually: claude mcp add -s user swiftmcp $INSTALL_PATH"
        fi
    fi
else
    log "claude CLI not found; register manually with: claude mcp add -s user swiftmcp $INSTALL_PATH"
fi

# Codex CLI uses ~/.codex/config.toml with [mcp_servers.<name>] sections.
# The file may not exist yet (fresh Codex install); creating it is safe —
# Codex tolerates an otherwise-empty config.toml. We append idempotently:
# if a `[mcp_servers.swiftmcp]` header already lives in the file, skip;
# otherwise append a fresh section pointing at $INSTALL_PATH. We don't
# attempt to update an existing section's command field because a TOML
# rewrite without a TOML parser is fragile; users who relocate the binary
# can run the install again with the new INSTALL_DIR + delete the old
# section, or edit the file directly.
CODEX_CONFIG_DIR="$HOME/.codex"
CODEX_CONFIG_PATH="$CODEX_CONFIG_DIR/config.toml"
mkdir -p "$CODEX_CONFIG_DIR"
if [ -f "$CODEX_CONFIG_PATH" ] && grep -q '^\[mcp_servers\.swiftmcp\]' "$CODEX_CONFIG_PATH"; then
    log "Codex CLI config already has '[mcp_servers.swiftmcp]'; leaving it alone. Edit $CODEX_CONFIG_PATH if you need to point at a different binary."
else
    log "registering with Codex CLI ($CODEX_CONFIG_PATH)"
    cat >>"$CODEX_CONFIG_PATH" <<EOF

[mcp_servers.swiftmcp]
command = "$INSTALL_PATH"
EOF
fi

cat <<EOF

Done. Claude Desktop is the one MCP client without an automated step here —
add this to ~/Library/Application Support/Claude/claude_desktop_config.json:
  {
    "mcpServers": {
      "swiftmcp": {
        "command": "$INSTALL_PATH"
      }
    }
  }
Then restart Claude Desktop.

EOF
