import Foundation

// MARK: - 文件與閱讀狀態

public enum DisplayMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case singlePage
    case twoUp
    case continuous

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .singlePage: return "單頁"
        case .twoUp: return "雙頁"
        case .continuous: return "連續捲動"
        }
    }
}

public enum ReadingDirection: String, Codable, Sendable, CaseIterable {
    case leftToRight
    case rightToLeft
}

public struct DocumentRecord: Codable, Sendable, Identifiable, Equatable {
    /// 快速指紋（見 DocumentFingerprint）。
    public var id: String
    public var path: String
    /// macOS URL bookmark，用來追蹤被搬移／重新命名的檔案。
    public var bookmarkData: Data?
    public var title: String
    public var pageCount: Int
    public var fileSize: Int64
    public var lastOpenedAt: Date

    public init(id: String, path: String, bookmarkData: Data?, title: String,
                pageCount: Int, fileSize: Int64, lastOpenedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
        self.title = title
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct ReadingProgress: Codable, Sendable, Equatable {
    public var documentID: String
    public var pageIndex: Int
    public var scaleFactor: Double
    public var autoScales: Bool
    public var displayMode: DisplayMode
    public var readingDirection: ReadingDirection
    public var updatedAt: Date

    public init(documentID: String, pageIndex: Int, scaleFactor: Double = 1.0,
                autoScales: Bool = true, displayMode: DisplayMode = .continuous,
                readingDirection: ReadingDirection = .leftToRight, updatedAt: Date = Date()) {
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.scaleFactor = scaleFactor
        self.autoScales = autoScales
        self.displayMode = displayMode
        self.readingDirection = readingDirection
        self.updatedAt = updatedAt
    }
}

public struct Bookmark: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: Int64?
    public var documentID: String
    public var pageIndex: Int
    public var title: String
    public var createdAt: Date

    public init(id: Int64? = nil, documentID: String, pageIndex: Int, title: String, createdAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.title = title
        self.createdAt = createdAt
    }
}

// MARK: - 文字結構

/// 頁面空間中的矩形（PDF points，原點在左下）。
public struct PageRect: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case heading
    case paragraph
    case caption
    case footnote
    case other
}

public enum TextSource: String, Codable, Sendable {
    case embedded   // PDF 原生文字層
    case ocr        // Apple Vision
}

public struct TextBlock: Codable, Sendable, Identifiable, Equatable {
    /// 穩定 ID：`<documentID>:p<page>:b<order>`
    public var id: String
    public var documentID: String
    public var pageIndex: Int
    public var readingOrder: Int
    public var kind: BlockKind
    public var text: String
    public var bounds: PageRect
    public var confidence: Double
    public var source: TextSource

    public init(id: String, documentID: String, pageIndex: Int, readingOrder: Int, kind: BlockKind,
                text: String, bounds: PageRect, confidence: Double, source: TextSource) {
        self.id = id
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.readingOrder = readingOrder
        self.kind = kind
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
        self.source = source
    }

    public static func makeID(documentID: String, pageIndex: Int, order: Int) -> String {
        "\(documentID):p\(pageIndex):b\(order)"
    }
}

// MARK: - 工作排程

/// 任務優先級（數字越小越優先）。刻意不用 P0–P3，避免與功能優先級撞名。
public enum JobPriority: Int, Codable, Sendable, Comparable, CaseIterable {
    case interactive = 0   // 使用者選取文字
    case visible = 1       // 目前可見頁
    case prefetch = 2      // 預翻譯
    case background = 3    // 整書

    public static func < (lhs: JobPriority, rhs: JobPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum JobState: String, Codable, Sendable {
    case pending, running, completed, failed, cancelled, stale
}

public enum JobKind: String, Codable, Sendable {
    case ocr
    case translate
}
