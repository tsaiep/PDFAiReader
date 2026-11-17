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

    func testBoldSubheadingSameSizeIsSeparated() {
        var heading = line("Early Practice", x: 50, top: 700, w: 110)
        heading.isBold = true
        let lines = [
            heading,
            line("Early practitioners understood the camera as an instrument", x: 50, top: 686, w: 500),
            line("of record, yet many treated it as a means of composing.", x: 50, top: 672, w: 480),
        ]
        let r = LayoutAnalyzer().analyze(lines: lines, pageBounds: page, documentID: "d", pageIndex: 0, source: .ocr)
        XCTAssertEqual(r.blocks.count, 2)
        XCTAssertEqual(r.blocks[0].kind, .heading)
        XCTAssertEqual(r.blocks[0].text, "Early Practice")
        XCTAssertTrue(r.blocks[1].text.hasPrefix("Early practitioners"))
    }

    func testShortTitleLineWithoutPunctuationIsSeparated() {
        let lines = [
            line("A long first paragraph line that fills the column width nicely", x: 50, top: 740, w: 500),
            line("and ends right here.", x: 50, top: 726, w: 160),
            line("The Deadpan Aesthetic", x: 50, top: 700, w: 170),
            line("The deadpan aesthetic favoured a cool, detached and sharply", x: 50, top: 686, w: 500),
            line("detailed style using large-format cameras.", x: 50, top: 672, w: 330),
        ]
        let r = LayoutAnalyzer().analyze(lines: lines, pageBounds: page, documentID: "d", pageIndex: 0, source: .ocr)
        XCTAssertEqual(r.blocks.map(\.kind), [.paragraph, .heading, .paragraph], r.blocks.map(\.text).description)
        XCTAssertEqual(r.blocks[1].text, "The Deadpan Aesthetic")
    }

    func testParagraphLastLineStaysInParagraph() {
        let lines = [
            line("This paragraph has a long first line that spans the column", x: 50, top: 740, w: 500),
            line("and a short last line", x: 50, top: 726, w: 170),
            line("Next paragraph starts with a full line of ordinary body text", x: 50, top: 700, w: 500),
            line("and continues here.", x: 50, top: 686, w: 150),
        ]
        let r = LayoutAnalyzer().analyze(lines: lines, pageBounds: page, documentID: "d", pageIndex: 0, source: .ocr)
        XCTAssertEqual(r.blocks.count, 2)
        XCTAssertTrue(r.blocks.allSatisfy { $0.kind == .paragraph })
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

final class ScanSelectionTests: XCTestCase {
    private let lines = [
        TextLine(text: "一二三四五六七八九十", bounds: PageRect(x: 100, y: 700, width: 200, height: 20)),
        TextLine(text: "甲乙丙丁戊己庚辛壬癸", bounds: PageRect(x: 100, y: 670, width: 200, height: 20)),
        TextLine(text: "子丑寅卯辰巳午未申酉", bounds: PageRect(x: 100, y: 640, width: 200, height: 20)),
        TextLine(text: "Right column text", bounds: PageRect(x: 400, y: 670, width: 150, height: 20)),
    ]

    func testFlowsAcrossLinesLikeText() {
        let p = ScanSelection.pieces(lines: lines, from: CGPoint(x: 160, y: 710), to: CGPoint(x: 181, y: 650))
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[0].text, "四五六七八九十")
        XCTAssertEqual(p[1].text, "甲乙丙丁戊己庚辛壬癸")
        XCTAssertEqual(p[2].text, "子丑寅卯")
        XCTAssertEqual(ScanSelection.text(of: p), "四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯")
        XCTAssertEqual(p[0].rect.minX, 160, accuracy: 0.01)
        XCTAssertEqual(p[0].rect.maxX, 300, accuracy: 0.01)
    }

    func testBackwardDragAndSingleLine() {
        let back = ScanSelection.pieces(lines: lines, from: CGPoint(x: 181, y: 650), to: CGPoint(x: 160, y: 710))
        XCTAssertEqual(back.map(\.text), ["四五六七八九十", "甲乙丙丁戊己庚辛壬癸", "子丑寅卯"])
        let one = ScanSelection.pieces(lines: lines, from: CGPoint(x: 141, y: 680), to: CGPoint(x: 199, y: 678))
        XCTAssertEqual(one.map(\.text), ["丙丁戊"])
    }

    func testFarFromTextSelectsNothing() {
        XCTAssertTrue(ScanSelection.pieces(lines: lines, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 120)).isEmpty)
    }
}

final class TextFlowTests: XCTestCase {
    private func block(_ id: String, _ text: String, x: CGFloat, top: CGFloat, perLine: Int, w: CGFloat = 10, h: CGFloat = 12) -> TextFlow.Block {
        let chars = Array(text)
        let rects = chars.indices.map { i in
            CGRect(x: x + CGFloat(i % perLine) * w, y: top - CGFloat(i / perLine + 1) * (h + 4), width: w, height: h)
        }
        return TextFlow.Block(id: id, chars: chars, rects: rects)
    }

    func testSelectionAcrossBlocksAndLines() {
        let flow = TextFlow(blocks: [block("a", "一二三四五六七八九十", x: 0, top: 500, perLine: 5),
                                     block("b", "甲乙丙丁戊", x: 0, top: 440, perLine: 5)])
        let s = flow.position(at: CGPoint(x: 22, y: 490))!          // 「三」的左半 → 第 2 個間隙
        let e = flow.position(at: CGPoint(x: 31, y: 430))!          // 「丁」的中心偏左 → 第 3 個間隙
        let spans = flow.spans(from: e, to: s)                     // 反向拖曳也一樣
        XCTAssertEqual(spans, [.init(blockID: "a", range: 2..<10), .init(blockID: "b", range: 0..<3)])
        XCTAssertEqual(flow.text(for: spans), "三四五六七八九十甲乙丙")
        XCTAssertEqual(flow.rects(for: spans[0]).count, 2)         // 兩行
    }

    func testCorrespondenceBySentence() {
        let src = Array("第一句很短。第二句比較長一點。第三句。")
        let dst = Array("First. The second sentence is longer. Third.")
        // 原文第二句 → 譯文第二句
        let second = 6..<15
        let mapped = TextCorrespondence.map(second, from: src, to: dst)
        XCTAssertEqual(String(dst[mapped]).trimmingCharacters(in: .whitespaces), "The second sentence is longer.")
        // 整段 → 整段
        XCTAssertEqual(TextCorrespondence.map(0..<src.count, from: src, to: dst), 0..<dst.count)
    }
}
