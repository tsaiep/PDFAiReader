import SwiftUI
import ReaderCore

struct ReaderView: View {
    @Environment(AppModel.self) private var app
    @Bindable var reader: ReaderModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var sidebarVisible: Bool { columnVisibility != .detailOnly }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(reader: reader, coordinator: reader.translation)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 360)
                .toolbar(removing: .sidebarToggle)   // 用工具列左邊自己的側邊欄按鈕
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    PDFKitView(model: reader)
                    Divider()
                    StatusBarView(reader: reader, translation: reader.translation)
                }
                .frame(minWidth: 420)

                if reader.showTranslationPanel {
                    TranslationPanelView(reader: reader, coordinator: reader.translation)
                        .frame(minWidth: 300, idealWidth: 400, maxWidth: 760)
                }
            }
        }
        .navigationTitle(reader.record.title)
        .toolbar {
            ReaderToolbar(reader: reader, sidebarVisible: sidebarVisible) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    columnVisibility = sidebarVisible ? .detailOnly : .all
                }
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar(removing: .title)   // 工具列上不顯示書名（視窗標題仍是書名，視窗選單看得到）
        .sheet(item: $reader.activeSheet) { sheet in
            switch sheet {
            case .wholeTranslation:
                WholeTranslationSheet(reader: reader, coordinator: reader.translation)
            case .export:
                ExportSheet(reader: reader, coordinator: reader.translation)
            case .addModel:
                AddModelSheet()
            }
        }
        .sheet(isPresented: Bindable(app).showAddModel) { AddModelSheet() }
    }
}

// MARK: - Toolbar

/// 上方工具列（系統標題列）：全螢幕時跟著選單列一起滑出／收回（系統原生行為）。
/// 左：側邊欄、頁碼與書籤；中：單頁／雙頁／連續、縮放；右：便利貼、螢光筆、翻譯。
struct ReaderToolbar: ToolbarContent {
    @Bindable var reader: ReaderModel
    let sidebarVisible: Bool
    let toggleSidebar: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 1) {
                Button(action: toggleSidebar) { BarIcon(systemName: "sidebar.left") }
                    .buttonStyle(BarButtonStyle())
                    .help(sidebarVisible ? L("隱藏側邊欄", "Hide Sidebar") : L("顯示側邊欄", "Show Sidebar"))
                BarDivider()
                Button { reader.previousPage() } label: { BarIcon(systemName: "chevron.left") }
                    .buttonStyle(BarButtonStyle())
                    .help(L("上一頁 (←)", "Previous page (←)"))
                PageField(reader: reader)
                Button { reader.nextPage() } label: { BarIcon(systemName: "chevron.right") }
                    .buttonStyle(BarButtonStyle())
                    .help(L("下一頁 (→)", "Next page (→)"))
                BookmarkButton(reader: reader)
            }
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 1) {
                DisplayModeButtons(reader: reader)
                BarDivider()
                ZoomMenu(reader: reader)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 1) {
                StickyNoteControl(reader: reader, notes: reader.notes)
                HighlighterControl(reader: reader, notes: reader.notes)
                BarDivider()
                TranslationControl(reader: reader, coordinator: reader.translation)
            }
        }
    }
}

/// 便利貼：按一下在目前頁面新增；旁邊的箭頭打開選單（無位置筆記、顯示／隱藏）。
private struct StickyNoteControl: View {
    let reader: ReaderModel
    @Bindable var notes: NotesController

    var body: some View {
        HStack(spacing: 0) {
            Button { reader.addStickyNote() } label: {
                BarIcon(systemName: notes.isVisible ? "note.text.badge.plus" : "note.text")
                    .opacity(notes.isVisible ? 1 : 0.55)
            }
            .buttonStyle(BarButtonStyle())
            .help(L("新增便利貼（按 N 顯示／隱藏）", "Add a sticky note (press N to show/hide)"))

            Menu {
                Button(L("在頁面上新增便利貼", "Add Sticky Note on Page")) { reader.addStickyNote() }
                Button(L("新增筆記（不放在頁面上）", "Add Note (Unplaced)")) { reader.addUnplacedNote() }
                Divider()
                Button(notes.isVisible ? L("隱藏頁面上的便利貼　（N）", "Hide Sticky Notes    (N)")
                                       : L("顯示頁面上的便利貼　（N）", "Show Sticky Notes    (N)")) { notes.toggleVisible() }
                Button(L("在側邊欄查看筆記", "Show Notes in Sidebar")) { reader.sidebarTab = .notes }
            } label: { BarChevron() }
            .barMenuStyle()
            .help(L("便利貼選項", "Sticky note options"))
        }
    }
}

/// 螢光筆：有選取文字就直接上色；沒有則切換螢光筆模式（選取後放開即上色）。箭頭打開顏色選單。
private struct HighlighterControl: View {
    let reader: ReaderModel
    @Bindable var notes: NotesController

    var body: some View {
        HStack(spacing: 0) {
            Button { reader.highlighterPrimaryAction() } label: {
                Image(nsImage: notes.highlighterColor.toolbarImage(active: notes.highlighterMode))
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(BarButtonStyle(isOn: notes.highlighterMode))
            .help(notes.highlighterMode
                  ? L("螢光筆模式開啟中：選取文字即上色。按一下關閉", "Highlighter on: selecting text colors it. Click to turn off")
                  : L("螢光筆：選取文字後按一下上色；沒有選取時開啟螢光筆模式",
                      "Highlighter: click to color the selection, or turn on highlighter mode"))

            Menu {
                ForEach(HighlightColor.allCases) { c in
                    Button {
                        notes.highlighterColor = c
                        if reader.hasAnySelection { notes.highlightSelection(c) }
                    } label: {
                        Label { Text((notes.highlighterColor == c ? "✓ " : "") + c.localizedName) }
                            icon: { Image(nsImage: c.swatchImage()) }
                    }
                }
                Divider()
                Toggle(L("螢光筆模式（選取後自動上色）", "Highlighter Mode (color on select)"), isOn: $notes.highlighterMode)
            } label: { BarChevron() }
            .barMenuStyle()
            .help(L("螢光筆顏色", "Highlighter color"))
        }
    }
}

/// 原文／譯文切換＋翻譯選項。只換字與圖示、不加底色；翻譯進行中圖示換成小轉圈。
private struct TranslationControl: View {
    let reader: ReaderModel
    @Bindable var coordinator: TranslationCoordinator

    var body: some View {
        HStack(spacing: 0) {
            Button { reader.setShowsTranslation(!reader.showsTranslation) } label: {
                HStack(spacing: 5) {
                    if !coordinator.currentBatch.isEmpty {
                        ProgressView().controlSize(.mini).frame(width: 18, height: 18)
                    } else {
                        BarIcon(systemName: reader.showsTranslation ? "character.book.closed.fill" : "character.book.closed")
                    }
                    Text(reader.showsTranslation ? L("譯文", "Translated") : L("原文", "Original"))
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.trailing, 3)
            }
            .buttonStyle(BarButtonStyle())
            .help(reader.showsTranslation
                  ? L("目前顯示譯文。按一下或按 C 顯示原文；按住 ⌥ 可暫時查看原文",
                      "Showing translation. Click or press C for the original; hold ⌥ to peek")
                  : L("目前顯示原文。按一下或按 C 在頁面上顯示譯文",
                      "Showing original. Click or press C to show the translation on the page"))

            TranslationOptionsMenu(reader: reader, coordinator: coordinator)
        }
    }
}

/// 翻譯相關選項：目標語言、字體、模型、整份翻譯、匯出。
private struct TranslationOptionsMenu: View {
    @Environment(AppModel.self) private var app
    @Bindable var reader: ReaderModel
    @Bindable var coordinator: TranslationCoordinator

    var body: some View {
        Menu {
            Button(L("翻譯目前頁面", "Translate Current Page")) { coordinator.translateFocusPages() }
            Button(L("重新辨識並翻譯目前頁面", "Re-recognize & Retranslate Current Pages")) {
                coordinator.reExtractFocusPages()
            }
            Button(L("翻譯選取文字", "Translate Selection")) { reader.translateCurrentSelection() }
                .disabled(!reader.hasAnySelection)
            Toggle(L("閱讀時自動翻譯（目前頁＋\(coordinator.prefetchCount) 頁）",
                     "Translate While Reading (current + \(coordinator.prefetchCount) pages)"),
                   isOn: $coordinator.autoTranslate)
            Divider()
            TargetLanguageMenu()
            FontMenu()
            Menu(L("翻譯模型與品質", "Model & Quality")) { ModelMenuItems(reader: reader) }
            Divider()
            Button(L("整份翻譯／重新翻譯…", "Translate or Retranslate Whole Document…")) { reader.activeSheet = .wholeTranslation }
            Button(L("匯出翻譯 PDF…", "Export Translated PDF…")) { reader.activeSheet = .export }
            Divider()
            Button(reader.showTranslationPanel ? L("隱藏翻譯側欄", "Hide Translation Sidebar")
                                               : L("顯示翻譯側欄", "Show Translation Sidebar")) {
                reader.showTranslationPanel.toggle()
            }
        } label: { BarChevron() }
        .barMenuStyle()
        .help(L("翻譯選項：目標語言、字體、模型、整份翻譯、匯出", "Translation options: language, font, model, whole document, export"))
    }
}

/// 目標語言子選單（工具列、側欄、設定共用）。
struct TargetLanguageMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu(L("目標語言：", "Translate To: ") + app.targetLanguage.menuName) {
            TargetLanguageItems()
        }
    }
}

struct TargetLanguageItems: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ForEach(TargetLanguage.allCases) { lang in
            Toggle(lang.menuName, isOn: Binding(get: { app.targetLanguage == lang },
                                               set: { if $0 { app.setTargetLanguage(lang) } }))
        }
    }
}

/// 譯文字體子選單。
struct FontMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let choices = Prefs.installedFontChoices(for: app.targetLanguage)
        let current = app.fontFamily
        Menu(L("譯文字體：", "Font: ") + (choices.first { $0.family == current }?.localizedName ?? current)) {
            ForEach(choices) { choice in
                Toggle(choice.localizedName, isOn: Binding(get: { current == choice.family },
                                                          set: { if $0 { app.setFontFamily(choice.family) } }))
            }
        }
    }
}

/// 雙頁模式的對頁調整：對頁錯位時切換封面是否單獨顯示（整體位移一頁）。收在縮放選單裡。
private struct SpreadAlignmentItems: View {
    let reader: ReaderModel

    var body: some View {
        Picker(L("對頁方式", "Page Pairing"), selection: Binding(get: { reader.coverAlone },
                                                            set: { reader.setCoverAlone($0) })) {
            Text(L("封面單獨顯示（1｜2-3｜4-5…）", "Cover alone (1 | 2-3 | 4-5…)")).tag(true)
            Text(L("從第一頁開始成對（1-2｜3-4…）", "Pair from first page (1-2 | 3-4…)")).tag(false)
        }
        .pickerStyle(.inline)
        Picker(L("閱讀方向", "Reading Direction"), selection: Binding(get: { reader.readingDirection },
                                                                set: { reader.setReadingDirection($0) })) {
            Text(L("左至右", "Left to Right")).tag(ReadingDirection.leftToRight)
            Text(L("右至左（直排書）", "Right to Left")).tag(ReadingDirection.rightToLeft)
        }
        .pickerStyle(.inline)
    }
}

/// 單頁／雙頁／連續：三顆圖示按鈕，目前模式以強調色標示。
private struct DisplayModeButtons: View {
    let reader: ReaderModel

    var body: some View {
        ForEach([(DisplayMode.singlePage, "doc", "⌘1"), (.twoUp, "book", "⌘2"), (.continuous, "scroll", "⌘3")],
                id: \.0) { mode, icon, key in
            Button { reader.setDisplayMode(mode) } label: { BarIcon(systemName: icon) }
                .buttonStyle(BarButtonStyle(isOn: reader.displayMode == mode))
                .help(mode.localizedLabel + "（\(key)）")
        }
    }
}

/// 縮放百分比；選單內含放大縮小、符合頁寬／視窗，雙頁模式另有對頁調整。
private struct ZoomMenu: View {
    let reader: ReaderModel
    var body: some View {
        Menu {
            Button(L("放大　　⌘+", "Zoom In    ⌘+")) { reader.zoomIn() }
            Button(L("縮小　　⌘−", "Zoom Out    ⌘−")) { reader.zoomOut() }
            Divider()
            Button(L("符合頁寬", "Fit Width")) { reader.fitWidth() }
            Button(L("符合視窗", "Fit Window")) { reader.fitWindow() }
            Button(L("實際大小", "Actual Size")) { reader.actualSize() }
            Divider()
            ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { p in
                Button("\(p)%") { reader.setScale(percent: Double(p)) }
            }
            if reader.displayMode == .twoUp {
                Divider()
                SpreadAlignmentItems(reader: reader)
            }
        } label: {
            Text("\(Int((reader.scaleFactor * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 38)
                .modifier(BarMenuLabel(horizontalPadding: 4))
        }
        .barMenuStyle()
        .help(reader.displayMode == .twoUp ? L("縮放與對頁調整", "Zoom & page pairing") : L("縮放", "Zoom"))
    }
}

private struct BookmarkButton: View {
    let reader: ReaderModel
    var body: some View {
        Button { reader.toggleBookmark() } label: {
            BarIcon(systemName: reader.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(BarButtonStyle())
        .help(L("加入／移除書籤 (⌘D)", "Add or remove bookmark (⌘D)"))
    }
}

private struct PageField: View {
    let reader: ReaderModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let digits = max(2, String(reader.pageCount).count)
        HStack(spacing: 4) {
            TextField(L("頁", "Page"), text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .frame(width: CGFloat(digits) * 8 + 8, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.12 : 0.06)))
                .focused($focused)
                .onSubmit {
                    if let n = Int(text.trimmingCharacters(in: .whitespaces)) {
                        reader.goTo(pageIndex: n - 1)
                    }
                    finishEditing()
                }
                .onExitCommand { finishEditing() }
            Text("/ \(reader.pageCount)")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .onAppear { text = "\(reader.currentPageIndex + 1)" }
        .onChange(of: reader.currentPageIndex) { _, new in
            if !focused { text = "\(new + 1)" }
        }
    }

    /// 輸入完把焦點還給 PDF，方向鍵翻頁才會繼續有效。
    private func finishEditing() {
        focused = false
        text = "\(reader.currentPageIndex + 1)"
        if let view = reader.pdfView { view.window?.makeFirstResponder(view) }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    let reader: ReaderModel
    let translation: TranslationCoordinator

    var body: some View {
        HStack(spacing: 14) {
            Text(L("第 \(reader.currentPageIndex + 1) / \(reader.pageCount) 頁",
                   "Page \(reader.currentPageIndex + 1) of \(reader.pageCount)"))
                .monospacedDigit()
            Text(reader.displayMode.localizedLabel)
            if reader.showsTranslation {
                Label(translation.targetLanguage.menuName, systemImage: "character.book.closed.fill")
            }
            Spacer()
            TranslationStatusLabel(translation: translation)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

private struct TranslationStatusLabel: View {
    let translation: TranslationCoordinator

    var body: some View {
        HStack(spacing: 10) {
            if let blocked = translation.blockedMessage {
                Label(L("翻譯已暫停：", "Translation paused: ") + blocked, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if !translation.currentBatch.isEmpty {
                ProgressView().controlSize(.mini)
                Text(L("翻譯中：第 ", "Translating page ")
                     + translation.currentBatch.map { "\($0 + 1)" }.joined(separator: ", ")
                     + L(" 頁", ""))
            }
            if let whole = translation.whole {
                Text(L("整份翻譯 ", "Whole document ") + "\(translation.wholeCompleted)/\(whole.range.count)"
                     + (whole.isPaused ? L("（已暫停）", " (paused)") : ""))
                    .monospacedDigit()
            } else {
                Text(L("已翻譯 \(translation.completedPages.count) 頁", "\(translation.completedPages.count) pages translated"))
                    .monospacedDigit()
            }
        }
    }
}

extension DisplayMode {
    var localizedLabel: String {
        switch self {
        case .singlePage: return L("單頁", "Single Page")
        case .twoUp: return L("雙頁", "Two Pages")
        case .continuous: return L("連續捲動", "Continuous")
        }
    }
}
