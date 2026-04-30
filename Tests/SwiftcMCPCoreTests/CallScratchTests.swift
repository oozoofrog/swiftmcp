import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("CallScratch")
struct CallScratchTests {
    @Test
    func directoryExistsAfterInit() throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        #expect(FileManager.default.fileExists(atPath: scratch.directory.path))
        #expect(scratch.directory.lastPathComponent.hasPrefix("swiftmcp-"))
    }

    @Test
    func writeCreatesFileWithContents() throws {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let url = try scratch.write(name: "main.swift", contents: "print(1)")
        let read = try String(contentsOf: url, encoding: .utf8)
        #expect(read == "print(1)")
    }

    @Test
    func disposeRemovesDirectory() throws {
        let scratch = try CallScratch()
        let dir = scratch.directory
        scratch.dispose()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test
    func disposeIsIdempotent() throws {
        let scratch = try CallScratch()
        scratch.dispose()
        scratch.dispose() // must not throw
    }

    @Test
    func deinitRemovesDirectoryWhenNotDisposed() throws {
        var capturedDir: URL?
        autoreleasepool {
            do {
                let scratch = try CallScratch()
                capturedDir = scratch.directory
            } catch {
                Issue.record("scratch init failed: \(error)")
            }
        }
        let dir = try #require(capturedDir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
