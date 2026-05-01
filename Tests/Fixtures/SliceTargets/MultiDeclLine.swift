// Two top-level typealiases on the same physical line. swiftc emits them as
// separate AST entries with identical startLine — the slice closure must merge
// their source ranges so the rendered slice doesn't duplicate the line.
public typealias Foo = Int; public typealias Bar = String

public func use() -> Int {
    let a: Foo = 1
    let b: Bar = "x"
    _ = b
    return a
}
