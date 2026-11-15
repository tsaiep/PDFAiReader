import XCTest
@testable import ReaderCore

final class PrefetchPlannerTests: XCTestCase {
    func testSinglePageForward() {
        let plan = PrefetchPlanner(aheadCount: 5).plan(visible: [19], pageCount: 300)
        XCTAssertEqual(plan.map(\.pageIndex), [19, 20, 21, 22, 23, 24])
        XCTAssertEqual(plan.first?.priority, .visible)
        XCTAssertTrue(plan.dropFirst().allSatisfy { $0.priority == .prefetch })
    }

    /// 計劃書範例：雙頁模式可見 20、21，N=5 → 20–26。
    func testTwoUpUsesVisibleSet() {
        let plan = PrefetchPlanner(aheadCount: 5).plan(visible: [20, 21], pageCount: 300)
        XCTAssertEqual(plan.map(\.pageIndex), [20, 21, 22, 23, 24, 25, 26])
        XCTAssertEqual(plan.filter { $0.priority == .visible }.count, 2)
    }

    func testClampsAtDocumentEnd() {
        let plan = PrefetchPlanner(aheadCount: 5).plan(visible: [8], pageCount: 10)
        XCTAssertEqual(plan.map(\.pageIndex), [8, 9])
    }

    func testBackwardDirection() {
        let plan = PrefetchPlanner(aheadCount: 3).plan(visible: [10], pageCount: 50, direction: .backward)
        XCTAssertEqual(plan.map(\.pageIndex), [10, 9, 8, 7])
    }

    func testZeroAheadAndEmpty() {
        XCTAssertEqual(PrefetchPlanner(aheadCount: 0).plan(visible: [3], pageCount: 10).map(\.pageIndex), [3])
        XCTAssertTrue(PrefetchPlanner().plan(visible: [], pageCount: 10).isEmpty)
        XCTAssertTrue(PrefetchPlanner().plan(visible: [1], pageCount: 0).isEmpty)
    }

    func testDirectionTracker() {
        var t = DirectionTracker()
        XCTAssertEqual(t.update(page: 5), .forward)
        XCTAssertEqual(t.update(page: 4), .backward)
        XCTAssertEqual(t.update(page: 4), .backward)
        XCTAssertEqual(t.update(page: 9), .forward)
    }
}
