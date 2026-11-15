# 開發決策紀錄（v1.1）

整合 v1.0 計劃書與審閱意見。本檔與 PLAN.md 衝突時以本檔為準。

## D1. 新增 Phase 0：Codex CLI 可行性測試
在寫翻譯 UI 前先執行 `scripts/phase0_codex_probe.sh`，量測：
- 單次呼叫啟動時間、單頁翻譯延遲
- `--output-schema` 是否穩定回傳合法 JSON
- CLI 能否列出模型（不能 → 模型清單改為「手動輸入＋測試驗證」）
- 額度消耗；連續翻譯是否觸發限制
- 使用條款（以 ChatGPT 訂閱大量翻譯是否允許）由使用者自行確認

結果寫入 `docs/phase0-results/`，並據此設定批次大小與預翻頁數 N 的預設值。

## D2. 翻譯引擎抽象
`ReaderCore.TranslationEngine` 從第一天存在。Codex 是第一個實作；測試使用 Mock。

## D3. 發佈與執行環境
- **不開 App Sandbox、不上 Mac App Store**，以 Developer ID 簽章＋公證發佈。
- GUI App 拿不到 shell PATH：`CodexLocator` 依序檢查使用者指定路徑、Homebrew、npm global、nvm、volta，最後用登入 shell `command -v codex`。啟動 codex 時補上 PATH（npm 版 codex 需要 node）。
- 安全：OCR 文字經 stdin 傳入；CLI 工作目錄為空的暫存資料夾；`--sandbox read-only`；`--skip-git-repo-check`。

## D4. 統一處理管線
OCR → 版面分析 → 翻譯 為同一條有依賴關係的管線，OCR 也依可見頁／預讀頁／背景排優先級。

## D5. 雙通道排程
- 互動通道（選取文字）保留 1 個名額
- 背景通道（可見頁、預翻、整書）1 個名額

## D6. 名稱與範圍
- 任務優先級：`interactive / visible / prefetch / background`（避免和功能 P0–P2 撞名）
- v1 目標語言只做**繁體中文（台灣）**；Prompt 已模板化，日後可擴充
- 術語表 v1 手動維護
- 版面分析 v1 只保證單欄與標準雙欄；不規則藝術書排版列為後續
- OCR 文字選取需自建透明 overlay（PDFKit 不會自動提供），估時另計

## D7. 識別與座標
- 文件 ID = 檔案大小 + 頭尾各 1MB 的 SHA-256（快速指紋），搭配 macOS bookmark 追蹤搬移
- 座標一律存頁面空間；Vision 正規化座標（原點左下）需經 cropBox 與旋轉換算，並有單元測試

## D8. 結果驗證
回傳區塊 ID 必須與送出完全一致（不缺、不多、不重複、不為空）；部分失敗只重試缺少的區塊。

## D9. 預翻譯方向
依最近翻頁方向決定往前或往後 N 頁；捲動事件 debounce 約 400ms。

## D10. 隱私
首次使用翻譯時明確告知：OCR 文字會送到 OpenAI（經 Codex CLI）處理。書頁影像不上傳。

## D11. 驗收量化（初版目標，Phase 0/1 後校正）
- 300 頁掃描 PDF 開啟後 2 秒內顯示第一頁
- OCR 進行中翻頁不卡頓；記憶體 < 1.5 GB
- 單頁 OCR（Apple Silicon、Accurate）< 3 秒
- 標準雙欄頁閱讀順序正確率 ≥ 95%（測試集）

## D12. 技術選型
- SQLite：GRDB.swift 7
- 專案格式：Swift Package（Xcode 可直接開啟 Package.swift）；`scripts/build_app.sh` 打包成 .app。日後需要簽章／Info.plist 細節時再改用 XcodeGen 產生 .xcodeproj
- 最低系統：macOS 14
- 大型文件效能列入 Phase 1 驗收

## Phase 0 結果（2026-11-15）
環境：macOS 26.3、Xcode 16.4、Swift 6.1.2、codex-cli 0.169.0（Homebrew）、預設模型取自 `~/.codex/config.toml`。
詳細報告：`docs/phase0-results/`。

| 設定 | 每頁秒數（5 區塊） | tokens／次 | JSON 合法 | 區塊 ID 正確 | 注入防護 |
|---|---|---|---|---|---|
| 預設推理強度 | 15.3／16.5／18.1 | ~17,200 | 3/3 | 3/3 | 3/3 |
| `model_reasoning_effort="low"` | 11.7／12.1／11.3 | ~17,600 | 3/3 | 3/3 | 3/3 |

結論：
- `--output-schema`＋`--output-last-message`＋stdin 的組合可行且穩定；`--ephemeral` 可用。
- **每次呼叫固定約 1.7 萬 tokens，主要是 Codex Agent 自身開銷**，實際翻譯內容只佔一小部分。
  → 批次應盡量大：預設每次送 2–4 頁（或約 6,000 字元），再用 Phase 0 第二輪實測調整。
- 300 頁書以單頁批次估計：約 1 小時、約 500 萬 tokens；改成 3 頁一批可降到約 1/3。
- CLI 沒有列出模型的指令 → **模型清單改為手動輸入＋「測試模型」按鈕驗證**（D-3.2 修正）。
- 使用者的 config.toml 中的 MCP 伺服器會被 codex exec 載入（`-c mcp_servers={}` 無法關閉）；
  不影響結果，但增加啟動時間與錯誤 log。後續研究以獨立 profile 隔離。
- 預設引擎參數：`--ephemeral`、`-c model_reasoning_effort="low"`。
- 待使用者確認：用量頁面上的額度消耗、使用條款。
