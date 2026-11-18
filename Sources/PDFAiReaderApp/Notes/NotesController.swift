import AppKit
import CoreImage
import SwiftUI
import PDFKit
import ReaderCore
import ReaderStore
import ReaderServices

/// 翻頁影像需要的頁面裝飾（螢光筆與便利貼）。可跨執行緒傳遞。
struct PageDecorations: @unchecked Sendable {
    var highlights: [(rects: [CGRect], color: CGColor)] = []   // 頁面座標
    var notes: [(note: StickyNote, rect: CGRect)] = []          // 顯示空間

    var isEmpty: Bool { highlights.isEmpty && notes.isEmpty }

    var signature: Int {
        var h = Hasher()
        for x in highlights { h.combine(x.rects.count); for r in x.rects { h.combine(r.minX); h.combine(r.minY); h.combine(r.width) }; h.combine(x.color.components ?? []) }
        for n in notes { h.combine(n.note); h.combine(n.rect.height) }
        return h.finalize()
    }

    /// 在已套用 pageToDisplay 的 context（頁面座標）中畫出。
    func draw(in ctx: CGContext, geometry: PageGeometry) {
        if !highlights.isEmpty {
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            for h in highlights {
                ctx.setFillColor(h.color)
                for r in h.rects { ctx.fill(r) }
            }
            ctx.restoreGState()
        }
        guard !notes.isEmpty else { return }
        ctx.saveGState()
        ctx.concatenate(geometry.displayToPage)
        for n in notes { StickyNoteRenderer.draw(n.note, in: ctx, displayRect: n.rect) }
        ctx.restoreGState()
    }
}

/// 便利貼與螢光筆：資料、儲存、頁面上的視圖與互動。
@MainActor
@Observable
final class NotesController {
    var notes: [StickyNote] = []
    var highlights: [Highlight] = []
    /// N 鍵切換：頁面上的便利貼顯示／隱藏（側邊欄仍可查看）。
    private(set) var isVisible: Bool
    var highlighterColor: HighlightColor {
        didSet { UserDefaults.standard.set(highlighterColor.rawValue, forKey: "highlighterColor") }
    }
    /// 螢光筆模式：選取文字放開滑鼠即上色。
    var highlighterMode = false {
        didSet {
            guard highlighterMode, let view = pdfView, let document else { return }
            for page in view.visiblePages { loadScanLines(document.index(for: page)) }
        }
    }
    /// 側邊欄要捲到並展開的筆記。
    var focusedNoteID: String?
    var editingNoteID: String?

    /// 便利貼或螢光筆改變（翻頁影像需要重新渲染）。
    @ObservationIgnored var onChange: ((Int) -> Void)?

    @ObservationIgnored let documentID: String
    @ObservationIgnored let database: AppDatabase?
    @ObservationIgnored weak var document: PDFDocument?
    @ObservationIgnored private(set) weak var pdfView: PDFView?
    @ObservationIgnored var views: [String: StickyNoteView] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var observedDocumentView: NSView?
    @ObservationIgnored private var relayoutScheduled = false
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var anchor = 0
    @ObservationIgnored var popover: NSPopover?
    @ObservationIgnored private var frontCounter: CGFloat = 20


    /// 目前以閱讀器自己選取的文字（譯文、或掃描頁的 OCR 文字）。PDF 文字層的原文選取仍交給 PDFKit。
    struct FlowSelectionState: Equatable {
        var page: Int
        var side: TextSide
        var spans: [TextFlow.Span]
        var text: String
    }
    var scanSelection: FlowSelectionState?

    @ObservationIgnored let documentURL: URL?
    @ObservationIgnored var lineProvider: TextExtractor?
    @ObservationIgnored var scanLines: [Int: [TextLine]] = [:]
    @ObservationIgnored var scanLoading: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored var textLayer: [Int: Bool] = [:]
    @ObservationIgnored var dragAnchor: (page: Int, side: TextSide, point: CGPoint)?
    @ObservationIgnored var dragLastPoint: CGPoint?
    @ObservationIgnored var dragEnded = false
    @ObservationIgnored var originalFlows: [Int: (signature: Int, flow: TextFlow, sourceIndex: [Int: TextFlow.Position])] = [:]
    @ObservationIgnored var translatedFlows: [Int: (signature: Int, flow: TextFlow)] = [:]
    @ObservationIgnored var markViews: [Int: PageMarksView] = [:]
    @ObservationIgnored var layerChars: [Int: [LayoutChar]] = [:]
    @ObservationIgnored var layerLoading: [Int: Task<Void, Never>] = [:]
    /// 拖曳便利貼途中：只移動便利貼，不重算螢光筆圖層。
    @ObservationIgnored var isDraggingNote = false
    /// 翻到某頁（由閱讀模型提供，會處理雙頁對齊與翻頁動畫）。
    @ObservationIgnored var navigateToPage: (Int) -> Void = { _ in }
    /// 側邊欄正在編輯的卡片。
    var sidebarEditingID: String?
    /// 某頁目前的譯文排版（由譯文圖層提供）。
    @ObservationIgnored var overlayDrawings: (Int) -> [OverlayDrawing] = { _ in [] }
    /// 某頁的原文區塊（版面分析結果）。
    @ObservationIgnored var pageBlocks: (Int) -> [TextBlock] = { _ in [] }
    /// 復原：記錄最近一次可合併的修改（連續打標題時只記一次）。
    @ObservationIgnored var lastUndoKey: (key: String, time: Date)?
    /// 便利貼開始編輯時的內容（結束時記成一次可復原的修改）。
    @ObservationIgnored var editSnapshots: [String: StickyNote] = [:]
    /// 拖曳或縮放便利貼前的狀態。
    @ObservationIgnored var interactionSnapshots: [String: StickyNote] = [:]

    /// PDF 文字層的選取（顯示空間）。譯文蓋住原文時 PDFKit 的反白看不到，改由標記圖層畫在譯文上。
    @ObservationIgnored var pdfSelectionRects: [Int: [CGRect]] = [:]
    /// 某頁目前是否有譯文蓋在頁面上。
    @ObservationIgnored var overlayCovers: (Int) -> Bool = { _ in false }

    init(document: PDFDocument, documentID: String, database: AppDatabase?, url: URL? = nil) {
        self.documentURL = url ?? document.documentURL
        self.document = document
        self.documentID = documentID
        self.database = database
        UserDefaults.standard.register(defaults: ["notesVisible": true])
        isVisible = UserDefaults.standard.bool(forKey: "notesVisible")
        highlighterColor = HighlightColor(rawValue: UserDefaults.standard.string(forKey: "highlighterColor") ?? "") ?? .yellow
        notes = (try? database?.notes(documentID: documentID)) ?? []
        highlights = (try? database?.highlights(documentID: documentID)) ?? []
    }

    // MARK: - 連結 PDFView

    func attach(to view: PDFView) {
        pdfView = view
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewDisplayModeChanged,
                     .PDFViewDisplayBoxChanged, .PDFViewPageChanged, .PDFViewDocumentChanged] {
            observers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRelayout() }
            })
        }
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRelayout() }
        })
        observeDocumentView()
        scheduleRelayout()
    }

    private func observeDocumentView() {
        guard let docView = pdfView?.documentView, docView !== observedDocumentView else { return }
        observedDocumentView = docView
        docView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                object: docView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRelayout() }
        })
    }

    func detach() {
        for v in markViews.values { v.removeFromSuperview() }
        markViews.removeAll()
        clearScanSelection()
        for t in scanLoading.values { t.cancel() }
        for t in layerLoading.values { t.cancel() }
        for v in views.values {
            v.endEditing()
            v.removeFromSuperview()
        }
        views.removeAll()
        flushSaves()
        popover?.close()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    // MARK: - 查詢

    /// 某頁的筆記，依側邊欄順序。
    func notes(page: Int) -> [StickyNote] {
        notes.filter { $0.pageIndex == page }
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.createdAt < $1.createdAt }
    }
    func highlights(page: Int) -> [Highlight] { highlights.filter { $0.pageIndex == page } }
    func note(id: String) -> StickyNote? { notes.first { $0.id == id } }
    var pagesWithNotes: Set<Int> { Set(notes.map(\.pageIndex)) }

    func geometry(_ page: PDFPage) -> PageGeometry {
        PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    /// 滑鼠位置 → 某頁的顯示空間座標。
    func displayPoint(event: NSEvent, page index: Int) -> CGPoint? {
        guard let view = pdfView, let page = document?.page(at: index) else { return nil }
        let inView = view.convert(event.locationInWindow, from: nil)
        return view.convert(inView, to: page).applying(geometry(page).pageToDisplay)
    }

    // MARK: - 新增／修改／刪除

    /// 在頁面某點（頁面座標）新增便利貼，並立即進入編輯。
    @discardableResult
    func addNote(page index: Int, at pagePoint: CGPoint? = nil) -> StickyNote? {
        guard let page = document?.page(at: index) else { return nil }
        let g = geometry(page)
        let size = g.displaySize
        let w = StickyNote.defaultSize.width, h = StickyNote.defaultSize.height
        var rect: PageRect
        if let pagePoint {
            let p = pagePoint.applying(g.pageToDisplay)
            rect = PageRect(x: Double(p.x) - 12, y: Double(p.y) - h + 8, width: w, height: h)
        } else {
            // 預設放在右上角，已有便利貼時往下錯開
            let existing = notes(page: index).filter(\.isPlaced).count
            let offset = Double(existing % 6) * 18
            rect = PageRect(x: Double(size.width) - w - 28 - offset, y: Double(size.height) - h - 36 - offset,
                            width: w, height: h)
        }
        rect = StickyNote.clamp(rect, pageSize: (Double(size.width), Double(size.height)))
        let note = StickyNote(documentID: documentID, pageIndex: index, rect: rect, color: lastColor,
                              fontFamily: lastFont, fontSize: lastFontSize)
        insert(note)
        if !isVisible { setVisible(true) }
        relayout()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.views[note.id]?.beginEditing() }
        }
        return note
    }

    /// 新增沒有實體位置的筆記（只在側邊欄）。
    @discardableResult
    func addUnplacedNote(page: Int) -> StickyNote {
        let note = StickyNote(documentID: documentID, pageIndex: page, rect: nil, color: lastColor,
                              fontFamily: lastFont, fontSize: lastFontSize)
        insert(note)
        focusedNoteID = note.id
        return note
    }

    private func insert(_ note: StickyNote) {
        notes.append(note)
        try? database?.saveNote(note)
        registerNoteUndo(id: note.id, before: nil, name: L("新增便利貼", "Add Note"))
        onChange?(note.pageIndex)
    }

    private var lastColor: NoteColor {
        NoteColor(rawValue: UserDefaults.standard.string(forKey: "note.lastColor") ?? "") ?? .butter
    }
    private var lastFont: String { UserDefaults.standard.string(forKey: "note.lastFont") ?? "" }
    private var lastFontSize: Double {
        let v = UserDefaults.standard.double(forKey: "note.lastFontSize")
        // 上次用的大小若已不在選項中（例如舊版的 17），改用預設的「中」
        return NoteFonts.sizes.contains { $0.value == v } ? v : 12
    }

    /// 修改一張筆記並儲存（debounce）。
    /// `undo`：可復原的動作名稱（nil＝不記錄，例如拖曳途中或編輯中的每個字）。連續修改同一張會合併。
    func update(_ id: String, save: Bool = true, undo: String? = L("修改便利貼", "Edit Note"),
                _ change: (inout StickyNote) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var n = notes[i]
        let before = n
        change(&n)
        guard n != before else { return }
        n.updatedAt = Date()
        notes[i] = n
        if let undo { registerNoteUndo(id: id, before: before, name: undo, coalesce: true) }
        if n.color != before.color { UserDefaults.standard.set(n.color.rawValue, forKey: "note.lastColor") }
        if n.fontFamily != before.fontFamily { UserDefaults.standard.set(n.fontFamily, forKey: "note.lastFont") }
        if n.fontSize != before.fontSize { UserDefaults.standard.set(n.fontSize, forKey: "note.lastFontSize") }
        views[id]?.apply(n)
        if save { scheduleSave(id) }
        if n.rect != before.rect || n.expanded != before.expanded || n.title != before.title
            || n.fontSize != before.fontSize || n.fontFamily != before.fontFamily {
            relayout()
        }
        onChange?(n.pageIndex)
        if n.pageIndex != before.pageIndex { onChange?(before.pageIndex) }
    }

    func delete(_ id: String) {
        guard let n = note(id: id) else { return }
        popover?.close()
        saveTasks.removeValue(forKey: id)?.cancel()
        // 先移除資料：結束編輯會觸發重新排版，資料還在的話會再建一個視圖留在畫面上
        notes.removeAll { $0.id == id }
        if editingNoteID == id { editingNoteID = nil }
        if let v = views.removeValue(forKey: id) {
            v.endEditing()
            v.removeFromSuperview()
        }
        try? database?.deleteNote(id: id)
        registerNoteUndo(id: id, before: n, name: L("刪除便利貼", "Delete Note"))
        onChange?(n.pageIndex)
    }

    /// 無位置筆記 → 放到頁面上；頁面上的 → 移到側邊欄。
    func togglePlacement(_ id: String) {
        guard let n = note(id: id), let page = document?.page(at: n.pageIndex) else { return }
        lastUndoKey = nil
        if n.isPlaced {
            update(id, undo: L("移到側邊欄", "Move to Sidebar")) { $0.rect = nil }
            if let v = views.removeValue(forKey: id) { v.removeFromSuperview() }
        } else {
            let size = geometry(page).displaySize
            let existing = notes(page: n.pageIndex).filter(\.isPlaced).count
            let offset = Double(existing % 6) * 18
            let w = StickyNote.defaultSize.width, h = StickyNote.defaultSize.height
            let rect = StickyNote.clamp(PageRect(x: Double(size.width) - w - 28 - offset,
                                                 y: Double(size.height) - h - 36 - offset, width: w, height: h),
                                        pageSize: (Double(size.width), Double(size.height)))
            update(id, undo: L("放到頁面上", "Place on Page")) { $0.rect = rect }
            if !isVisible { setVisible(true) }
        }
    }

    func toggleExpanded(id: String) {
        lastUndoKey = nil
        update(id, undo: L("展開／收合便利貼", "Expand/Collapse Note")) { $0.expanded.toggle() }
    }

    func setRect(_ rect: PageRect, for id: String, live: Bool, collapse: Bool = false) {
        guard let n = note(id: id), let page = document?.page(at: n.pageIndex) else { return }
        let size = geometry(page).displaySize
        let clamped = StickyNote.clamp(rect, pageSize: (Double(size.width), Double(size.height)))
        update(id, save: !live, undo: live ? nil : L("移動便利貼", "Move Note")) {
            $0.rect = clamped
            if collapse { $0.expanded = false }
        }
    }

    /// 拖曳或縮放結束：存檔並記成一次可復原的修改。
    func commitRect(for id: String, resized: Bool = false) {
        scheduleSave(id, delay: 0)
        if let before = interactionSnapshots.removeValue(forKey: id), let now = note(id: id), now != before {
            lastUndoKey = nil
            registerNoteUndo(id: id, before: before,
                             name: resized ? L("調整便利貼大小", "Resize Note") : L("移動便利貼", "Move Note"))
        }
    }

    func noteBodyChanged(id: String, body: String) {
        update(id, undo: nil) { $0.body = body }
        // 編輯中內容變多：便利貼跟著長高
        relayout()
    }

    func noteDidBeginEditing(_ view: StickyNoteView) {
        editingNoteID = view.note.id
        editSnapshots[view.note.id] = note(id: view.note.id)
        relayout()
    }

    func noteDidEndEditing(_ view: StickyNoteView) {
        if editingNoteID == view.note.id { editingNoteID = nil }
        scheduleSave(view.note.id, delay: 0)
        // 整段編輯記成一次可復原的修改（編輯中的 ⌘Z 由文字框自己處理）
        if let before = editSnapshots.removeValue(forKey: view.note.id), let now = note(id: view.note.id),
           now.body != before.body {
            lastUndoKey = nil
            registerNoteUndo(id: now.id, before: before, name: L("編輯便利貼文字", "Edit Note Text"))
        }
        relayout()
        view.needsLayout = true
        view.needsDisplay = true
    }

    // MARK: - 儲存

    private func scheduleSave(_ id: String, delay: Double = 0.5) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard !Task.isCancelled, let self else { return }
            self.saveTasks.removeValue(forKey: id)
            if let n = self.note(id: id) { try? self.database?.saveNote(n) }
        }
    }

    func flushSaves() {
        for (id, task) in saveTasks {
            task.cancel()
            if let n = note(id: id) { try? database?.saveNote(n) }
        }
        saveTasks.removeAll()
    }

    // MARK: - 顯示

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: "notesVisible")
        if !visible { views.values.forEach { $0.endEditing() } }
        relayout()
        for p in pagesWithNotes { onChange?(p) }
    }

    func toggleVisible() { setVisible(!isVisible) }

    func visiblePagesChanged(_ pages: Set<Int>) {
        anchor = pages.min() ?? anchor
        if let s = scanSelection, !pages.contains(s.page) { clearScanSelection() }
        // 螢光筆模式：先辨識畫面上的掃描頁，拖曳時立即有反應
        if highlighterMode { for p in pages { loadScanLines(p) } }
        // 背景準備原文的字元版面（螢光筆換算、選取用），不在主執行緒逐字計算
        for p in pages { loadTextLayer(p) }
        relayout()
    }

    func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.relayoutScheduled = false
                self?.relayout()
            }
        }
    }

    /// 依目前版面放置每張便利貼。單頁／雙頁只放可見頁；連續模式放閱讀位置附近。
    func relayout() {
        guard let view = pdfView, let document, let docView = view.documentView else { return }
        observeDocumentView()
        let continuous = view.displayMode == .singlePageContinuous || view.displayMode == .twoUpContinuous
        let visible = Set(view.visiblePages.map { document.index(for: $0) })
        var keep = Set<String>()

        if isVisible {
            for note in notes {
                guard let rect = note.rect, let page = document.page(at: note.pageIndex) else { continue }
                let shown = continuous ? (visible.contains(note.pageIndex) || abs(note.pageIndex - anchor) <= 4)
                                       : visible.contains(note.pageIndex)
                guard shown else { continue }
                keep.insert(note.id)
                let nv: StickyNoteView
                if let existing = views[note.id] {
                    nv = existing
                } else {
                    nv = StickyNoteView(note: note)
                    nv.controller = self
                    views[note.id] = nv
                }
                if nv.superview !== docView {
                    nv.removeFromSuperview()
                    docView.addSubview(nv, positioned: .above, relativeTo: nil)
                }
                let editing = nv.isEditing
                let w = CGFloat(rect.width)
                let h = StickyNoteLayout.displayHeight(note, width: w, baseHeight: CGFloat(rect.height), growForEditing: editing)
                let top = CGFloat(rect.maxY)
                let display = CGRect(x: CGFloat(rect.x), y: top - h, width: w, height: h)
                let pageRect = geometry(page).toPage(display)
                let frame = docView.convert(view.convert(pageRect, from: page), from: view)
                if nv.frame != frame { nv.frame = frame }
                if nv.bounds.size != display.size { nv.setBoundsSize(display.size) }
                nv.needsLayout = true
                nv.needsDisplay = true
            }
        }
        for (id, v) in views where !keep.contains(id) {
            v.endEditing()
            v.removeFromSuperview()
            views.removeValue(forKey: id)
        }
        if !isDraggingNote {
            relayoutMarks(view: view, document: document, docView: docView, continuous: continuous, visible: visible)
        }

        // 層次：頁面 → 譯文 → 螢光筆／選取 → 便利貼。把排在上層之上的譯文圖層移到下面
        // （只移動譯文圖層，不動便利貼，編輯焦點不受影響）
        let subs = docView.subviews
        if let topIndex = subs.firstIndex(where: { $0 is StickyNoteView || $0 is PageMarksView }) {
            let top = subs[topIndex]
            for overlay in subs[topIndex...] where overlay is PageOverlayView {
                docView.addSubview(overlay, positioned: .below, relativeTo: top)
            }
        }
    }

    /// 頁面上目前的便利貼視圖（測試用）。
    func noteView(_ id: String) -> StickyNoteView? { views[id] }
    var placedViewCount: Int { views.count }
    func marksView(page: Int) -> PageMarksView? { markViews[page] }

    func bringToFront(_ view: StickyNoteView) {
        frontCounter += 0.01
        view.layer?.zPosition = frontCounter
    }

    /// 側邊欄點選：跳到該頁並開始編輯便利貼。
    func reveal(_ id: String, reader: ReaderModel, edit: Bool = true) {
        guard let n = note(id: id) else { return }
        if !n.isPlaced { focusedNoteID = id; return }
        if !isVisible { setVisible(true) }
        let visible = Set(pdfView?.visiblePages.compactMap { document?.index(for: $0) } ?? [])
        if !visible.contains(n.pageIndex) { reader.goTo(pageIndex: n.pageIndex) }
        guard edit else {
            relayout()
            if let v = views[id] { bringToFront(v) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.relayout()
                if let v = self.views[id] {
                    self.bringToFront(v)
                    v.beginEditing()
                }
            }
        }
    }

    // MARK: - 選項（顏色、字體、標題）

    func showOptions(for id: String, from anchorView: NSView, rect: CGRect? = nil) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let panel = NoteOptionsPanel(controller: self, noteID: id) { [weak p] in p?.close() }
        p.contentViewController = NSHostingController(rootView: panel)
        p.appearance = NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
        p.show(relativeTo: rect ?? anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        popover = p
    }

    func contextMenu(for id: String) -> NSMenu? {
        guard let n = note(id: id) else { return nil }
        let menu = NSMenu()
        let colors = NSMenuItem(title: L("顏色", "Color"), action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for c in NoteColor.allCases {
            let item = ClosureMenuItem(title: c.localizedName) { [weak self] in self?.update(id) { $0.color = c } }
            item.state = n.color == c ? .on : .off
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                c.fill.setFill(); path.fill()
                c.border.setStroke(); path.stroke()
                return true
            }
            colorMenu.addItem(item)
        }
        colors.submenu = colorMenu
        menu.addItem(colors)
        menu.addItem(ClosureMenuItem(title: n.expanded ? L("收合", "Collapse") : L("展開", "Expand")) { [weak self] in
            self?.toggleExpanded(id: id)
        })
        menu.addItem(ClosureMenuItem(title: L("標題、字體…", "Title & Font…")) { [weak self] in
            guard let self, let v = self.views[id] else { return }
            self.showOptions(for: id, from: v, rect: CGRect(x: 0, y: 0, width: v.bounds.width,
                                                            height: StickyNoteLayout.headerHeight(v.note)))
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("移到側邊欄（不放在頁面上）", "Move to Sidebar (Unplaced)")) { [weak self] in
            self?.togglePlacement(id)
        })
        menu.addItem(ClosureMenuItem(title: L("刪除便利貼", "Delete Note")) { [weak self] in self?.delete(id) })
        return menu
    }

}

/// 以 closure 執行的選單項目。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

// MARK: - 便利貼選項面板

struct NoteOptionsPanel: View {
    let controller: NotesController
    let noteID: String
    let close: () -> Void
    @State private var title = ""

    var body: some View {
        let note = controller.note(id: noteID)
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("標題（選填）", "Title (optional)"), text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitTitle() }
                .onChange(of: title) { _, _ in commitTitle() }

            NoteColorRow(selected: note?.color ?? .butter) { c in controller.update(noteID) { $0.color = c } }

            HStack(spacing: 8) {
                Picker(L("字體", "Font"), selection: Binding(
                    get: { note?.fontFamily ?? "" },
                    set: { v in controller.update(noteID) { $0.fontFamily = v } })) {
                    ForEach(NoteFonts.installed) { f in Text(f.localizedName).tag(f.family) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Picker(L("大小", "Size"), selection: Binding(
                    get: { note?.fontSize ?? 12 },
                    set: { v in controller.update(noteID) { $0.fontSize = v } })) {
                    ForEach(NoteFonts.sizes, id: \.value) { s in Text(L(s.zh, s.en)).tag(s.value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
            }

            Divider()
            HStack {
                Button {
                    close()
                    controller.togglePlacement(noteID)
                } label: {
                    Label(note?.isPlaced == true ? L("移到側邊欄", "Move to Sidebar") : L("放到頁面上", "Place on Page"),
                          systemImage: note?.isPlaced == true ? "sidebar.left" : "pin")
                }
                Spacer()
                Button(role: .destructive) {
                    close()
                    controller.delete(noteID)
                } label: {
                    Label(L("刪除", "Delete"), systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 268)
        .onAppear { title = note?.title ?? "" }
    }

    private func commitTitle() {
        controller.update(noteID) { $0.title = title }
    }
}

/// 6 個顏色圓點。
struct NoteColorRow: View {
    let selected: NoteColor
    let pick: (NoteColor) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(NoteColor.allCases) { c in
                Button { pick(c) } label: {
                    ZStack {
                        Circle().fill(c.swatch)
                        Circle().strokeBorder(c.swatchBorder, lineWidth: 0.5)
                        if c == selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(c.isDark ? Color.white : Color.black.opacity(0.65))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(c.localizedName)
            }
        }
    }
}

/// 一頁的螢光筆與選取反白。不攔截滑鼠；以色彩增值混合疊在頁面（與譯文）上，文字仍清楚。
final class PageMarksView: NSView {
    struct Mark: Equatable {
        var rects: [CGRect]   // 顯示空間
        var color: NSColor
    }

    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var displaySize: CGSize = .zero { didSet { if displaySize != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        let sx = bounds.width / displaySize.width, sy = bounds.height / displaySize.height
        for m in marks {
            m.color.setFill()
            for r in m.rects {
                let rect = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
                let radius = min(3, rect.height * 0.18)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }
}
