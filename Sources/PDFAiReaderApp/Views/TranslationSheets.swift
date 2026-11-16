import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReaderCore
import ReaderServices

// MARK: - 整份翻譯

struct WholeTranslationSheet: View {
    let reader: ReaderModel
    let coordinator: TranslationCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var useRange = false
    /// true = 全部重新翻譯（重新辨識版面），false = 只翻譯尚未翻譯的頁面
    @State var retranslateAll = false
    @State private var fromText = "1"
    @State private var toText = ""

    private var range: ClosedRange<Int>? {
        guard useRange else { return 0...(reader.pageCount - 1) }
        guard let a = Int(fromText), let b = Int(toText), a >= 1, b >= a else { return nil }
        return (a - 1)...min(b - 1, reader.pageCount - 1)
    }

    private var remaining: Int {
        guard let range else { return 0 }
        if retranslateAll { return range.count }
        return range.filter { !coordinator.completedPages.contains($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("整份翻譯", "Translate Whole Document")).font(.title2.weight(.semibold))
            Text(L("在背景依序辨識並翻譯頁面。閱讀中的頁面永遠優先；可隨時暫停，關閉程式後可從未完成的頁面繼續。", "Pages are recognized and translated in the background. The pages you are reading always come first; you can pause any time and resume after relaunching."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker(L("翻譯方式", "Mode"), selection: $retranslateAll) {
                    Text(L("只翻譯尚未翻譯的頁面", "Translate untranslated pages only")).tag(false)
                    Text(L("全部重新翻譯（以最新版面規則重新辨識文字）", "Retranslate everything (re-recognize text with the latest layout rules)")).tag(true)
                }
                .pickerStyle(.radioGroup)
                Picker(L("範圍", "Range"), selection: $useRange) {
                    Text(L("全部 \(reader.pageCount) 頁", "All \(reader.pageCount) pages")).tag(false)
                    Text(L("指定頁碼", "Page range")).tag(true)
                }
                .pickerStyle(.radioGroup)
                if useRange {
                    HStack {
                        TextField(L("從", "From"), text: $fromText).frame(width: 70)
                        Text(L("到", "to"))
                        TextField(L("到", "To"), text: $toText).frame(width: 70)
                        Text(L("頁", ""))
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if let range {
                        if retranslateAll {
                            Text(L("範圍內 \(range.count) 頁將全部重新辨識並重新翻譯；處理到某頁時，該頁會暫時顯示原文，完成後換成新譯文。",
                                   "All \(range.count) pages in range will be re-recognized and retranslated. Each page briefly shows the original while it is being redone."))
                        } else {
                            Text(L("範圍內共 \(range.count) 頁，已完成 \(range.count - remaining) 頁，需翻譯 \(remaining) 頁", "\(range.count) pages in range, \(range.count - remaining) done, \(remaining) to translate"))
                        }
                        let calls = Int((Double(remaining) / 2.5).rounded(.up))
                        Text(L("預估約 \(calls) 次 Codex 呼叫，每次約 12–20 秒（實際依頁面字數而定）", "About \(calls) Codex calls, roughly 12–20 seconds each (depends on page length)"))
                            .foregroundStyle(.secondary)
                        Text(L("每次呼叫約消耗 1.7 萬 tokens 以上，請留意 Codex 額度。額度用盡時會自動暫停並保留進度。簡繁轉換在本機完成，不消耗額度。", "Each call uses 17k+ tokens; watch your Codex quota. Translation pauses automatically when quota runs out. Simplified/Traditional Chinese conversion runs locally and uses no quota."))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("請輸入有效的頁碼範圍", "Enter a valid page range")).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(retranslateAll ? L("開始重新翻譯", "Start Retranslation") : L("開始翻譯", "Start")) {
                    if let range { coordinator.startWhole(range: range, retranslate: retranslateAll) }
                    reader.showTranslationPanel = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(range == nil || remaining == 0)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { toText = "\(reader.pageCount)" }
    }
}

// MARK: - 匯出

struct ExportSheet: View {
    let reader: ReaderModel
    let coordinator: TranslationCoordinator
    @Environment(\.dismiss) private var dismiss

    @AppStorage("exportMode") private var modeRaw = ExportMode.inPlace.rawValue
    @State private var progress: Double = 0
    @State private var isExporting = false
    @State private var resultURL: URL?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var cancelFlag = CancelFlag()

    private var mode: ExportMode { ExportMode(rawValue: modeRaw) ?? .inPlace }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("匯出翻譯 PDF", "Export Translated PDF")).font(.title2.weight(.semibold))

            Picker(L("版面", "Layout"), selection: $modeRaw) {
                ForEach(ExportMode.allCases) { m in Text(m.label).tag(m.rawValue) }
            }
            .pickerStyle(.radioGroup)
            .disabled(isExporting)

            let translated = coordinator.completedPages.count
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("已翻譯 \(translated)／\(reader.pageCount) 頁", "\(translated) of \(reader.pageCount) pages translated"))
                    if translated < reader.pageCount {
                        Text(mode == .inPlace || mode == .interleaved
                             ? L("未翻譯的頁面會保留原文。", "Untranslated pages keep the original text.")
                             : L("純譯文模式只會輸出已翻譯的頁面。", "Translation-only mode includes translated pages only."))
                            .foregroundStyle(.secondary)
                        Button(L("先整份翻譯剩下的頁面…", "Translate Remaining Pages First…")) { reader.activeSheet = .wholeTranslation }
                            .disabled(isExporting)
                    }
                    if mode == .inPlace {
                        Text(L("原位翻譯會以紙色覆蓋原文區塊再填入譯文，圖片與版面維持原樣；字級依區塊大小自動調整，字體使用目前的譯文字體。", "In-place mode covers the original text with the paper color and fills in the translation, keeping images and layout. Font size adapts to each block; the current translation font is used."))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isExporting {
                ProgressView(value: progress) { Text(L("匯出中…", "Exporting…")) }
            }
            if let resultURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("已匯出：", "Exported: ") + resultURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("在 Finder 中顯示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([resultURL]) }
                    Button(L("開啟", "Open")) { NSWorkspace.shared.open(resultURL) }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                if isExporting {
                    Button(L("取消匯出", "Cancel Export")) { cancelFlag.cancel() }
                } else {
                    Button(resultURL == nil ? L("取消", "Cancel") : L("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("匯出…", "Export…")) { chooseDestinationAndExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(translated == 0)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let suffix: String
        switch mode {
        case .inPlace: suffix = L("譯文版", "translated")
        case .interleaved: suffix = L("對照", "bilingual")
        case .translationOnly: suffix = L("純譯文", "translation only")
        }
        panel.nameFieldStringValue = "\(reader.record.title) (\(suffix)).pdf"
        panel.directoryURL = reader.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        guard dest.standardizedFileURL != reader.url.standardizedFileURL else {
            errorMessage = L("不能覆蓋原始 PDF，請選擇其他檔名。", "You can’t overwrite the original PDF. Choose another name.")
            return
        }

        let source = reader.url
        let mode = self.mode
        let db = coordinator.databaseForExport
        let docID = coordinator.documentID
        let key = coordinator.cacheKey
        let range = 0...(reader.pageCount - 1)
        let fontFamily = coordinator.fontFamily
        let flag = CancelFlag()
        cancelFlag = flag
        isExporting = true
        progress = 0
        resultURL = nil
        errorMessage = nil

        exportTask = Task {
            let outcome: Result<ExportSummary, Error> = await Task.detached(priority: .userInitiated) {
                let blocks = TranslationCoordinator.exportBlocks(database: db, documentID: docID, key: key, range: range)
                return Result {
                    try TranslatedPDFExporter.export(
                        source: source, destination: dest, mode: mode, pageRange: range, blocksByPage: blocks,
                        fontFamily: fontFamily,
                        progress: { done, total in
                            Task { @MainActor in progress = Double(done) / Double(max(1, total)) }
                        },
                        isCancelled: { flag.isCancelled })
                }
            }.value
            isExporting = false
            switch outcome {
            case .success(let summary): resultURL = summary.outputURL
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }
}

/// 跨執行緒的取消旗標。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
