import SwiftUI
import ReaderCore

struct ReaderView: View {
    @Environment(AppModel.self) private var app
    @Bindable var reader: ReaderModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(reader: reader, coordinator: reader.translation)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 360)
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
        .toolbar { ReaderToolbar(reader: reader) }
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

struct ReaderToolbar: ToolbarContent {
    @Bindable var reader: ReaderModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { reader.previousPage() } label: { Label(L("上一頁", "Previous Page"), systemImage: "chevron.left") }
                .help(L("上一頁 (←)", "Previous page (←)"))
            PageField(reader: reader)
            Button { reader.nextPage() } label: { Label(L("下一頁", "Next Page"), systemImage: "chevron.right") }
                .help(L("下一頁 (→)", "Next page (→)"))
        }

        ToolbarItemGroup(placement: .primaryAction) {
            DisplayModePicker(reader: reader)
            if reader.displayMode == .twoUp {
                SpreadAlignmentMenu(reader: reader)
            }

            ControlGroup {
                Button { reader.zoomOut() } label: { Label(L("縮小", "Zoom Out"), systemImage: "minus.magnifyingglass") }
                Button { reader.zoomIn() } label: { Label(L("放大", "Zoom In"), systemImage: "plus.magnifyingglass") }
            }

            ZoomMenu(reader: reader)
            BookmarkButton(reader: reader)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            TranslationToggle(reader: reader)
            TranslationOptionsMenu(reader: reader, coordinator: reader.translation)
        }
    }
}

/// 原文／譯文切換：按鈕呈按下狀態＝目前顯示譯文。
private struct TranslationToggle: View {
    let reader: ReaderModel

    var body: some View {
        Toggle(isOn: Binding(get: { reader.showsTranslation }, set: { reader.setShowsTranslation($0) })) {
            Label(reader.showsTranslation ? L("譯文", "Translated") : L("原文", "Original"),
                  systemImage: reader.showsTranslation ? "character.book.closed.fill" : "character.book.closed")
                .labelStyle(.titleAndIcon)
        }
        .toggleStyle(.button)
        .help(reader.showsTranslation
              ? L("目前顯示譯文。按一下或按 C 顯示原文；按住 ⌥ 可暫時查看原文",
                  "Showing translation. Click or press C for the original; hold ⌥ to peek")
              : L("目前顯示原文。按一下或按 C 在頁面上顯示譯文",
                  "Showing original. Click or press C to show the translation on the page"))
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
            Button(L("翻譯選取文字", "Translate Selection")) { reader.translateCurrentSelection() }
                .disabled(!reader.hasSelection)
            Toggle(L("閱讀時自動翻譯（目前頁＋\(coordinator.prefetchCount) 頁）",
                     "Translate While Reading (current + \(coordinator.prefetchCount) pages)"),
                   isOn: $coordinator.autoTranslate)
            Divider()
            TargetLanguageMenu()
            FontMenu()
            Menu(L("翻譯模型與品質", "Model & Quality")) { ModelMenuItems(reader: reader) }
            Divider()
            Button(L("整份翻譯…", "Translate Whole Document…")) { reader.activeSheet = .wholeTranslation }
            Button(L("匯出翻譯 PDF…", "Export Translated PDF…")) { reader.activeSheet = .export }
            Divider()
            Button(reader.showTranslationPanel ? L("隱藏翻譯側欄", "Hide Translation Sidebar")
                                               : L("顯示翻譯側欄", "Show Translation Sidebar")) {
                reader.showTranslationPanel.toggle()
            }
        } label: {
            Label(L("翻譯選項", "Translation Options"), systemImage: "ellipsis.circle")
        }
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

/// 雙頁模式的對頁調整：對頁錯位時切換封面是否單獨顯示（整體位移一頁）。
private struct SpreadAlignmentMenu: View {
    let reader: ReaderModel

    var body: some View {
        Menu {
            Picker(L("對頁方式", "Page Pairing"), selection: Binding(get: { reader.coverAlone },
                                                                set: { reader.setCoverAlone($0) })) {
                Text(L("封面單獨顯示（1｜2-3｜4-5…）", "Cover alone (1 | 2-3 | 4-5…)")).tag(true)
                Text(L("從第一頁開始成對（1-2｜3-4…）", "Pair from first page (1-2 | 3-4…)")).tag(false)
            }
            .pickerStyle(.inline)
            Divider()
            Picker(L("閱讀方向", "Reading Direction"), selection: Binding(get: { reader.readingDirection },
                                                                    set: { reader.setReadingDirection($0) })) {
                Text(L("左至右", "Left to Right")).tag(ReadingDirection.leftToRight)
                Text(L("右至左（直排書）", "Right to Left")).tag(ReadingDirection.rightToLeft)
            }
            .pickerStyle(.inline)
        } label: {
            Label(L("對頁調整", "Spread Alignment"), systemImage: "book.pages")
        }
        .help(L("對頁沒對上時，切換封面是否單獨顯示即可整體位移一頁", "If facing pages are misaligned, toggle the cover setting to shift pairing by one page"))
    }
}

/// 各工具列元件獨立成 View，翻頁時只會重繪真正依賴頁碼的部分。
private struct DisplayModePicker: View {
    let reader: ReaderModel
    var body: some View {
        Picker(L("顯示模式", "Display Mode"), selection: Binding(get: { reader.displayMode }, set: { reader.setDisplayMode($0) })) {
            Label(L("單頁", "Single Page"), systemImage: "doc").tag(DisplayMode.singlePage)
            Label(L("雙頁", "Two Pages"), systemImage: "book").tag(DisplayMode.twoUp)
            Label(L("連續", "Continuous"), systemImage: "scroll").tag(DisplayMode.continuous)
        }
        .pickerStyle(.segmented)
        .help(L("顯示模式：單頁 ⌘1／雙頁 ⌘2／連續 ⌘3", "Display mode: single ⌘1 / two pages ⌘2 / continuous ⌘3"))
    }
}

private struct ZoomMenu: View {
    let reader: ReaderModel
    var body: some View {
        Menu {
            Button(L("符合頁寬", "Fit Width")) { reader.fitWidth() }
            Button(L("符合視窗", "Fit Window")) { reader.fitWindow() }
            Button(L("實際大小", "Actual Size")) { reader.actualSize() }
            Divider()
            ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { p in
                Button("\(p)%") { reader.setScale(percent: Double(p)) }
            }
        } label: {
            Text("\(Int((reader.scaleFactor * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 44)
        }
        .help(L("縮放", "Zoom"))
    }
}

private struct BookmarkButton: View {
    let reader: ReaderModel
    var body: some View {
        Button { reader.toggleBookmark() } label: {
            Label(L("書籤", "Bookmark"), systemImage: reader.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
        }
        .help(L("加入／移除書籤 (⌘D)", "Add or remove bookmark (⌘D)"))
    }
}

private struct PageField: View {
    let reader: ReaderModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(L("頁", "Page"), text: $text)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let n = Int(text.trimmingCharacters(in: .whitespaces)) {
                        reader.goTo(pageIndex: n - 1)
                    }
                    focused = false
                    text = "\(reader.currentPageIndex + 1)"
                }
            Text("/ \(reader.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onAppear { text = "\(reader.currentPageIndex + 1)" }
        .onChange(of: reader.currentPageIndex) { _, new in
            if !focused { text = "\(new + 1)" }
        }
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
