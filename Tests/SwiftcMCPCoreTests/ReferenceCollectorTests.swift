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
        let refs = ReferenceCollector.collect(astText: sampleAST, enclosing: 5...8)
        let names = Set(refs.map(\.name))
        #expect(names.contains("formatLabel"))
        #expect(names.contains("Counter"))   // value reference inside member_ref's declref
        #expect(names.contains("String"))    // type_unqualified_ident
    }

    @Test
    func excludesLocalBindings() {
        // `counter` is a parameter declared at line 5:18 — its decl line falls inside
        // the enclosing 5...8 range, so it must be filtered out.
        let refs = ReferenceCollector.collect(astText: sampleAST, enclosing: 5...8)
        let names = Set(refs.map(\.name))
        #expect(names.contains("counter") == false)
    }

    @Test
    func ignoresNodesOutsideEnclosingRange() {
        // Restricting to lines 6...6 should still catch `formatLabel` (declref on line 6)
        // but not the type_unqualified_ident on line 7.
        let refs = ReferenceCollector.collect(astText: sampleAST, enclosing: 6...6)
        let names = Set(refs.map(\.name))
        #expect(names.contains("formatLabel"))
        #expect(names.contains("String") == false)
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
