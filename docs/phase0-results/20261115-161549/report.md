# Phase 0 Codex CLI 測試 — 2026-11-15 16:15

- codex 路徑：`/opt/homebrew/bin/codex`
- 版本：`codex-cli 0.169.0`
- 登入狀態（rc=0）：`Logged in using ChatGPT`
- macOS：`26.3`，晶片：`arm64`

## 1. CLI 啟動時間
`codex --version`：0.03 秒

## 2. 模型清單
`codex exec --help` 中的模型相關說明：
```
  -m, --model <MODEL>
  -s, --sandbox <SANDBOX_MODE>
      --skip-git-repo-check
          outside the sandbox. Persists even with --ephemeral. Does not override
      --ephemeral
      --output-schema <FILE>
      --json
  -o, --output-last-message <FILE>
```
config.toml 中的 model 設定：`model = "gpt-6.1-sol"`
（CLI 若沒有列出模型的指令 → App 改用手動輸入＋測試驗證）

## 3. 單頁翻譯（5 個區塊、約 1 頁）× 3 次

| # | 秒數 | 結束碼 | JSON 合法 | 區塊數正確 | 注入防護 |
|---|---|---|---|---|---|
