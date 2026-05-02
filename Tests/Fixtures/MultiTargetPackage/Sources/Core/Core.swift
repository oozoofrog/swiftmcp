public struct CoreValue {
    public let payload: Int
    public init(payload: Int) { self.payload = payload }
    public func doubled() -> Int { payload * 2 }
}
