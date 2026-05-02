public struct ModuleAValue {
    public let payload: Int
    public init(payload: Int) { self.payload = payload }
    public func doubled() -> Int { payload * 2 }
}

public func helloA() -> String { "hello from A" }
