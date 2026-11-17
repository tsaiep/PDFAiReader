import SwiftUI
import PDFKit
import ReaderCore
import ReaderServices

/// PDFView 子類別：加入「翻譯選取文字」右鍵選單與單頁模式的動畫鍵盤翻頁。
final class ReaderPDFView: PDFView {
    var keyHandler: ((NSEvent) -> Bool)?
    var scrollHandler: ((NSEvent) -> Bool)?
    var swipeHandler: ((Bool) -> Void)?
    var optionHandler: ((Bool) -> Void)?
    var translateSelectionHandler: ((String) -> Void)?
    /// 右鍵選單的筆記與螢光筆項目（由閱讀模型提供）。
    var extraMenuItems: ((NSEvent) -> [NSMenuItem])?
    /// 放開滑鼠（螢光筆模式：選取後自動上色）。
    var mouseUpHandler: (() -> Void)?
    /// 掃描頁的文字選取：回傳 true 表示已處理（不交給 PDFKit）。
    var scanMouseHandler: ((NSEvent, ScanMousePhase) -> Bool)?
    /// 滑鼠移動（掃描頁游標）。
    var mouseMovedHandler: ((NSEvent) -> Void)?
    /// ⌘C：掃描頁選取的文字。
    var scanCopyText: (() -> String?)?
    /// 從側邊欄拖來的筆記放到頁面上（筆記 ID、視窗座標）。
    var noteDropHandler: ((String, NSPoint) -> Bool)?

    static let noteDragPrefix = "pdfaireader-note:"

    private func draggedNoteID(_ info: NSDraggingInfo) -> String? {
        guard let s = info.draggingPasteboard.string(forType: .string), s.hasPrefix(Self.noteDragPrefix) else { return nil }
        return String(s.dropFirst(Self.noteDragPrefix.count))
    }

    /// PDFView 換文件時會重新註冊拖放類型（只剩檔案），每次都補上筆記拖放用的文字類型。
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes(newTypes.contains(.string) ? newTypes : newTypes + [.string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedNoteID(sender) != nil ? .move : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedNoteID(sender) != nil ? .move : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedNoteID(sender) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let id = draggedNoteID(sender) { return noteDropHandler?(id, sender.draggingLocation) ?? false }
        return super.performDragOperation(sender)
    }

    enum ScanMousePhase { case down, dragged, up }


    @objc override func copy(_ sender: Any?) {
        if let text = scanCopyText?(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        super.copy(sender)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if scrollHandler?(event) == true { return }
        super.scrollWheel(with: event)
    }

    /// 三指滑動（系統設定為「在頁面之間滑動」時）。
    override func swipe(with event: NSEvent) {
        if event.deltaX != 0 { swipeHandler?(event.deltaX > 0) } else { super.swipe(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        optionHandler?(event.modifierFlags.contains(.option))
        super.flagsChanged(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let item = NSMenuItem(title: L("翻譯選取文字", "Translate Selection"), action: #selector(translateSelectionAction(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        if let extra = extraMenuItems?(event), !extra.isEmpty {
            var at = menu.items.firstIndex { $0.isSeparatorItem }.map { $0 + 1 } ?? 0
            if menu.items.isEmpty || at == 0 { at = 0 }
            for item in extra { menu.insertItem(item, at: at); at += 1 }
            menu.insertItem(.separator(), at: at)
        }
        return menu
    }

    @objc private func translateSelectionAction(_ sender: Any?) {
        if let text = currentSelection?.string { translateSelectionHandler?(text) }
    }
}

/// 包裝 PDFView。狀態由 ReaderModel 命令式驅動，PDFView 的變化透過通知回報。
struct PDFKitView: NSViewRepresentable {
    let model: ReaderModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.document = model.document
        view.autoScales = true
        view.displayDirection = .vertical
        // 掃描頁面不做反相；深色模式只改變頁面外的背景。
        view.backgroundColor = .underPageBackgroundColor
        view.pageShadowsEnabled = true
        view.enableDataDetectors = false
        view.interpolationQuality = .high
        context.coordinator.installEventMonitor(for: view)
        view.translateSelectionHandler = { [weak model] text in
            model?.showTranslationPanel = true
            model?.translation.translateSelection(text)
        }
        view.extraMenuItems = { [weak model] event in model?.contextMenuItems(for: event) ?? [] }
        view.mouseUpHandler = { [weak model] in model?.pdfMouseUp() }
        view.scanMouseHandler = { [weak model] event, phase in model?.scanMouse(event, phase) ?? false }
        view.mouseMovedHandler = { [weak model] event in model?.pdfMouseMoved(event) }
        view.scanCopyText = { [weak model] in model?.notes.scanSelection?.text }
        view.noteDropHandler = { [weak model] id, point in model?.dropNote(id, windowPoint: point) ?? false }
        view.registerForDraggedTypes([.string])

        let center = NotificationCenter.default
        center.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
                           name: .PDFViewPageChanged, object: view)
        center.addObserver(context.coordinator, selector: #selector(Coordinator.scaleChanged(_:)),
                           name: .PDFViewScaleChanged, object: view)
        center.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)),
                           name: .PDFViewSelectionChanged, object: view)

        model.attach(view)
        return view
    }

    func updateNSView(_ nsView: ReaderPDFView, context: Context) {}

    static func dismantleNSView(_ nsView: ReaderPDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.removeEventMonitor()
    }

    final class Coordinator: NSObject {
        let model: ReaderModel
        init(model: ReaderModel) { self.model = model }

        @MainActor @objc func pageChanged(_ note: Notification) { model.pdfViewPageChanged() }
        @MainActor @objc func scaleChanged(_ note: Notification) { model.pdfViewScaleChanged() }
        @MainActor @objc func selectionChanged(_ note: Notification) { model.pdfViewSelectionChanged() }

        private var monitor: Any?
        private var mouseCaptured = false

        @MainActor
        private func handleMouse(_ event: NSEvent, in view: PDFView) -> NSEvent? {
            if event.type == .mouseMoved {
                // PDFKit 處理完再設定游標，才不會被它蓋掉
                if isOverPDF(event, view) {
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.model.pdfMouseMoved(event) } }
                }
                return event
            }
            // 右鍵（或 ⌃點按）在譯文或掃描頁上：PDFKit 會先選取底下原文的字，改由閱讀器自己顯示選單
            let isContextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            if isContextClick {
                guard isOverPDF(event, view), model.ownsTextInteraction(event) else { return event }
                if let window = view.window, window.firstResponder is NSText { window.makeFirstResponder(view) }
                let menu = NSMenu()
                for item in model.contextMenuItems(for: event) { menu.addItem(item) }
                guard !menu.items.isEmpty else { return nil }
                NSMenu.popUpContextMenu(menu, with: event, for: view)
                return nil
            }
            // 點 PDF 區域：結束側邊欄或便利貼的文字輸入（游標不再閃）、取消側邊欄的選取外框
            if event.type == .leftMouseDown || event.type == .rightMouseDown, isOverPDF(event, view) {
                if let window = view.window, window.firstResponder is NSText { window.makeFirstResponder(view) }
                if model.notes.focusedNoteID != nil { model.notes.focusedNoteID = nil }
                if model.notes.sidebarEditingID != nil { model.notes.sidebarEditingID = nil }
            }
            switch event.type {
            case .leftMouseDown:
                mouseCaptured = false
                guard isOverPDF(event, view) else { return event }
                if model.scanMouse(event, .down) {
                    mouseCaptured = true
                    return nil
                }
                return event
            case .leftMouseDragged:
                guard mouseCaptured else { return event }
                _ = model.scanMouse(event, .dragged)
                return nil
            case .leftMouseUp:
                if mouseCaptured {
                    mouseCaptured = false
                    _ = model.scanMouse(event, .up)
                    return nil
                }
                // PDFKit 原生選取：等它更新選取後再處理（螢光筆模式上色）
                if isOverPDF(event, view) {
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.model.pdfMouseUp() } }
                }
                return event
            default:
                return event
            }
        }

        /// 滑鼠在 PDF 頁面區域上，而且不是在便利貼上（便利貼自己處理拖曳與編輯）。
        @MainActor
        private func isOverPDF(_ event: NSEvent, _ view: PDFView) -> Bool {
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point), let content = view.window?.contentView else { return false }
            var hit = content.hitTest(event.locationInWindow)
            guard let first = hit, first === view || first.isDescendant(of: view) else { return false }
            while let h = hit {
                if h is StickyNoteView || h is NSText { return false }
                hit = h.superview
            }
            return true
        }

        /// 觸控板捲動事件是送到 PDFView 內部的捲動視圖，不會經過 PDFView 本身；
        /// 因此用 App 層級的事件監聽先攔截，交給閱讀模型處理翻頁，未處理的才放行。
        @MainActor
        func installEventMonitor(for view: PDFView) {
            removeEventMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .keyDown, .flagsChanged,
                                                                  .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved,
                                                                  .rightMouseDown]) {
                [weak self, weak view] event in
                guard let self, let view, let window = view.window, event.window === window else { return event }
                switch event.type {
                case .scrollWheel, .swipe:
                    let point = view.convert(event.locationInWindow, from: nil)
                    guard view.bounds.contains(point) else { return event }
                    if event.type == .swipe {
                        guard event.deltaX != 0 else { return event }
                        let rtl = self.model.readingDirection == .rightToLeft
                        self.model.turnPage(forward: (event.deltaX > 0) != rtl)
                        return nil
                    }
                    return self.model.handleScroll(event) ? nil : event
                case .keyDown:
                    // 只在焦點位於 PDF 區域時處理（輸入框打字不受影響）
                    guard let responder = window.firstResponder as? NSView,
                          responder === view || responder.isDescendant(of: view) else { return event }
                    // 便利貼編輯中：按鍵交給文字視圖
                    if responder is NSText { return event }
                    return self.model.handleKey(event) ? nil : event
                case .flagsChanged:
                    self.model.setPeekingOriginal(event.modifierFlags.contains(.option))
                    return event
                case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .rightMouseDown:
                    // 滑鼠事件實際送到 PDFKit 內部的文件視圖，PDFView 子類別的 mouseDown 不一定會被呼叫；
                    // 因此在這裡先攔截：譯文上的選取、掃描頁的選取由閱讀器處理，不讓 PDFKit 選到底下的原文。
                    return self.handleMouse(event, in: view)
                default:
                    return event
                }
            }
        }

        func removeEventMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// 側邊縮圖（PDFKit 原生，按需產生縮圖，適合大型文件）。
struct ThumbnailsView: NSViewRepresentable {
    let model: ReaderModel

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 110, height: 150)
        view.maximumNumberOfColumns = 1
        view.backgroundColor = .clear
        view.allowsDragging = false
        view.allowsMultipleSelection = false
        view.pdfView = model.pdfView
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== model.pdfView {
            nsView.pdfView = model.pdfView
        }
    }
}

/// 翻頁動畫用的頁面影像快取。背景預先渲染目前與相鄰頁（含譯文疊加），
/// 同時讓 Quartz 先解碼掃描影像，翻頁時不必等待。
final class PageRenderCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PDFAiReader.PageRender", qos: .utility)
    private let lock = NSLock()
    private var cache: [Int: (key: String, image: CGImage)] = [:]
    private var order: [Int] = []
    private var inflight: Set<String> = []
    private let capacity = 10

    static func key(index: Int, longSide: CGFloat, overlays: [OverlayDrawing], decorations: PageDecorations) -> String {
        var h = Hasher()
        for o in overlays { h.combine(o.item.text); h.combine(o.style.fontSize); h.combine(o.style.fontFamily) }
        h.combine(decorations.signature)
        return "\(index)-\(Int(longSide / 40))-\(overlays.count)-\(h.finalize())"
    }

    private func cached(_ index: Int, _ key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[index], entry.key == key else { return nil }
        return entry.image
    }

    private func store(_ index: Int, _ key: String, _ image: CGImage?) {
        lock.lock(); defer { lock.unlock() }
        inflight.remove(key)
        guard let image else { return }
        cache[index] = (key, image)
        order.removeAll { $0 == index }
        order.append(index)
        while order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
    }

    func prepare(page: PDFPage, index: Int, longSide: CGFloat, overlays: [OverlayDrawing],
                 decorations: PageDecorations = PageDecorations()) {
        let key = Self.key(index: index, longSide: longSide, overlays: overlays, decorations: decorations)
        lock.lock()
        let skip = (cache[index]?.key == key) || inflight.contains(key)
        if !skip { inflight.insert(key) }
        lock.unlock()
        guard !skip, let ref = page.pageRef else { return }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        queue.async { [weak self] in
            let image = Self.render(ref: ref, geometry: geometry, longSide: longSide, overlays: overlays,
                                    decorations: decorations)
            self?.store(index, key, image)
        }
    }

    /// 取得頁面影像；沒有快取時同步渲染（主執行緒）。
    func image(page: PDFPage, index: Int, longSide: CGFloat, overlays: [OverlayDrawing],
               decorations: PageDecorations = PageDecorations()) -> CGImage? {
        let key = Self.key(index: index, longSide: longSide, overlays: overlays, decorations: decorations)
        if let hit = cached(index, key) { return hit }
        guard let ref = page.pageRef else { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        // 同步渲染用較低解析度，避免卡住動畫開始
        let image = Self.render(ref: ref, geometry: geometry, longSide: min(longSide, 1400), overlays: overlays,
                                decorations: decorations)
        store(index, key, image)
        return image
    }

    static func render(ref: CGPDFPage, geometry: PageGeometry, longSide: CGFloat,
                       overlays: [OverlayDrawing], decorations: PageDecorations = PageDecorations()) -> CGImage? {
        let size = geometry.displaySize
        let s = max(0.25, longSide / max(size.width, size.height))
        let w = Int((size.width * s).rounded()), h = Int((size.height * s).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        ctx.concatenate(geometry.pageToDisplay)
        ctx.drawPDFPage(ref)
        for o in overlays {
            OverlayRenderer.drawInPageSpace(ctx, item: o.item, style: o.style, geometry: o.geometry)
        }
        // 與畫面相同的層次：頁面 → 譯文 → 螢光筆（色彩增值）→ 便利貼
        decorations.draw(in: ctx, geometry: geometry)
        return ctx.makeImage()
    }
}
