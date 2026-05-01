import Foundation

public struct Counter {
    public var value: Int
    public init(value: Int) { self.value = value }
    public func incremented() -> Counter { Counter(value: value + 1) }
}

public func formatLabel(_ s: String) -> String {
    return "<\(s)>"
}

public func describe(_ counter: Counter) -> String {
    let next = counter.incremented()
    return formatLabel("\(next.value)")
}

public func unrelated() -> Int {
    return 42
}

public func helper() -> Int { 0 }
public func helper(_ x: Int) -> Int { x }

public func useHelper() -> Int {
    return helper() + helper(7)
}
