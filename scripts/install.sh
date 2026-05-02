#!/usr/bin/env bash
# swiftmcp installer: build the `mcpswx` binary, copy it to a destination
# directory, then register it with each MCP client we know about. Two modes,
# detected automatically:
#
#   - Local mode: invoked from inside an existing swiftmcp checkout
#     (`Package.swift` in cwd or a parent declares the `mcpswx` target).
#     Builds the current source tree as-is — no clone, no network.
#   - Remote mode: invoked via `curl … | sh` outside a checkout, OR with
#     SWIFTMCP_REF/SWIFTMCP_REPO explicitly set. Shallow-clones into a temp
#     directory and builds from there.
#
# Either way the install destination defaults to ~/.local/bin so the
# script never needs sudo. Override by passing INSTALL_DIR=/usr/local/bin.
#
# Usage (remote, defaults):
#   curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | sh
#
# Local (from the repo):
#   ./scripts/install.sh
#
# Override the install destination:
#   curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | INSTALL_DIR=/usr/local/bin sh
#
# Pin to a specific commit / tag / branch (forces remote mode):
#   curl -fsSL https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/scripts/install.sh | SWIFTMCP_REF=v0.1.0 sh

set -euo pipefail

REPO_URL="${SWIFTMCP_REPO:-https://github.com/oozoofrog/swiftmcp.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="mcpswx"

log() {
    printf '\033[1;34m[swiftmcp]\033[0m %s\n' "$*"
}

err() {
    printf '\033[1;31m[swiftmcp:error]\033[0m %s\n' "$*" >&2
    exit 1
}

# Walk up from cwd looking for a swiftmcp `Package.swift`. We treat any
# Package.swift that mentions the `mcpswx` executable target as a swiftmcp
# checkout — the marker is unique enough that a sibling Swift project
# wouldn't false-positive. Falls back to remote-mode clone if we never
# find one.
locate_local_checkout() {
    local dir
    dir="$(pwd -P)"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/Package.swift" ] && grep -q '"mcpswx"' "$dir/Package.swift" 2>/dev/null; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Preflight: macOS host + Swift toolchain reachable.
case "$(uname -s)" in
    Darwin) ;;
    *) err "swiftmcp currently targets macOS; uname reports $(uname -s)." ;;
esac

if ! command -v swift >/dev/null 2>&1; then
    err "swift not found on PATH. Install Xcode (https://developer.apple.com/xcode/) or a standalone toolchain (https://swift.org/install/), then re-run."
fi

SWIFT_VERSION="$(swift --version | head -1)"
log "swift: $SWIFT_VERSION"

# Mode selection. If the user explicitly set SWIFTMCP_REF or
# SWIFTMCP_REPO, they want a specific remote source — skip the local
# detection. Otherwise prefer an in-place checkout if one is reachable
# from cwd, since that's what `./scripts/install.sh` is supposed to
# install and it picks up any uncommitted edits the developer has staged.
USE_LOCAL_CHECKOUT=""
if [ -z "${SWIFTMCP_REF:-}" ] && [ -z "${SWIFTMCP_REPO:-}" ]; then
    USE_LOCAL_CHECKOUT="$(locate_local_checkout 2>/dev/null || true)"
fi

if [ -n "$USE_LOCAL_CHECKOUT" ]; then
    BUILD_ROOT="$USE_LOCAL_CHECKOUT"
    log "local checkout detected at $BUILD_ROOT — building in place (no clone)"
else
    if ! command -v git >/dev/null 2>&1; then
        err "git not found on PATH; required for remote-mode install."
    fi
    REF="${SWIFTMCP_REF:-main}"
    WORK_DIR="$(mktemp -d -t swiftmcp-install)"
    trap 'rm -rf "$WORK_DIR"' EXIT
    log "cloning $REPO_URL@$REF into $WORK_DIR"
    git clone --depth 1 --branch "$REF" "$REPO_URL" "$WORK_DIR/swiftmcp" >/dev/null 2>&1 || \
        err "git clone failed. If you pinned a non-default ref via SWIFTMCP_REF, confirm it exists on origin."
    BUILD_ROOT="$WORK_DIR/swiftmcp"
fi

cd "$BUILD_ROOT"

log "swift build -c release (this builds the mcpswx executable; a few minutes on a cold build)"
swift build -c release

BIN_PATH="$BUILD_ROOT/.build/release/$BIN_NAME"
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

# Codex CLI ships its own `codex mcp add` subcommand that owns the
# `[mcp_servers.<name>]` sections in ~/.codex/config.toml — preferred
# over editing the TOML by hand because Codex parses + rewrites the
# file safely. Idempotency: `codex mcp list` returns the registered
# servers; if 'swiftmcp' is already there we leave it alone.
if command -v codex >/dev/null 2>&1; then
    if codex mcp list 2>/dev/null | grep -q '^swiftmcp\b'; then
        log "Codex CLI already has a 'swiftmcp' entry; skipping registration. Re-register with: codex mcp remove swiftmcp && codex mcp add swiftmcp -- $INSTALL_PATH"
    else
        log "registering with Codex CLI"
        if ! codex mcp add swiftmcp -- "$INSTALL_PATH"; then
            log "codex mcp add failed; register manually: codex mcp add swiftmcp -- $INSTALL_PATH"
        fi
    fi
else
    log "codex CLI not found; register manually with: codex mcp add swiftmcp -- $INSTALL_PATH"
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
