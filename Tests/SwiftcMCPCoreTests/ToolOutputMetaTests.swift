import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ToolOutputMeta")
struct ToolOutputMetaTests {
    @Test
    func roundtripsCodable() throws {
        let meta = ToolOutputMeta(
            toolchain: .init(path: "/usr/bin/swiftc", version: "Apple Swift version 6.3.1"),
            target: "arm64-apple-macos14",
            durationMs: 123
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ToolOutputMeta.self, from: data)
        #expect(decoded == meta)
    }

    @Test
    func encodesCamelCaseKeys() throws {
        let meta = ToolOutputMeta(
            toolchain: .init(path: "/p", version: "v"),
            target: nil,
            durationMs: 7
        )
        let data = try JSONEncoder().encode(meta)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"durationMs\""))
        #expect(!json.contains("\"duration_ms\""))
    }

    @Test
    func omitsTargetWhenNil() throws {
        let meta = ToolOutputMeta(
            toolchain: .init(path: "/p", version: "v"),
            target: nil,
            durationMs: 1
        )
        let data = try JSONEncoder().encode(meta)
        let json = try #require(String(data: data, encoding: .utf8))
        // Default Codable encodes nil as absent; ensure we did not gain a "target" key.
        #expect(!json.contains("\"target\""))
    }
}
