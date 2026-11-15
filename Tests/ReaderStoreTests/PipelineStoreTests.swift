import XCTest
import ReaderCore
@testable import ReaderStore

final class PipelineStoreTests: XCTestCase {
    private func setup() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.upsertDocument(DocumentRecord(id: "d", path: "/x.pdf", bookmarkData: nil, title: "x",
                                             pageCount: 10, fileSize: 1))
        return db
    }

    private func block(_ order: Int, _ text: String, page: Int = 0) -> TextBlock {
        TextBlock(id: TextBlock.makeID(documentID: "d", pageIndex: page, order: order), documentID: "d",
                  pageIndex: page, readingOrder: order, kind: .paragraph, text: text,
                  bounds: PageRect(x: 1, y: 2, width: 3, height: 4), confidence: 0.9, source: .ocr)
    }

    func testBlocksRoundTripAndSearch() throws {
        let db = try setup()
        XCTAssertNil(try db.textBlocks(documentID: "d", pageIndex: 0))
        let page = StoredPage(pageIndex: 0, width: 600, height: 800, rotation: 0, textSource: .ocr, meanConfidence: 0.9)
        try db.saveTextBlocks(documentID: "d", page: page, blocks: [block(0, "Hello world"), block(1, "100% sure_x")])
        let loaded = try db.textBlocks(documentID: "d", pageIndex: 0)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?.first?.bounds, PageRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(try db.searchTextBlocks(documentID: "d", query: "WORLD").count, 1)
        XCTAssertEqual(try db.searchTextBlocks(documentID: "d", query: "%").count, 1)
        XCTAssertEqual(try db.extractedPageIndices(documentID: "d"), [0])
    }

    func testTranslationsInvalidateWhenSourceChanges() throws {
        let db = try setup()
        let page = StoredPage(pageIndex: 0, width: 1, height: 1, rotation: 0, textSource: .ocr, meanConfidence: 1)
        let b = block(0, "Original")
        try db.saveTextBlocks(documentID: "d", page: page, blocks: [b])
        let key = TranslationCacheKey(engine: "e", model: nil)
        try db.saveTranslations(documentID: "d", key: key, items: [(b, "原文")])
        XCTAssertEqual(try db.translations(documentID: "d", pageIndex: 0, key: key)[b.id], "原文")
        XCTAssertTrue(try db.translations(documentID: "d", pageIndex: 0,
                                          key: TranslationCacheKey(engine: "e", model: "other")).isEmpty)
        // 重新 OCR 後文字改變 → 舊譯文失效
        try db.saveTextBlocks(documentID: "d", page: page, blocks: [block(0, "Changed")])
        XCTAssertTrue(try db.translations(documentID: "d", pageIndex: 0, key: key).isEmpty)
    }

    func testPageStates() throws {
        let db = try setup()
        let key = TranslationCacheKey(engine: "e", model: nil)
        try db.setPageTranslationState(documentID: "d", pageIndex: 2, key: key, state: .failed, error: "x")
        try db.setPageTranslationState(documentID: "d", pageIndex: 2, key: key, state: .done)
        let states = try db.pageTranslationStates(documentID: "d", key: key)
        XCTAssertEqual(states[2]?.state, .done)
        XCTAssertNil(states[2]?.errorMessage)
    }
}
