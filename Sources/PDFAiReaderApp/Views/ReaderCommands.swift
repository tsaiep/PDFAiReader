import SwiftUI
import ReaderCore

struct ReaderCommands: Commands {
    let app: AppModel

    var body: some Commands {
        // 讀取介面語言，切換後選單即時更新
        let _ = UILanguageStore.shared.language

        CommandGroup(replacing: .newItem) {
            Button(L("開啟…", "Open…")) { app.presentOpenPanel() }
                .keyboardShortcut("o")
            Menu(L("最近開啟", "Open Recent")) {
                ForEach(app.recentDocuments.prefix(15)) { record in
                    Button(record.title) { app.reopen(record) }
                }
            }
            Divider()
            Button(L("匯出翻譯 PDF…", "Export Translated PDF…")) { app.reader?.activeSheet = .export }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(app.reader == nil)
            Divider()
            Button(L("關閉文件", "Close Document")) { app.closeDocument() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.reader == nil)
        }

        CommandMenu(L("閱讀", "Read")) {
            Button(L("上一頁", "Previous Page")) { app.reader?.previousPage() }
                .keyboardShortcut("[")
            Button(L("下一頁", "Next Page")) { app.reader?.nextPage() }
                .keyboardShortcut("]")
            Button(L("第一頁", "First Page")) { app.reader?.goToFirstPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(L("最後一頁", "Last Page")) { app.reader?.goToLastPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button(L("放大", "Zoom In")) { app.reader?.zoomIn() }
                .keyboardShortcut("=")
            Button(L("縮小", "Zoom Out")) { app.reader?.zoomOut() }
                .keyboardShortcut("-")
            Button(L("實際大小", "Actual Size")) { app.reader?.actualSize() }
                .keyboardShortcut("0")
            Button(L("符合頁寬", "Fit Width")) { app.reader?.fitWidth() }
                .keyboardShortcut("9")
            Button(L("符合視窗", "Fit Window")) { app.reader?.fitWindow() }
                .keyboardShortcut("8")
            Divider()
            Button(L("單頁", "Single Page")) { app.reader?.setDisplayMode(.singlePage) }
                .keyboardShortcut("1")
            Button(L("雙頁", "Two Pages")) { app.reader?.setDisplayMode(.twoUp) }
                .keyboardShortcut("2")
            Button(L("連續捲動", "Continuous")) { app.reader?.setDisplayMode(.continuous) }
                .keyboardShortcut("3")
            Menu(L("雙頁對頁", "Two-Page Pairing")) {
                Button((app.reader?.coverAlone ?? true ? "✓ " : "　") + L("封面單獨顯示", "Cover Alone")) {
                    app.reader?.setCoverAlone(true)
                }
                Button((app.reader?.coverAlone ?? true ? "　" : "✓ ") + L("從第一頁開始成對", "Pair from First Page")) {
                    app.reader?.setCoverAlone(false)
                }
            }
            .disabled(app.reader == nil)
            Menu(L("閱讀方向", "Reading Direction")) {
                Button(L("左至右", "Left to Right")) { app.reader?.setReadingDirection(.leftToRight) }
                Button(L("右至左", "Right to Left")) { app.reader?.setReadingDirection(.rightToLeft) }
            }
            Divider()
            Button(L("加入／移除書籤", "Add/Remove Bookmark")) { app.reader?.toggleBookmark() }
                .keyboardShortcut("d")
            Button(L("搜尋", "Search")) { app.reader?.sidebarTab = .search }
                .keyboardShortcut("f")
        }

        CommandMenu(L("翻譯", "Translate")) {
            Button(app.reader?.showsTranslation == true ? L("顯示原文　　（C）", "Show Original    (C)")
                                                        : L("顯示譯文　　（C）", "Show Translation    (C)")) {
                app.reader?.toggleTranslation()
            }
            .keyboardShortcut("y")
            .disabled(app.reader == nil)
            Divider()
            Button(L("翻譯目前頁面", "Translate Current Page")) { app.reader?.translation.translateFocusPages() }
                .keyboardShortcut("t")
                .disabled(app.reader == nil)
            Button(L("翻譯選取文字", "Translate Selection")) { app.reader?.translateCurrentSelection() }
                .keyboardShortcut("e")
                .disabled(app.reader == nil)
            Divider()
            Menu(L("目標語言", "Translate To")) {
                ForEach(TargetLanguage.allCases) { lang in
                    Button((app.targetLanguage == lang ? "✓ " : "　") + lang.menuName) { app.setTargetLanguage(lang) }
                }
            }
            Divider()
            Button(L("整份翻譯…", "Translate Whole Document…")) { app.reader?.activeSheet = .wholeTranslation }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(app.reader == nil)
            Button(L("新增翻譯模型…", "Add Model…")) { app.showAddModel = true }
            Divider()
            Button(L("顯示／隱藏翻譯側欄", "Show/Hide Translation Sidebar")) { app.reader?.showTranslationPanel.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(app.reader == nil)
        }
    }
}
