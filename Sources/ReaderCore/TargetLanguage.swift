import Foundation

/// 翻譯目標語言。rawValue 為 BCP-47，存入資料庫作為快取鍵的一部分。
public enum TargetLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case zhHantTW = "zh-Hant-TW"
    case zhHans = "zh-Hans"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case de = "de"
    case es = "es"

    public var id: String { rawValue }

    /// 以該語言本身書寫的名稱（選單顯示用）。
    public var nativeName: String {
        switch self {
        case .zhHantTW: return "繁體中文（台灣）"
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        }
    }

    /// 給模型看的語言描述與風格要求。
    public var promptDescription: String {
        switch self {
        case .zhHantTW: return "Traditional Chinese (繁體中文) using vocabulary and phrasing common in Taiwan"
        case .zhHans: return "Simplified Chinese (简体中文) using vocabulary common in mainland China"
        case .en: return "English"
        case .ja: return "Japanese (日本語)"
        case .ko: return "Korean (한국어)"
        case .fr: return "French (français)"
        case .de: return "German (Deutsch)"
        case .es: return "Spanish (español)"
        }
    }

    /// NaturalLanguage 的語言代碼（判斷原文是否已是目標語言）。
    public var languageCode: String {
        switch self {
        case .zhHantTW: return "zh-Hant"
        case .zhHans: return "zh-Hans"
        default: return rawValue
        }
    }

    public var isChinese: Bool { self == .zhHantTW || self == .zhHans }

    /// 可選的譯文字體（實際顯示時再過濾掉未安裝的）。第一個為預設。
    public var fontChoices: [FontChoice] {
        switch self {
        case .zhHantTW:
            return [.init("PingFang TC", "蘋方", "PingFang"), .init("Songti TC", "宋體", "Songti"),
                    .init("Heiti TC", "黑體", "Heiti"), .init("Kaiti TC", "楷體", "Kaiti"),
                    .init("Yuanti TC", "圓體", "Yuanti"), .init("Lantinghei TC", "蘭亭黑", "Lantinghei")]
        case .zhHans:
            return [.init("PingFang SC", "苹方", "PingFang"), .init("Songti SC", "宋体", "Songti"),
                    .init("Heiti SC", "黑体", "Heiti"), .init("Kaiti SC", "楷体", "Kaiti"),
                    .init("Yuanti SC", "圆体", "Yuanti"), .init("Lantinghei SC", "兰亭黑", "Lantinghei")]
        case .ja:
            return [.init("Hiragino Sans", "ヒラギノ角ゴ", "Hiragino Sans"),
                    .init("Hiragino Mincho ProN", "ヒラギノ明朝", "Hiragino Mincho"),
                    .init("Hiragino Maru Gothic ProN", "ヒラギノ丸ゴ", "Hiragino Maru Gothic"),
                    .init("Klee", "クレー", "Klee")]
        case .ko:
            return [.init("Apple SD Gothic Neo", "애플 SD 산돌고딕 Neo", "Apple SD Gothic Neo"),
                    .init("AppleMyungjo", "애플명조", "AppleMyungjo"), .init("Nanum Myeongjo", "나눔명조", "Nanum Myeongjo")]
        default:
            return [.init("Helvetica Neue", "Helvetica Neue", "Helvetica Neue"), .init("Avenir Next", "Avenir Next", "Avenir Next"),
                    .init("Georgia", "Georgia", "Georgia"), .init("Palatino", "Palatino", "Palatino"),
                    .init("Baskerville", "Baskerville", "Baskerville"), .init("Times New Roman", "Times New Roman", "Times New Roman")]
        }
    }

    public var defaultFont: String { fontChoices[0].family }
}

public struct FontChoice: Sendable, Hashable, Identifiable {
    public var family: String
    public var zhName: String
    public var enName: String
    public var id: String { family }

    public init(_ family: String, _ zhName: String, _ enName: String) {
        self.family = family
        self.zhName = zhName
        self.enName = enName
    }
}
