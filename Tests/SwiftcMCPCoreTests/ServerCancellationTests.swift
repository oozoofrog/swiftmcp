import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("Server cancellation")
struct ServerCancellationTests {
    @Test
    func cancellationNotificationCancelsInFlightRequest() async throws {
        let registry = ToolRegistry()
        await registry.register(SlowTool())
        let server = makeServer(registry: registry)

        let request = #"""
        {"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"slow","arguments":{}}}
        """#
        let cancelNotification = #"""
        {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99,"reason":"test"}}
        """#

        // Start the long-running request.
        let requestTask = Task {
            await server.handleInbound(Data(request.utf8))
        }

        // Give the server a moment to register the in-flight task.
        try await Task.sleep(for: .milliseconds(150))

        // Send cancellation as a separate inbound message.
        let notificationResponse = await server.handleInbound(Data(cancelNotification.utf8))
        #expect(notificationResponse == nil)

        // Per spec: cancelled requests should not produce a response.
        let response = await requestTask.value
        #expect(response == nil)
    }

    @Test
    func cancellationOfUnknownRequestIdIsBenign() async throws {
        let server = makeServer()
        let cancelNotification = #"""
        {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42}}
        """#
        let response = await server.handleInbound(Data(cancelNotification.utf8))
        #expect(response == nil)
    }

    @Test
    func cancellationStringRequestId() async throws {
        let registry = ToolRegistry()
        await registry.register(SlowTool())
        let server = makeServer(registry: registry)

        let request = #"""
        {"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"slow","arguments":{}}}
        """#
        let cancelNotification = #"""
        {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"abc"}}
        """#

        let requestTask = Task {
            await server.handleInbound(Data(request.utf8))
        }
        try await Task.sleep(for: .milliseconds(150))

        _ = await server.handleInbound(Data(cancelNotification.utf8))
        let response = await requestTask.value
        #expect(response == nil)
    }
}

@Suite("BuildIsolatedSnippet cancellation (integration)")
struct BuildIsolatedSnippetCancellationTests {
    @Test
    func taskCancellationTerminatesChildProcess() async throws {
        let tool = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())

        // Long timeout so the only way the test finishes quickly is via cancellation.
        let task = Task {
            try await tool.call(arguments: .object([
                "code": .string("while true { }"),
                "timeout_ms": .integer(60_000)
            ]))
        }

        // Allow time for the build to finish and the child process to actually start.
        try await Task.sleep(for: .seconds(2))

        let cancelStart = Date()
        task.cancel()

        // The Task should resolve within a few seconds — the SIGTERM from the
        // cancellation handler must reach the child and bring it down.
        do {
            _ = try await task.value
        } catch {
            // Either CancellationError or some other Swift Task cancellation surface.
        }
        let elapsed = Date().timeIntervalSince(cancelStart)
        #expect(elapsed < 5.0, "cancellation should bring the child down within a few seconds, got \(elapsed)s")
    }
}
