public struct Counter {
    public private(set) var value: Int = 0
    public init(start: Int = 0) { value = start }
    public mutating func increment() { value += 1 }
}

public func answer() -> Int { 42 }
