import Testing
@testable import SwiftcMCPCore

@Test
func versionIsNonEmpty() {
    #expect(!SwiftcMCPCore.version.isEmpty)
}
