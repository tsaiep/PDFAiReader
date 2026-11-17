import Foundation

/// 便利貼的 6 種預設顏色（不提供調色盤）。`graphite` 為深色，文字改用白色。
public enum NoteColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case butter, peach, mint, sky, lavender, graphite
    public var id: String { rawValue }
    public var isDark: Bool { self == .graphite }
}

/// 螢光筆顏色。
public enum HighlightColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case yellow, red, blue
    public var id: String { rawValue }
}

/// 便利貼。`rect` 為 nil 表示「沒有實體位置」的筆記（只在側邊欄顯示）。
///
/// `rect` 使用頁面的「顯示空間」：已套用頁面旋轉、單位為 PDF 點、原點在左下角，
/// 與 `PageGeometry.displaySize` 同一座標系。存的是收合時的大小，展開時只往下長高。
public struct StickyNote: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var documentID: String
    public var pageIndex: Int
    public var rect: PageRect?
    public var title: String
    public var body: String
    public var color: NoteColor
    /// 字體家族名稱；空字串＝系統字體。
    public var fontFamily: String
    public var fontSize: Double
    public var expanded: Bool
    /// 側邊欄同一頁內的排列順序（小的在前）。
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date

    public static let defaultSize = (width: 190.0, height: 130.0)
    public static let minimumSize = (width: 110.0, height: 64.0)

    public init(id: String = UUID().uuidString, documentID: String, pageIndex: Int, rect: PageRect?,
                title: String = "", body: String = "", color: NoteColor = .butter,
                fontFamily: String = "", fontSize: Double = 13, expanded: Bool = false,
                sortOrder: Double? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.rect = rect
        self.title = title
        self.body = body
        self.color = color
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.expanded = expanded
        self.sortOrder = sortOrder ?? createdAt.timeIntervalSince1970
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isPlaced: Bool { rect != nil }
    public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var hasTitle: Bool { !trimmedTitle.isEmpty }

    /// 側邊欄／列表用的一行摘要。
    public var summary: String {
        if hasTitle { return trimmedTitle }
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// 把便利貼限制在頁面內（顯示空間），並保證最小尺寸。
    public static func clamp(_ rect: PageRect, pageSize: (width: Double, height: Double)) -> PageRect {
        var r = rect
        r.width = min(max(r.width, minimumSize.width), max(pageSize.width, minimumSize.width))
        r.height = min(max(r.height, minimumSize.height), max(pageSize.height, minimumSize.height))
        r.x = min(max(r.x, 0), max(0, pageSize.width - r.width))
        r.y = min(max(r.y, 0), max(0, pageSize.height - r.height))
        return r
    }
}

/// 螢光筆標在哪一種文字上。
public enum TextSide: String, Codable, Sendable {
    case original, translated
}

/// 螢光筆的文字錨點：標在某區塊（原文或譯文）的第幾個字到第幾個字。
/// 切換原文／譯文時以句子對齊換算到另一邊，因此兩種畫面都標在對應的文字上。
public struct HighlightSpan: Codable, Sendable, Equatable, Hashable {
    public var blockID: String
    public var side: TextSide
    public var start: Int
    public var end: Int
    /// 標記時該區塊的完整文字；之後文字變了（例如重新翻譯）用來換算。
    public var source: String

    public init(blockID: String, side: TextSide, start: Int, end: Int, source: String) {
        self.blockID = blockID
        self.side = side
        self.start = start
        self.end = end
        self.source = source
    }
}

/// 螢光筆標記。`rects` 為頁面座標（PDFPage 原生空間，未旋轉），每行文字一個矩形：原文畫面的位置（沒有錨點時的備援）。
public struct Highlight: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var documentID: String
    public var pageIndex: Int
    public var color: HighlightColor
    public var rects: [PageRect]
    public var text: String
    public var spans: [HighlightSpan]
    public var createdAt: Date

    public init(id: String = UUID().uuidString, documentID: String, pageIndex: Int, color: HighlightColor,
                rects: [PageRect], text: String, spans: [HighlightSpan] = [], createdAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.color = color
        self.rects = rects
        self.text = text
        self.spans = spans
        self.createdAt = createdAt
    }

    /// 點是否落在標記上（頁面座標）。
    public func contains(x: Double, y: Double, tolerance: Double = 1) -> Bool {
        rects.contains { x >= $0.minX - tolerance && x <= $0.maxX + tolerance && y >= $0.minY - tolerance && y <= $0.maxY + tolerance }
    }
}
