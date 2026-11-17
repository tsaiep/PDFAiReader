import XCTest
import ReaderCore
@testable import ReaderStore

final class NotesStoreTests: XCTestCase {
    private func makeDB() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.upsertDocument(DocumentRecord(id: "d", path: "/x.pdf", bookmarkData: nil, title: "x",
                                             pageCount: 5, fileSize: 1))
        return db
    }

    func testNoteRoundTripPlacedAndUnplaced() throws {
        let db = try makeDB()
        var placed = StickyNote(documentID: "d", pageIndex: 2, rect: PageRect(x: 40, y: 300, width: 180, height: 120),
                                title: "重點", body: "第一行\n第二行", color: .graphite, fontFamily: "Yuanti TC",
                                fontSize: 15, expanded: true)
        let loose = StickyNote(documentID: "d", pageIndex: 2, rect: nil, body: "沒有位置的筆記")
        try db.saveNote(placed)
        try db.saveNote(loose)

        var loaded = try db.notes(documentID: "d")
        XCTAssertEqual(loaded.count, 2)
        let p = try XCTUnwrap(loaded.first { $0.id == placed.id })
        XCTAssertEqual(p.rect, placed.rect)
        XCTAssertEqual(p.color, .graphite)
        XCTAssertEqual(p.fontFamily, "Yuanti TC")
        XCTAssertTrue(p.expanded)
        XCTAssertNil(loaded.first { $0.id == loose.id }?.rect)

        placed.body = "改過"
        placed.rect = nil
        try db.saveNote(placed)
        loaded = try db.notes(documentID: "d")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == placed.id }?.body, "改過")

        try db.deleteNote(id: loose.id)
        XCTAssertEqual(try db.notes(documentID: "d").count, 1)
    }

    func testHighlightRoundTripAndCascade() throws {
        let db = try makeDB()
        let h = Highlight(documentID: "d", pageIndex: 0, color: .blue,
                          rects: [PageRect(x: 10, y: 700, width: 200, height: 12), PageRect(x: 10, y: 686, width: 120, height: 12)],
                          text: "hello")
        try db.saveHighlight(h)
        let loaded = try db.highlights(documentID: "d")
        XCTAssertEqual(loaded, [h].map { var x = $0; x.createdAt = loaded[0].createdAt; return x })
        XCTAssertTrue(loaded[0].contains(x: 50, y: 690))
        XCTAssertFalse(loaded[0].contains(x: 300, y: 690))

        try db.saveNote(StickyNote(documentID: "d", pageIndex: 0, rect: nil, body: "x"))
        try db.removeDocument(id: "d")
        XCTAssertTrue(try db.highlights(documentID: "d").isEmpty)
        XCTAssertTrue(try db.notes(documentID: "d").isEmpty)
    }

    func testClampKeepsNoteInsidePage() {
        let r = StickyNote.clamp(PageRect(x: 580, y: -20, width: 50, height: 400), pageSize: (612, 300))
        XCTAssertEqual(r.width, StickyNote.minimumSize.width)
        XCTAssertEqual(r.height, 300)
        XCTAssertEqual(r.maxX, 612)
        XCTAssertEqual(r.y, 0)
    }
}
