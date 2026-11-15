import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import ReaderCore
import ReaderStore
import TranslationCodex

@MainActor
@Observable
final class AppModel {
    private(set) var database: AppDatabase?
    private(set) var recentDocuments: [DocumentRecord] = []
    private(set) var reader: ReaderModel?
    var alertMessage: String?

    let codex = CodexCLIEngine()
    private(set) var codexStatus: EngineAvailability?
    private(set) var isCheckingCodex = false
    private(set) var modelTestResult: String?
    private(set) var isTestingModel = false
    /// `~/.codex/config.toml` 中的預設模型（僅供顯示）。
    private(set) var configDefaultModel: String?
    var showAddModel = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        do {
            database = try AppDatabase.openDefault()
        } catch {
            alertMessage = "無法開啟資料庫：\(error.localizedDescription)\n閱讀功能仍可使用，但不會保存進度與譯文。"
        }
        refreshRecent()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .openDocumentURLs, object: nil, queue: .main) { [weak self] note in
            guard let urls = note.object as? [URL], let url = urls.first else { return }
            MainActor.assumeIsolated { self?.open(url: url) }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reader?.close() }
        })

        configDefaultModel = Self.readConfigDefaultModel()
        Task { await applyStoredCodexSettings() }
    }

    // MARK: - 文件

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "選擇要閱讀的 PDF"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        guard let pdf = PDFDocument(url: url) else {
            alertMessage = "無法開啟「\(url.lastPathComponent)」，檔案可能不是有效的 PDF。"
            return
        }
        if pdf.isLocked && !pdf.unlock(withPassword: "") {
            alertMessage = "「\(url.lastPathComponent)」有密碼保護，目前版本尚不支援。"
            return
        }

        let fingerprint: (id: String, fileSize: Int64)
        do {
            fingerprint = try DocumentFingerprint.compute(url: url)
        } catch {
            alertMessage = "無法讀取檔案：\(error.localizedDescription)"
            return
        }

        reader?.close()

        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let record = DocumentRecord(id: fingerprint.id, path: url.path, bookmarkData: bookmark,
                                    title: title, pageCount: pdf.pageCount,
                                    fileSize: fingerprint.fileSize, lastOpenedAt: Date())
        try? database?.upsertDocument(record)

        let progress = (try? database?.progress(documentID: record.id)) ?? nil
        let bookmarks = (try? database?.bookmarks(documentID: record.id)) ?? []
        let coordinator = TranslationCoordinator(documentID: record.id, url: url, pageCount: pdf.pageCount,
                                                 title: title, database: database, engine: codex)

        reader = ReaderModel(document: pdf, url: url, record: record, progress: progress,
                             bookmarks: bookmarks, database: database, translation: coordinator)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshRecent()
    }

    /// 從最近開啟紀錄重新開啟：優先用 bookmark 找回被搬移的檔案。
    func reopen(_ record: DocumentRecord) {
        if let url = resolveURL(for: record) {
            open(url: url)
        } else {
            alertMessage = "找不到「\(record.title)」。檔案可能已被刪除或移到無法存取的位置。\n原路徑：\(record.path)"
        }
    }

    func resolveURL(for record: DocumentRecord) -> URL? {
        if let data = record.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return FileManager.default.fileExists(atPath: record.path) ? URL(fileURLWithPath: record.path) : nil
    }

    func closeDocument() {
        reader?.close()
        reader = nil
        refreshRecent()
    }

    func removeFromRecent(_ record: DocumentRecord) {
        try? database?.removeDocument(id: record.id)
        refreshRecent()
    }

    func refreshRecent() {
        recentDocuments = (try? database?.recentDocuments(limit: 30)) ?? []
    }

    // MARK: - Codex

    func applyStoredCodexSettings() async {
        let d = UserDefaults.standard
        await applyCodexSettings(path: d.string(forKey: "codexPath") ?? "", model: d.string(forKey: "codexModel") ?? "")
    }

    func applyCodexSettings(path: String, model: String) async {
        let effort = UserDefaults.standard.string(forKey: "reasoningEffort") ?? "low"
        let safeEffort = ["low", "medium", "high"].contains(effort) ? effort : "low"
        let config = CodexConfiguration(
            executablePath: path.trimmingCharacters(in: .whitespaces).isEmpty ? nil : path,
            defaultModel: model.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model,
            extraArguments: ["-c", "model_reasoning_effort=\"\(safeEffort)\""]
        )
        await codex.update(configuration: config)
        reader?.translation.settingsChanged()
    }

    func checkCodex() async {
        isCheckingCodex = true
        codexStatus = await codex.availability()
        isCheckingCodex = false
    }

    /// 讀取 Codex 設定檔的預設模型名稱。
    static func readConfigDefaultModel() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }   // 只看最上層設定
            guard t.hasPrefix("model"), let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// 以指定模型翻譯一句短文，確認可用。
    func testModel(_ model: String) async -> (ok: Bool, message: String) {
        let request = TranslationRequest(segments: [TranslationSegment(id: "t", kind: .paragraph,
                                                                       text: "Light writes the picture.")],
                                         model: model.isEmpty ? nil : model)
        let start = Date()
        do {
            let r = try await codex.translate(request)
            let secs = String(format: "%.1f", Date().timeIntervalSince(start))
            return (true, "可用（\(secs) 秒）：\(r.translations.first?.translation ?? "")")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// 以一句短文實際呼叫一次，確認模型可用。
    func testModel() async {
        isTestingModel = true
        modelTestResult = nil
        let model = UserDefaults.standard.string(forKey: "codexModel")
        let request = TranslationRequest(segments: [TranslationSegment(id: "t", kind: .paragraph,
                                                                       text: "Light writes the picture.")],
                                         model: (model?.isEmpty ?? true) ? nil : model)
        let start = Date()
        do {
            let r = try await codex.translate(request)
            let secs = String(format: "%.1f", Date().timeIntervalSince(start))
            modelTestResult = "✅ 可用（\(secs) 秒）：\(r.translations.first?.translation ?? "")"
        } catch {
            modelTestResult = "❌ \(error.localizedDescription)"
        }
        isTestingModel = false
    }
}
