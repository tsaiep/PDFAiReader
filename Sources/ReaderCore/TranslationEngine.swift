import Foundation

public struct GlossaryEntry: Codable, Sendable, Equatable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct TranslationSegment: Codable, Sendable, Equatable {
    public var id: String
    public var kind: BlockKind
    public var text: String

    public init(id: String, kind: BlockKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// 翻譯上下文：只用於理解，不得出現在輸出。每次請求範圍有界。
public struct TranslationContext: Codable, Sendable, Equatable {
    public var bookTitle: String?
    public var author: String?
    public var chapterTitle: String?
    public var precedingText: [String]
    public var glossary: [GlossaryEntry]
    public var userNotes: String?

    public init(bookTitle: String? = nil, author: String? = nil, chapterTitle: String? = nil,
                precedingText: [String] = [], glossary: [GlossaryEntry] = [], userNotes: String? = nil) {
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
        self.precedingText = precedingText
        self.glossary = glossary
        self.userNotes = userNotes
    }

    /// 限制上下文大小，避免隨閱讀進度無限累積。
    public func bounded(maxPrecedingCharacters: Int = 1200, maxGlossaryEntries: Int = 200) -> TranslationContext {
        var copy = self
        var budget = maxPrecedingCharacters
        var kept: [String] = []
        for paragraph in precedingText.reversed() {
            guard budget > 0 else { break }
            if paragraph.count <= budget {
                kept.insert(paragraph, at: 0)
                budget -= paragraph.count
            } else {
                kept.insert(String(paragraph.suffix(budget)), at: 0)
                budget = 0
            }
        }
        copy.precedingText = kept
        copy.glossary = Array(glossary.prefix(maxGlossaryEntries))
        return copy
    }
}

public struct TranslationRequest: Codable, Sendable, Equatable {
    public var segments: [TranslationSegment]
    public var context: TranslationContext
    /// BCP-47，v1 固定 zh-Hant-TW。
    public var targetLanguage: String
    /// nil = 使用引擎預設模型。
    public var model: String?
    public var customRules: String?

    public init(segments: [TranslationSegment], context: TranslationContext = TranslationContext(),
                targetLanguage: String = "zh-Hant-TW", model: String? = nil, customRules: String? = nil) {
        self.segments = segments
        self.context = context
        self.targetLanguage = targetLanguage
        self.model = model
        self.customRules = customRules
    }
}

public struct TranslatedSegment: Codable, Sendable, Equatable {
    public var id: String
    public var translation: String

    public init(id: String, translation: String) {
        self.id = id
        self.translation = translation
    }
}

public struct TranslationResponse: Codable, Sendable, Equatable {
    public var translations: [TranslatedSegment]

    public init(translations: [TranslatedSegment]) {
        self.translations = translations
    }
}

public enum EngineAvailability: Sendable, Equatable {
    case available(version: String)
    case notInstalled
    case notLoggedIn(detail: String)
    case error(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .available(let v): return CoreStrings.L("可用（\(v)）", "Available (\(v))")
        case .notInstalled: return CoreStrings.L("找不到 Codex CLI", "Codex CLI not found")
        case .notLoggedIn(let d): return CoreStrings.L("尚未登入：\(d)", "Not logged in: \(d)")
        case .error(let e): return CoreStrings.L("錯誤：\(e)", "Error: \(e)")
        }
    }
}

/// 翻譯引擎抽象。Codex CLI 是其中一個實作；測試使用 Mock。
public protocol TranslationEngine: Sendable {
    var engineID: String { get }
    func availability() async -> EngineAvailability
    func translate(_ request: TranslationRequest) async throws -> TranslationResponse
}

/// 測試與 UI 預覽用的假引擎。
public struct MockTranslationEngine: TranslationEngine {
    public let engineID = "mock"
    public var prefix: String
    public var dropIDs: Set<String>

    public init(prefix: String = "【譯】", dropIDs: Set<String> = []) {
        self.prefix = prefix
        self.dropIDs = dropIDs
    }

    public func availability() async -> EngineAvailability { .available(version: "mock") }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        TranslationResponse(translations: request.segments
            .filter { !dropIDs.contains($0.id) }
            .map { TranslatedSegment(id: $0.id, translation: prefix + $0.text) })
    }
}
