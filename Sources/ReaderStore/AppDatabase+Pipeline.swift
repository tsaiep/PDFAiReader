import Foundation
import GRDB
import ReaderCore

/// 頁面的文字擷取結果（OCR 或內嵌文字層）。
public struct StoredPage: Sendable, Equatable {
    public var pageIndex: Int
    public var width: Double
    public var height: Double
    public var rotation: Int
    public var textSource: TextSource
    public var meanConfidence: Double

    public init(pageIndex: Int, width: Double, height: Double, rotation: Int,
                textSource: TextSource, meanConfidence: Double) {
        self.pageIndex = pageIndex
        self.width = width
        self.height = height
        self.rotation = rotation
        self.textSource = textSource
        self.meanConfidence = meanConfidence
    }
}

public enum PageTranslationRecordState: String, Sendable {
    case done
    case failed
}

public struct PageTranslationRecord: Sendable, Equatable {
    public var pageIndex: Int
    public var state: PageTranslationRecordState
    public var errorMessage: String?
}

extension AppDatabase {
    // MARK: - 文字區塊

    /// 寫入某頁的文字擷取結果（覆蓋舊資料）。
    public func saveTextBlocks(documentID: String, page: StoredPage, blocks: [TextBlock]) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO pages(documentID, pageIndex, width, height, rotation, textSource, ocrState, ocrConfidence)
                VALUES (?, ?, ?, ?, ?, ?, 'done', ?)
                ON CONFLICT(documentID, pageIndex) DO UPDATE SET
                  width = excluded.width, height = excluded.height, rotation = excluded.rotation,
                  textSource = excluded.textSource, ocrState = 'done', ocrConfidence = excluded.ocrConfidence
                """, arguments: [documentID, page.pageIndex, page.width, page.height, page.rotation,
                                 page.textSource.rawValue, page.meanConfidence])
            try db.execute(sql: "DELETE FROM text_blocks WHERE documentID = ? AND pageIndex = ?",
                           arguments: [documentID, page.pageIndex])
            for b in blocks {
                let bounds = String(decoding: try JSONEncoder().encode(b.bounds), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO text_blocks(id, documentID, pageIndex, readingOrder, kind, text, bounds,
                                            confidence, source, textHash, userEdited)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    """, arguments: [b.id, documentID, b.pageIndex, b.readingOrder, b.kind.rawValue, b.text,
                                     bounds, b.confidence, b.source.rawValue, DocumentFingerprint.textHash(b.text)])
            }
        }
    }

    /// 已擷取文字的頁；nil 表示尚未擷取。
    public func textBlocks(documentID: String, pageIndex: Int) throws -> [TextBlock]? {
        try writer.read { db in
            let state = try String.fetchOne(db, sql: "SELECT ocrState FROM pages WHERE documentID = ? AND pageIndex = ?",
                                            arguments: [documentID, pageIndex])
            guard state == "done" else { return nil }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM text_blocks WHERE documentID = ? AND pageIndex = ? ORDER BY readingOrder
                """, arguments: [documentID, pageIndex]).compactMap(Self.block(from:))
        }
    }

    public func extractedPageIndices(documentID: String) throws -> Set<Int> {
        try writer.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT pageIndex FROM pages WHERE documentID = ? AND ocrState = 'done'",
                                 arguments: [documentID]))
        }
    }

    /// 搜尋 OCR／內嵌文字（不分大小寫）。
    public func searchTextBlocks(documentID: String, query: String, limit: Int = 500) throws -> [TextBlock] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM text_blocks WHERE documentID = ? AND text LIKE ? ESCAPE '\\'
                ORDER BY pageIndex, readingOrder LIMIT ?
                """, arguments: [documentID, "%" + Self.escapeLike(query) + "%", limit]).compactMap(Self.block(from:))
        }
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func block(from row: Row) -> TextBlock? {
        guard let kind = BlockKind(rawValue: row["kind"]),
              let source = TextSource(rawValue: row["source"]),
              let boundsJSON: String = row["bounds"],
              let bounds = try? JSONDecoder().decode(PageRect.self, from: Data(boundsJSON.utf8)) else { return nil }
        return TextBlock(id: row["id"], documentID: row["documentID"], pageIndex: row["pageIndex"],
                         readingOrder: row["readingOrder"], kind: kind, text: row["text"], bounds: bounds,
                         confidence: row["confidence"], source: source)
    }

    // MARK: - 譯文

    public func saveTranslations(documentID: String, key: TranslationCacheKey,
                                 items: [(block: TextBlock, translation: String)]) throws {
        guard !items.isEmpty else { return }
        try writer.write { db in
            for item in items {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO translations(blockID, documentID, pageIndex, sourceHash, targetLanguage,
                        engine, model, promptVersion, contextVersion, translation, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [item.block.id, documentID, item.block.pageIndex,
                                     DocumentFingerprint.textHash(item.block.text), key.targetLanguage,
                                     key.engine, key.model, key.promptVersion, key.contextVersion,
                                     item.translation, Date()])
            }
        }
    }

    /// 某頁目前有效的譯文（來源文字未變、設定相同），blockID → 譯文。
    public func translations(documentID: String, pageIndex: Int, key: TranslationCacheKey) throws -> [String: String] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.blockID, t.translation FROM translations t
                JOIN text_blocks b ON b.id = t.blockID AND b.textHash = t.sourceHash
                WHERE t.documentID = ? AND t.pageIndex = ? AND t.targetLanguage = ? AND t.engine = ?
                  AND t.model = ? AND t.promptVersion = ? AND t.contextVersion = ?
                """, arguments: [documentID, pageIndex, key.targetLanguage, key.engine, key.model,
                                 key.promptVersion, key.contextVersion])
            var map: [String: String] = [:]
            for r in rows { map[r["blockID"]] = r["translation"] }
            return map
        }
    }

    /// 某頁目前有效的譯文：同一目標語言、來源文字未變；不分引擎、模型與 Prompt 版本，取最新一筆。
    /// （換模型或升級 Prompt 後仍沿用既有譯文，「重新翻譯」才會產生新版本。）
    public func latestTranslations(documentID: String, pageIndex: Int, targetLanguage: String) throws -> [String: String] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.blockID, t.translation FROM translations t
                JOIN text_blocks b ON b.id = t.blockID AND b.textHash = t.sourceHash
                WHERE t.documentID = ? AND t.pageIndex = ? AND t.targetLanguage = ?
                ORDER BY t.createdAt ASC, t.id ASC
                """, arguments: [documentID, pageIndex, targetLanguage])
            var map: [String: String] = [:]
            for r in rows { map[r["blockID"]] = r["translation"] }   // 後面的覆蓋前面的 → 最新
            return map
        }
    }

    // MARK: - 頁面翻譯狀態

    public func setPageTranslationState(documentID: String, pageIndex: Int, key: TranslationCacheKey,
                                        state: PageTranslationRecordState, error: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO page_translation_status(documentID, pageIndex, cacheKey, state, errorMessage, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(documentID, pageIndex, cacheKey) DO UPDATE SET
                  state = excluded.state, errorMessage = excluded.errorMessage, updatedAt = excluded.updatedAt
                """, arguments: [documentID, pageIndex, key.fingerprint, state.rawValue, error, Date()])
        }
    }

    public func pageTranslationStates(documentID: String, key: TranslationCacheKey) throws -> [Int: PageTranslationRecord] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT pageIndex, state, errorMessage FROM page_translation_status
                WHERE documentID = ? AND cacheKey = ?
                """, arguments: [documentID, key.fingerprint])
            var map: [Int: PageTranslationRecord] = [:]
            for r in rows {
                let idx: Int = r["pageIndex"]
                map[idx] = PageTranslationRecord(pageIndex: idx,
                                                 state: PageTranslationRecordState(rawValue: r["state"]) ?? .failed,
                                                 errorMessage: r["errorMessage"])
            }
            return map
        }
    }
}
