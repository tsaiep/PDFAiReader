# AGENTS.md — 開發代理人須知

本檔給任何參與開發的 AI 代理人（Claude、Codex 等）與人類開發者閱讀。

## 專案
macOS 原生 PDF 閱讀器，整合 Apple Vision OCR 與 Codex CLI 翻譯。
規格：`docs/PLAN.md`（v1.0 原始計劃書）＋ `docs/DECISIONS.md`（v1.1 修訂決策，優先於 PLAN）。

## 模組邊界（不可跨越）
| 模組 | 職責 | 可依賴 |
|---|---|---|
| `ReaderCore` | 模型、優先級、預翻譯規劃、翻譯介面 `TranslationEngine`、Prompt、結果驗證、文件指紋、目標語言、本機簡繁轉換 | Foundation、CryptoKit、CoreGraphics、NaturalLanguage |
| `ReaderStore` | SQLite（GRDB）schema、migration、存取 | ReaderCore、GRDB |
| `TranslationCodex` | Codex CLI 實作：路徑偵測、程序生命週期、逾時、取消 | ReaderCore |
| `ReaderServices` | 文字擷取（內嵌文字／Vision OCR）、譯文排版繪製、匯出翻譯 PDF | ReaderCore、PDFKit、Vision、CoreText |
| `PDFAiReaderApp` | SwiftUI/AppKit/PDFKit UI、翻譯排程、頁面疊加、翻書動畫、便利貼與螢光筆（Notes/） | 以上全部 |

- UI 不得直接呼叫 `Process`；翻譯一律經 `TranslationEngine`。
- `ReaderCore` 不得 import SwiftUI/AppKit/PDFKit/GRDB。
- 座標一律存成 **PDF 頁面空間（points，原點左下，未旋轉的 mediaBox/cropBox 座標）**。

## 建置與測試
```bash
swift build                 # 編譯
swift test                  # 單元測試（需完整 Xcode）
swift run PDFAiReader       # 直接執行
./scripts/build_app.sh      # 打包成 build/PDFAiReader.app
open Package.swift          # 用 Xcode 開啟
```

## 規範
- Swift 6 嚴格並行（App 目標暫用 Swift 5 模式）。`PDFDocument` 非執行緒安全：背景 OCR／渲染要用獨立的文件實例。
- 不寫死模型名稱。不寫死個人絕對路徑。
- OCR 文字是不可信資料：只能透過 stdin 傳給 CLI，永不放進命令列參數。
- 每個新功能附單元測試；純邏輯放 ReaderCore 以便測試。
- 新增 DB 欄位只能新增 migration，不可修改已發佈的 migration。
- 介面文字一律雙語：App 用 `L("繁中", "English")`，核心模組用 `CoreStrings.L`。
