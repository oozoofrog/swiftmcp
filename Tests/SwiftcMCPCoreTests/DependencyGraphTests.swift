import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("DependencyGraph")
struct DependencyGraphTests {
    /// AST that exercises direct + transitive deps + an overload. We synthesize the
    /// shape minimally — `DependencyGraph` only needs DeclIndex entries plus the AST
    /// text that `ReferenceCollector` will scan inside their ranges.
    private let sampleAST = #"""
    (source_file "/tmp/sample.swift"
      (struct_decl decl_context=0x1 range=[/tmp/sample.swift:3:8 - line:5:1] "Counter")
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:7:8 - line:7:60] "formatLabel(_:)" interface_type="(String) -> String"
        (declref_expr range=[/tmp/sample.swift:7:50 - line:7:50] decl="sample.(file).Counter@/tmp/sample.swift:3:8" function_ref=single))
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:9:8 - line:11:1] "describe(_:)" interface_type="(Counter) -> String"
        (declref_expr range=[/tmp/sample.swift:10:5 - line:10:5] decl="sample.(file).formatLabel(_:)@/tmp/sample.swift:7:8" function_ref=single))
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:13:8 - line:13:35] "unrelated()" interface_type="() -> Int"
        (declref_expr range=[/tmp/sample.swift:13:20 - line:13:20] decl="Swift.(file).Int@/dev/null:0:0" function_ref=single))
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:15:8 - line:15:30] "helper()" interface_type="() -> Int")
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:16:8 - line:16:38] "helper(_:)" interface_type="(Int) -> Int")
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:18:8 - line:18:60] "useHelper()" interface_type="() -> Int"
        (declref_expr range=[/tmp/sample.swift:18:25 - line:18:25] decl="sample.(file).helper@/tmp/sample.swift:15:8" function_ref=single)))
    """#

    @Test
    func includesDirectDependency() throws {
        let index = DeclIndex.build(astText: sampleAST)
        let graph = DependencyGraph(index: index, astText: sampleAST)
        let formatLabel = try #require(index.find(signatureKey: "formatLabel(_:)"))
        let output = graph.transitiveClosure(startingAt: formatLabel)
        let names = Set(output.closure.map(\.name))
        #expect(names == ["formatLabel", "Counter"])
    }

    @Test
    func includesTransitiveDependency() throws {
        let index = DeclIndex.build(astText: sampleAST)
        let graph = DependencyGraph(index: index, astText: sampleAST)
        let describe = try #require(index.find(signatureKey: "describe(_:)"))
        let output = graph.transitiveClosure(startingAt: describe)
        let names = Set(output.closure.map(\.name))
        #expect(names.contains("describe"))
        #expect(names.contains("formatLabel"))
        #expect(names.contains("Counter"))   // transitively via formatLabel
    }

    @Test
    func recordsExternalReferences() throws {
        let index = DeclIndex.build(astText: sampleAST)
        let graph = DependencyGraph(index: index, astText: sampleAST)
        let unrelated = try #require(index.find(signatureKey: "unrelated()"))
        let output = graph.transitiveClosure(startingAt: unrelated)
        // `Int` is from Swift module — not in DeclIndex — so it goes to external.
        #expect(output.externalReferences.contains("Int"))
        let names = Set(output.closure.map(\.name))
        #expect(names == ["unrelated"])
    }

    @Test
    func includesAllOverloads() throws {
        let index = DeclIndex.build(astText: sampleAST)
        let graph = DependencyGraph(index: index, astText: sampleAST)
        let useHelper = try #require(index.find(signatureKey: "useHelper()"))
        let output = graph.transitiveClosure(startingAt: useHelper)
        let helperKeys = Set(output.closure.filter { $0.name == "helper" }.map(\.signatureKey))
        #expect(helperKeys == ["helper()", "helper(_:)"])
    }

    @Test
    func avoidsRevisitingDecls() throws {
        // Synthetic mutual-call AST: A → B and B → A. Closure must include each
        // exactly once, regardless of cycle direction.
        let cycleAST = #"""
        (source_file "/tmp/cycle.swift"
          (func_decl decl_context=0x1 range=[/tmp/cycle.swift:1:1 - line:3:1] "alpha()" interface_type="() -> Void"
            (declref_expr range=[/tmp/cycle.swift:2:5 - line:2:5] decl="sample.(file).beta@/tmp/cycle.swift:5:1" function_ref=single))
          (func_decl decl_context=0x1 range=[/tmp/cycle.swift:5:1 - line:7:1] "beta()" interface_type="() -> Void"
            (declref_expr range=[/tmp/cycle.swift:6:5 - line:6:5] decl="sample.(file).alpha@/tmp/cycle.swift:1:1" function_ref=single)))
        """#
        let index = DeclIndex.build(astText: cycleAST)
        let graph = DependencyGraph(index: index, astText: cycleAST)
        let alpha = try #require(index.find(signatureKey: "alpha()"))
        let output = graph.transitiveClosure(startingAt: alpha)
        let names = output.closure.map(\.name).sorted()
        #expect(names == ["alpha", "beta"])
    }
}
