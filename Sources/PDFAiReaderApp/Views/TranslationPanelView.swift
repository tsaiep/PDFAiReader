import SwiftUI
import AppKit
import ReaderCore

struct TranslationPanelView: View {
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
                        Text("翻到任一頁即可開始").foregroundStyle(.secondary)
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
            HStack {
                Text("翻譯").font(.headline)
                Spacer()
                Picker("", selection: $showsOriginal) {
                    Text("譯文").tag(false)
                    Text("對照").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            HStack(spacing: 8) {
                Button {
                    coordinator.translateFocusPages()
                } label: {
                    Label("翻譯此頁", systemImage: "character.book.closed")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("翻譯目前看到的頁面 (⌘T)")

                Toggle(isOn: $coordinator.autoTranslate) {
                    Text("自動翻譯＋\(coordinator.prefetchCount) 頁")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("閱讀時自動翻譯目前頁與後續頁面（頁數可在設定中調整）")

                Spacer()

                ModelMenu(reader: reader)
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                Menu {
                    Button("整份翻譯…") { reader.activeSheet = .wholeTranslation }
                    Button("匯出翻譯 PDF…") { reader.activeSheet = .export }
                    Divider()
                    Button("重試失敗的頁面") { coordinator.retryFailed() }
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
                Text("第 \(page + 1) 頁").font(.subheadline.weight(.semibold))
                StatusBadge(status: status)
                Spacer()
                Menu {
                    Button("翻譯此頁") { coordinator.translatePages([page]) }
                    Button("重新翻譯此頁") { coordinator.retranslate(page) }
                    Button("重新辨識文字（OCR）") { coordinator.reExtract(page) }
                    Divider()
                    Button("複製本頁譯文") {
                        let text = (blocks ?? []).compactMap { translations[$0.id] }.joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let blocks {
                if blocks.isEmpty {
                    Text("此頁沒有可辨識的文字").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(blocks) { block in
                        BlockRow(block: block, translation: translations[block.id], showsOriginal: showsOriginal,
                                 isTranslating: status == .translating)
                            .contentShape(Rectangle())
                            .onTapGesture { reader.highlight(rect: block.bounds.cgRect, pageIndex: block.pageIndex) }
                            .contextMenu {
                                if let t = translations[block.id] {
                                    Button("複製譯文") { copy(t) }
                                }
                                Button("複製原文") { copy(block.text) }
                                Button("立即翻譯此段") { coordinator.translateBlockNow(block) }
                                Button("在頁面上標示") {
                                    reader.highlight(rect: block.bounds.cgRect, pageIndex: block.pageIndex)
                                }
                            }
                    }
                }
            } else if status == .extracting {
                HStack { ProgressView().controlSize(.small); Text("辨識文字中…").foregroundStyle(.secondary) }
            } else {
                HStack { ProgressView().controlSize(.small); Text("準備中…").foregroundStyle(.secondary) }
            }

            if case .failed(let message) = status {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("重試") { coordinator.translatePages([page]) }.controlSize(.small)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        case .extracting: badge("辨識中", "text.viewfinder", .secondary, spinning: true)
        case .queued: badge("排隊中", "clock", .secondary)
        case .translating: badge("翻譯中", "character.book.closed", .blue, spinning: true)
        case .done: badge("完成", "checkmark.circle.fill", .green)
        case .failed: badge("失敗", "exclamationmark.triangle.fill", .orange)
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
                Text("翻譯已暫停").font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                Text("請確認 Codex 已登入、額度足夠，或到「設定 → 翻譯」檢查。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("繼續", action: retry).controlSize(.small)
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
                    Text(coordinator.wholeIsFinished ? "整份翻譯完成" : (whole.isPaused ? "整份翻譯（已暫停）" : "整份翻譯中"))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("第 \(whole.range.lowerBound + 1)–\(whole.range.upperBound + 1) 頁")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(coordinator.wholeCompleted), total: Double(max(1, whole.range.count)))
                HStack(spacing: 8) {
                    Text("完成 \(coordinator.wholeCompleted)／\(whole.range.count) 頁"
                         + (coordinator.wholeFailed > 0 ? "，失敗 \(coordinator.wholeFailed)" : ""))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    if coordinator.wholeIsFinished {
                        Button("匯出 PDF…") { reader.activeSheet = .export }.controlSize(.small)
                        Button("關閉") { coordinator.cancelWhole() }.controlSize(.small)
                    } else {
                        if coordinator.wholeFailed > 0 {
                            Button("重試失敗") { coordinator.retryFailed() }.controlSize(.small)
                        }
                        if whole.isPaused {
                            Button("繼續") { coordinator.resumeWhole() }.controlSize(.small)
                        } else {
                            Button("暫停") { coordinator.pauseWhole() }.controlSize(.small)
                        }
                        Button("取消") { coordinator.cancelWhole() }.controlSize(.small)
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
                Text("選取文字").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let t = selection.translation {
                    Button { copy(t) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("複製譯文")
                }
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Text(selection.original).font(.callout).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
            if selection.isLoading {
                HStack { ProgressView().controlSize(.small); Text("翻譯中…").foregroundStyle(.secondary) }
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
