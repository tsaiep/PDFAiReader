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

        /// 觸控板捲動事件是送到 PDFView 內部的捲動視圖，不會經過 PDFView 本身；
        /// 因此用 App 層級的事件監聽先攔截，交給閱讀模型處理翻頁，未處理的才放行。
        @MainActor
        func installEventMonitor(for view: PDFView) {
            removeEventMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .keyDown, .flagsChanged]) {
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
                    return self.model.handleKey(event) ? nil : event
                case .flagsChanged:
                    self.model.setPeekingOriginal(event.modifierFlags.contains(.option))
                    return event
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

    static func key(index: Int, longSide: CGFloat, overlays: [OverlayDrawing]) -> String {
        var h = Hasher()
        for o in overlays { h.combine(o.item.text); h.combine(o.style.fontSize); h.combine(o.style.fontFamily) }
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

    func prepare(page: PDFPage, index: Int, longSide: CGFloat, overlays: [OverlayDrawing]) {
        let key = Self.key(index: index, longSide: longSide, overlays: overlays)
        lock.lock()
        let skip = (cache[index]?.key == key) || inflight.contains(key)
        if !skip { inflight.insert(key) }
        lock.unlock()
        guard !skip, let ref = page.pageRef else { return }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        queue.async { [weak self] in
            let image = Self.render(ref: ref, geometry: geometry, longSide: longSide, overlays: overlays)
            self?.store(index, key, image)
        }
    }

    /// 取得頁面影像；沒有快取時同步渲染（主執行緒）。
    func image(page: PDFPage, index: Int, longSide: CGFloat, overlays: [OverlayDrawing]) -> CGImage? {
        let key = Self.key(index: index, longSide: longSide, overlays: overlays)
        if let hit = cached(index, key) { return hit }
        guard let ref = page.pageRef else { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        // 同步渲染用較低解析度，避免卡住動畫開始
        let image = Self.render(ref: ref, geometry: geometry, longSide: min(longSide, 1400), overlays: overlays)
        store(index, key, image)
        return image
    }

    static func render(ref: CGPDFPage, geometry: PageGeometry, longSide: CGFloat,
                       overlays: [OverlayDrawing]) -> CGImage? {
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
        return ctx.makeImage()
    }
}
