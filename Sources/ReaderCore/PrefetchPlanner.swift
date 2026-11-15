import Foundation

public enum NavigationDirection: Sendable, Equatable {
    case forward    // 頁碼遞增
    case backward   // 頁碼遞減
}

public struct PlannedPage: Sendable, Equatable {
    public var pageIndex: Int
    public var priority: JobPriority

    public init(pageIndex: Int, priority: JobPriority) {
        self.pageIndex = pageIndex
        self.priority = priority
    }
}

/// 根據「可見頁集合 + N 頁」產生處理順序。
///
/// 例：可見 {20, 21}、N = 5、往前讀 → 20, 21（visible），22…26（prefetch）。
public struct PrefetchPlanner: Sendable {
    public var aheadCount: Int

    public init(aheadCount: Int = 5) {
        self.aheadCount = max(0, aheadCount)
    }

    public func plan(visible: Set<Int>, pageCount: Int,
                     direction: NavigationDirection = .forward) -> [PlannedPage] {
        guard pageCount > 0 else { return [] }
        let validVisible = visible.filter { $0 >= 0 && $0 < pageCount }.sorted()
        guard let first = validVisible.first, let last = validVisible.last else { return [] }

        var result = validVisible.map { PlannedPage(pageIndex: $0, priority: .visible) }
        var seen = Set(validVisible)

        let ahead: [Int]
        switch direction {
        case .forward:
            ahead = aheadCount == 0 ? [] : Array((last + 1)...(last + aheadCount))
        case .backward:
            ahead = aheadCount == 0 ? [] : stride(from: first - 1, through: first - aheadCount, by: -1).map { $0 }
        }
        for page in ahead where page >= 0 && page < pageCount && !seen.contains(page) {
            result.append(PlannedPage(pageIndex: page, priority: .prefetch))
            seen.insert(page)
        }
        return result
    }
}

/// 從連續的頁面變化推斷閱讀方向。
public struct DirectionTracker: Sendable {
    public private(set) var direction: NavigationDirection = .forward
    private var lastPage: Int?

    public init() {}

    public mutating func update(page: Int) -> NavigationDirection {
        if let last = lastPage {
            if page > last { direction = .forward }
            else if page < last { direction = .backward }
        }
        lastPage = page
        return direction
    }
}
