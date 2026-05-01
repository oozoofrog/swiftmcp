// Intentionally broken Swift source: type mismatch between declared return
// type (String) and the actual returned value (Int + Int). Used as a fixture
// for verifying that XcodebuildResolver still resolves args when the target's
// own Swift code fails to compile (so analysis tools can surface the
// diagnostics rather than the resolver swallowing them).
public func brokenAdd(_ a: Int, _ b: Int) -> String {
    return a + b
}
