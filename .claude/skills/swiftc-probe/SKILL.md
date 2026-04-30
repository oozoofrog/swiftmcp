---
name: swiftc-probe
description: Capture verbatim swiftc output for a given option set against the locally installed toolchain. Use BEFORE introducing a new tool whose parser/regex/sanity-check depends on swiftc's exact output shape — prevents format guesses that may drift from the real toolchain. Examples — probe `-warn-long-expression-type-checking` warning format, capture `-emit-sil` heading, verify `frontend -interpret` runtime behavior on host SDK.
disable-model-invocation: true
---

# swiftc-probe

Capture the exact swiftc output for an option set so the parser/regex/sanity-check we build is verified against the actually installed toolchain. We do this manually before every new tool — this skill formalizes the procedure.

## When to use

- Introducing a new tool that depends on swiftc stdout/stderr text format.
- A toolchain upgrade is suspected to have changed output shape — re-probe.
- A test fails because parsing assumed a format that doesn't match.
- Hidden / experimental options whose behavior may differ across versions.

## Inputs

- The option set under test (one or more swiftc flags).
- A minimal Swift sample exercising the relevant feature. Keep it small — one to ten lines.

## Procedure

1. `mkdir -p /tmp/swiftmcp-probe`.
2. Write the sample to `/tmp/swiftmcp-probe/<name>.swift`.
3. Capture toolchain version: `swiftc --version | head -1`.
4. Run swiftc with the option set. Use `2>&1` to interleave stderr if you need to study warning/error placement, or split with `1>stdout.txt 2>stderr.txt` if their separation matters.
5. Show the first ~20 lines of the captured output and note the total line count.
6. If the output suggests a single regex pattern, write the regex AND a literal sample line in the same record so future drift is detectable.
7. Record findings in:
   - `.claude/PLAN.md` — when it pins a regex or output contract for an upcoming tool.
   - `.claude/references/swiftc.md` or `swift-static-analysis.md` — when it's a general option discovery worth keeping.

## Hard rules

- The probe target is the actually installed toolchain, not docs. swift.org documentation may lag; the toolchain output is authoritative.
- Never paraphrase swiftc output. Preserve verbatim characters (quoting style, punctuation, spacing) so regexes match.
- Hidden options behave differently across versions; if probing a `-help-hidden` option, mark `unstable` in the record.
- Never edit the project's source code from this skill — write only to `/tmp/swiftmcp-probe/` for the sample, and the relevant reference / PLAN file for the record.

## Examples

### Example 1: warn-long-expression-type-checking format

Sample: `/tmp/swiftmcp-probe/slow.swift`

```swift
func compute() -> Int {
    let result = 1 + 2 + 3
    return result
}
```

Command:

```sh
swiftc -typecheck \
  -Xfrontend -warn-long-expression-type-checking=1 \
  -Xfrontend -warn-long-function-bodies=1 \
  /tmp/swiftmcp-probe/slow.swift 2>&1 | head -20
```

Captured stderr line forms:

- `…/slow.swift:2:18: warning: expression took 2ms to type-check (limit: 1ms)`
- `…/slow.swift:1:6: warning: global function 'compute()' took 8ms to type-check (limit: 1ms)`

Generalized regex (records this in PLAN §3.1):

```
^(.+?):(\d+):(\d+): warning: (.+?) took (\d+)ms to type-check \(limit: (\d+)ms\)$
```

### Example 2: emit-sil heading sanity

Command:

```sh
swiftc -emit-sil /tmp/swiftmcp-probe/tiny.swift 2>/dev/null | head -3
```

Captured: `sil_stage canonical` — used as the integration-test sanity check for `EmitSILTool`.

### Example 3: frontend -interpret host capability

Command:

```sh
swiftc -frontend -interpret /tmp/swiftmcp-probe/hi.swift
```

Captured (macOS 26 host):

```
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx26.0'
```

Recorded in PLAN §3.1 as the reason `build_isolated_snippet` uses the heavy path (compile + run) only.
