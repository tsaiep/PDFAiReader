import XCTest
import ReaderCore
@testable import ReaderStore

final class AppDatabaseTests: XCTestCase {
    func testDocumentProgressBookmarkRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let doc = DocumentRecord(id: "doc1", path: "/tmp/a.pdf", bookmarkData: nil,
                                 title: "A", pageCount: 10, fileSize: 123)
        try db.upsertDocument(doc)
        XCTAssertEqual(try db.document(id: "doc1")?.title, "A")

        var updated = doc
        updated.title = "B"
        try db.upsertDocument(updated)
        XCTAssertEqual(try db.recentDocuments().count, 1)
        XCTAssertEqual(try db.document(id: "doc1")?.title, "B")

        let progress = ReadingProgress(documentID: "doc1", pageIndex: 7, scaleFactor: 1.5,
                                       autoScales: false, displayMode: .twoUp)
        try db.saveProgress(progress)
        let loaded = try db.progress(documentID: "doc1")
        XCTAssertEqual(loaded?.pageIndex, 7)
        XCTAssertEqual(loaded?.displayMode, .twoUp)

        let bm = try db.addBookmark(Bookmark(documentID: "doc1", pageIndex: 3, title: "第 4 頁"))
        XCTAssertNotNil(bm.id)
        XCTAssertEqual(try db.bookmarks(documentID: "doc1").count, 1)
        try db.deleteBookmark(id: bm.id!)
        XCTAssertTrue(try db.bookmarks(documentID: "doc1").isEmpty)
    }

    func testDeletingDocumentCascades() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertDocument(DocumentRecord(id: "d", path: "/x", bookmarkData: nil, title: "x",
                                             pageCount: 1, fileSize: 1))
        try db.addBookmark(Bookmark(documentID: "d", pageIndex: 0, title: "b"))
        try db.removeDocument(id: "d")
        XCTAssertTrue(try db.bookmarks(documentID: "d").isEmpty)
    }

    func testPreferences() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertNil(try db.preference("k"))
        try db.setPreference("k", value: "1")
        try db.setPreference("k", value: "2")
        XCTAssertEqual(try db.preference("k"), "2")
        try db.setPreference("k", value: nil)
        XCTAssertNil(try db.preference("k"))
    }
}
