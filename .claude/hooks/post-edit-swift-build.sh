#!/usr/bin/env bash
# Post-edit auto-build for Swift sources. Triggered by Claude Code's PostToolUse
# hook on Edit / Write. If the touched file is not *.swift the hook exits 0
# without running anything. Output is the last 20 lines of `swift build` so
# compilation breakage surfaces immediately in the next assistant turn.

set -uo pipefail

file="$(python3 - <<'PY'
import json
import sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
print(data.get("tool_input", {}).get("file_path", ""))
PY
)"

case "$file" in
    *.swift)
        cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
        # Non-fatal: hook never blocks subsequent tool calls.
        swift build 2>&1 | tail -20 || true
        ;;
    *)
        exit 0
        ;;
esac
