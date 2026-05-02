public struct Counter {
    public var value: Int = 0
    public init(value: Int = 0) { self.value = value }
    public func incremented() -> Counter { Counter(value: value + 1) }
}

public func helloAdd(_ a: Int, _ b: Int) -> Int { a + b }
