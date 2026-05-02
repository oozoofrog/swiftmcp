import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ReferenceCollector")
struct ReferenceCollectorTests {
    /// Sample fragment captured from `swiftc -dump-ast`. Different decls live on
    /// different line ranges so the locality filter has something to bite on.
    private let sampleAST = #"""
    (source_file "/tmp/sample.swift"
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:5:1 - line:8:1] "describe(_:)" interface_type="(Counter) -> String"
        (parameter "counter" decl_context=0x2 interface_type="Counter")
        (call_expr type="String" range=[/tmp/sample.swift:6:5 - line:6:35]
          (declref_expr type="(String) -> String" range=[/tmp/sample.swift:6:5 - line:6:5] decl="sample.(file).formatLabel(_:)@/tmp/sample.swift:11:6" function_ref=single)
          (member_ref_expr range=[/tmp/sample.swift:6:18 - line:6:18] decl="sample.(file).Counter.value@/tmp/sample.swift:3:9"
            (declref_expr range=[/tmp/sample.swift:6:18 - line:6:18] decl="sample.(file).describe(_:).counter@/tmp/sample.swift:5:18" function_ref=unapplied)))
        (pattern_typed range=[/tmp/sample.swift:7:5 - line:7:5]
          (pattern_named "result")
          (type_unqualified_ident id="String" bind="Swift.(file).String"))))
    """#

    @Test
    func extractsValueAndTypeReferencesWithinRange() {
        let refs = ReferenceCollector.collect(astText: sampleAST, enclosing: 5...8, enclosingFile: "/tmp/sample.swift")
        let names = Set(refs.map(\.name))
        #expect(names.contains("formatLabel"))
        #expect(names.contains("Counter"))   // value reference inside member_ref's declref
        #expect(names.contains("String"))    // type_unqualified_ident
    }

    @Test
    func excludesLocalBindings() {
        // `counter` is a parameter declared at line 5:18 — its decl line falls inside
        // the enclosing 5...8 range, so it must be filtered out.
        let refs = ReferenceCollector.collect(astText: sampleAST, enclosing: 5...8, enclosingFile: "/tmp/sample.swift")
        let names = Set(refs.map(\.name))
        #expect(names.contains("counter") == false)
    }

    @Test
    func ignoresNodesOutsideEnclosingRange() {
        // Restricting to lines 6...6 should still catch `formatLabel` (declref on line 6)
        // but not the type_unqualified_ident on line 7.
        let refs = ReferenceCollector.collect(astText: sampleAST, enclosing: 6...6, enclosingFile: "/tmp/sample.swift")
        let names = Set(refs.map(\.name))
        #expect(names.contains("formatLabel"))
        #expect(names.contains("String") == false)
    }

    /// Multi-file AST: two source_file blocks sharing line numbers.
    /// `formatLabel` lives at line 6 of `/tmp/A.swift`; `unrelated` lives at
    /// the same line of `/tmp/B.swift`. With the file filter the collector
    /// must only return references from the file we asked about — without
    /// it, slice_function on a directory input would mix references from
    /// peer files that happen to share line numbers.
    @Test
    func filtersByEnclosingFileEvenAcrossSharedLineNumbers() {
        let multiFileAST = #"""
        (source_file "/tmp/A.swift"
          (func_decl range=[/tmp/A.swift:5:1 - line:8:1] "describe(_:)" interface_type="() -> String"
            (call_expr type="String" range=[/tmp/A.swift:6:5 - line:6:18]
              (declref_expr range=[/tmp/A.swift:6:5 - line:6:5] decl="sample.(file).formatLabel(_:)@/tmp/A.swift:11:6" function_ref=single))))
        (source_file "/tmp/B.swift"
          (func_decl range=[/tmp/B.swift:5:1 - line:8:1] "explain(_:)" interface_type="() -> Int"
            (call_expr type="Int" range=[/tmp/B.swift:6:5 - line:6:18]
              (declref_expr range=[/tmp/B.swift:6:5 - line:6:5] decl="sample.(file).unrelated(_:)@/tmp/B.swift:11:6" function_ref=single))))
        """#
        let refsA = ReferenceCollector.collect(astText: multiFileAST, enclosing: 5...8, enclosingFile: "/tmp/A.swift")
        let namesA = Set(refsA.map(\.name))
        #expect(namesA.contains("formatLabel"))
        #expect(namesA.contains("unrelated") == false)

        let refsB = ReferenceCollector.collect(astText: multiFileAST, enclosing: 5...8, enclosingFile: "/tmp/B.swift")
        let namesB = Set(refsB.map(\.name))
        #expect(namesB.contains("unrelated"))
        #expect(namesB.contains("formatLabel") == false)
    }

    @Test
    func baseNameStripsModuleAndArgumentLabels() {
        #expect(ReferenceCollector.baseName(fromDeclChain: "sample.(file).formatLabel(_:)") == "formatLabel")
        #expect(ReferenceCollector.baseName(fromDeclChain: "sample.(file).Counter.value") == "Counter")
        #expect(ReferenceCollector.baseName(fromDeclChain: "sample.(file).Counter.init(value:)") == "Counter")
    }

    @Test
    func emptyChainReturnsEmptyName() {
        #expect(ReferenceCollector.baseName(fromDeclChain: "") == "")
        #expect(ReferenceCollector.baseName(fromDeclChain: "Swift") == "")
    }
}
