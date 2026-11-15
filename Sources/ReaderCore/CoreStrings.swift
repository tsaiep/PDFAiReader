import Foundation

/// 核心模組的雙語錯誤訊息。介面語言由 App 設定。
public enum CoreStrings {
    nonisolated(unsafe) public static var isEnglish = false

    public static func L(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}
