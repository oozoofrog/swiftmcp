import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ApiDigesterParser")
struct ApiDigesterParserTests {
    /// Exact text shape produced by `swift-api-digester -diagnose-sdk` against
    /// two dump-sdk JSONs (verified live in the Stage 4-4 probe).
    private let allSectionsSample = """

    /* Generic Signature Changes */

    /* RawRepresentable Changes */

    /* Removed Decls */
    Func helloAdd(_:_:) has been removed
    Struct OldType has been removed

    /* Moved Decls */

    /* Renamed Decls */

    /* Type Changes */

    /* Decl Attribute changes */

    /* Fixed-layout Type Changes */

    /* Protocol Conformance Change */

    /* Protocol Requirement Change */

    /* Class Inheritance Change */

    /* Others */
    """

    @Test
    func parsesAllTwelveSectionsAndCollectsFindings() {
        let findings = ApiDigesterParser.parse(allSectionsSample)
        #expect(findings.removedDecls == [
            "Func helloAdd(_:_:) has been removed",
            "Struct OldType has been removed"
        ])
        #expect(findings.movedDecls.isEmpty)
        #expect(findings.renamedDecls.isEmpty)
        #expect(findings.typeChanges.isEmpty)
        #expect(findings.declAttributeChanges.isEmpty)
        #expect(findings.fixedLayoutTypeChanges.isEmpty)
        #expect(findings.protocolConformanceChanges.isEmpty)
        #expect(findings.protocolRequirementChanges.isEmpty)
        #expect(findings.classInheritanceChanges.isEmpty)
        #expect(findings.genericSignatureChanges.isEmpty)
        #expect(findings.rawRepresentableChanges.isEmpty)
        #expect(findings.others.isEmpty)
        #expect(findings.totalFindings == 2)
    }

    @Test
    func emptyTextProducesEmptyFindings() {
        let findings = ApiDigesterParser.parse("")
        #expect(findings.totalFindings == 0)
        #expect(findings.byCategory.values.allSatisfy { $0 == 0 })
    }

    @Test
    func headersOnlyWithNoFindingsParseEmpty() {
        let text = """
        /* Removed Decls */
        /* Moved Decls */
        /* Type Changes */
        """
        let findings = ApiDigesterParser.parse(text)
        #expect(findings.totalFindings == 0)
    }

    @Test
    func multipleFindingsInSameSection() {
        let text = """
        /* Decl Attribute changes */
        Func a() is a new API without '@available'
        Func b() is a new API without '@available'
        Func c() is a new API without '@available'
        """
        let findings = ApiDigesterParser.parse(text)
        #expect(findings.declAttributeChanges.count == 3)
        #expect(findings.declAttributeChanges.contains("Func b() is a new API without '@available'"))
    }

    @Test
    func compilerStyleApiBreakagePrefixIsPreserved() {
        // `-compiler-style-diags` annotates removed decls with an "API breakage:"
        // prefix. We deliberately keep the marker so consumers can grep for
        // breakages without re-classifying themselves.
        let text = """
        /* Removed Decls */
        API breakage: func helloAdd(_:_:) has been removed
        """
        let findings = ApiDigesterParser.parse(text)
        #expect(findings.removedDecls == [
            "API breakage: func helloAdd(_:_:) has been removed"
        ])
    }

    @Test
    func unknownSectionLandsInOthersBucket() {
        // Defensive case: a future toolchain could rename a header. We don't
        // want unknown sections to silently lose findings — drop them in
        // `others` so the data is still visible.
        let text = """
        /* SomeFutureSection */
        Func mystery() got a new attribute
        /* Removed Decls */
        Func legit() has been removed
        """
        let findings = ApiDigesterParser.parse(text)
        #expect(findings.others == ["Func mystery() got a new attribute"])
        #expect(findings.removedDecls == ["Func legit() has been removed"])
    }
}
