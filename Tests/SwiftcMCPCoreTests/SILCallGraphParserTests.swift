import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("SILCallGraphParser (unit)")
struct SILCallGraphParserTests {
    @Test
    func directCalleeFromFunctionRef() throws {
        let sil = """
        sil_stage canonical

        sil hidden @$s4main3addyS2i_SitF : $@convention(thin) (Int, Int) -> Int {
        bb0(%0 : $Int, %1 : $Int):
          %2 = function_ref @$sSi1poiyS2i_SitFZ : $@convention(method) (Int, Int, @thin Int.Type) -> Int
          %3 = apply %2(%0, %1) : $@convention(method) (Int, Int, @thin Int.Type) -> Int
          return %3
        }
        """
        let out = SILCallGraphParser.parse(sil)
        #expect(out.summary.totalFunctions == 1)
        #expect(out.summary.totalApplies == 1)
        let fn = try #require(out.functions.first)
        #expect(fn.name == "$s4main3addyS2i_SitF")
        #expect(fn.directCallees == ["$sSi1poiyS2i_SitFZ"])
        #expect(fn.apply == 1)
    }

    @Test
    func dynamicDispatchInstructionsAreCounted() throws {
        let sil = """
        sil hidden @$s4main3useyS2iAA1P_pF : $@convention(thin) (any P) -> Int {
        bb0(%0 : $any P):
          %1 = open_existential_addr %0 : $*any P to $*@opened
          %2 = witness_method $@opened, #P.work : <Self> (Self) -> () -> Int
          %3 = apply %2<...>(%1)
          return %3
        }

        sil hidden @$s4main3useCyS2iAA1CCF : $@convention(thin) (C) -> Int {
        bb0(%0 : $C):
          %1 = class_method %0 : $C, #C.work
          %2 = apply %1(%0)
          return %2
        }
        """
        let out = SILCallGraphParser.parse(sil)
        #expect(out.summary.totalFunctions == 2)
        #expect(out.summary.totalApplies == 2)
        #expect(out.summary.totalDynamicDispatchSites == 2)
        // 2 dynamic / (0 direct + 2 dynamic) == 1.0
        #expect(out.summary.dynamicDispatchRatio == 1.0)
    }

    @Test
    func partialApplyIsTrackedSeparately() throws {
        let sil = """
        sil hidden @$s4main7adapter : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @$s4main3addyS2i_SitF : $@convention(thin) (Int, Int) -> Int
          %1 = partial_apply [callee_guaranteed] %0(%2) : $@convention(thin) (Int, Int) -> Int
          return
        }
        """
        let out = SILCallGraphParser.parse(sil)
        let fn = try #require(out.functions.first)
        #expect(fn.partialApply == 1)
        #expect(out.summary.totalPartialApplies == 1)
        // partial_apply is not counted in apply.
        #expect(fn.apply == 0)
    }

    @Test
    func emptyOrDeclOnlySILProducesNoFunctions() throws {
        let declOnly = """
        sil_stage canonical

        sil [readonly] @$external : $@convention(thin) () -> ()
        """
        let out = SILCallGraphParser.parse(declOnly)
        #expect(out.functions.isEmpty)
        #expect(out.summary.totalFunctions == 0)
        #expect(out.summary.dynamicDispatchRatio == 0.0)
    }

    @Test
    func directCalleesAreUnique() throws {
        let sil = """
        sil hidden @$s4main4manyyyF : $@convention(thin) () -> () {
        bb0:
          %0 = function_ref @$same : $@convention(thin) () -> ()
          %1 = apply %0()
          %2 = function_ref @$same : $@convention(thin) () -> ()
          %3 = apply %2()
          %4 = function_ref @$other : $@convention(thin) () -> ()
          %5 = apply %4()
          return
        }
        """
        let out = SILCallGraphParser.parse(sil)
        let fn = try #require(out.functions.first)
        #expect(fn.directCallees.sorted() == ["$other", "$same"])
        #expect(fn.apply == 3)
    }
}
