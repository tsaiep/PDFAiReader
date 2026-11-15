# AI PDF Reader

macOS 原生 PDF 閱讀器，整合 Apple Vision OCR 與 Codex CLI 翻譯。

- 規格：[docs/PLAN.md](docs/PLAN.md)
- 修訂決策（優先）：[docs/DECISIONS.md](docs/DECISIONS.md)
- 開發代理人須知：[AGENTS.md](AGENTS.md)

## 需求
- macOS 14 以上、Apple Silicon 或 Intel
- Xcode 16 以上（或 Command Line Tools 中的 Swift 6）
- 翻譯功能：Codex CLI（`brew install codex` 或 `npm install -g @openai/codex`），並執行 `codex login`

## 執行
```bash
swift run PDFAiReader            # 開發時直接執行
./scripts/build_app.sh           # 打包成 build/PDFAiReader.app
open build/PDFAiReader.app
open Package.swift               # 用 Xcode 開啟並編輯
swift test                       # 單元測試
```

## 進度
| 階段 | 狀態 |
|---|---|
| Phase 0：Codex CLI 可行性測試 | 腳本完成：`scripts/phase0_codex_probe.sh` |
| Phase 1：PDF 閱讀器 | 開發中 |
| Phase 2：OCR 與文字結構 | 未開始 |
| Phase 3：Codex 翻譯 | 引擎介面與 Codex Adapter 已完成，UI 未開始 |
| Phase 4：預翻譯與整書任務 | 預翻譯規劃器已完成，排程器未開始 |

## Phase 1 已完成功能
- 開啟 PDF：選單、拖放、最近開啟、Finder「打開方式」（.app 版本）
- 單頁／雙頁（書本模式）／連續捲動，左至右／右至左
- 放大縮小、符合頁寬、符合視窗、實際大小、指定比例
- 頁碼輸入、上下頁、首頁末頁
- 側邊欄：縮圖、目錄（PDF 大綱）、書籤、搜尋（內嵌文字）
- 自動保存閱讀進度（頁碼、縮放、顯示模式）
- 檔案搬移／重新命名後仍可找回（快速指紋＋macOS bookmark）

## v0.4 更新
- 翻頁：單頁／雙頁模式下 ← → ↑ ↓、空白鍵、Page Up/Down、觸控板雙指上下左右滑動，一律左右翻書；
  翻書效果為柔軟的頁面捲曲（Core Image），跟手即時，放開後完成或回彈。連續模式維持上下捲動
- 工具列「原文／譯文」按鈕會顯示目前狀態；單鍵 **T** 切換（⌘Y 亦可），按住 ⌥ 暫看原文
- 目標語言可選：繁中（台灣）、简中、English、日本語、한국어、Français、Deutsch、Español
- 簡↔繁在本機轉換字形，只替換明確的兩岸用語，不改句構、不消耗額度；已是目標語言的段落保留原文
- 譯文字體可選（依目標語言列出已安裝字體）；畫面與匯出 PDF 共用
- 介面語言：繁體中文／English（設定 → 一般）
- 縮圖欄標記每頁翻譯狀態：✓ 已翻譯、轉圈 翻譯中、時鐘 排隊中、! 失敗

## 翻譯功能（v0.3）
- 工具列中央「原文｜譯文」：譯文直接疊在 PDF 頁面上、保留排版（⌘Y 切換；按住 ⌥ 暫看原文）
- 模型選單：翻譯側欄右上、工具列「翻譯」選單、設定 → 翻譯；可新增並測試自訂模型、選擇速度／品質
- 翻頁動畫：翻書（預設）／滑動／無，設定 → 閱讀；觸控板左右滑動翻頁；連續模式 ← → 平滑捲動

## 翻譯功能（v0.2）
- 工具列「翻譯」按鈕：按一下開關翻譯面板，箭頭開啟選單
- 翻譯面板：「翻譯此頁」、「自動翻譯＋N 頁」開關、譯文／對照切換；點段落會在頁面上標示位置
- 選取文字 → 右鍵「翻譯選取文字」或 ⌘E
- 整份翻譯（⇧⌘T）：可指定範圍、暫停／繼續／取消，重新開啟後可繼續
- 匯出翻譯 PDF（⇧⌘E）：原位翻譯／原頁＋譯文頁對照／純譯文
- 翻頁：單頁／雙頁模式支援 ← → 空白鍵翻頁與推移動畫，背景預先渲染前後頁

## 端到端測試（會消耗 Codex 額度）
`touch .dev/e2e-enabled && swift test --filter PipelineE2ETests`，報告與匯出檔在 `.dev/artifacts/`。

## 資料位置
`~/Library/Application Support/PDFAiReader/reader.sqlite`

## 已知限制
- 掃描 PDF 的文字選取與搜尋要等 Phase 2（OCR）
- 有密碼的 PDF 尚不支援
