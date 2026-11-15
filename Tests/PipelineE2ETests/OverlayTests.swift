import XCTest
import PDFKit
import AppKit
import CoreText
@testable import PDFAiReaderApp
import ReaderCore
import ReaderStore
import ReaderServices

/// 頁面譯文疊加：以假引擎走完 OCR → 翻譯 → 疊加，並把頁面畫成 PNG 供人工檢查。
@MainActor
final class OverlayTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    struct FakeChineseEngine: TranslationEngine {
        let engineID = "fake"
        func availability() async -> EngineAvailability { .available(version: "fake") }
        func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
            let samples = [
                "攝影作為藝術表現手段的運用，從未像今日這般廣泛。然而，攝影的無所不在，並未使圍繞其地位的批判性辯論減少。",
                "冷面美學偏好冷靜、疏離且細節清晰銳利的風格，通常使用大畫幅相機，製作尺寸相當大的相片。",
            ]
            return TranslationResponse(translations: request.segments.enumerated().map { i, s in
                TranslatedSegment(id: s.id, translation: s.kind == .heading ? "第一章：光" : samples[i % samples.count])
            })
        }
    }

    func testOverlayAppearsOnPageAndToggles() async throws {
        let artifacts = root.appendingPathComponent(".dev/artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let pdfURL = artifacts.appendingPathComponent("overlay-src.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        PipelineE2ETests.makeScannedPDFForTests(at: pdfURL)

        let db = try AppDatabase.inMemory()
        let fp = try DocumentFingerprint.compute(url: pdfURL)
        try db.upsertDocument(DocumentRecord(id: fp.id, path: pdfURL.path, bookmarkData: nil, title: "T",
                                             pageCount: 3, fileSize: fp.fileSize))
        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        let coordinator = TranslationCoordinator(documentID: fp.id, url: pdfURL, pageCount: 3, title: "T",
                                                 database: db, engine: FakeChineseEngine())
        coordinator.autoTranslate = false
        let overlay = TranslationOverlayManager(document: doc, coordinator: coordinator)
        // 與 App 相同：在真正的 PDFView 上疊加
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 850), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 850))
        window.contentView = view
        view.document = doc
        view.displayMode = .singlePage
        view.autoScales = true
        overlay.attach(to: view)
        coordinator.onTranslationsChanged = { overlay.translationsChanged(page: $0) }
        overlay.setEnabled(true, around: [0])

        coordinator.translatePages([0])
        let start = Date()
        while !coordinator.completedPages.contains(0) && Date().timeIntervalSince(start) < 20 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(coordinator.completedPages.contains(0))
        // 等疊加樣式在背景算完並掛到頁面上
        let page = try XCTUnwrap(doc.page(at: 0))
        while !overlay.isApplied(page: 0) && Date().timeIntervalSince(start) < 20 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(overlay.drawings(page: 0).count, 2)
        XCTAssertTrue(overlay.isApplied(page: 0))

        try save(page.thumbnail(of: CGSize(width: 600, height: 850), for: .cropBox),
                 to: artifacts.appendingPathComponent("overlay-on.png"))

        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        // 等 PDFKit 在背景把頁面圖塊畫完
        for _ in 0..<15 {
            view.display()
            try await Task.sleep(for: .milliseconds(100))
        }
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: artifacts.appendingPathComponent("overlay-pdfview.png"))

        // PDFPage.draw（PDFKit 繪製頁面＋註解的路徑）
        let w = 600, h = 850
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let b = page.bounds(for: .cropBox)
        ctx.scaleBy(x: CGFloat(w) / b.width, y: CGFloat(h) / b.height)
        page.draw(with: .cropBox, to: ctx)
        try save(NSImage(cgImage: ctx.makeImage()!, size: .zero), to: artifacts.appendingPathComponent("overlay-pagedraw.png"))

        // ⌥ 暫看原文 → 疊加移除；放開 → 恢復
        overlay.setPeeking(true)
        XCTAssertFalse(overlay.isApplied(page: 0))
        let rep2 = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep2)
        try XCTUnwrap(rep2.representation(using: .png, properties: [:]))
            .write(to: artifacts.appendingPathComponent("overlay-pdfview-peek.png"))
        try save(page.thumbnail(of: CGSize(width: 600, height: 850), for: .cropBox),
                 to: artifacts.appendingPathComponent("overlay-off.png"))
        overlay.setPeeking(false)
        XCTAssertTrue(overlay.isApplied(page: 0))

        // 翻頁動畫用的背景渲染也要包含疊加
        let drawings = overlay.drawings(page: 0)
        XCTAssertFalse(drawings.isEmpty)
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let img = try XCTUnwrap(PageRenderCache.render(ref: page.pageRef!, geometry: geometry, longSide: 900,
                                                       overlays: drawings))
        try save(NSImage(cgImage: img, size: .zero), to: artifacts.appendingPathComponent("overlay-turn-cache.png"))

        // 放大後圖層仍對齊頁面
        view.autoScales = false
        view.scaleFactor = view.scaleFactor * 1.5
        overlay.relayout()
        XCTAssertTrue(overlay.isApplied(page: 0))

        // 關閉疊加
        overlay.setEnabled(false, around: [0])
        XCTAssertFalse(overlay.isApplied(page: 0))
    }

    func testConfigModelParsing() {
        // 只驗證不會崩潰；實際值依使用者設定而定
        _ = AppModel.readConfigDefaultModel()
    }

    private func save(_ image: NSImage, to url: URL) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

extension PipelineE2ETests {
    static func makeScannedPDFForTests(at url: URL) {
        let size = CGSize(width: 595, height: 842)
        var box = CGRect(origin: .zero, size: size)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in pages {
            let scale: CGFloat = 2.5
            let bmp = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bmp.setFillColor(CGColor(red: 0.97, green: 0.95, blue: 0.9, alpha: 1))
            bmp.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            bmp.scaleBy(x: scale, y: scale)
            bmp.textMatrix = .identity
            func draw(_ text: String, font: String, size fs: CGFloat, rect: CGRect) {
                let attr = CFAttributedStringCreate(nil, text as CFString, [
                    kCTFontAttributeName: CTFontCreateWithName(font as CFString, fs, nil)] as CFDictionary)!
                CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr),
                                                     CFRange(location: 0, length: 0),
                                                     CGPath(rect: rect, transform: nil), nil), bmp)
            }
            draw(page.title, font: "Helvetica-Bold", size: 22, rect: CGRect(x: 60, y: 730, width: 475, height: 40))
            var y: CGFloat = 690
            for p in page.body {
                draw(p, font: "Times-Roman", size: 13, rect: CGRect(x: 60, y: y - 90, width: 475, height: 90))
                y -= 120
            }
            bmp.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 1))
            bmp.fill(CGRect(x: 60, y: 100, width: 475, height: 200))
            pdf.beginPDFPage(nil)
            pdf.draw(bmp.makeImage()!, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }
}
