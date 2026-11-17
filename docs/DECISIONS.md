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

## v0.4 決策（2026-11-16）
- **頁面譯文疊加**：PDFView 文件視圖中每頁一層透明 NSView。PDFAnnotation 自訂繪製與 PDFPage 子類別
  `draw(with:to:)` 都不會被 PDFView 呼叫；PDFPage Swift 子類別有儲存屬性時會因 ObjC 初始化而崩潰。
- **翻書**：`CIPageCurlWithShadowTransition`，半徑 = 紙寬 × 0.22（較軟）、角度傾斜 0.18 rad（下角先翻起）。
  手勢驅動進度，放開時依進度與速度（每秒進度）決定完成或回彈；每格約 11 ms。
  往回翻以「上一頁為正面、時間反向」呈現攤平效果。雙頁模式翻動的是閱讀方向前方那張，另一側在後半段淡入。
- **簡繁轉換**：ICU `Hans-Hant`／`Hant-Hans` 只轉字形，再套用保守的台灣用語表；不送 AI。
  已是目標語言（NaturalLanguage 判斷，信心 > 0.85）的段落保留原文、不算缺譯。
- **Prompt v2**：英文指令＋目標語言參數。譯文查詢不再依 Prompt 版本過濾（舊譯文持續顯示，重新翻譯才用新版）。
- **快取鍵**：譯文與頁面完成狀態依目標語言區分；本機轉換以 engine = local 記錄。
- **介面語言**：`L(zh, en)` 雙語字串＋@Observable 的 UILanguageStore，切換即時生效；核心模組錯誤訊息用 CoreStrings。

## v0.5 決策（2026-11-17）筆記與螢光筆
- **資料**：migration v3 新增 `sticky_notes`（rect 為 JSON、可為 NULL＝無位置筆記）與 `highlights`（每行一個矩形，頁面座標）。
  舊的 `annotations` 表不用。資料只存資料庫，不寫回 PDF。
- **便利貼座標**：頁面「顯示空間」（已旋轉、原點左下、PDF 點），存收合時的大小；展開只往下長高、寬度不變。
- **便利貼視圖**：PDFView 文件視圖的子視圖（與譯文圖層同一層，但排在其上）。視圖 bounds＝未縮放的點數、frame＝縮放後大小，
  字體與版面不受縮放影響。頂端＝拖曳、左右下緣＝縮放（畫面上至少約 7 點寬）、內文交給 NSTextView（點擊即游標位置）。
  macOS 14 起視圖預設不裁切，文字視圖需 `clipsToBounds = true`。
- **編輯狀態**以控制器的 `editingNoteID` 為準：`textDidEndEditing` 送達時焦點還沒移走，用 firstResponder 判斷會算錯高度。
- **快捷鍵**：便利貼編輯中（firstResponder 是 NSText）時不攔截 C／N／方向鍵。N 以 keyCode 45 判斷。
- **螢光筆與選取反白**：不用 PDF 註解，改為每頁一層 `PageMarksView`（`compositingFilter` = 色彩增值），
  層次為 頁面 → 譯文 → 標記 → 便利貼。原因：譯文圖層不透明，PDFKit 的註解與文字選取反白都會被蓋住。
  PDF 文字層的選取在譯文蓋住該頁時也由標記圖層重畫。翻頁影像依同樣順序繪製。
- **掃描頁選字**：沒有可用文字層的頁面由閱讀器接手滑鼠拖曳，以 OCR 文字行（`TextExtractor.scanLines`，顯示空間）
  做「流式」選取（首行從起點到行尾、中間整行、末行到終點；只取同欄的行），字元位置以平均字寬對齊。
  每頁首次滑鼠經過或按下時背景辨識一次並快取；連結註解仍交給 PDFKit。
- **便利貼選項**改由右鍵（或雙擊頂端）開啟，不再顯示 ⋯ 按鈕。刪除時先移除資料再結束編輯，避免重新排版又建立視圖。
- **顏色**：便利貼 6 色預設（不提供調色盤），深色只有石墨一種；螢光筆 黃 #FFE81F、紅 #FF5C7C、藍 #45C4FF，α 0.55。

## v0.5.1 決策（2026-11-17）螢光筆跟著原文／譯文、復原
- **螢光筆錨點**（migration v4 `highlights.spans`）：記錄標在哪個區塊、哪一邊（原文／譯文）的第幾到第幾字，以及當時該區塊全文。
  畫面以 `TextFlow`（每個字元的位置）計算：譯文用與繪製相同的 CoreText 排版（`OverlayRenderer.characterRects`），
  原文用 PDF 字元位置（以 `page.selection(for:)` 取字元框；`characterBounds(at:)` 的索引在部分 PDF 會錯位）或 OCR 行。
  另一邊以 `TextCorrespondence` 換算：句數相同時逐句對應、句內按比例，否則整段按比例；英文擴到完整單字。
  舊的標記（沒有錨點）維持畫在原文位置。
- **選取**：譯文蓋住的頁面、在譯文上拖曳 → 閱讀器自己的選取（譯文）；掃描頁 → OCR 選取；其餘交給 PDFKit。
- **復原**：使用視窗的 UndoManager。便利貼的每個動作記一次（拖曳／縮放在放開時記；同一張連續改標題 1.5 秒內合併）；
  便利貼編輯中用文字框自己的 UndoManager，結束編輯時整段記成一次。螢光筆新增／改色／移除各記一次。
- **滑鼠事件改在 App 層攔截**：PDFKit 的滑鼠事件由內部文件視圖處理，PDFView 子類別的 `mouseDown` 不會被呼叫，
  導致譯文模式下 PDFKit 選到底下的原文。改用本機事件監聽：滑鼠在譯文框內（或掃描頁）時由閱讀器選取並吞掉事件；
  連點兩下選詞（到標點為止）、三下選整段。便利貼上的事件不攔截。
- **右鍵也在 App 層攔截**：PDFKit 收到右鍵會先選取游標下的原文字。滑鼠在譯文框內或掃描頁時，右鍵／⌃點按改由閱讀器
  直接彈出自己的選單（螢光筆改色／移除、新增便利貼、拷貝等），事件不交給 PDFKit。
- **側邊欄筆記卡片**（v0.5.2）：預設只顯示，按兩下才進入編輯（避免右鍵或點一下就進入輸入）；點 PDF 區域會結束側邊欄的輸入。
  排序存在 `sticky_notes.sortOrder`（migration v5）；拖曳以字串 `pdfaireader-note:<id>` 傳遞，
  卡片之間＝排序，拖到 `ReaderPDFView`（registerForDraggedTypes .string）＝放到頁面上該點。
- **輸入法組字**：NSTextView 的 `markedTextAttributes` 預設跟系統深色模式變白，改成便利貼文字色。
- 頁面上的便利貼投影改用 `NSView.shadow`（直接設在 layer 上會被 AppKit 覆蓋，看不到）。
- **效能**（v0.5.3）：文字層逐字取位置改在背景 `TextExtractor.textLayerChars` 計算（一頁可能數百毫秒，之前在主執行緒造成
  第一次拖曳便利貼卡頓）；拖曳便利貼途中不重算螢光筆圖層。
- **側邊欄**：單擊立即反應（不等雙擊判定）、雙擊編輯；點空白處或 PDF 取消選取與輸入；空白處右鍵可新增側邊欄筆記、顯示／隱藏。
  下方工具列只保留「新增筆記」與顯示／隱藏（新增頁面便利貼用工具列或頁面右鍵）。
- **頁碼一律用實際頁序**（v0.5.4）：側邊欄原本用 PDF 自帶的頁面標籤（書頁編號，例如第 12 頁標「3」），與狀態列不一致；
  改為「第 N 頁」＝實際頁序，標籤不同時附「（書頁 x）」。
- **前往並標示**：側邊欄單擊或右鍵「前往第 N 頁並標示」會翻到該頁（經 ReaderModel.goTo，處理雙頁與翻頁動畫），
  再以外框閃兩下標出便利貼或螢光筆位置。
- **拖到頁面無效的原因**（v0.5.5）：PDFView 設定文件時會重新註冊拖放類型（只剩檔案），把先前加的文字類型蓋掉。
  `ReaderPDFView.registerForDraggedTypes` 覆寫成永遠補上 `.string`，並在連結模型後再註冊一次。
- 側邊欄單擊只選取、不跳頁；「前往該筆記頁面」只在右鍵選單。標亮改為一次柔和光暈（約 1 秒淡出）。
