public struct SampleValue {
    public let payload: Int
    public init(payload: Int) { self.payload = payload }
    public func doubled() -> Int { payload * 2 }
}

public func sampleAdd(_ a: Int, _ b: Int) -> Int { a + b }
