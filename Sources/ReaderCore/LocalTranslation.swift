import Foundation
import NaturalLanguage

/// 不需要（或不該）交給 AI 的翻譯：簡繁互轉只轉字形、已是目標語言就保留原文。
public enum LocalTranslation: Equatable, Sendable {
    /// 本機轉換結果（簡↔繁）
    case convert(String)
    /// 原文已是目標語言，不需翻譯（頁面上保留原文）
    case keepOriginal
    /// 交給翻譯引擎
    case useEngine

    public static func decide(text: String, target: TargetLanguage) -> LocalTranslation {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .keepOriginal }

        if ChineseText.isMostlyHan(t) {
            switch target {
            case .zhHantTW:
                let converted = ChineseText.toTraditionalTaiwan(t)
                return converted == t ? .keepOriginal : .convert(converted)
            case .zhHans:
                let converted = ChineseText.toSimplified(t)
                return converted == t ? .keepOriginal : .convert(converted)
            default:
                return .useEngine
            }
        }
        // 非中文：判斷是否已是目標語言（例如英文書選英文）
        if !target.isChinese, t.count >= 12 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(t)
            if let lang = recognizer.dominantLanguage,
               let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang],
               lang.rawValue.hasPrefix(target.languageCode), confidence > 0.85 {
                return .keepOriginal
            }
        }
        return .useEngine
    }
}

/// 中文字形處理。簡繁轉換使用 ICU（只轉字形，不重組句子），台灣用語只替換明確的兩岸差異詞。
public enum ChineseText {
    public static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF: return true
        default: return false
        }
    }

    /// 字母類字元中漢字佔一半以上。
    public static func isMostlyHan(_ text: String) -> Bool {
        var han = 0, letters = 0
        for s in text.unicodeScalars where CharacterSet.letters.contains(s) {
            letters += 1
            if isHan(s) { han += 1 }
        }
        return letters > 0 && han * 2 >= letters
    }

    public static func toTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? text
    }

    public static func toSimplified(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? text
    }

    /// 簡轉繁後，只替換兩岸明確不同、且不易誤判的詞彙。
    public static func toTraditionalTaiwan(_ text: String) -> String {
        var s = toTraditional(text)
        // 只有原文是簡體（轉換後有變化）才套用用語表，避免改動原本就是繁體的文字
        guard s != text else { return text }
        for (from, to) in taiwanTerms where s.contains(from) {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    /// 依長度由長到短排列，避免短詞先替換破壞長詞。
    static let taiwanTerms: [(String, String)] = [
        ("互聯網", "網際網路"), ("數據庫", "資料庫"), ("文件夾", "資料夾"), ("打印機", "印表機"),
        ("服務器", "伺服器"), ("程序員", "程式設計師"), ("出租車", "計程車"), ("公交車", "公車"),
        ("軟件", "軟體"), ("硬件", "硬體"), ("網絡", "網路"), ("鼠標", "滑鼠"), ("屏幕", "螢幕"),
        ("打印", "列印"), ("硬盤", "硬碟"), ("內存", "記憶體"), ("默認", "預設"), ("激光", "雷射"),
        ("短信", "簡訊"), ("視頻", "影片"), ("博客", "部落格"), ("鏈接", "連結"), ("菜單", "選單"),
        ("U盤", "隨身碟"), ("優盤", "隨身碟"), ("數碼", "數位"), ("模擬信號", "類比訊號"),
    ].sorted { $0.0.count > $1.0.count }
}
