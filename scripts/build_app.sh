#!/bin/bash
# 編譯並打包成 build/PDFAiReader.app
# 用法：./scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product PDFAiReader
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PDFAiReader"

APP="$ROOT/build/PDFAiReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PDFAiReader"

VERSION="0.1.0"
BUILD="$(date +%Y%m%d%H%M)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AI PDF Reader</string>
    <key>CFBundleDisplayName</key><string>AI PDF Reader</string>
    <key>CFBundleIdentifier</key><string>local.pdfaireader.app</string>
    <key>CFBundleExecutable</key><string>PDFAiReader</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 本機 ad-hoc 簽章（正式發佈需改用 Developer ID + 公證）
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "警告：ad-hoc 簽章失敗（不影響本機執行）"

echo "完成：$APP"
