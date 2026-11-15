import SwiftUI
import ReaderCore

struct ReaderView: View {
    @Environment(AppModel.self) private var app
    @Bindable var reader: ReaderModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(reader: reader)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 380)
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
            Button { reader.previousPage() } label: { Label("上一頁", systemImage: "chevron.left") }
                .help("上一頁 (⌘[)")
            PageField(reader: reader)
            Button { reader.nextPage() } label: { Label("下一頁", systemImage: "chevron.right") }
                .help("下一頁 (⌘])")
        }

        ToolbarItem(placement: .principal) {
            OriginalTranslationToggle(reader: reader)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            DisplayModePicker(reader: reader)

            ControlGroup {
                Button { reader.zoomOut() } label: { Label("縮小", systemImage: "minus.magnifyingglass") }
                Button { reader.zoomIn() } label: { Label("放大", systemImage: "plus.magnifyingglass") }
            }

            ZoomMenu(reader: reader)
            BookmarkButton(reader: reader)
            TranslateMenu(reader: reader, coordinator: reader.translation)
        }
    }
}

/// 原文／譯文切換：譯文直接疊在 PDF 頁面上，保留原本排版。
private struct OriginalTranslationToggle: View {
    let reader: ReaderModel
    var body: some View {
        Picker("顯示", selection: Binding(get: { reader.showsTranslation }, set: { reader.setShowsTranslation($0) })) {
            Text("原文").tag(false)
            Text("譯文").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 120)
        .help("切換原文／譯文 (⌘Y)；顯示譯文時按住 ⌥ 可暫時查看原文")
    }
}

/// 各工具列元件獨立成 View，翻頁時只會重繪真正依賴頁碼的部分。
private struct DisplayModePicker: View {
    let reader: ReaderModel
    var body: some View {
        Picker("顯示模式", selection: Binding(get: { reader.displayMode }, set: { reader.setDisplayMode($0) })) {
            Label("單頁", systemImage: "doc").tag(DisplayMode.singlePage)
            Label("雙頁", systemImage: "book").tag(DisplayMode.twoUp)
            Label("連續", systemImage: "scroll").tag(DisplayMode.continuous)
        }
        .pickerStyle(.segmented)
        .help("顯示模式：單頁 ⌘1／雙頁 ⌘2／連續 ⌘3")
    }
}

private struct ZoomMenu: View {
    let reader: ReaderModel
    var body: some View {
        Menu {
            Button("符合頁寬") { reader.fitWidth() }
            Button("符合視窗") { reader.fitWindow() }
            Button("實際大小") { reader.actualSize() }
            Divider()
            ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { p in
                Button("\(p)%") { reader.setScale(percent: Double(p)) }
            }
        } label: {
            Text("\(Int((reader.scaleFactor * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 44)
        }
        .help("縮放")
    }
}

private struct BookmarkButton: View {
    let reader: ReaderModel
    var body: some View {
        Button { reader.toggleBookmark() } label: {
            Label("書籤", systemImage: reader.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
        }
        .help("加入／移除書籤 (⌘D)")
    }
}

private struct TranslateMenu: View {
    @Bindable var reader: ReaderModel
    @Bindable var coordinator: TranslationCoordinator

    var body: some View {
        Menu {
            Button(reader.showsTranslation ? "顯示原文" : "在頁面上顯示譯文") { reader.toggleTranslation() }
            Divider()
            Button("翻譯目前頁面") { coordinator.translateFocusPages() }
            Button("翻譯選取文字") { reader.translateCurrentSelection() }
                .disabled(!reader.hasSelection)
            Toggle("閱讀時自動翻譯（目前頁＋\(coordinator.prefetchCount) 頁）", isOn: $coordinator.autoTranslate)
            Divider()
            Button("整份翻譯…") { reader.activeSheet = .wholeTranslation }
            Button("匯出翻譯 PDF…") { reader.activeSheet = .export }
            Divider()
            Menu("翻譯模型與品質") { ModelMenuItems(reader: reader) }
            Divider()
            Button(reader.showTranslationPanel ? "隱藏翻譯側欄" : "顯示翻譯側欄") {
                reader.showTranslationPanel.toggle()
            }
        } label: {
            Label("翻譯", systemImage: "character.book.closed")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            reader.toggleTranslation()
        }
        .help("翻譯：按一下切換原文／譯文，按箭頭開啟翻譯選單（模型、整份翻譯、匯出）")
    }
}

private struct PageField: View {
    let reader: ReaderModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("頁", text: $text)
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
            Text("第 \(reader.currentPageIndex + 1) / \(reader.pageCount) 頁")
                .monospacedDigit()
            Text(reader.displayMode.label)
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
                Label("翻譯已暫停：\(blocked)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if !translation.currentBatch.isEmpty {
                ProgressView().controlSize(.mini)
                Text("翻譯中：第 \(translation.currentBatch.map { "\($0 + 1)" }.joined(separator: "、")) 頁")
            }
            if let whole = translation.whole {
                Text("整份翻譯 \(translation.wholeCompleted)/\(whole.range.count)\(whole.isPaused ? "（已暫停）" : "")")
                    .monospacedDigit()
            } else {
                Text("已翻譯 \(translation.completedPages.count) 頁").monospacedDigit()
            }
        }
    }
}
