import SwiftUI
import AppKit
import ReaderCore

struct TranslationPanelView: View {
    @Environment(AppModel.self) private var app
    let reader: ReaderModel
    @Bindable var coordinator: TranslationCoordinator
    @AppStorage("panelShowsOriginal") private var showsOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let blocked = coordinator.blockedMessage {
                BlockedBanner(message: blocked) { coordinator.clearBlocked() }
            }
            if coordinator.whole != nil {
                WholeProgressView(reader: reader, coordinator: coordinator)
                Divider()
            }
            if let selection = coordinator.selection {
                SelectionCard(selection: selection, onClose: coordinator.dismissSelection)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(coordinator.focusPages, id: \.self) { page in
                        PageSection(reader: reader, coordinator: coordinator, page: page, showsOriginal: showsOriginal)
                    }
                    if coordinator.focusPages.isEmpty {
                        Text(L("翻到任一頁即可開始", "Turn to any page to begin")).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L("翻譯", "Translation")).font(.headline)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Menu {
                    TargetLanguageItems()
                } label: {
                    Text(app.targetLanguage.menuName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("目標語言", "Target language"))
                Spacer()
                Picker("", selection: $showsOriginal) {
                    Text(L("譯文", "Text")).tag(false)
                    Text(L("對照", "Side by Side")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 8) {
                Button {
                    coordinator.translateFocusPages()
                } label: {
                    Label(L("翻譯此頁", "Translate Page"), systemImage: "character.book.closed")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Toggle(isOn: $coordinator.autoTranslate) {
                    Text(L("自動＋\(coordinator.prefetchCount) 頁", "Auto +\(coordinator.prefetchCount)"))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(L("閱讀時自動翻譯目前頁與後續頁面（頁數可在設定中調整）",
                        "Translate the current and following pages while reading (count in Settings)"))

                Spacer()

                ModelMenu(reader: reader)
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                Menu {
                    FontMenu()
                    Divider()
                    Button(L("整份翻譯／重新翻譯…", "Translate or Retranslate Whole Document…")) { reader.activeSheet = .wholeTranslation }
                    Button(L("匯出翻譯 PDF…", "Export Translated PDF…")) { reader.activeSheet = .export }
                    Divider()
                    Button(L("重新辨識並翻譯目前頁面", "Re-recognize & Retranslate Current Pages")) {
                        coordinator.reExtractFocusPages()
                    }
                    Button(L("重試失敗的頁面", "Retry Failed Pages")) { coordinator.retryFailed() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(12)
    }
}

// MARK: - 頁面區段

private struct PageSection: View {
    let reader: ReaderModel
    let coordinator: TranslationCoordinator
    let page: Int
    let showsOriginal: Bool

    var body: some View {
        let blocks = coordinator.blocks[page]
        let translations = coordinator.translations[page] ?? [:]
        let status = coordinator.status[page] ?? .idle

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("第 \(page + 1) 頁", "Page \(page + 1)")).font(.subheadline.weight(.semibold))
                StatusBadge(status: status)
                Spacer()
                Menu {
                    Button(L("翻譯此頁", "Translate Page")) { coordinator.translatePages([page]) }
                    Button(L("重新翻譯此頁", "Retranslate Page")) { coordinator.retranslate(page) }
                    Button(L("重新辨識並翻譯此頁", "Re-recognize & Retranslate Page")) { coordinator.reExtract(page) }
                    Divider()
                    Button(L("複製本頁譯文", "Copy Page Translation")) {
                        let text = (blocks ?? []).compactMap { translations[$0.id] }.joined(separator: "\n\n")
                        copy(text)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let blocks {
                if blocks.isEmpty {
                    Text(L("此頁沒有可辨識的文字", "No recognizable text on this page")).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(blocks) { block in
                        BlockRow(block: block, translation: translations[block.id], showsOriginal: showsOriginal,
                                 isTranslating: status == .translating,
                                 keepsOriginal: !coordinator.requiresTranslation(block))
                            .contentShape(Rectangle())
                            .onTapGesture { reader.highlight(rect: block.bounds.cgRect, pageIndex: block.pageIndex) }
                            .contextMenu {
                                if let t = translations[block.id] {
                                    Button(L("複製譯文", "Copy Translation")) { copy(t) }
                                }
                                Button(L("複製原文", "Copy Original")) { copy(block.text) }
                                Button(L("立即翻譯此段", "Translate This Paragraph Now")) { coordinator.translateBlockNow(block) }
                                Button(L("在頁面上標示", "Show on Page")) {
                                    reader.highlight(rect: block.bounds.cgRect, pageIndex: block.pageIndex)
                                }
                            }
                    }
                }
            } else if status == .extracting {
                HStack { ProgressView().controlSize(.small); Text(L("辨識文字中…", "Recognizing text…")).foregroundStyle(.secondary) }
            } else {
                HStack { ProgressView().controlSize(.small); Text(L("準備中…", "Preparing…")).foregroundStyle(.secondary) }
            }

            if case .failed(let message) = status {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button(L("重試", "Retry")) { coordinator.translatePages([page]) }.controlSize(.small)
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct BlockRow: View {
    let block: TextBlock
    let translation: String?
    let showsOriginal: Bool
    let isTranslating: Bool
    let keepsOriginal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if keepsOriginal {
                Text(block.text)
                    .font(translationFont)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                if showsOriginal || translation == nil {
                    Text(block.text)
                        .font(originalFont)
                        .foregroundStyle(translation == nil ? .secondary : .tertiary)
                        .textSelection(.enabled)
                        .opacity(translation == nil && isTranslating ? 0.6 : 1)
                }
                if let translation {
                    Text(translation)
                        .font(translationFont)
                        .foregroundStyle(block.kind == .caption || block.kind == .footnote ? .secondary : .primary)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var translationFont: Font {
        switch block.kind {
        case .heading: return .title3.weight(.semibold)
        case .caption, .footnote: return .callout
        default: return .body
        }
    }

    private var originalFont: Font {
        block.kind == .heading ? .callout.weight(.semibold) : .callout
    }
}

private struct StatusBadge: View {
    let status: PageStatus
    var body: some View {
        switch status {
        case .idle: EmptyView()
        case .extracting: badge(L("辨識中", "Recognizing"), "text.viewfinder", .secondary, spinning: true)
        case .queued: badge(L("排隊中", "Queued"), "clock", .secondary)
        case .translating: badge(L("翻譯中", "Translating"), "character.book.closed", .blue, spinning: true)
        case .done: badge(L("完成", "Done"), "checkmark.circle.fill", .green)
        case .failed: badge(L("失敗", "Failed"), "exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder
    private func badge(_ text: String, _ icon: String, _ color: Color, spinning: Bool = false) -> some View {
        HStack(spacing: 3) {
            if spinning { ProgressView().controlSize(.mini) } else { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
    }
}

// MARK: - 其他區塊

private struct BlockedBanner: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("翻譯已暫停", "Translation paused")).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                Text(L("請確認 Codex 已登入、額度足夠，或到「設定 → 翻譯」檢查。",
                       "Check that Codex is logged in and has quota, or review Settings → Translation."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("繼續", "Resume"), action: retry).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
    }
}

private struct WholeProgressView: View {
    let reader: ReaderModel
    let coordinator: TranslationCoordinator

    var body: some View {
        if let whole = coordinator.whole {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(coordinator.wholeIsFinished ? L("整份翻譯完成", "Whole document translated")
                         : (whole.isPaused ? L("整份翻譯（已暫停）", "Whole document (paused)")
                                           : L("整份翻譯中", "Translating whole document")))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(L("第 \(whole.range.lowerBound + 1)–\(whole.range.upperBound + 1) 頁",
                           "Pages \(whole.range.lowerBound + 1)–\(whole.range.upperBound + 1)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(coordinator.wholeCompleted), total: Double(max(1, whole.range.count)))
                HStack(spacing: 8) {
                    Text(L("完成 \(coordinator.wholeCompleted)／\(whole.range.count) 頁",
                           "\(coordinator.wholeCompleted) of \(whole.range.count) pages")
                         + (coordinator.wholeFailed > 0 ? L("，失敗 \(coordinator.wholeFailed)", ", \(coordinator.wholeFailed) failed") : ""))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    if coordinator.wholeIsFinished {
                        Button(L("匯出 PDF…", "Export PDF…")) { reader.activeSheet = .export }.controlSize(.small)
                        Button(L("關閉", "Close")) { coordinator.cancelWhole() }.controlSize(.small)
                    } else {
                        if coordinator.wholeFailed > 0 {
                            Button(L("重試失敗", "Retry Failed")) { coordinator.retryFailed() }.controlSize(.small)
                        }
                        if whole.isPaused {
                            Button(L("繼續", "Resume")) { coordinator.resumeWhole() }.controlSize(.small)
                        } else {
                            Button(L("暫停", "Pause")) { coordinator.pauseWhole() }.controlSize(.small)
                        }
                        Button(L("取消", "Cancel")) { coordinator.cancelWhole() }.controlSize(.small)
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct SelectionCard: View {
    let selection: SelectionTranslation
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("選取文字", "Selection")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let t = selection.translation {
                    Button { copy(t) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help(L("複製譯文", "Copy translation"))
                }
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Text(selection.original).font(.callout).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
            if selection.isLoading {
                HStack { ProgressView().controlSize(.small); Text(L("翻譯中…", "Translating…")).foregroundStyle(.secondary) }
            } else if let t = selection.translation {
                Text(t).textSelection(.enabled)
            } else if let e = selection.error {
                Text(e).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06))
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
