---
name: swift-stage-commit
description: Format and create a Stage X.Y commit for swiftmcp using the established message format (HEREDOC subject + bullet body + test-count line) and push to origin/main. Wraps git add + commit + push in one user-driven step. User-only invocation — commits land on a public GitHub repository.
disable-model-invocation: true
---

# swift-stage-commit

Format and create a sub-stage commit for swiftmcp using the message style established in commits b44fca9 (Stage 1.A) / 369f132 (Stage 1.B) / 1dfe4d6 (Stage 1.C) / 276fdf8 (Stage 1.D).

## When to use

- A sub-stage just completed (build clean, all tests pass — ideally validated by the `swiftmcp-stage-validator` subagent first).
- The user says something like "commit it", "stage 1.X 커밋해줘", "push it".

## Inputs (ask the user if not provided)

- The sub-stage label, e.g. `Stage 1.E`, `Stage 2.A`.
- A 5–10 word subject summarizing the change (used after the colon).
- 3–6 bullet points describing the change. One per file or logical unit.

## Procedure

1. Run `git status --short`. Confirm there are unstaged or untracked changes worth committing.
2. Run `swift test 2>&1 | grep "Test run with"` — extract the current `<N> tests in <M> suites passed` count. This goes on the last bullet.
3. Run `git diff --stat HEAD` — confirm the change footprint matches the bullets.
4. Compose the commit message in the format below (HEREDOC).
5. `git add -A`.
6. `git commit -m "$(cat <<'EOF' …  EOF)"`.
7. `git push`.
8. Report the new commit short SHA.

## Commit message format

```
<Stage label>: <5–10 word subject>

<bullet 1 — one logical unit, can wrap to two lines>
<bullet 2>
…
<bullet N>
N total / M suites passing.
```

The blank line between subject and body is required.

## Reference subjects (style examples)

- `Stage 1.A: diagnostics, scratch directory, result metadata`
- `Stage 1.B: find_slow_typecheck tool`
- `Stage 1.C: emit_ast, emit_sil, emit_ir tools + invocation builder`
- `Stage 1.D: build_isolated_snippet tool`

## Hard rules

- This skill is **user-only** (`disable-model-invocation: true`). Never invoke it from the assistant side without explicit user instruction — the result is a `git push` to a public repository, which is a visible / shared-state action.
- Always use HEREDOC for the message. Single-line `-m "…"` corrupts multi-line bodies.
- Never use `--no-verify`, `--amend`, `--force`, or `push --force` unless the user explicitly asks.
- The remote is `origin` on `github.com:oozoofrog/swiftmcp` (public). Do not include local-only paths or secrets in the message.
- If `swift test` reports any failure, abort and ask the user — never commit a red bar.
- If `git push` fails (rejected, network), report the failure verbatim and stop. Do not retry with destructive flags.

## Optional notes section

If the change carries a non-obvious environmental fact worth recording for future sessions (e.g. "swift test --parallel deadlocks on macOS 26"), include it after the bulleted body as a `Note:` paragraph. Reference Stage 1.D's commit message as the precedent.
