import SwiftUI
import ReaderCore
import ReaderStore
import ReaderServices
import TranslationCodex

enum PageStatus: Equatable {
    case idle
    case extracting
    case queued
    case translating
    case done
    case failed(String)

    var isBusy: Bool { self == .extracting || self == .queued || self == .translating }
}

struct WholeJob: Equatable {
    var range: ClosedRange<Int>
    var isPaused: Bool
}

struct SelectionTranslation: Equatable {
    var original: String
    var translation: String?
    var error: String?
    var isLoading: Bool
}

/// 單一文件的 OCR＋翻譯管線。
///
/// - 互動通道：選取文字／單段立即翻譯，直接呼叫引擎，不排隊
/// - 背景通道：可見頁 > 預翻頁 > 整份翻譯，一次一個批次（相鄰頁合併）
/// - 所有結果寫入 SQLite；重新開啟文件或程式後沿用
@MainActor
@Observable
final class TranslationCoordinator {
    let documentID: String
    let url: URL
    let pageCount: Int
    let title: String

    // MARK: 對外狀態
    private(set) var status: [Int: PageStatus] = [:]
    private(set) var blocks: [Int: [TextBlock]] = [:]
    private(set) var translations: [Int: [String: String]] = [:]
    private(set) var focusPages: [Int] = []
    private(set) var whole: WholeJob?
    private(set) var completedPages: Set<Int> = []
    private(set) var currentBatch: [Int] = []
    private(set) var blockedMessage: String?
    private(set) var selection: SelectionTranslation?
    private(set) var lastBatchSeconds: Double?

    var autoTranslate: Bool {
        didSet { UserDefaults.standard.set(autoTranslate, forKey: "autoTranslate"); refreshPrefetch() }
    }

    var model: String? {
        let m = UserDefaults.standard.string(forKey: "codexModel")?.trimmingCharacters(in: .whitespaces)
        return (m?.isEmpty ?? true) ? nil : m
    }

    /// 實際寫入譯文時記錄的引擎與模型。
    var cacheKey: TranslationCacheKey { TranslationCacheKey(engine: engine.engineID, model: model) }

    /// 頁面完成狀態不分模型：換模型後已翻好的頁面維持完成，只有新頁面或「重新翻譯」才用新模型。
    var statusKey: TranslationCacheKey { TranslationCacheKey(engine: "any", model: "any") }

    /// 某頁的譯文有變動時通知（頁面疊加層據此重繪）。
    @ObservationIgnored var onTranslationsChanged: ((Int) -> Void)?

    // MARK: 內部
    @ObservationIgnored private let database: AppDatabase?
    @ObservationIgnored private let engine: any TranslationEngine
    @ObservationIgnored private var extractor: TextExtractor?
    @ObservationIgnored private var queue: [Int: JobPriority] = [:]
    @ObservationIgnored private var forceRetranslate: Set<Int> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var extractionTasks: [Int: Task<[TextBlock], Error>] = [:]
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var visible: Set<Int> = []
    @ObservationIgnored private var direction: NavigationDirection = .forward
    @ObservationIgnored private let batcher = TranslationBatcher(maxCharacters: 6000, maxPages: 3)

    init(documentID: String, url: URL, pageCount: Int, title: String,
         database: AppDatabase?, engine: any TranslationEngine) {
        self.documentID = documentID
        self.url = url
        self.pageCount = pageCount
        self.title = title
        self.database = database
        self.engine = engine
        UserDefaults.standard.register(defaults: ["autoTranslate": true, "prefetchPageCount": 5])
        self.autoTranslate = UserDefaults.standard.bool(forKey: "autoTranslate")
        loadPersistedState()
    }

    var prefetchCount: Int { max(0, UserDefaults.standard.integer(forKey: "prefetchPageCount")) }

    // MARK: - 持久化狀態

    private func loadPersistedState() {
        guard let db = database else { return }
        let states = (try? db.pageTranslationStates(documentID: documentID, key: statusKey)) ?? [:]
        completedPages = Set(states.values.filter { $0.state == .done }.map(\.pageIndex))
        for (i, s) in states {
            status[i] = s.state == .done ? .done : .failed(s.errorMessage ?? "翻譯失敗")
        }
        if let active = try? db.preference("whole.active", scope: documentID), active == "1",
           let rangeText = try? db.preference("whole.range", scope: documentID),
           let range = Self.parseRange(rangeText, pageCount: pageCount) {
            // 重新開啟後先暫停，避免一開檔就自動消耗額度
            whole = WholeJob(range: range, isPaused: true)
        }
    }

    private func persistWhole() {
        guard let db = database else { return }
        if let whole {
            try? db.setPreference("whole.active", value: "1", scope: documentID)
            try? db.setPreference("whole.range", value: "\(whole.range.lowerBound)-\(whole.range.upperBound)",
                                  scope: documentID)
        } else {
            try? db.setPreference("whole.active", value: nil, scope: documentID)
        }
    }

    static func parseRange(_ s: String, pageCount: Int) -> ClosedRange<Int>? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[0] <= parts[1], pageCount > 0 else { return nil }
        return max(0, parts[0])...min(pageCount - 1, parts[1])
    }

    /// 設定（模型）改變後重新載入完成狀態。
    func settingsChanged() {
        status = status.filter { $0.value.isBusy }
        loadPersistedState()
        for p in focusPages { loadCached(p) }
    }

    // MARK: - 閱讀位置

    func visibleChanged(_ pages: Set<Int>, direction: NavigationDirection) {
        visible = pages
        self.direction = direction
        focusPages = Array(pages.sorted().prefix(3))
        for p in focusPages {
            loadCached(p)
            if blocks[p] == nil { Task { try? await self.extractIfNeeded(p) } }
        }
        refreshPrefetch()
    }

    private func refreshPrefetch() {
        let plan = autoTranslate
            ? PrefetchPlanner(aheadCount: prefetchCount).plan(visible: visible, pageCount: pageCount, direction: direction)
            : []
        let planned = Dictionary(plan.map { ($0.pageIndex, $0.priority) }, uniquingKeysWith: min)

        // 已不在規劃範圍內的預翻頁：整份翻譯中降為背景，否則移出佇列
        for (page, priority) in queue where priority == .visible || priority == .prefetch {
            if planned[page] == nil {
                if let whole, !whole.isPaused, whole.range.contains(page) {
                    queue[page] = .background
                } else {
                    queue.removeValue(forKey: page)
                    if status[page] == .queued { status[page] = .idle }
                }
            }
        }
        for (page, priority) in planned {
            enqueue(page, priority: priority)
        }
        startWorkerIfNeeded()
    }

    /// 從資料庫載入某頁已有的文字與譯文。
    func loadCached(_ page: Int) {
        guard let db = database else { return }
        if blocks[page] == nil, let stored = try? db.textBlocks(documentID: documentID, pageIndex: page) {
            blocks[page] = stored
        }
        if translations[page] == nil {
            translations[page] = (try? db.latestTranslations(documentID: documentID, pageIndex: page,
                                                            targetLanguage: cacheKey.targetLanguage,
                                                            promptVersion: cacheKey.promptVersion)) ?? [:]
        }
    }

    // MARK: - 文字擷取

    @discardableResult
    func extractIfNeeded(_ page: Int, force: Bool = false) async throws -> [TextBlock] {
        if !force {
            if let b = blocks[page] { return b }
            if let stored = try? database?.textBlocks(documentID: documentID, pageIndex: page) {
                blocks[page] = stored
                return stored
            }
        }
        if let running = extractionTasks[page] { return try await running.value }

        if extractor == nil { extractor = try TextExtractor(url: url, documentID: documentID) }
        guard let extractor else { return [] }
        let previous = status[page]
        status[page] = .extracting
        let task = Task<[TextBlock], Error> {
            let result = try await extractor.extract(pageIndex: page, forceOCR: force)
            let stored = StoredPage(pageIndex: page, width: result.geometry.cropBox.width,
                                    height: result.geometry.cropBox.height, rotation: result.geometry.rotation,
                                    textSource: result.source, meanConfidence: result.meanConfidence)
            try? self.database?.saveTextBlocks(documentID: self.documentID, page: stored, blocks: result.blocks)
            return result.blocks
        }
        extractionTasks[page] = task
        defer { extractionTasks.removeValue(forKey: page) }
        do {
            let result = try await task.value
            blocks[page] = result
            if force { translations[page] = [:]; onTranslationsChanged?(page) }
            if status[page] == .extracting { status[page] = (previous == .extracting ? .idle : previous) ?? .idle }
            return result
        } catch {
            status[page] = .failed("文字辨識失敗：\(error.localizedDescription)")
            throw error
        }
    }

    func reExtract(_ page: Int) {
        Task {
            _ = try? await extractIfNeeded(page, force: true)
            completedPages.remove(page)
            status[page] = .idle
        }
    }

    // MARK: - 佇列

    private func enqueue(_ page: Int, priority: JobPriority) {
        guard page >= 0, page < pageCount else { return }
        guard !completedPages.contains(page) || forceRetranslate.contains(page) else { return }
        guard !currentBatch.contains(page) else { return }
        if case .failed = status[page], priority == .prefetch { return }   // 失敗頁不自動重試
        queue[page] = min(queue[page] ?? priority, priority)
        if status[page] != .extracting { status[page] = .queued }
    }

    func translatePages(_ pages: [Int]) {
        for p in pages {
            if case .failed = status[p] { status[p] = .idle }
            enqueue(p, priority: .visible)
        }
        blockedMessage = nil
        startWorkerIfNeeded()
    }

    func translateFocusPages() { translatePages(focusPages.isEmpty ? Array(visible) : focusPages) }

    func retranslate(_ page: Int) {
        forceRetranslate.insert(page)
        completedPages.remove(page)
        translatePages([page])
    }

    // MARK: - 整份翻譯

    func startWhole(range: ClosedRange<Int>) {
        whole = WholeJob(range: range, isPaused: false)
        persistWhole()
        blockedMessage = nil
        for p in range { enqueue(p, priority: .background) }
        startWorkerIfNeeded()
    }

    func pauseWhole() {
        guard var w = whole else { return }
        w.isPaused = true
        whole = w
        for (p, pr) in queue where pr == .background {
            queue.removeValue(forKey: p)
            if status[p] == .queued { status[p] = .idle }
        }
    }

    func resumeWhole() {
        guard let w = whole else { return }
        startWhole(range: w.range)
    }

    func cancelWhole() {
        pauseWhole()
        whole = nil
        persistWhole()
    }

    func retryFailed() {
        let failed = status.compactMap { (k, v) -> Int? in if case .failed = v { return k } else { return nil } }
        translatePages(failed.sorted())
    }

    var wholeCompleted: Int { whole.map { w in completedPages.filter { w.range.contains($0) }.count } ?? 0 }

    var wholeFailed: Int {
        guard let w = whole else { return 0 }
        var n = 0
        for (k, v) in status where w.range.contains(k) {
            if case .failed = v { n += 1 }
        }
        return n
    }

    var wholeIsFinished: Bool {
        guard let w = whole else { return false }
        return wholeCompleted + wholeFailed >= w.range.count
    }

    // MARK: - 背景工作

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty, blockedMessage == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let next = self.nextPage() else { break }
                await self.process(first: next)
            }
            self?.worker = nil
            self?.finishWholeIfDone()
        }
    }

    private func nextPage() -> Int? {
        guard blockedMessage == nil else { return nil }
        let anchor = visible.min() ?? 0
        return queue.min { a, b in
            if a.value != b.value { return a.value < b.value }
            if a.value == .background { return a.key < b.key }
            return abs(a.key - anchor) < abs(b.key - anchor)
        }?.key
    }

    private func pendingCharacters(_ page: Int) -> Int {
        guard let b = blocks[page] else { return Int.max / 4 }
        let done = translations[page] ?? [:]
        return b.filter { $0.needsTranslation && done[$0.id] == nil }.map(\.text.count).reduce(0, +)
    }

    private func process(first: Int) async {
        // 1. 確保有文字（本頁與可合併的相鄰頁）
        do {
            try await extractIfNeeded(first)
            for c in [first + 1, first + 2, first - 1] where queue[c] != nil && blocks[c] == nil {
                _ = try? await extractIfNeeded(c)
            }
        } catch {
            queue.removeValue(forKey: first)
            markFailed([first], "文字辨識失敗：\(error.localizedDescription)")
            return
        }
        guard queue[first] != nil else { return }   // 等待期間被移出佇列

        for p in [first - 1, first, first + 1, first + 2] where p >= 0 && p < pageCount { loadCached(p) }
        let pages = batcher.batch(first: first, candidates: Array(queue.keys)) { self.pendingCharacters($0) }
        for p in pages {
            queue.removeValue(forKey: p)
            status[p] = .translating
        }
        currentBatch = pages
        defer { currentBatch = [] }

        // 2. 組成請求（略過已有有效譯文的區塊）
        var segments: [TranslationSegment] = []
        var blockByID: [String: TextBlock] = [:]
        for p in pages {
            // 重新翻譯時保留舊譯文顯示，直到新譯文回來
            let existing = forceRetranslate.contains(p) ? [:] : (translations[p] ?? [:])
            for b in blocks[p] ?? [] where b.needsTranslation && existing[b.id] == nil {
                segments.append(TranslationSegment(id: b.id, kind: b.kind, text: b.text))
                blockByID[b.id] = b
            }
        }
        guard !segments.isEmpty else {
            markDone(pages)
            return
        }

        let previousTail = (blocks[pages[0] - 1] ?? []).suffix(2).map(\.text)
        var request = TranslationRequest(segments: segments,
                                         context: TranslationContext(bookTitle: title, precedingText: Array(previousTail)),
                                         model: model)
        let started = Date()

        // 3. 呼叫引擎；缺漏的區塊重試一次
        for attempt in 0..<2 {
            do {
                let response = try await engine.translate(request)
                let outcome = TranslationResultValidator.validate(request: request, response: response)
                let items = outcome.accepted.compactMap { t in blockByID[t.id].map { ($0, t.translation) } }
                try? database?.saveTranslations(documentID: documentID, key: cacheKey, items: items)
                for (b, t) in items { translations[b.pageIndex, default: [:]][b.id] = t }
                for p in Set(items.map(\.0.pageIndex)) { onTranslationsChanged?(p) }
                if outcome.isComplete || attempt == 1 { break }
                request.segments = request.segments.filter { outcome.missingIDs.contains($0.id) }
            } catch {
                handle(error: error, pages: pages)
                return
            }
        }
        lastBatchSeconds = Date().timeIntervalSince(started)

        // 4. 結算每頁
        var done: [Int] = [], failed: [Int] = []
        for p in pages {
            let t = translations[p] ?? [:]
            let missing = (blocks[p] ?? []).filter { $0.needsTranslation && t[$0.id] == nil }
            if missing.isEmpty { done.append(p) } else { failed.append(p) }
        }
        markDone(done)
        markFailed(failed, "有 \(failed.count) 頁部分段落未翻譯")
    }

    private func handle(error: Error, pages: [Int]) {
        if error is CancellationError || (error as? CodexError) == .cancelled || Task.isCancelled {
            for p in pages { status[p] = .idle }
            return
        }
        let message = error.localizedDescription
        let lower = message.lowercased()
        let isBlocking: Bool = {
            if let c = error as? CodexError, c == .notInstalled { return true }
            return ["usage limit", "rate limit", "quota", "429", "not logged in", "login", "unauthorized", "401"]
                .contains { lower.contains($0) }
        }()
        if isBlocking {
            // 引擎無法使用（未安裝、未登入、額度用盡）：暫停所有背景翻譯，保留進度
            blockedMessage = message
            for p in pages { status[p] = .idle }
            pauseWhole()
            queue.removeAll()
            for (p, s) in status where s == .queued { status[p] = .idle }
        } else {
            markFailed(pages, message)
        }
    }

    private func markDone(_ pages: [Int]) {
        for p in pages {
            status[p] = .done
            completedPages.insert(p)
            forceRetranslate.remove(p)
            try? database?.setPageTranslationState(documentID: documentID, pageIndex: p, key: statusKey, state: .done)
        }
    }

    private func markFailed(_ pages: [Int], _ message: String) {
        for p in pages {
            status[p] = .failed(message)
            forceRetranslate.remove(p)
            try? database?.setPageTranslationState(documentID: documentID, pageIndex: p, key: statusKey,
                                                   state: .failed, error: message)
        }
    }

    private func finishWholeIfDone() {
        if wholeIsFinished, let w = whole, !w.isPaused {
            try? database?.setPreference("whole.active", value: nil, scope: documentID)
        }
    }

    func clearBlocked() {
        blockedMessage = nil
        refreshPrefetch()
    }

    // MARK: - 互動通道

    func translateSelection(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectionTask?.cancel()
        selection = SelectionTranslation(original: trimmed, translation: nil, error: nil, isLoading: true)
        let request = TranslationRequest(
            segments: [TranslationSegment(id: "selection", kind: .paragraph, text: String(trimmed.prefix(8000)))],
            context: TranslationContext(bookTitle: title), model: model)
        selectionTask = Task {
            do {
                let response = try await engine.translate(request)
                guard !Task.isCancelled else { return }
                let text = response.translations.first { $0.id == "selection" }?.translation
                selection = SelectionTranslation(original: trimmed, translation: text,
                                                 error: text == nil ? "沒有取得譯文" : nil, isLoading: false)
            } catch {
                guard !Task.isCancelled else { return }
                selection = SelectionTranslation(original: trimmed, translation: nil,
                                                 error: error.localizedDescription, isLoading: false)
            }
        }
    }

    /// 立即翻譯單一區塊（走互動通道並寫入快取）。
    func translateBlockNow(_ block: TextBlock) {
        let request = TranslationRequest(segments: [TranslationSegment(id: block.id, kind: block.kind, text: block.text)],
                                         context: TranslationContext(bookTitle: title), model: model)
        Task {
            do {
                let response = try await engine.translate(request)
                let outcome = TranslationResultValidator.validate(request: request, response: response)
                if let t = outcome.accepted.first {
                    try? database?.saveTranslations(documentID: documentID, key: cacheKey, items: [(block, t.translation)])
                    translations[block.pageIndex, default: [:]][block.id] = t.translation
                    onTranslationsChanged?(block.pageIndex)
                }
            } catch {
                selection = SelectionTranslation(original: block.text, translation: nil,
                                                 error: error.localizedDescription, isLoading: false)
            }
        }
    }

    func dismissSelection() {
        selectionTask?.cancel()
        selection = nil
    }

    // MARK: - 頁面疊加

    /// 計算某頁譯文疊加的幾何與樣式（背景取樣在擷取器的獨立文件實例上進行）。
    func overlayStyles(page: Int, items: [OverlayItem]) async -> (geometry: PageGeometry, styles: [OverlayStyle])? {
        if extractor == nil { extractor = try? TextExtractor(url: url, documentID: documentID) }
        guard let extractor else { return nil }
        return await extractor.overlayStyles(pageIndex: page, items: items)
    }

    // MARK: - 匯出資料

    /// 收集匯出所需資料（在背景執行緒讀取資料庫）。
    nonisolated static func exportBlocks(database: AppDatabase?, documentID: String, key: TranslationCacheKey,
                                         range: ClosedRange<Int>) -> [Int: [ExportBlock]] {
        guard let database else { return [:] }
        var result: [Int: [ExportBlock]] = [:]
        for p in range {
            guard let blocks = try? database.textBlocks(documentID: documentID, pageIndex: p), !blocks.isEmpty else { continue }
            let t = (try? database.latestTranslations(documentID: documentID, pageIndex: p,
                                                       targetLanguage: key.targetLanguage,
                                                       promptVersion: key.promptVersion)) ?? [:]
            result[p] = blocks.map { ExportBlock(kind: $0.kind, bounds: $0.bounds, original: $0.text, translation: t[$0.id]) }
        }
        return result
    }

    var databaseForExport: AppDatabase? { database }

    // MARK: - 結束

    func shutdown() {
        worker?.cancel()
        selectionTask?.cancel()
        for t in extractionTasks.values { t.cancel() }
    }
}
