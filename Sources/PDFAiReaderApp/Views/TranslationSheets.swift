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
    @State private var fromText = "1"
    @State private var toText = ""

    private var range: ClosedRange<Int>? {
        guard useRange else { return 0...(reader.pageCount - 1) }
        guard let a = Int(fromText), let b = Int(toText), a >= 1, b >= a else { return nil }
        return (a - 1)...min(b - 1, reader.pageCount - 1)
    }

    private var remaining: Int {
        guard let range else { return 0 }
        return range.filter { !coordinator.completedPages.contains($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("整份翻譯").font(.title2.weight(.semibold))
            Text("在背景依序辨識並翻譯頁面。閱讀中的頁面永遠優先；可隨時暫停，關閉程式後可從未完成的頁面繼續。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("範圍", selection: $useRange) {
                    Text("全部 \(reader.pageCount) 頁").tag(false)
                    Text("指定頁碼").tag(true)
                }
                .pickerStyle(.radioGroup)
                if useRange {
                    HStack {
                        TextField("從", text: $fromText).frame(width: 70)
                        Text("到")
                        TextField("到", text: $toText).frame(width: 70)
                        Text("頁")
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if let range {
                        Text("範圍內共 \(range.count) 頁，已完成 \(range.count - remaining) 頁，需翻譯 \(remaining) 頁")
                        let calls = Int((Double(remaining) / 2.5).rounded(.up))
                        Text("預估約 \(calls) 次 Codex 呼叫，每次約 12–20 秒（實際依頁面字數而定）")
                            .foregroundStyle(.secondary)
                        Text("每次呼叫約消耗 1.7 萬 tokens 以上，請留意 Codex 額度。額度用盡時會自動暫停並保留進度。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("請輸入有效的頁碼範圍").foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("開始翻譯") {
                    if let range { coordinator.startWhole(range: range) }
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
            Text("匯出翻譯 PDF").font(.title2.weight(.semibold))

            Picker("版面", selection: $modeRaw) {
                ForEach(ExportMode.allCases) { m in Text(m.label).tag(m.rawValue) }
            }
            .pickerStyle(.radioGroup)
            .disabled(isExporting)

            let translated = coordinator.completedPages.count
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已翻譯 \(translated)／\(reader.pageCount) 頁")
                    if translated < reader.pageCount {
                        Text(mode == .inPlace || mode == .interleaved
                             ? "未翻譯的頁面會保留原文。"
                             : "純譯文模式只會輸出已翻譯的頁面。")
                            .foregroundStyle(.secondary)
                        Button("先整份翻譯剩下的頁面…") { reader.activeSheet = .wholeTranslation }
                            .disabled(isExporting)
                    }
                    if mode == .inPlace {
                        Text("原位翻譯會以紙色覆蓋原文區塊再填入譯文，圖片與版面維持原樣；字級依區塊大小自動調整。")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isExporting {
                ProgressView(value: progress) { Text("匯出中…") }
            }
            if let resultURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已匯出：\(resultURL.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([resultURL]) }
                    Button("開啟") { NSWorkspace.shared.open(resultURL) }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                if isExporting {
                    Button("取消匯出") { cancelFlag.cancel() }
                } else {
                    Button(resultURL == nil ? "取消" : "完成") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("匯出…") { chooseDestinationAndExport() }
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
        case .inPlace: suffix = "中譯"
        case .interleaved: suffix = "中英對照"
        case .translationOnly: suffix = "譯文"
        }
        panel.nameFieldStringValue = "\(reader.record.title)（\(suffix)）.pdf"
        panel.directoryURL = reader.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        guard dest.standardizedFileURL != reader.url.standardizedFileURL else {
            errorMessage = "不能覆蓋原始 PDF，請選擇其他檔名。"
            return
        }

        let source = reader.url
        let mode = self.mode
        let db = coordinator.databaseForExport
        let docID = coordinator.documentID
        let key = coordinator.cacheKey
        let range = 0...(reader.pageCount - 1)
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
