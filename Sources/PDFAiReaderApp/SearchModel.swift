import SwiftUI
import PDFKit
import ReaderCore
import ReaderStore

struct SearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let pageIndex: Int
    let pageLabel: String
    let snippet: String
    /// 頁面空間座標，用於在主文件上重建選取或標示。
    let bounds: CGRect
    /// 來自 OCR 文字（掃描頁），無法建立文字選取，只能標示區塊。
    let isOCR: Bool
}

/// 文字搜尋：PDF 內嵌文字＋已辨識的 OCR 文字。
/// PDFDocument 非執行緒安全，因此在背景開一個獨立的文件實例搜尋。
@MainActor
@Observable
final class SearchModel {
    let url: URL
    let documentID: String
    var query = ""
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var truncated = false
    private(set) var lastQuery = ""

    @ObservationIgnored private let database: AppDatabase?
    @ObservationIgnored private var task: Task<Void, Never>?
    nonisolated static let maxResults = 500

    init(url: URL, documentID: String, database: AppDatabase?) {
        self.url = url
        self.documentID = documentID
        self.database = database
    }

    func run() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            lastQuery = ""
            return
        }
        isSearching = true
        results = []
        let url = self.url, db = self.database, docID = self.documentID
        task = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                SearchModel.find(q, in: url, database: db, documentID: docID, limit: SearchModel.maxResults)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.results = found.results
            self.truncated = found.truncated
            self.lastQuery = q
            self.isSearching = false
        }
    }

    nonisolated static func find(_ query: String, in url: URL, database: AppDatabase?, documentID: String,
                                 limit: Int) -> (results: [SearchResult], truncated: Bool) {
        var results: [SearchResult] = []
        var truncated = false
        var embeddedPages = Set<Int>()

        if let doc = PDFDocument(url: url) {
            let selections = doc.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            truncated = selections.count > limit
            for selection in selections.prefix(limit) {
                guard let page = selection.pages.first else { continue }
                let index = doc.index(for: page)
                embeddedPages.insert(index)
                var snippet = selection.string ?? query
                if let context = selection.copy() as? PDFSelection {
                    context.extend(atStart: 30)
                    context.extend(atEnd: 40)
                    if let s = context.string { snippet = s.replacingOccurrences(of: "\n", with: " ") }
                }
                results.append(SearchResult(pageIndex: index, pageLabel: page.label ?? "\(index + 1)",
                                            snippet: snippet, bounds: selection.bounds(for: page), isOCR: false))
            }
        }

        // OCR 文字（掃描頁）
        let blocks = (try? database?.searchTextBlocks(documentID: documentID, query: query, limit: limit)) ?? []
        for b in blocks where b.source == .ocr && !embeddedPages.contains(b.pageIndex) {
            results.append(SearchResult(pageIndex: b.pageIndex, pageLabel: "\(b.pageIndex + 1)",
                                        snippet: snippet(of: b.text, around: query),
                                        bounds: b.bounds.cgRect, isOCR: true))
        }
        results.sort { $0.pageIndex < $1.pageIndex }
        return (Array(results.prefix(limit)), truncated || results.count > limit)
    }

    nonisolated static func snippet(of text: String, around query: String) -> String {
        guard let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(90))
        }
        let start = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
