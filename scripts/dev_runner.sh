#!/bin/bash
# 開發用建置小幫手：讓 AI 代理人透過「請求檔」觸發固定的建置動作，並讀回 log。
#
# 安全設計：只接受下列白名單動作，請求檔內容不會被當成指令執行。
#   build   → swift build
#   test    → swift test
#   app     → ./scripts/build_app.sh debug，然後開啟 App
#   run     → 開啟已打包的 build/PDFAiReader.app
#   quit    → 關閉執行中的 App
#   phase0  → ./scripts/phase0_codex_probe.sh
#   env     → 顯示 Xcode／Swift／codex 環境資訊
#
# 用法：在 Terminal 執行  ./scripts/dev_runner.sh   （Ctrl+C 結束）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQ="$ROOT/.dev/requests"
LOG="$ROOT/.dev/logs"
mkdir -p "$REQ" "$LOG"
cd "$ROOT"

# GUI 以外啟動時也要找得到 Homebrew / npm 的工具
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$PATH"

echo "dev_runner 啟動：${ROOT}"
echo "等待請求中…（Ctrl+C 結束）"

run_action() {
  local action="$1"
  case "$action" in
    build)  swift build 2>&1 ;;
    test)   swift test 2>&1 ;;
    app)    ./scripts/build_app.sh debug 2>&1 && { pkill -x PDFAiReader 2>/dev/null; sleep 0.5; open "$ROOT/build/PDFAiReader.app"; echo "已開啟 App"; } ;;
    run)    open "$ROOT/build/PDFAiReader.app" 2>&1 && echo "已開啟 App" ;;
    quit)   pkill -x PDFAiReader 2>&1; echo "已關閉 App" ;;
    phase0) ./scripts/phase0_codex_probe.sh 2>&1 ;;
    env)
      sw_vers 2>&1; uname -m
      echo "--- xcode-select"; xcode-select -p 2>&1
      echo "--- xcodebuild"; xcodebuild -version 2>&1 | head -2
      echo "--- swift"; swift --version 2>&1 | head -2
      echo "--- brew"; command -v brew 2>&1
      echo "--- node"; command -v node 2>&1 && node --version 2>&1
      echo "--- codex"; command -v codex 2>&1 && codex --version 2>&1 ;;
    *) echo "未知動作：${action} (只接受 build/test/app/run/quit/phase0/env)"; return 2 ;;
  esac
}

while true; do
  for f in "$REQ"/*.req; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .req)"
    action="$(head -1 "$f" | tr -cd 'a-z0-9')"
    mv "$f" "$LOG/$id.req.taken" 2>/dev/null || continue
    echo "[$(date +%H:%M:%S)] ${id} → ${action}"
    start=$(date +%s)
    run_action "$action" > "$LOG/$id.log" 2>&1
    rc=$?
    end=$(date +%s)
    echo "exit=${rc} seconds=$((end-start))" > "${LOG}/${id}.done"
    echo "[$(date +%H:%M:%S)] ${id} 完成 exit=${rc} (${start:+$((end-start))} 秒)"
  done
  sleep 1
done
