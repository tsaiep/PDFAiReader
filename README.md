# AI PDF Reader

macOS 原生 PDF 閱讀器，能把 PDF 內容直接翻譯並疊在原頁面上，保留原本排版。

- **翻譯**：譯文疊在頁面上，按 **C** 切換原文／譯文；可整份翻譯、匯出翻譯版 PDF
- **掃描檔也能用**：沒有文字層的頁面會用 Apple Vision 在本機 OCR
- **目標語言**：繁中（台灣）、简中、English、日本語、한국어、Français、Deutsch、Español；簡繁互轉在本機完成，不耗 AI 額度
- **閱讀**：單頁／雙頁書本模式／連續捲動，翻書動畫、觸控板手勢
- **筆記**：便利貼、螢光筆（譯文和原文上的標記會互相對應）

## 系統需求

| 項目 | 需求 |
|---|---|
| 系統 | macOS 15 (Sequoia) 以上，Apple Silicon 或 Intel 皆可 |
| 編譯工具 | Xcode 16 以上（從 App Store 安裝） |
| 翻譯功能 | Codex CLI，並登入 ChatGPT 帳號（只看 PDF 不需要） |

## 安裝

### 1. 安裝 Xcode

從 App Store 安裝 Xcode，安裝完先打開一次，同意授權條款。

### 2. 下載並安裝

打開「終端機」，貼上：

```bash
git clone https://github.com/tsaiep/PDFAiReader.git
cd PDFAiReader
./scripts/install.sh
```

腳本會編譯 app、安裝到你的「應用程式」資料夾（`~/Applications`），然後自動打開。第一次編譯要下載相依套件，大約 1–3 分鐘。

之後在 Launchpad 或 Spotlight 搜尋「AI PDF Reader」就能開啟。想用它當預設 PDF 閱讀器：在 Finder 對任一 PDF 按右鍵 →「取得資訊」→「打開檔案的應用程式」選 AI PDF Reader →「全部更改」。

### 3. 設定翻譯功能

翻譯透過 [Codex CLI](https://github.com/openai/codex) 呼叫 AI，使用的是**你自己的** ChatGPT 帳號額度。

```bash
brew install codex          # 有 Homebrew 的話
# 或：npm install -g @openai/codex

codex login                 # 會開瀏覽器，登入 ChatGPT 帳號
```

登入後重新開啟 app 就能翻譯。app 會自動找 Codex 的位置；如果找不到，到「設定 → 翻譯」的「Codex 路徑」手動填入（在終端機執行 `which codex` 可查到路徑）。

## 更新到新版

```bash
cd PDFAiReader
git pull
./scripts/install.sh
```

閱讀進度、筆記和已翻譯的內容都會保留。

## 常見問題

**`./scripts/install.sh` 顯示 permission denied**
執行 `chmod +x scripts/*.sh` 再試一次。

**編譯錯誤：`xcrun: error: unable to find utility` 或找不到 SDK**
執行 `sudo xcode-select -s /Applications/Xcode.app`，讓系統使用完整的 Xcode。

**翻譯一直失敗**
先在終端機執行 `codex login status` 確認已登入，並確認帳號還有額度。

**資料存在哪裡？**
`~/Library/Application Support/PDFAiReader/`。便利貼與螢光筆存在這裡，不會修改原本的 PDF 檔。要完全移除 app，刪掉 `~/Applications/PDFAiReader.app` 和這個資料夾即可。

## 已知限制

- 有密碼的 PDF 尚不支援
- 匯出的翻譯 PDF 不含便利貼與螢光筆
- 掃描頁的選字位置是依 OCR 結果估計，可能略有偏移

## 開發

```bash
swift run PDFAiReader        # 直接執行（開發用）
./scripts/build_app.sh       # 只打包成 build/PDFAiReader.app，不安裝
open Package.swift           # 用 Xcode 開啟
swift test                   # 單元測試
```

- 規格：[docs/PLAN.md](docs/PLAN.md)；修訂決策（優先）：[docs/DECISIONS.md](docs/DECISIONS.md)
- 更新紀錄：[docs/CHANGELOG.md](docs/CHANGELOG.md)
- 開發代理人須知：[AGENTS.md](AGENTS.md)
