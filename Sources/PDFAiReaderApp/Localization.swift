import SwiftUI
import ReaderCore

/// 介面語言。翻譯目標語言是另一個設定（TargetLanguage）。
enum UILanguage: String, CaseIterable, Identifiable {
    case zhHant = "zh-Hant"
    case en = "en"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .zhHant: return "繁體中文"
        case .en: return "English"
        }
    }
}

/// 目前介面語言。SwiftUI 在 body 中讀取 `language` 時會自動追蹤，切換後畫面即時更新。
@Observable
final class UILanguageStore {
    static let shared = UILanguageStore()

    var language: UILanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "uiLanguage")
            CoreStrings.isEnglish = (language == .en)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "uiLanguage"), let l = UILanguage(rawValue: raw) {
            language = l
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            language = preferred.hasPrefix("zh") ? .zhHant : .en
        }
        CoreStrings.isEnglish = (language == .en)
    }
}

/// 雙語字串：`L("翻譯", "Translate")`。
func L(_ zh: String, _ en: String) -> String {
    UILanguageStore.shared.language == .en ? en : zh
}

/// 使用者偏好（UserDefaults）。
enum Prefs {
    static var targetLanguage: TargetLanguage {
        get { TargetLanguage(rawValue: UserDefaults.standard.string(forKey: "targetLanguage") ?? "") ?? .zhHantTW }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "targetLanguage") }
    }

    /// 某目標語言使用的譯文字體（未設定或未安裝時使用該語言的預設字體）。
    static func fontFamily(for language: TargetLanguage) -> String {
        let stored = UserDefaults.standard.string(forKey: "translationFont.\(language.rawValue)")
        let installed = installedFontChoices(for: language).map(\.family)
        if let stored, installed.contains(stored) { return stored }
        return installed.first ?? language.defaultFont
    }

    static func setFontFamily(_ family: String, for language: TargetLanguage) {
        UserDefaults.standard.set(family, forKey: "translationFont.\(language.rawValue)")
    }

    static func installedFontChoices(for language: TargetLanguage) -> [FontChoice] {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        let available = language.fontChoices.filter { families.contains($0.family) }
        return available.isEmpty ? [language.fontChoices[0]] : available
    }
}

extension FontChoice {
    var localizedName: String { UILanguageStore.shared.language == .en ? enName : zhName }
}

extension TargetLanguage {
    /// 選單中的名稱：以介面語言加註原文名稱。
    var menuName: String {
        guard UILanguageStore.shared.language == .en else { return nativeName }
        switch self {
        case .zhHantTW: return "Traditional Chinese (Taiwan)"
        case .zhHans: return "Simplified Chinese"
        case .en: return "English"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .fr: return "French"
        case .de: return "German"
        case .es: return "Spanish"
        }
    }
}

extension Notification.Name {
    /// 目標語言、字體或模型改變。
    static let translationSettingsChanged = Notification.Name("PDFAiReader.translationSettingsChanged")
}
