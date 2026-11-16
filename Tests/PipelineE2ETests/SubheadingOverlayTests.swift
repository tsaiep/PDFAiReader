import XCTest
import PDFKit
import AppKit
import CoreText
@testable import PDFAiReaderApp
import ReaderCore
import ReaderStore
import ReaderServices

/// 重現「小標題與內文」的疊加版面：掃描頁 → OCR → 分段 → 假翻譯 → 疊加，輸出原頁與譯文頁並排圖。
@MainActor
final class SubheadingOverlayTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static let body1 = "Photography has never been more widely used as a means of artistic expression than it is today. Its ubiquity, however, has not diminished the critical debates surrounding its status, its relation to painting, and its claims to truth."
    static let body2 = "In the late 1970s a group of artists began to stage elaborate tableaux for the camera, borrowing the language of cinema and advertising to construct images that were at once seductive and unsettling."
    static let body3 = "The deadpan aesthetic, by contrast, favoured a cool, detached and sharply detailed style, typically using large-format cameras to produce prints of considerable scale. Its subjects were often banal."

    /// 依原文長度產生長度相近的中文假譯文。
    struct LengthEngine: TranslationEngine {
        let engineID = "fake"
        func availability() async -> EngineAvailability { .available(version: "fake") }
        func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
            let base = "攝影作為藝術表現手段的運用從未像今日這般廣泛然而攝影的無所不在並未使圍繞其地位與繪畫的關係以及真實性主張的批判性辯論減少"
            return TranslationResponse(translations: request.segments.map { s in
                if s.kind == .heading { return TranslatedSegment(id: s.id, translation: "【標題】" + s.text.prefix(12)) }
                let n = max(4, Int(Double(s.text.count) / 2.3))
                let text = String(repeating: base, count: n / base.count + 1).prefix(n)
                return TranslatedSegment(id: s.id, translation: String(text) + "。")
            })
        }
    }

    /// - Parameters:
    ///   - boldHeadings: 小標題用粗體（否則與內文同字重同字級）
    ///   - gapBeforeHeading: 小標題上方的間距（真實書籍常常很小）
    static func makePage(at url: URL, boldHeadings: Bool = true, gapBeforeHeading: CGFloat = 14) {
        let size = CGSize(width: 595, height: 842)
        let scale: CGFloat = 2.5
        let bmp = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bmp.setFillColor(CGColor(red: 0.97, green: 0.95, blue: 0.9, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        bmp.scaleBy(x: scale, y: scale)
        bmp.textMatrix = .identity
        /// 由上往下排版，回傳下一段的頂端 y
        func draw(_ text: String, font: String, size fs: CGFloat, top: CGFloat, gapAfter: CGFloat) -> CGFloat {
            let attr = CFAttributedStringCreate(nil, text as CFString, [
                kCTFontAttributeName: CTFontCreateWithName(font as CFString, fs, nil)] as CFDictionary)!
            let fsetter = CTFramesetterCreateWithAttributedString(attr)
            let need = CTFramesetterSuggestFrameSizeWithConstraints(fsetter, CFRange(location: 0, length: 0), nil,
                                                                    CGSize(width: 475, height: 1000), nil)
            let rect = CGRect(x: 60, y: top - need.height, width: 475, height: need.height)
            CTFrameDraw(CTFramesetterCreateFrame(fsetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: rect, transform: nil), nil), bmp)
            return rect.minY - gapAfter
        }
        var y: CGFloat = 780
        y = draw("Chapter Two", font: "Helvetica-Bold", size: 22, top: y, gapAfter: 18)
        let headingFont = boldHeadings ? "Times-Bold" : "Times-Roman"
        y = draw(body1, font: "Times-Roman", size: 12, top: y, gapAfter: gapBeforeHeading)
        y = draw("Staged Photography", font: headingFont, size: 12, top: y, gapAfter: 3)
        y = draw(body2, font: "Times-Roman", size: 12, top: y, gapAfter: gapBeforeHeading)
        y = draw("The Deadpan Aesthetic", font: headingFont, size: 12, top: y, gapAfter: 3)
        _ = draw(body3, font: "Times-Roman", size: 12, top: y, gapAfter: 0)

        var box = CGRect(origin: .zero, size: size)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(bmp.makeImage()!, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    func testSubheadingOverlayLayout() async throws {
        try await run(name: "subheading", bold: true, gap: 14)
    }

    /// 小標題上方間距很小、而且不是粗體：只能靠「句子結束＋短行＋無句末標點」判斷。
    func testTightRegularWeightSubheadings() async throws {
        try await run(name: "subheading-tight", bold: false, gap: 3)
    }

    /// 小標題上方間距很小、粗體。
    func testTightBoldSubheadings() async throws {
        try await run(name: "subheading-tight-bold", bold: true, gap: 3)
    }

    private func run(name: String, bold: Bool, gap: CGFloat) async throws {
        let artifacts = root.appendingPathComponent(".dev/artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let pdfURL = artifacts.appendingPathComponent("\(name)-src.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        Self.makePage(at: pdfURL, boldHeadings: bold, gapBeforeHeading: gap)

        let db = try AppDatabase.inMemory()
        let fp = try DocumentFingerprint.compute(url: pdfURL)
        try db.upsertDocument(DocumentRecord(id: fp.id, path: pdfURL.path, bookmarkData: nil, title: "T",
                                             pageCount: 1, fileSize: fp.fileSize))
        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        let coordinator = TranslationCoordinator(documentID: fp.id, url: pdfURL, pageCount: 1, title: "T",
                                                 database: db, engine: LengthEngine())
        coordinator.autoTranslate = false
        let overlay = TranslationOverlayManager(document: doc, coordinator: coordinator)
        coordinator.onTranslationsChanged = { overlay.translationsChanged(page: $0) }
        overlay.setEnabled(true, around: [0])
        coordinator.translatePages([0])

        let start = Date()
        while overlay.drawings(page: 0).isEmpty && Date().timeIntervalSince(start) < 20 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let blocks = try XCTUnwrap(coordinator.blocks[0])
        var report = ""
        for b in blocks {
            report += String(format: "[%@] y=%.0f-%.0f x=%.0f w=%.0f  %@\n", b.kind.rawValue, b.bounds.minY, b.bounds.maxY,
                             b.bounds.minX, b.bounds.width, String(b.text.prefix(60)))
        }
        let drawings = overlay.drawings(page: 0)
        for d in drawings {
            report += String(format: "  draw y=%.0f-%.0f size=%.1f  %@\n", d.item.bounds.minY, d.item.bounds.maxY,
                             d.style.fontSize, String(d.item.text.prefix(20)))
        }
        try report.write(to: artifacts.appendingPathComponent("\(name)-report.txt"), atomically: true, encoding: .utf8)

        // 並排輸出：原頁｜疊加後
        let page = try XCTUnwrap(doc.page(at: 0))
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let original = try XCTUnwrap(PageRenderCache.render(ref: page.pageRef!, geometry: geometry, longSide: 1100, overlays: []))
        let translated = try XCTUnwrap(PageRenderCache.render(ref: page.pageRef!, geometry: geometry, longSide: 1100,
                                                              overlays: drawings))
        let w = original.width, h = original.height
        let combo = NSImage(size: NSSize(width: w * 2 + 20, height: h), flipped: false) { _ in
            NSColor.gray.setFill()
            NSRect(x: 0, y: 0, width: w * 2 + 20, height: h).fill()
            NSImage(cgImage: original, size: .zero).draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSImage(cgImage: translated, size: .zero).draw(in: NSRect(x: w + 20, y: 0, width: w, height: h))
            return true
        }
        let rep = NSBitmapImageRep(data: combo.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent("\(name)-overlay.png"))

        // 期望：兩個小標題各自成段且為標題，內文段落不與標題合併
        XCTAssertTrue(blocks.contains { $0.kind == .heading && $0.text == "Staged Photography" }, report)
        XCTAssertTrue(blocks.contains { $0.kind == .heading && $0.text == "The Deadpan Aesthetic" }, report)
        XCTAssertEqual(drawings.count, blocks.filter(\.needsTranslation).count, report)
        XCTAssertEqual(blocks.count, 6, report)
    }
}
