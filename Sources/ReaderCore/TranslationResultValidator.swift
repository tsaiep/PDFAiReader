import Foundation

public struct ValidationOutcome: Sendable, Equatable {
    /// 通過驗證、可寫入快取的譯文（依請求順序）。
    public var accepted: [TranslatedSegment]
    /// 請求中有、回應中缺少或為空 → 需重試。
    public var missingIDs: [String]
    /// 回應中出現、請求中沒有 → 丟棄。
    public var unexpectedIDs: [String]
    /// 回應中重複的 ID → 取第一個，記錄下來。
    public var duplicateIDs: [String]

    public var isComplete: Bool { missingIDs.isEmpty }
}

public enum TranslationResultValidator {
    public static func validate(request: TranslationRequest, response: TranslationResponse) -> ValidationOutcome {
        let requestedIDs = request.segments.map(\.id)
        let requestedSet = Set(requestedIDs)

        var firstByID: [String: TranslatedSegment] = [:]
        var duplicates: [String] = []
        var unexpected: [String] = []

        for item in response.translations {
            guard requestedSet.contains(item.id) else {
                if !unexpected.contains(item.id) { unexpected.append(item.id) }
                continue
            }
            if firstByID[item.id] != nil {
                if !duplicates.contains(item.id) { duplicates.append(item.id) }
                continue
            }
            firstByID[item.id] = item
        }

        var accepted: [TranslatedSegment] = []
        var missing: [String] = []
        for id in requestedIDs {
            if let item = firstByID[id],
               !item.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accepted.append(item)
            } else {
                missing.append(id)
            }
        }
        return ValidationOutcome(accepted: accepted, missingIDs: missing,
                                 unexpectedIDs: unexpected, duplicateIDs: duplicates)
    }

    /// 解析模型輸出：容忍外層 ``` 圍欄與前後空白。
    public static func decode(_ raw: String) throws -> TranslationResponse {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8) else {
            throw TranslationDecodeError.notUTF8
        }
        do {
            return try JSONDecoder().decode(TranslationResponse.self, from: data)
        } catch {
            throw TranslationDecodeError.invalidJSON(String(text.prefix(500)))
        }
    }
}

public enum TranslationDecodeError: Error, Equatable, LocalizedError {
    case notUTF8
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .notUTF8: return "輸出不是 UTF-8"
        case .invalidJSON(let s): return "輸出不是合法 JSON：\(s)"
        }
    }
}
