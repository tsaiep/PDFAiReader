import XCTest
import PDFKit
import AppKit
import CoreText
@testable import PDFAiReaderApp
import ReaderCore
import ReaderStore
import ReaderServices

/// 便利貼與螢光筆：在真正的 PDFView 上放置、互動、儲存，並把畫面存成 PNG 供人工檢查。
@MainActor
final class NotesTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var artifacts: URL { root.appendingPathComponent(".dev/artifacts") }

    /// 有文字層的頁面（可選取文字）。
    static func makeTextPDF(at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        let paragraphs = [
            ("Chapter Two", "Helvetica-Bold", CGFloat(22)),
            ("The use of photography as a means of artistic expression has never been more widespread than it is today. Yet the ubiquity of photography has not diminished the critical debates that surround its status.", "Times-Roman", 12),
            ("Staged Photography", "Times-Bold", 12),
            ("Staged photography is not a new phenomenon. Photographers have always constructed scenes for the camera, borrowing from painting, theatre and cinema to tell stories that unfold within a single frame.", "Times-Roman", 12),
            ("The Deadpan Aesthetic", "Times-Bold", 12),
            ("The deadpan aesthetic favours a cool, detached and sharply detailed style. It is usually made with large-format cameras and printed at a considerable size, so that the viewer can scrutinise every detail.", "Times-Roman", 12),
        ]
        for _ in 0..<2 {
            pdf.beginPDFPage(nil)
            pdf.textMatrix = .identity
            var top: CGFloat = 780
            for (text, font, size) in paragraphs {
                let attr = CFAttributedStringCreate(nil, text as CFString, [
                    kCTFontAttributeName: CTFontCreateWithName(font as CFString, size, nil)] as CFDictionary)!
                let setter = CTFramesetterCreateWithAttributedString(attr)
                let need = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                        CGSize(width: 475, height: 1000), nil)
                let rect = CGRect(x: 60, y: top - need.height, width: 475, height: need.height)
                CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                                     CGPath(rect: rect, transform: nil), nil), pdf)
                top = rect.minY - 14
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    private func snapshot(_ view: NSView, _ name: String) async throws {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<12 {
            view.display()
            try await Task.sleep(for: .milliseconds(80))
        }
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: artifacts.appendingPathComponent(name))
    }

    func testStickyNotesAndHighlights() async throws {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let pdfURL = artifacts.appendingPathComponent("notes-src.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        Self.makeTextPDF(at: pdfURL)

        let db = try AppDatabase.inMemory()
        try db.upsertDocument(DocumentRecord(id: "doc", path: pdfURL.path, bookmarkData: nil, title: "T",
                                             pageCount: 2, fileSize: 1))
        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(doc.page(at: 0))
        UserDefaults.standard.set(true, forKey: "notesVisible")
        let notes = NotesController(document: doc, documentID: "doc", database: db)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 880), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 640, height: 880))
        window.contentView = view
        view.document = doc
        view.displayMode = .singlePage
        view.autoScales = true
        notes.attach(to: view)
        view.layoutDocumentView()

        // 螢光筆：三種顏色各標一段
        func select(_ phrase: String) -> PDFSelection? {
            doc.findString(phrase, withOptions: []).first
        }
        for (phrase, color) in [("artistic expression", HighlightColor.yellow),
                                ("constructed scenes", .red),
                                ("large-format cameras", .blue)] {
            let sel = try XCTUnwrap(select(phrase), "找不到：\(phrase)；頁面文字：\(page.string ?? "nil")")
            view.setCurrentSelection(sel, animate: false)
            XCTAssertTrue(notes.highlightSelection(color))
        }
        XCTAssertEqual(notes.highlights.count, 3)
        notes.relayout()
        XCTAssertEqual(notes.marksView(page: 0)?.marks.count, 3)

        // 便利貼：有標題深色、短的淺色、超出（收合）、展開
        let size = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation).displaySize
        let titled = try XCTUnwrap(notes.addNote(page: 0, at: CGPoint(x: 370, y: 820)))
        notes.update(titled.id) {
            $0.title = "閱讀重點"
            $0.body = "冷面美學：冷靜、疏離、細節銳利。\n大畫幅相機。"
            $0.color = .graphite
        }
        let short = try XCTUnwrap(notes.addNote(page: 0, at: CGPoint(x: 70, y: 300)))
        notes.update(short.id) { $0.body = "這段可以引用在報告裡 ✍️"; $0.color = .butter }
        let long = try XCTUnwrap(notes.addNote(page: 0, at: CGPoint(x: 300, y: 300)))
        notes.update(long.id) {
            $0.body = String(repeating: "很長的筆記內容，超過便利貼的高度時下方會出現「展開」。", count: 4)
            $0.color = .mint
            $0.fontFamily = NoteFonts.installed.contains { $0.family == "Yuanti TC" } ? "Yuanti TC" : ""
        }
        let expanded = try XCTUnwrap(notes.addNote(page: 0, at: CGPoint(x: 70, y: 170)))
        notes.update(expanded.id) {
            $0.title = "展開的筆記"
            $0.body = String(repeating: "展開後往下長高，寬度不變。", count: 8)
            $0.color = .sky
            $0.expanded = true
            $0.rect?.width = 230
        }
        _ = notes.addUnplacedNote(page: 0)
        window.makeFirstResponder(view)
        notes.relayout()
        XCTAssertEqual(notes.placedViewCount, 4)

        // 展開的便利貼高度 > 收合高度；寬度不變
        let ev = try XCTUnwrap(notes.noteView(expanded.id))
        XCTAssertGreaterThan(ev.bounds.height, CGFloat(StickyNote.defaultSize.height))
        XCTAssertEqual(ev.bounds.width, 230, accuracy: 0.5)
        XCTAssertEqual(notes.noteView(long.id)?.strip, .expand)
        XCTAssertEqual(notes.noteView(expanded.id)?.strip, .collapse)

        // 點擊位置：頂端 → 拖曳（便利貼本身），中央 → 文字視圖
        let lv = try XCTUnwrap(notes.noteView(long.id))
        let sup = try XCTUnwrap(lv.superview)
        let headerPoint = sup.convert(CGPoint(x: lv.bounds.midX, y: 5), from: lv)
        let bodyPoint = sup.convert(CGPoint(x: lv.bounds.midX, y: lv.bounds.midY), from: lv)
        let edgePoint = sup.convert(CGPoint(x: lv.bounds.maxX - 2, y: lv.bounds.midY), from: lv)
        XCTAssertTrue(lv.hitTest(headerPoint) === lv)
        XCTAssertTrue(lv.hitTest(bodyPoint) is NoteTextView)
        XCTAssertTrue(lv.hitTest(edgePoint) === lv)

        try await snapshot(view, "notes-pdfview.png")
        XCTAssertEqual(notes.noteView(long.id)?.bounds.height ?? 0, CGFloat(StickyNote.defaultSize.height), accuracy: 0.5,
                       "結束編輯後應回到收合高度")

        // 編輯：游標落在點擊位置
        let sv = try XCTUnwrap(notes.noteView(short.id))
        sv.beginEditing(at: CGPoint(x: StickyNoteLayout.padding + 1, y: StickyNoteLayout.headerHeight(short) + 8))
        XCTAssertTrue(window.firstResponder === sv.textView)
        XCTAssertEqual(sv.textView.selectedRange().location, 0)
        sv.textView.insertText("★", replacementRange: sv.textView.selectedRange())
        XCTAssertTrue(notes.note(id: short.id)?.body.hasPrefix("★") == true)
        sv.endEditing()
        XCTAssertFalse(window.firstResponder === sv.textView)

        // 移動與縮放（顯示空間），會限制在頁面內
        notes.setRect(PageRect(x: 1000, y: -50, width: 60, height: 40), for: short.id, live: false)
        let r = try XCTUnwrap(notes.note(id: short.id)?.rect)
        XCTAssertLessThanOrEqual(r.maxX, Double(size.width) + 0.01)
        XCTAssertGreaterThanOrEqual(r.y, 0)
        XCTAssertEqual(r.width, StickyNote.minimumSize.width)
        notes.setRect(PageRect(x: 70, y: 210, width: 190, height: 90), for: short.id, live: false)

        // 翻頁影像包含螢光筆與便利貼
        let decorations = notes.decorations(page: 0)
        XCTAssertEqual(decorations.highlights.count, 3)
        XCTAssertEqual(decorations.notes.count, 4)
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let img = try XCTUnwrap(PageRenderCache.render(ref: page.pageRef!, geometry: geometry, longSide: 1100,
                                                       overlays: [], decorations: decorations))
        let rep = NSBitmapImageRep(cgImage: img)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: artifacts.appendingPathComponent("notes-turn-cache.png"))

        // N：隱藏 → 頁面上沒有便利貼；翻頁影像也不含
        notes.setVisible(false)
        XCTAssertEqual(notes.placedViewCount, 0)
        XCTAssertTrue(notes.decorations(page: 0).notes.isEmpty)
        notes.setVisible(true)
        XCTAssertEqual(notes.placedViewCount, 4)

        // 放大後仍跟著頁面
        view.autoScales = false
        view.scaleFactor = view.scaleFactor * 1.4
        notes.relayout()
        XCTAssertEqual(try XCTUnwrap(notes.noteView(long.id)).bounds.width, CGFloat(notes.note(id: long.id)!.rect!.width),
                       accuracy: 0.5)

        // 移除一個螢光標記
        let blue = try XCTUnwrap(notes.highlights.first { $0.color == .blue })
        notes.removeHighlight(blue.id)
        XCTAssertEqual(notes.highlights.count, 2)

        // 儲存後重新開啟，內容與位置都保留
        notes.flushSaves()
        notes.detach()
        let reopened = NotesController(document: doc, documentID: "doc", database: db)
        XCTAssertEqual(reopened.notes.count, 5)
        XCTAssertEqual(reopened.notes.filter { !$0.isPlaced }.count, 1)
        XCTAssertEqual(reopened.note(id: titled.id)?.title, "閱讀重點")
        XCTAssertEqual(reopened.note(id: titled.id)?.color, .graphite)
        XCTAssertEqual(reopened.note(id: expanded.id)?.expanded, true)
        XCTAssertEqual(reopened.highlights.count, 2)
        UserDefaults.standard.set(true, forKey: "notesVisible")
    }

    /// 掃描頁：以 OCR 文字行選取並上螢光筆。
    func testScanPageSelectionAndHighlight() async throws {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let pdfURL = artifacts.appendingPathComponent("notes-scan-src.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        PipelineE2ETests.makeScannedPDFForTests(at: pdfURL)
        let db = try AppDatabase.inMemory()
        try db.upsertDocument(DocumentRecord(id: "scan", path: pdfURL.path, bookmarkData: nil, title: "S",
                                             pageCount: 3, fileSize: 1))
        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        let notes = NotesController(document: doc, documentID: "scan", database: db, url: pdfURL)
        XCTAssertTrue(notes.isScannedPage(0))

        let page = try XCTUnwrap(doc.page(at: 0))
        let size = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation).displaySize
        // 從頁面上方三分之一拖到中間，涵蓋幾行文字（辨識完成前就開始拖曳也要能補算）
        notes.beginScanSelection(page: 0, displayPoint: CGPoint(x: size.width * 0.15, y: size.height * 0.8))
        notes.updateScanSelection(to: CGPoint(x: size.width * 0.6, y: size.height * 0.6))
        notes.endScanSelection()
        let start = Date()
        while notes.scanSelection == nil && Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let sel = try XCTUnwrap(notes.scanSelection)
        XCTAssertFalse(sel.text.isEmpty)
        XCTAssertGreaterThanOrEqual(sel.spans.count, 1)

        XCTAssertTrue(notes.highlightSelection(.red))
        XCTAssertNil(notes.scanSelection)
        XCTAssertEqual(notes.highlights.first?.color, .red)
        XCTAssertFalse(notes.highlights.first?.text.isEmpty ?? true)

        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let img = try XCTUnwrap(PageRenderCache.render(ref: page.pageRef!, geometry: geometry, longSide: 1200,
                                                       overlays: [], decorations: notes.decorations(page: 0)))
        try XCTUnwrap(NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]))
            .write(to: artifacts.appendingPathComponent("notes-scan-highlight.png"))
    }

    /// 在譯文上標螢光筆：顯示譯文時標在譯文的位置，切回原文時標在對應的原文位置；⌘Z 可復原。
    func testHighlightFollowsTranslationAndUndo() async throws {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let pdfURL = artifacts.appendingPathComponent("notes-tr-src.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        Self.makeTextPDF(at: pdfURL)
        let db = try AppDatabase.inMemory()
        try db.upsertDocument(DocumentRecord(id: "tr", path: pdfURL.path, bookmarkData: nil, title: "T",
                                             pageCount: 2, fileSize: 1))
        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(doc.page(at: 0))
        let g = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)

        // 第二段原文（Times 12pt，在頁面上方）當作一個區塊
        let para = try XCTUnwrap(doc.findString("The use of photography", withOptions: []).first)
        var paraRect = para.bounds(for: page)
        for phrase in ["Yet the ubiquity", "diminished", "debates"] {
            if let more = doc.findString(phrase, withOptions: []).first { paraRect = paraRect.union(more.bounds(for: page)) }
        }
        paraRect = CGRect(x: 60, y: paraRect.minY - 2, width: 475, height: paraRect.height + 4)
        let block = TextBlock(id: "tr:p0:b1", documentID: "tr", pageIndex: 0, readingOrder: 1, kind: .paragraph,
                              text: "The use of photography…", bounds: PageRect(paraRect), confidence: 1, source: .embedded)
        let translation = "攝影作為藝術表達的手段，從未像今天這樣普遍。然而攝影的無所不在，並沒有減少圍繞其地位的批評與爭論。"
        let item = OverlayItem(bounds: block.bounds, kind: .paragraph, text: translation, blockID: block.id)
        let style = OverlayStyle(background: .white, fontSize: 11, fontFamily: "PingFang TC")
        let drawing = OverlayDrawing(item: item, style: style, geometry: g)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 880), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 640, height: 880))
        window.contentView = view
        view.document = doc
        view.displayMode = .singlePage
        view.autoScales = true
        let notes = NotesController(document: doc, documentID: "tr", database: db, url: pdfURL)
        var covered = true
        notes.overlayCovers = { _ in covered }
        notes.overlayDrawings = { _ in covered ? [drawing] : [] }
        notes.pageBlocks = { $0 == 0 ? [block] : [] }
        notes.attach(to: view)
        window.makeFirstResponder(view)

        // 原文字元版面在背景準備
        notes.loadTextLayer(0)
        let t0 = Date()
        while notes.originalFlow(0) == nil, Date().timeIntervalSince(t0) < 10 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(notes.originalFlow(0))

        // 譯文上選取第二句「然而攝影的無所不在」
        let tflow = try XCTUnwrap(notes.translatedFlow(0))
        let tb = try XCTUnwrap(tflow.block(id: block.id))
        let startIndex = tb.chars.firstIndex(of: "然")!
        let r0 = tb.rects[startIndex], r1 = tb.rects[startIndex + 8]
        XCTAssertTrue(notes.beginScanSelection(page: 0, displayPoint: CGPoint(x: r0.minX + 0.5, y: r0.midY)))
        notes.updateScanSelection(to: CGPoint(x: r1.maxX - 0.5, y: r1.midY))
        notes.endScanSelection()
        XCTAssertEqual(notes.scanSelection?.text, "然而攝影的無所不在")
        XCTAssertTrue(notes.highlightSelection(.yellow))
        let h = try XCTUnwrap(notes.highlights.first)
        XCTAssertEqual(h.spans.first?.side, .translated)

        // 從譯文左側的頁邊開始拖曳：仍由閱讀器選取譯文，不交給 PDFKit 選到底下的原文
        let blockRect = OverlayRenderer.displayRect(block.bounds, geometry: g)
        let firstRect = tb.rects[0]
        XCTAssertTrue(notes.beginScanSelection(page: 0, displayPoint: CGPoint(x: blockRect.minX - 25, y: firstRect.midY)))
        notes.updateScanSelection(to: CGPoint(x: tb.rects[1].maxX - 0.5, y: tb.rects[1].midY))
        notes.endScanSelection()
        XCTAssertEqual(notes.scanSelection?.text, String(tb.chars[0..<2]))
        // 段落上方的空白處開始也一樣
        XCTAssertTrue(notes.beginScanSelection(page: 0, displayPoint: CGPoint(x: firstRect.midX, y: blockRect.maxY + 5)))
        notes.endScanSelection()
        // 點在沒有譯文、仍顯示原文的字上：交給 PDFKit
        let outside = try XCTUnwrap(doc.findString("Staged photography", withOptions: []).first { $0.pages.contains(page) })
        let outsideRect = g.toDisplay(outside.bounds(for: page))
        XCTAssertFalse(blockRect.intersects(outsideRect))
        XCTAssertFalse(notes.beginScanSelection(page: 0, displayPoint: CGPoint(x: outsideRect.midX, y: outsideRect.midY)))
        notes.clearScanSelection()

        // 譯文畫面：標在譯文的字上
        let onTranslation = notes.displayRects(for: h, page: 0)
        XCTAssertFalse(onTranslation.isEmpty)
        XCTAssertEqual(onTranslation[0].minX, r0.minX, accuracy: 1)

        // 切到原文：標在原文第二句（Yet the ubiquity …）
        covered = false
        let onOriginal = notes.displayRects(for: h, page: 0)
        XCTAssertFalse(onOriginal.isEmpty)
        let yet = try XCTUnwrap(doc.findString("Yet the ubiquity", withOptions: []).first)
        let yetRect = g.toDisplay(yet.bounds(for: page))
        XCTAssertTrue(onOriginal.contains { $0.insetBy(dx: -3, dy: -3).intersects(yetRect) },
                      "原文標記 \(onOriginal) 應涵蓋 \(yetRect)")
        XCTAssertFalse(onOriginal.contains { $0.intersects(g.toDisplay(para.bounds(for: page))) && $0.minX < yetRect.minX - 40 },
                       "不應標到第一句")

        // 原文畫面截圖、譯文畫面截圖
        for (name, cover) in [("notes-hl-original.png", false), ("notes-hl-translated.png", true)] {
            covered = cover
            let img = try XCTUnwrap(PageRenderCache.render(ref: page.pageRef!, geometry: g, longSide: 1200,
                                                           overlays: cover ? [drawing] : [],
                                                           decorations: notes.decorations(page: 0)))
            try XCTUnwrap(NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]))
                .write(to: artifacts.appendingPathComponent(name))
        }

        // ⌘Z：復原螢光筆，再重做
        let um = try XCTUnwrap(view.undoManager)
        func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        um.removeAllActions()
        notes.removeHighlight(h.id)
        XCTAssertTrue(notes.highlights.isEmpty)
        flush(); um.undo()
        XCTAssertEqual(notes.highlights.count, 1)
        flush(); um.redo()
        XCTAssertTrue(notes.highlights.isEmpty)
        flush(); um.undo()

        // ⌘Z：新增、移動、刪除便利貼
        um.removeAllActions()
        let n = try XCTUnwrap(notes.addNote(page: 0))
        flush(); um.undo()
        XCTAssertNil(notes.note(id: n.id))
        flush(); um.redo()
        XCTAssertNotNil(notes.note(id: n.id))
        let before = try XCTUnwrap(notes.note(id: n.id)?.rect)
        notes.beginInteraction(id: n.id)
        notes.setRect(PageRect(x: 100, y: 300, width: before.width, height: before.height), for: n.id, live: true)
        notes.commitRect(for: n.id)
        flush(); um.undo()
        XCTAssertEqual(notes.note(id: n.id)?.rect, before)
        notes.delete(n.id)
        XCTAssertNil(notes.note(id: n.id))
        flush(); um.undo()
        XCTAssertNotNil(notes.note(id: n.id))
        XCTAssertEqual(try db.notes(documentID: "tr").count, 1)

        // 側邊欄排序與拖到頁面上
        let a1 = notes.addUnplacedNote(page: 0), a2 = notes.addUnplacedNote(page: 0)
        flush()
        XCTAssertEqual(notes.notes(page: 0).map(\.id).suffix(2), [a1.id, a2.id])
        notes.moveNote(a2.id, before: a1.id, page: 0)
        let order = notes.notes(page: 0).map(\.id)
        XCTAssertLessThan(order.firstIndex(of: a2.id)!, order.firstIndex(of: a1.id)!)
        flush(); um.undo()
        let restored = notes.notes(page: 0).map(\.id)
        XCTAssertLessThan(restored.firstIndex(of: a1.id)!, restored.firstIndex(of: a2.id)!)
        notes.placeNote(a1.id, page: 1, at: CGPoint(x: 200, y: 500))
        let placed = try XCTUnwrap(notes.note(id: a1.id))
        XCTAssertEqual(placed.pageIndex, 1)
        XCTAssertEqual(placed.rect?.maxY ?? 0, 508, accuracy: 1)
        XCTAssertEqual(try db.notes(documentID: "tr").first { $0.id == a1.id }?.sortOrder, notes.note(id: a1.id)?.sortOrder)
        notes.detach()
    }
}
