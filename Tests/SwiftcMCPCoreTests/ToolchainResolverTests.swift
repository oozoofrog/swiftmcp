import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ToolchainResolver")
struct ToolchainResolverTests {
    @Test
    func sdkPathCancellationDoesNotPoisonCache() async {
        let resolver = ToolchainResolver()

        // Run-and-cancel: kick off a sdkPath probe inside a task we cancel
        // immediately. The underlying xcrun call surfaces cancellation through
        // `firstNonEmptyPath` as `nil`; we verify that result is *not* written
        // to the cache.
        let task = Task { await resolver.sdkPath() }
        task.cancel()
        _ = await task.value

        // Subsequent uncancelled call must still be able to resolve. If the
        // cancelled call had poisoned the cache, this would return the cached
        // `nil` without re-probing.
        let resolved = await resolver.sdkPath()
        #expect(resolved != nil)
        #expect(resolved?.contains("MacOSX") == true)
    }

    @Test
    func sdkPathCachesSuccessfulResult() async {
        let resolver = ToolchainResolver()
        let first = await resolver.sdkPath()
        let second = await resolver.sdkPath()
        #expect(first != nil)
        #expect(first == second)
    }
}
