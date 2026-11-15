import XCTest
import CoreGraphics
@testable import ReaderCore

final class LayoutTests: XCTestCase {
    private let page = PageRect(x: 0, y: 0, width: 600, height: 800)

    private func line(_ text: String, x: Double, top: Double, w: Double, h: Double = 12) -> TextLine {
        TextLine(text: text, bounds: PageRect(x: x, y: top - h, width: w, height: h))
    }

    func testSingleColumnParagraphsAndHeading() {
        let lines = [
            line("Chapter One", x: 50, top: 760, w: 200, h: 24),
            line("The first paragraph starts here and", x: 50, top: 720, w: 500),
            line("continues on this line.", x: 50, top: 705, w: 300),
            line("A second paragraph after a gap", x: 50, top: 670, w: 500),
            line("ends here.", x: 50, top: 655, w: 120),
        ]
        let r = LayoutAnalyzer().analyze(lines: lines, pageBounds: page, documentID: "d", pageIndex: 0, source: .ocr)
        XCTAssertEqual(r.columnCount, 1)
        XCTAssertEqual(r.blocks.map(\.kind), [.heading, .paragraph, .paragraph])
        XCTAssertEqual(r.blocks[1].text, "The first paragraph starts here and continues on this line.")
        XCTAssertEqual(r.blocks.map(\.readingOrder), [0, 1, 2])
        XCTAssertEqual(r.blocks[0].id, "d:p0:b0")
    }

    func testTwoColumnsReadLeftThenRight() {
        var lines = [line("A Spanning Title Across Both Columns", x: 50, top: 770, w: 500, h: 22)]
        for i in 0..<6 {
            lines.append(line("left \(i)", x: 40, top: 720 - Double(i) * 14, w: 240))
            lines.append(line("right \(i)", x: 320, top: 720 - Double(i) * 14, w: 240))
        }
        let r = LayoutAnalyzer().analyze(lines: lines, pageBounds: page, documentID: "d", pageIndex: 3, source: .ocr)
        XCTAssertEqual(r.columnCount, 2)
        XCTAssertEqual(r.blocks.count, 3)
        XCTAssertEqual(r.blocks[0].kind, .heading)
        XCTAssertTrue(r.blocks[1].text.hasPrefix("left 0"))
        XCTAssertTrue(r.blocks[1].text.hasSuffix("left 5"))
        XCTAssertTrue(r.blocks[2].text.hasPrefix("right 0"))
    }

    func testHyphenJoinAndCaption() {
        XCTAssertEqual(LayoutAnalyzer.join(["photo-", "graphy is"]), "photography is")
        XCTAssertEqual(LayoutAnalyzer.join(["攝影", "藝術"]), "攝影藝術")
        let lines = [
            line("Body text line one of the paragraph", x: 50, top: 700, w: 500),
            line("Body text line two of the paragraph", x: 50, top: 686, w: 500),
            line("Fig. 3. Untitled, 1998.", x: 50, top: 400, w: 200, h: 9),
        ]
        let r = LayoutAnalyzer().analyze(lines: lines, pageBounds: page, documentID: "d", pageIndex: 0, source: .ocr)
        XCTAssertEqual(r.blocks.last?.kind, .caption)
    }

    func testNeedsTranslation() {
        let b = TextBlock(id: "x", documentID: "d", pageIndex: 0, readingOrder: 0, kind: .other,
                          text: "12", bounds: page, confidence: 1, source: .ocr)
        XCTAssertFalse(b.needsTranslation)
    }

    // MARK: - 座標

    func testGeometryRoundTripAllRotations() {
        let crop = CGRect(x: 10, y: 20, width: 600, height: 800)
        let r = CGRect(x: 100, y: 200, width: 50, height: 30)
        for rot in [0, 90, 180, 270] {
            let g = PageGeometry(cropBox: crop, rotation: rot)
            let back = g.toPage(g.toDisplay(r))
            XCTAssertEqual(back.minX, r.minX, accuracy: 0.001, "rot \(rot)")
            XCTAssertEqual(back.minY, r.minY, accuracy: 0.001, "rot \(rot)")
            XCTAssertEqual(back.width, r.width, accuracy: 0.001, "rot \(rot)")
            // 整個 cropBox 應映射到 (0,0)-displaySize
            let full = g.toDisplay(crop)
            XCTAssertEqual(full.minX, 0, accuracy: 0.001)
            XCTAssertEqual(full.minY, 0, accuracy: 0.001)
            XCTAssertEqual(full.width, g.displaySize.width, accuracy: 0.001)
            XCTAssertEqual(full.height, g.displaySize.height, accuracy: 0.001)
        }
    }

    func testRotation90TopLeftGoesToTopRight() {
        let g = PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 90)
        // 未旋轉頁面左上角 (0, 800) 順時針轉 90° 後應在顯示空間右上角 (800, 600)
        let p = CGPoint(x: 0, y: 800).applying(g.pageToDisplay)
        XCTAssertEqual(p.x, 800, accuracy: 0.001)
        XCTAssertEqual(p.y, 600, accuracy: 0.001)
    }

    func testNormalizedVisionRect() {
        let g = PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 0)
        let r = g.pageRect(fromNormalized: CGRect(x: 0.5, y: 0.25, width: 0.1, height: 0.05))
        XCTAssertEqual(r.minX, 300, accuracy: 0.001)
        XCTAssertEqual(r.minY, 200, accuracy: 0.001)
        XCTAssertEqual(r.height, 40, accuracy: 0.001)
    }

    // MARK: - 批次

    func testBatcherMergesAdjacentWithinBudget() {
        let b = TranslationBatcher(maxCharacters: 5000, maxPages: 3)
        let counts = [10: 2000, 11: 2000, 12: 2000, 13: 100]
        XCTAssertEqual(b.batch(first: 10, candidates: [11, 12, 13], characterCount: { counts[$0] ?? 0 }), [10, 11])
        XCTAssertEqual(b.batch(first: 12, candidates: [13, 20], characterCount: { counts[$0] ?? 0 }), [12, 13])
        XCTAssertEqual(b.batch(first: 5, candidates: [9], characterCount: { _ in 10 }), [5])
    }

    func testCacheKeyDefaultsModel() {
        XCTAssertEqual(TranslationCacheKey(engine: "codex-cli", model: nil).model, "default")
        XCTAssertNotEqual(TranslationCacheKey(engine: "e", model: "a").fingerprint,
                          TranslationCacheKey(engine: "e", model: "b").fingerprint)
    }
}
