import AppKit
import PDFKit
import ReaderCore
import ReaderServices

/// 繪製一個譯文區塊所需的全部資料（可跨執行緒傳遞）。
struct OverlayDrawing: Sendable {
    let item: OverlayItem
    let style: OverlayStyle
    let geometry: PageGeometry
}

/// 單一頁面的譯文圖層。放在 PDFView 的文件視圖裡、與頁面同位置同大小，
/// 因此會跟著捲動；縮放或版面變動時由管理器重新對齊。不攔截滑鼠事件，文字選取照常運作。
final class PageOverlayView: NSView {
    var geometry: PageGeometry
    var drawings: [OverlayDrawing] = [] { didSet { needsDisplay = true } }

    init(geometry: PageGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !drawings.isEmpty else { return }
        let size = geometry.displaySize
        guard size.width > 0, size.height > 0 else { return }
        ctx.saveGState()
        // 顯示空間（頁面點數、已旋轉、原點左下）→ 本視圖座標
        ctx.scaleBy(x: bounds.width / size.width, y: bounds.height / size.height)
        for d in drawings {
            OverlayRenderer.draw(ctx, item: d.item, style: d.style,
                                 rect: OverlayRenderer.displayRect(d.item.bounds, geometry: geometry))
        }
        ctx.restoreGState()
    }
}

/// 管理各頁的譯文疊加：建立、更新、顯示／隱藏、對齊。只保留閱讀位置附近的頁面以節省記憶體。
@MainActor
final class TranslationOverlayManager {
    private weak var document: PDFDocument?
    private weak var pdfView: PDFView?
    private let coordinator: TranslationCoordinator

    private(set) var isEnabled = false
    private var isPeeking = false
    private var drawingsByPage: [Int: [OverlayDrawing]] = [:]
    private var signatures: [Int: Int] = [:]
    private var building: [Int: Task<Void, Never>] = [:]
    private var views: [Int: PageOverlayView] = [:]
    private var anchor: Int = 0
    private var observers: [NSObjectProtocol] = []
    private weak var observedDocumentView: NSView?
    private var relayoutScheduled = false

    init(document: PDFDocument, coordinator: TranslationCoordinator) {
        self.document = document
        self.coordinator = coordinator
    }

    /// 連結 PDFView 並監聽縮放、版面與翻頁。
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
        view.postsFrameChangedNotifications = true
        observeDocumentView()
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

    private var isShowing: Bool { isEnabled && !isPeeking }

    func setEnabled(_ enabled: Bool, around pages: Set<Int>) {
        isEnabled = enabled
        if enabled { refresh(around: pages) }
        relayout()
    }

    func setPeeking(_ peeking: Bool) {
        guard peeking != isPeeking else { return }
        isPeeking = peeking
        for v in views.values { v.isHidden = !isShowing || v.drawings.isEmpty }
    }

    func refresh(around pages: Set<Int>) {
        guard let document else { return }
        anchor = pages.min() ?? anchor
        guard isEnabled else { return }
        let lo = max(0, (pages.min() ?? 0) - 2)
        let hi = min(document.pageCount - 1, (pages.max() ?? 0) + 3)
        guard lo <= hi else { return }
        for p in lo...hi { update(page: p) }
        for p in Array(drawingsByPage.keys) where abs(p - anchor) > 12 {
            drawingsByPage.removeValue(forKey: p)
            signatures.removeValue(forKey: p)
            views.removeValue(forKey: p)?.removeFromSuperview()
        }
        relayout()
    }

    func translationsChanged(page: Int) {
        guard isEnabled, abs(page - anchor) <= 12 else { return }
        update(page: page)
    }

    private func update(page: Int) {
        coordinator.loadCached(page)
        guard let blocks = coordinator.blocks[page] else { return }
        let translations = coordinator.translations[page] ?? [:]
        let entries: [(TextBlock, String)] = blocks.compactMap { b in
            guard let t = translations[b.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return (b, t)
        }
        var hasher = Hasher()
        hasher.combine(coordinator.fontFamily)
        for (b, t) in entries { hasher.combine(b.id); hasher.combine(t); hasher.combine(b.text) }
        let signature = hasher.finalize()

        if signatures[page] == signature, drawingsByPage[page] != nil { return }
        guard !entries.isEmpty else {
            drawingsByPage[page] = []
            signatures[page] = signature
            relayout()
            return
        }
        building[page]?.cancel()
        let items = entries.map { OverlayItem(bounds: $0.0.bounds, kind: $0.0.kind, text: $0.1) }
        building[page] = Task { [weak self] in
            guard let self, let result = await self.coordinator.overlayStyles(page: page, items: items),
                  !Task.isCancelled else { return }
            self.drawingsByPage[page] = zip(items, result.styles).map {
                OverlayDrawing(item: $0.0, style: $0.1, geometry: result.geometry)
            }
            self.signatures[page] = signature
            self.building.removeValue(forKey: page)
            self.relayout()
        }
    }

    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        // 等 PDFKit 完成本輪版面配置後再對齊
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.relayoutScheduled = false
                self?.relayout()
            }
        }
    }

    /// 依目前版面放置／隱藏每頁的譯文圖層。
    func relayout() {
        guard let view = pdfView, let document, let docView = view.documentView else { return }
        observeDocumentView()
        // 單頁／雙頁模式只有可見頁有版面位置
        let continuous = view.displayMode == .singlePageContinuous || view.displayMode == .twoUpContinuous
        let visible = Set(view.visiblePages.map { document.index(for: $0) })

        for (p, drawings) in drawingsByPage {
            let shouldShow = isEnabled && !drawings.isEmpty && (continuous || visible.contains(p))
            guard shouldShow, let page = document.page(at: p) else {
                views[p]?.isHidden = true
                continue
            }
            let overlayView: PageOverlayView
            if let existing = views[p] {
                overlayView = existing
            } else {
                overlayView = PageOverlayView(geometry: drawings[0].geometry)
                views[p] = overlayView
            }
            if overlayView.superview !== docView {
                overlayView.removeFromSuperview()
                docView.addSubview(overlayView, positioned: .above, relativeTo: nil)
            }
            let inView = view.convert(page.bounds(for: view.displayBox), from: page)
            let frame = docView.convert(inView, from: view).integral
            if overlayView.frame != frame { overlayView.frame = frame }
            overlayView.geometry = drawings[0].geometry
            if overlayView.drawings.count != drawings.count
                || !zip(overlayView.drawings, drawings).allSatisfy({ $0.0.item.text == $0.1.item.text && $0.0.style == $0.1.style }) {
                overlayView.drawings = drawings
            }
            overlayView.isHidden = !isShowing
        }
        for (p, v) in views where drawingsByPage[p] == nil { v.isHidden = true }
    }

    /// 目前某頁的疊加內容（給翻頁動畫的預先渲染使用）。
    func drawings(page: Int) -> [OverlayDrawing] { drawingsByPage[page] ?? [] }

    /// 某頁目前是否正在畫面上顯示譯文。
    func isApplied(page: Int) -> Bool {
        guard let v = views[page] else { return false }
        return !v.isHidden && v.superview != nil && !v.drawings.isEmpty
    }

    func removeAll() {
        for t in building.values { t.cancel() }
        for v in views.values { v.removeFromSuperview() }
        views.removeAll()
        drawingsByPage.removeAll()
        signatures.removeAll()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }
}
