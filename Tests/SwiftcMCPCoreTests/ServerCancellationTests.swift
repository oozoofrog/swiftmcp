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

/// Regression guard for Codex stop-time review: when XcodebuildResolver started
/// routing through `runProcessWithTimeoutDiscardingOutput` to dodge the
/// macOS 26.x SWBBuildService stdio-hang, the bypass had to keep the existing
/// parent-task → child SIGTERM contract that `runProcess` provides. This test
/// exercises the discarding variant directly: it spawns a 60-second `sleep`
/// (so timeout-driven termination cannot rescue us), cancels the parent Task a
/// moment later, and asserts the call returns well before the 60s wall-clock
/// — proving the PIDHolder + onCancel handshake is wired through.
@Suite("runProcessWithTimeoutDiscardingOutput cancellation")
struct DiscardingOutputCancellationTests {
    @Test
    func parentTaskCancelTerminatesChild() async throws {
        let task = Task {
            try await runProcessWithTimeoutDiscardingOutput(
                executable: "/bin/sleep",
                arguments: ["60"],
                timeout: 60
            )
        }

        try await Task.sleep(for: .milliseconds(200))
        let cancelStart = Date()
        task.cancel()

        var caughtCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            caughtCancellation = true
        } catch {
            // Any other error path also counts as "the call returned" — but the
            // helper's contract under cancellation is specifically to throw
            // CancellationError so resolvers don't keep running follow-up steps
            // on a SIGTERM'd build.
        }
        let elapsed = Date().timeIntervalSince(cancelStart)
        // Same 7s rationale as `taskCancellationTerminatesChildProcess`: the
        // PIDHolder hop + 50ms polling + waitUntilExit add variance, but the
        // cancel must not let us wait the full 60s.
        #expect(elapsed < 7.0, "cancellation should propagate well before the 60s timeout, got \(elapsed)s")
        // Codex stop-time review: the helper must throw CancellationError so
        // the calling resolver bails out before processing partial artifacts.
        #expect(caughtCancellation, "expected CancellationError to propagate so resolvers stop after SIGTERM")
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
        // 7s threshold is a margin over a few realistic effects:
        //   - Actor-based PIDHolder requires the onCancel-spawned Task to schedule and
        //     await the actor before SIGTERM is delivered (microseconds typically, but
        //     under heavy concurrent xcodebuild/SwiftPM load — see Stage 3.D/E tests —
        //     it can stretch into hundreds of ms).
        //   - The 50 ms polling cadence in runProcessWithTimeout adds variance.
        //   - The killed child still has to flush the pipe and let waitUntilExit return.
        // What we actually want to prove is "cancellation propagated" vs "we waited the
        // full 60s wall-clock timeout" — 7s vs 60s is a clear signal either way.
        #expect(elapsed < 7.0, "cancellation should propagate well before the 60s wall-clock timeout, got \(elapsed)s")
    }
}
