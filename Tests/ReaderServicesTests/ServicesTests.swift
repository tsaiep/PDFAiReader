import XCTest
import PDFKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import ReaderServices
import ReaderCore

final class ServicesTests: XCTestCase {
    private var tmp: URL!
    /// 測試輸出（給開發者／AI 代理人檢視）：<package>/.dev/artifacts
    private var artifacts: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".dev/artifacts")
    }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    static let paragraph1 = "Photography has never been more widely used as a means of artistic expression than it is today. Its ubiquity has not diminished the critical debates surrounding its status."
    static let paragraph2 = "The deadpan aesthetic favoured a cool, detached and sharply detailed style, typically using large-format cameras to produce prints of considerable scale."

    // MARK: - 測試文件產生

    private func drawPage(in ctx: CGContext, size: CGSize) {
        func draw(_ text: String, font: String, size fs: CGFloat, rect: CGRect) {
            let attr = CFAttributedStringCreate(nil, text as CFString, [
                kCTFontAttributeName: CTFontCreateWithName(font as CFString, fs, nil),
            ] as CFDictionary)!
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr),
                                                 CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
            CTFrameDraw(frame, ctx)
        }
        ctx.textMatrix = .identity
        draw("The Photograph as Contemporary Art", font: "Helvetica-Bold", size: 22,
             rect: CGRect(x: 60, y: size.height - 110, width: size.width - 120, height: 40))
        draw(Self.paragraph1, font: "Times-Roman", size: 13,
             rect: CGRect(x: 60, y: size.height - 260, width: size.width - 120, height: 130))
        draw(Self.paragraph2, font: "Times-Roman", size: 13,
             rect: CGRect(x: 60, y: size.height - 400, width: size.width - 120, height: 120))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 120, width: size.width - 120, height: 200))   // 「插圖」
    }

    private func makeTextPDF(pages: Int = 2) -> URL {
        let url = tmp.appendingPathComponent("text.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            drawPage(in: ctx, size: box.size)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// 只有影像、沒有文字層（模擬掃描書）。
    private func makeScannedPDF() -> URL {
        let size = CGSize(width: 595, height: 842)
        let scale: CGFloat = 2.5
        let bmp = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bmp.setFillColor(CGColor(gray: 0.97, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        bmp.scaleBy(x: scale, y: scale)
        drawPage(in: bmp, size: size)
        let image = bmp.makeImage()!

        let url = tmp.appendingPathComponent("scan.pdf")
        var box = CGRect(origin: .zero, size: size)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    // MARK: - 擷取

    func testEmbeddedTextExtraction() async throws {
        let url = makeTextPDF()
        let extractor = try TextExtractor(url: url, documentID: "doc")
        let page = try await extractor.extract(pageIndex: 0)
        XCTAssertEqual(page.source, .embedded)
        XCTAssertGreaterThanOrEqual(page.blocks.count, 3)
        XCTAssertEqual(page.blocks.first?.kind, .heading)
        XCTAssertTrue(page.blocks.contains { $0.text.contains("deadpan aesthetic") })
    }

    func testVisionOCROnScannedPage() async throws {
        let url = makeScannedPDF()
        let extractor = try TextExtractor(url: url, documentID: "doc")
        let page = try await extractor.extract(pageIndex: 0)
        XCTAssertEqual(page.source, .ocr)
        let all = page.blocks.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(all.contains("photography"), all)
        XCTAssertTrue(all.contains("deadpan"), all)
        XCTAssertEqual(page.blocks.first?.kind, .heading)
        // 標題框應位於頁面上方
        XCTAssertGreaterThan(page.blocks.first!.bounds.minY, 842 * 0.8)
        print("OCR 單頁耗時：\(String(format: "%.2f", page.duration)) 秒，區塊 \(page.blocks.count)")
    }

    // MARK: - 匯出

    private func exportBlocks(from url: URL) async throws -> [Int: [ExportBlock]] {
        let extractor = try TextExtractor(url: url, documentID: "doc")
        var result: [Int: [ExportBlock]] = [:]
        let fake = [
            "作為當代藝術的攝影",
            "攝影作為藝術表現媒介的運用，從未像今日這般普遍。然而，攝影無所不在，卻未使圍繞其地位的批判性論辯稍有消退。",
            "相較之下，冷面美學偏好冷靜、疏離且細節清晰銳利的風格，通常使用大畫幅相機，製作尺寸可觀的相片。",
        ]
        for i in 0..<(await extractor.pageCount) {
            let page = try await extractor.extract(pageIndex: i)
            result[i] = page.blocks.enumerated().map { j, b in
                ExportBlock(kind: b.kind, bounds: b.bounds, original: b.text,
                            translation: j < fake.count ? fake[j] : "譯文 \(j)")
            }
        }
        return result
    }

    func testExportModes() async throws {
        let url = makeTextPDF(pages: 2)
        let blocks = try await exportBlocks(from: url)

        let inPlace = tmp.appendingPathComponent("inplace.pdf")
        let s1 = try TranslatedPDFExporter.export(source: url, destination: inPlace, mode: .inPlace, blocksByPage: blocks)
        XCTAssertEqual(PDFDocument(url: inPlace)?.pageCount, 2)
        XCTAssertEqual(s1.translatedPages, 2)
        let text = PDFDocument(url: inPlace)?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("冷面美學"), text)

        let inter = tmp.appendingPathComponent("inter.pdf")
        _ = try TranslatedPDFExporter.export(source: url, destination: inter, mode: .interleaved, blocksByPage: blocks)
        XCTAssertEqual(PDFDocument(url: inter)?.pageCount, 4)

        let only = tmp.appendingPathComponent("only.pdf")
        _ = try TranslatedPDFExporter.export(source: url, destination: only, mode: .translationOnly, blocksByPage: blocks)
        XCTAssertEqual(PDFDocument(url: only)?.pageCount, 2)

        // 未翻譯的頁面在原位模式保留原文
        let partial = tmp.appendingPathComponent("partial.pdf")
        let s2 = try TranslatedPDFExporter.export(source: url, destination: partial, mode: .inPlace,
                                                  blocksByPage: [0: blocks[0]!])
        XCTAssertEqual(s2.translatedPages, 1)
        XCTAssertEqual(PDFDocument(url: partial)?.pageCount, 2)

        // 存一份預覽圖給人工檢查
        try? FileManager.default.removeItem(at: artifacts.appendingPathComponent("export-inplace.pdf"))
        try? FileManager.default.copyItem(at: inPlace, to: artifacts.appendingPathComponent("export-inplace.pdf"))
        try? FileManager.default.removeItem(at: artifacts.appendingPathComponent("export-interleaved.pdf"))
        try? FileManager.default.copyItem(at: inter, to: artifacts.appendingPathComponent("export-interleaved.pdf"))
    }

    func testExportScannedInPlace() async throws {
        let url = makeScannedPDF()
        let blocks = try await exportBlocks(from: url)
        let out = tmp.appendingPathComponent("scan-inplace.pdf")
        _ = try TranslatedPDFExporter.export(source: url, destination: out, mode: .inPlace, blocksByPage: blocks)
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
        try? FileManager.default.removeItem(at: artifacts.appendingPathComponent("export-scan-inplace.pdf"))
        try? FileManager.default.copyItem(at: out, to: artifacts.appendingPathComponent("export-scan-inplace.pdf"))
    }

    func testExportCancellation() throws {
        let url = makeTextPDF(pages: 2)
        XCTAssertThrowsError(try TranslatedPDFExporter.export(source: url, destination: tmp.appendingPathComponent("c.pdf"),
                                                              mode: .inPlace, blocksByPage: [:], isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("c.pdf").path))
    }
}
