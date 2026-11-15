import SwiftUI
import ReaderCore

struct ReaderCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("開啟…") { app.presentOpenPanel() }
                .keyboardShortcut("o")
            Menu("最近開啟") {
                ForEach(app.recentDocuments.prefix(15)) { record in
                    Button(record.title) { app.reopen(record) }
                }
            }
            Divider()
            Button("匯出翻譯 PDF…") { app.reader?.activeSheet = .export }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(app.reader == nil)
            Divider()
            Button("關閉文件") { app.closeDocument() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(app.reader == nil)
        }

        CommandMenu("閱讀") {
            Button("上一頁") { app.reader?.previousPage() }
                .keyboardShortcut("[")
            Button("下一頁") { app.reader?.nextPage() }
                .keyboardShortcut("]")
            Button("第一頁") { app.reader?.goToFirstPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("最後一頁") { app.reader?.goToLastPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("放大") { app.reader?.zoomIn() }
                .keyboardShortcut("=")
            Button("縮小") { app.reader?.zoomOut() }
                .keyboardShortcut("-")
            Button("實際大小") { app.reader?.actualSize() }
                .keyboardShortcut("0")
            Button("符合頁寬") { app.reader?.fitWidth() }
                .keyboardShortcut("9")
            Button("符合視窗") { app.reader?.fitWindow() }
                .keyboardShortcut("8")
            Divider()
            Button("單頁") { app.reader?.setDisplayMode(.singlePage) }
                .keyboardShortcut("1")
            Button("雙頁") { app.reader?.setDisplayMode(.twoUp) }
                .keyboardShortcut("2")
            Button("連續捲動") { app.reader?.setDisplayMode(.continuous) }
                .keyboardShortcut("3")
            Menu("閱讀方向") {
                Button("左至右") { app.reader?.setReadingDirection(.leftToRight) }
                Button("右至左") { app.reader?.setReadingDirection(.rightToLeft) }
            }
            Divider()
            Button("加入／移除書籤") { app.reader?.toggleBookmark() }
                .keyboardShortcut("d")
            Button("搜尋") { app.reader?.sidebarTab = .search }
                .keyboardShortcut("f")
        }

        CommandMenu("翻譯") {
            Button("切換原文／譯文") { app.reader?.toggleTranslation() }
                .keyboardShortcut("y")
                .disabled(app.reader == nil)
            Divider()
            Button("翻譯目前頁面") {
                app.reader?.translation.translateFocusPages()
            }
            .keyboardShortcut("t")
            .disabled(app.reader == nil)
            Button("翻譯選取文字") { app.reader?.translateCurrentSelection() }
                .keyboardShortcut("e")
                .disabled(app.reader == nil)
            Divider()
            Button("整份翻譯…") { app.reader?.activeSheet = .wholeTranslation }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(app.reader == nil)
            Button("匯出翻譯 PDF…") { app.reader?.activeSheet = .export }
                .disabled(app.reader == nil)
            Divider()
            Button("新增翻譯模型…") { app.showAddModel = true }
            Divider()
            Button("顯示／隱藏翻譯側欄") { app.reader?.showTranslationPanel.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(app.reader == nil)
        }
    }
}
