import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("DeclIndex")
struct DeclIndexTests {
    /// Realistic AST fragment captured from `swiftc -dump-ast` against a multi-decl
    /// fixture. Unit tests work against this string verbatim — that way a toolchain
    /// upgrade that changes the AST formatting is loud (these tests fail) rather than
    /// silent (downstream slicing returns wrong ranges).
    private let sampleAST = """
    (source_file "/tmp/sample.swift"
      (import_decl decl_context=0x1 range=[/tmp/sample.swift:1:1 - line:1:8] module="Foundation")
      (struct_decl decl_context=0x1 range=[/tmp/sample.swift:3:8 - line:8:1] "Counter" interface_type="Counter.Type" access=public
        (var_decl decl_context=0x2 range=[/tmp/sample.swift:4:16 - line:4:16] "value" interface_type="Int")
        (func_decl decl_context=0x2 range=[/tmp/sample.swift:5:12 - line:7:5] "incremented()" interface_type="(Counter) -> () -> Counter"))
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:10:8 - line:10:59] "formatLabel(_:)" interface_type="(String) -> String")
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:12:8 - line:15:1] "describe(_:)" interface_type="(Counter) -> String")
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:17:8 - line:17:35] "unrelated()" interface_type="() -> Int")
      (extension_decl decl_context=0x1 range=[/tmp/sample.swift:19:1 - line:21:1] "Counter")
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:23:8 - line:23:30] "helper()" interface_type="() -> Int")
      (func_decl decl_context=0x1 range=[/tmp/sample.swift:24:8 - line:24:38] "helper(_:)" interface_type="(Int) -> Int"))
    """

    @Test
    func indexesTopLevelStructAndFunctions() {
        let index = DeclIndex.build(astText: sampleAST)
        let names = Set(index.entries.map(\.name))
        #expect(names.contains("Counter"))
        #expect(names.contains("formatLabel"))
        #expect(names.contains("describe"))
        #expect(names.contains("unrelated"))
        #expect(names.contains("helper"))
    }

    @Test
    func skipsInnerDeclarations() {
        // `incremented()` and `value` live inside Counter (deeper indent) and must
        // NOT appear in the top-level index — that's the slicer's contract.
        let index = DeclIndex.build(astText: sampleAST)
        let names = Set(index.entries.map(\.name))
        #expect(names.contains("incremented") == false)
        #expect(names.contains("value") == false)
    }

    @Test
    func capturesSourceRanges() throws {
        let index = DeclIndex.build(astText: sampleAST)
        let counter = try #require(index.entries.first(where: { $0.name == "Counter" }))
        #expect(counter.startLine == 3)
        #expect(counter.endLine == 8)
        let describe = try #require(index.entries.first(where: { $0.name == "describe" }))
        #expect(describe.startLine == 12)
        #expect(describe.endLine == 15)
    }

    @Test
    func recognizesExtensionAsTopLevel() throws {
        let index = DeclIndex.build(astText: sampleAST)
        let ext = try #require(index.entries.first(where: { $0.kind == .extensionDecl }))
        #expect(ext.name == "Counter")
        #expect(ext.startLine == 19)
        #expect(ext.endLine == 21)
    }

    @Test
    func overloadsHaveDistinctSignatureKeys() {
        let index = DeclIndex.build(astText: sampleAST)
        let helpers = index.find(name: "helper")
        #expect(helpers.count == 2)
        let keys = Set(helpers.map(\.signatureKey))
        #expect(keys == ["helper()", "helper(_:)"])
    }

    @Test
    func findBySignatureKeyReturnsExactMatch() throws {
        let index = DeclIndex.build(astText: sampleAST)
        let helper = try #require(index.find(signatureKey: "helper(_:)"))
        #expect(helper.name == "helper")
        #expect(helper.signatureKey == "helper(_:)")
    }

    @Test
    func indexesTypealiasNodeWithoutDeclSuffix() {
        // swiftc emits `(typealias …)` for typealiases — note the missing `_decl`
        // suffix that other top-level kinds carry. The index must recognize both
        // forms so typealiases aren't silently skipped.
        let typealiasAST = #"""
        (source_file "/tmp/multi.swift"
          (typealias decl_context=0x1 range=[/tmp/multi.swift:1:8 - line:1:24] trailing_semi "Foo" interface_type="Foo.Type" type="Int")
          (typealias_decl decl_context=0x1 range=[/tmp/multi.swift:2:8 - line:2:24] "Bar" interface_type="Bar.Type" type="String"))
        """#
        let index = DeclIndex.build(astText: typealiasAST)
        let names = Set(index.entries.filter { $0.kind == .typealiasDecl }.map(\.name))
        #expect(names == ["Foo", "Bar"])
    }

    @Test
    func entryContainingLineFindsParent() throws {
        let index = DeclIndex.build(astText: sampleAST)
        // Line 5 is inside Counter (lines 3..8).
        let parent = try #require(index.entry(containingLine: 5, inFile: "/tmp/sample.swift"))
        #expect(parent.name == "Counter")
    }

    /// Multi-file build: each top-level decl is tagged with the source file
    /// it came from, derived from the `range=[<file>:…]` payload. Without
    /// per-entry filePath, slicing a directory input would conflate decls
    /// that share line numbers across files.
    @Test
    func tracksSourceFilePathPerEntry() {
        let multiAST = """
        (source_file "/tmp/A.swift"
          (struct_decl decl_context=0x1 range=[/tmp/A.swift:1:8 - line:3:1] "Greeter" interface_type="Greeter.Type" access=public)
          (func_decl decl_context=0x1 range=[/tmp/A.swift:4:6 - line:6:1] "describe(_:)" interface_type="(Greeter) -> String" access=public))
        (source_file "/tmp/B.swift"
          (struct_decl decl_context=0x1 range=[/tmp/B.swift:1:8 - line:3:1] "Listener" interface_type="Listener.Type" access=public))
        """
        let index = DeclIndex.build(astText: multiAST)
        let greeter = index.entries.first { $0.name == "Greeter" }
        let describe = index.entries.first { $0.name == "describe" }
        let listener = index.entries.first { $0.name == "Listener" }
        #expect(greeter?.filePath == "/tmp/A.swift")
        #expect(describe?.filePath == "/tmp/A.swift")
        #expect(listener?.filePath == "/tmp/B.swift")
        // entry(containingLine:inFile:) must respect the file filter so
        // line-number collisions across files don't return the wrong decl.
        #expect(index.entry(containingLine: 1, inFile: "/tmp/A.swift")?.name == "Greeter")
        #expect(index.entry(containingLine: 1, inFile: "/tmp/B.swift")?.name == "Listener")
    }
}
