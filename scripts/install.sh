#!/bin/bash
# 編譯 AI PDF Reader 並安裝到 ~/Applications
# 用法：./scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 檢查環境
if [[ "$(uname)" != "Darwin" ]]; then
  echo "錯誤：這個 app 只能在 macOS 上執行。" >&2; exit 1
fi
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MAJOR < 15 )); then
  echo "錯誤：需要 macOS 15 以上（目前是 $(sw_vers -productVersion)）。" >&2; exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "錯誤：找不到 swift。請先安裝 Xcode（App Store）或執行 xcode-select --install。" >&2; exit 1
fi

echo "→ 編譯中（第一次會下載相依套件，約需 1–3 分鐘）…"
./scripts/build_app.sh release

DEST="$HOME/Applications"
mkdir -p "$DEST"
if [[ -d "$DEST/PDFAiReader.app" ]]; then
  echo "→ 移除舊版"
  mv "$DEST/PDFAiReader.app" "$(mktemp -d)/"
fi
cp -R build/PDFAiReader.app "$DEST/"
echo "✓ 已安裝到 $DEST/PDFAiReader.app"

if ! command -v codex >/dev/null 2>&1; then
  echo
  echo "提醒：沒有偵測到 Codex CLI，閱讀功能可正常使用，但無法翻譯。"
  echo "      安裝方式見 README 的「設定翻譯功能」。"
fi

open "$DEST/PDFAiReader.app"
