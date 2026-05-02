public struct Counter {
    public var value: Int = 0
    public init(value: Int = 0) { self.value = value }
    public func incremented() -> Counter { Counter(value: value + 1) }
    public func doubled() -> Counter { Counter(value: value * 2) }
}

// helloAdd was removed
public func newApi(_ x: Int) -> Int { x }
