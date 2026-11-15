import Foundation

/// 翻譯快取鍵：任一欄位改變，舊譯文即視為不同版本。
public struct TranslationCacheKey: Sendable, Hashable, Codable {
    public var engine: String
    public var model: String
    public var targetLanguage: String
    public var promptVersion: String
    public var contextVersion: String

    public init(engine: String, model: String?, targetLanguage: String = "zh-Hant-TW",
                promptVersion: String = TranslationPrompt.version, contextVersion: String = "v1") {
        self.engine = engine
        self.model = (model?.isEmpty == false ? model! : "default")
        self.targetLanguage = targetLanguage
        self.promptVersion = promptVersion
        self.contextVersion = contextVersion
    }

    /// 存進資料庫用的單一字串。
    public var fingerprint: String {
        [engine, model, targetLanguage, promptVersion, contextVersion].joined(separator: "|")
    }
}

/// 將待翻譯頁面合併成批次。Phase 0 顯示每次呼叫有約 1.7 萬 tokens 的固定開銷，
/// 因此在字數上限內盡量把相鄰頁合併成一次呼叫。
public struct TranslationBatcher: Sendable {
    public var maxCharacters: Int
    public var maxPages: Int

    public init(maxCharacters: Int = 6000, maxPages: Int = 3) {
        self.maxCharacters = maxCharacters
        self.maxPages = maxPages
    }

    /// - Parameters:
    ///   - first: 優先處理的頁（一定包含）
    ///   - candidates: 其他排隊中的頁，依偏好順序
    ///   - characterCount: 取得某頁待翻譯字數
    /// - Returns: 本批要處理的頁（依頁碼排序）
    public func batch(first: Int, candidates: [Int], characterCount: (Int) -> Int) -> [Int] {
        var pages = [first]
        var total = characterCount(first)
        // 只合併與目前批次相鄰的頁，維持上下文連貫
        var changed = true
        while changed && pages.count < maxPages {
            changed = false
            let lo = pages.min()!, hi = pages.max()!
            for c in candidates where !pages.contains(c) && (c == hi + 1 || c == lo - 1) {
                let n = characterCount(c)
                if total + n <= maxCharacters || total == 0 {
                    pages.append(c)
                    total += n
                    changed = true
                    break
                }
            }
        }
        return pages.sorted()
    }
}
