import SwiftUI
import PDFKit
import QuartzCore
import ReaderCore
import ReaderStore
import ReaderServices

enum SidebarTab: String, CaseIterable, Identifiable {
    case thumbnails, outline, bookmarks, search
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thumbnails: return "縮圖"
        case .outline: return "目錄"
        case .bookmarks: return "書籤"
        case .search: return "搜尋"
        }
    }
    var systemImage: String {
        switch self {
        case .thumbnails: return "square.grid.2x2"
        case .outline: return "list.bullet.indent"
        case .bookmarks: return "bookmark"
        case .search: return "magnifyingglass"
        }
    }
}

enum ReaderSheet: String, Identifiable {
    case wholeTranslation, export, addModel
    var id: String { rawValue }
}

enum PageTurnStyle: String, CaseIterable, Identifiable {
    case curl, slide, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .curl: return L("翻書", "Page curl")
        case .slide: return L("滑動", "Slide")
        case .none: return L("無動畫", "None")
        }
    }
}

/// 單一開啟中文件的閱讀狀態。PDFView 由此模型命令式驅動。
@MainActor
@Observable
final class ReaderModel {
    let document: PDFDocument
    let url: URL
    let record: DocumentRecord
    let pageCount: Int
    let outline: [OutlineItem]
    let search: SearchModel
    let translation: TranslationCoordinator

    private(set) var currentPageIndex: Int = 0
    private(set) var displayMode: DisplayMode
    private(set) var readingDirection: ReadingDirection
    private(set) var scaleFactor: Double = 1.0
    private(set) var autoScales: Bool = true
    private(set) var bookmarks: [Bookmark]
    private(set) var hasSelection = false
    /// 頁面上顯示譯文（false = 原文）。
    private(set) var showsTranslation: Bool
    private(set) var isPeekingOriginal = false
    /// 雙頁模式：第一頁（封面）單獨顯示，之後兩兩成對。關閉時從第一頁開始成對。
    private(set) var coverAlone = true
    /// 目前畫面上的頁（縮圖列高亮用）。
    private(set) var visiblePageIndicesForSidebar: Set<Int> = []

    var sidebarTab: SidebarTab = .thumbnails
    var showTranslationPanel: Bool {
        didSet { UserDefaults.standard.set(showTranslationPanel, forKey: "showTranslationPanel") }
    }
    var activeSheet: ReaderSheet?

    /// 由 PDFKitView 在建立時設定。
    private(set) var pdfView: PDFView?

    @ObservationIgnored private let database: AppDatabase?
    @ObservationIgnored private var initialProgress: ReadingProgress?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var visibleTask: Task<Void, Never>?
    @ObservationIgnored private var directionTracker = DirectionTracker()
    @ObservationIgnored private var highlightAnnotation: (PDFAnnotation, PDFPage)?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private let renderCache = PageRenderCache()
    @ObservationIgnored let overlay: TranslationOverlayManager
    @ObservationIgnored private var turnHost: NSView?
    @ObservationIgnored private let curl = PageCurlController()
    @ObservationIgnored private var gesture = TurnGesture()

    init(document: PDFDocument, url: URL, record: DocumentRecord, progress: ReadingProgress?,
         bookmarks: [Bookmark], database: AppDatabase?, translation: TranslationCoordinator) {
        self.document = document
        self.url = url
        self.record = record
        self.pageCount = document.pageCount
        self.database = database
        self.bookmarks = bookmarks
        self.initialProgress = progress
        self.displayMode = progress?.displayMode ?? .continuous
        self.readingDirection = progress?.readingDirection ?? .leftToRight
        self.currentPageIndex = min(max(progress?.pageIndex ?? 0, 0), max(document.pageCount - 1, 0))
        self.search = SearchModel(url: url, documentID: record.id, database: database)
        self.outline = document.outlineRoot.map { OutlineItem.children(of: $0, in: document) } ?? []
        self.translation = translation
        self.overlay = TranslationOverlayManager(document: document, coordinator: translation)
        UserDefaults.standard.register(defaults: ["showTranslationPanel": false, "pageTurnStyle": "curl",
                                                  "prerenderPages": true, "showTranslationOverlay": true])
        self.showTranslationPanel = UserDefaults.standard.bool(forKey: "showTranslationPanel")
        self.showsTranslation = UserDefaults.standard.bool(forKey: "showTranslationOverlay")
        if let stored = try? database?.preference("twoUp.coverAlone", scope: record.id) {
            self.coverAlone = stored != "0"
        }
        translation.onTranslationsChanged = { [weak self] page in
            self?.overlay.translationsChanged(page: page)
        }
    }

    // MARK: - PDFView 連結

    func attach(_ view: PDFView) {
        pdfView = view
        curl.view = view
        curl.imageForPage = { [weak self, weak view] page in
            guard let self, let view else { return nil }
            let index = self.document.index(for: page)
            return self.renderCache.image(page: page, index: index, longSide: self.renderLongSide(for: page, view: view),
                                          overlays: self.overlayDrawings(index))
        }
        curl.isRTL = { [weak self] in self?.readingDirection == .rightToLeft }
        curl.isSpread = { [weak self] in self?.displayMode == .twoUp }
        curl.navigate = { [weak self, weak view] forward in
            guard let self, let view else { return }
            self.step(view, forward)
        }
        overlay.attach(to: view)
        applyDisplayMode(to: view)

        let progress = initialProgress
        initialProgress = nil
        // 等第一次 layout 完成後再還原縮放與頁碼，否則 scaleFactor 會被 autoScales 覆蓋。
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            if let progress, !progress.autoScales {
                view.autoScales = false
                view.scaleFactor = CGFloat(progress.scaleFactor)
            } else {
                view.autoScales = true
            }
            if let page = self.document.page(at: self.currentPageIndex) {
                view.go(to: page)
            }
            self.syncFromView()
            self.overlay.setEnabled(self.showsTranslation, around: self.visiblePageIndices)
            self.scheduleVisibleUpdate(delay: 0)
        }
    }

    func pdfViewPageChanged() {
        guard let view = pdfView, let page = view.currentPage else { return }
        let index = document.index(for: page)
        if index != currentPageIndex {
            currentPageIndex = index
            _ = directionTracker.update(page: index)
        }
        scheduleSave()
        scheduleVisibleUpdate(delay: 0.3)
    }

    func pdfViewScaleChanged() {
        let view = pdfView
        let newScale = Double(view?.scaleFactor ?? 1)
        if abs(newScale - scaleFactor) > 0.001 { scaleFactor = newScale }
        if let v = view, v.autoScales != autoScales { autoScales = v.autoScales }
        scheduleSave()
        scheduleVisibleUpdate(delay: 0.4)
    }

    func pdfViewSelectionChanged() {
        let has = !(pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if has != hasSelection { hasSelection = has }
    }

    private func syncFromView() {
        guard let view = pdfView else { return }
        scaleFactor = Double(view.scaleFactor)
        autoScales = view.autoScales
        if let page = view.currentPage {
            currentPageIndex = document.index(for: page)
        }
    }

    /// 翻頁停住後才通知翻譯排程、疊加層與預先渲染，快速翻頁時不會觸發大量工作。
    private func scheduleVisibleUpdate(delay: Double) {
        visibleTask?.cancel()
        visibleTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard !Task.isCancelled, let self else { return }
            let visible = self.visiblePageIndices
            if self.visiblePageIndicesForSidebar != visible { self.visiblePageIndicesForSidebar = visible }
            self.translation.visibleChanged(visible, direction: self.directionTracker.direction)
            self.overlay.refresh(around: visible)
            self.prepareTurnImages()
        }
    }

    var visiblePageIndices: Set<Int> {
        guard let view = pdfView else { return [currentPageIndex] }
        let pages = view.visiblePages.map { document.index(for: $0) }
        return pages.isEmpty ? [currentPageIndex] : Set(pages)
    }

    /// 目標語言或字體改變：重新排版頁面上的譯文、重新準備翻頁影像。
    func translationSettingsChanged() {
        overlay.refresh(around: visiblePageIndices)
        prepareTurnImages()
    }

    func pageLabel(_ index: Int) -> String {
        document.page(at: index)?.label ?? "\(index + 1)"
    }

    // MARK: - 原文／譯文

    func setShowsTranslation(_ on: Bool) {
        showsTranslation = on
        UserDefaults.standard.set(on, forKey: "showTranslationOverlay")
        let visible = visiblePageIndices
        overlay.setEnabled(on, around: visible)
        if on {
            // 切到譯文時，目前頁面若還沒翻譯就立刻開始
            let missing = visible.filter { !translation.completedPages.contains($0) }
            if !missing.isEmpty { translation.translatePages(missing.sorted()) }
        }
        prepareTurnImages()
    }

    func toggleTranslation() { setShowsTranslation(!showsTranslation) }

    /// 按住 ⌥ 暫時顯示原文。
    func setPeekingOriginal(_ peeking: Bool) {
        guard showsTranslation, peeking != isPeekingOriginal else { return }
        isPeekingOriginal = peeking
        overlay.setPeeking(peeking)
    }

    // MARK: - 導覽

    func goTo(pageIndex: Int) {
        let clamped = min(max(pageIndex, 0), pageCount - 1)
        guard let page = document.page(at: clamped) else { return }
        pdfView?.go(to: page)
    }

    func nextPage() { turnPage(forward: true) }
    func previousPage() { turnPage(forward: false) }
    func goToFirstPage() { goTo(pageIndex: 0) }
    func goToLastPage() { goTo(pageIndex: pageCount - 1) }

    private var turnStyle: PageTurnStyle {
        PageTurnStyle(rawValue: UserDefaults.standard.string(forKey: "pageTurnStyle") ?? "") ?? .curl
    }

    /// 翻頁（鍵盤、按鈕、選單）。單頁／雙頁模式播放翻書或滑動動畫；連續模式平滑捲動。
    func turnPage(forward: Bool) {
        guard let view = pdfView else { return }
        let style = turnStyle
        if displayMode == .continuous {
            finishTurnAnimation()
            guard forward ? view.canGoToNextPage : view.canGoToPreviousPage else { return }
            if style == .none || !animatedScroll(view: view, forward: forward) { step(view, forward) }
            return
        }
        if style == .curl, curl.play(forward: forward) { return }
        curl.finishImmediately()
        guard forward ? view.canGoToNextPage : view.canGoToPreviousPage else { return }
        finishTurnAnimation()
        guard style != .none else { step(view, forward); return }

        // 滑動樣式（也是翻書無法使用時的替代，例如雙頁模式的封面）
        let host = PageTurnHostView(frame: view.bounds)
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        turnHost = host
        let before = orderedVisiblePages(view).map { ($0, makePageLayer($0, view: view, host: host)) }
        step(view, forward)
        animateSlide(host: host, before: before, forward: forward)
    }

    private func step(_ view: PDFView, _ forward: Bool) {
        if forward { view.goToNextPage(nil) } else { view.goToPreviousPage(nil) }
    }

    private func orderedVisiblePages(_ view: PDFView) -> [PDFPage] {
        // 依畫面上由左到右排列（右至左閱讀時頁碼順序與畫面順序相反）
        view.visiblePages.sorted {
            view.convert($0.bounds(for: view.displayBox), from: $0).minX
                < view.convert($1.bounds(for: view.displayBox), from: $1).minX
        }
    }

    private func finishTurnAnimation() {
        turnHost?.removeFromSuperview()
        turnHost = nil
    }

    // MARK: 翻頁動畫

    private func pageRect(_ page: PDFPage, view: PDFView, host: NSView) -> CGRect {
        host.convert(view.convert(page.bounds(for: view.displayBox), from: page), from: view)
    }

    private func renderLongSide(for page: PDFPage, view: PDFView) -> CGFloat {
        let b = page.bounds(for: view.displayBox)
        let backing = view.window?.backingScaleFactor ?? 2
        return min(2400, max(b.width, b.height) * view.scaleFactor * backing)
    }

    private func overlayDrawings(_ index: Int) -> [OverlayDrawing] {
        (showsTranslation && !isPeekingOriginal) ? overlay.drawings(page: index) : []
    }

    private func makePageLayer(_ page: PDFPage, view: PDFView, host: NSView) -> CALayer {
        let layer = CALayer()
        layer.frame = pageRect(page, view: view, host: host)
        let index = document.index(for: page)
        let longSide = renderLongSide(for: page, view: view)
        let drawings = overlayDrawings(index)
        layer.contents = renderCache.image(page: page, index: index, longSide: longSide, overlays: drawings)
        layer.contentsGravity = .resize
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        return layer
    }

    private func animateSlide(host: PageTurnHostView, before: [(PDFPage, CALayer)], forward: Bool) {
        guard let root = host.layer else { finishTurnAnimation(); return }
        let container = CALayer()
        container.frame = root.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, l) in before { container.addSublayer(l) }
        root.addSublayer(container)
        CATransaction.commit()

        let movesLeft = forward != (readingDirection == .rightToLeft)
        let dx = (movesLeft ? -1 : 1) * root.bounds.width * 0.45
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak host] in
            host?.removeFromSuperview()
            if self?.turnHost === host { self?.turnHost = nil }
        }
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = container.position.x
        move.toValue = container.position.x + dx
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.26
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        container.add(group, forKey: "slide")
        CATransaction.commit()
    }

    /// 連續捲動模式：平滑捲到上一頁／下一頁的頂端。
    private func animatedScroll(view: PDFView, forward: Bool) -> Bool {
        let target = min(max(currentPageIndex + (forward ? 1 : -1), 0), pageCount - 1)
        guard let page = document.page(at: target),
              let docView = view.documentView,
              let scroll = docView.enclosingScrollView else { return false }
        let clip = scroll.contentView
        let inView = view.convert(page.bounds(for: view.displayBox), from: page)
        let inDoc = docView.convert(inView, from: view)
        var origin = clip.bounds.origin
        let margin: CGFloat = 8
        origin.y = docView.isFlipped ? inDoc.minY - margin : inDoc.maxY + margin - clip.bounds.height
        origin.y = min(max(origin.y, 0), max(0, docView.bounds.height - clip.bounds.height))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: {
            scroll.reflectScrolledClipView(clip)
        }
        return true
    }

    /// 先在背景把目前與相鄰頁面渲染好（含譯文疊加），翻頁動畫可立即開始。
    private func prepareTurnImages() {
        guard let view = pdfView, displayMode != .continuous, turnStyle != .none,
              UserDefaults.standard.bool(forKey: "prerenderPages") else { return }
        let step = displayMode == .twoUp ? 2 : 1
        let base = visiblePageIndices
        var targets = base
        for p in base { for d in [-step, step, step + 1, -step - 1] { targets.insert(p + d) } }
        for index in targets where index >= 0 && index < pageCount {
            guard let page = document.page(at: index) else { continue }
            renderCache.prepare(page: page, index: index, longSide: renderLongSide(for: page, view: view),
                                overlays: overlayDrawings(index))
        }
    }

    // MARK: - 鍵盤與觸控板

    private var contentScrollsVertically: Bool {
        guard let doc = pdfView?.documentView, let clip = doc.enclosingScrollView?.contentView else { return false }
        return doc.bounds.height > clip.bounds.height + 4
    }

    private var contentScrollsHorizontally: Bool {
        guard let doc = pdfView?.documentView, let clip = doc.enclosingScrollView?.contentView else { return false }
        return doc.bounds.width > clip.bounds.width + 4
    }

    /// 鍵盤：C 切換原文／譯文；單頁／雙頁模式下 ← → ↑ ↓、空白鍵、Page Up/Down 一律左右翻書。
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }
        if event.charactersIgnoringModifiers?.lowercased() == "c" {
            toggleTranslation()
            return true
        }
        let rtl = readingDirection == .rightToLeft
        if displayMode == .continuous {
            switch event.keyCode {
            case 124: turnPage(forward: !rtl); return true
            case 123: turnPage(forward: rtl); return true
            default: return false   // ↑ ↓ 維持捲動
            }
        }
        switch event.keyCode {
        case 124: turnPage(forward: !rtl); return true                        // →
        case 123: turnPage(forward: rtl); return true                         // ←
        case 125: if contentScrollsVertically { return false }; turnPage(forward: true); return true    // ↓
        case 126: if contentScrollsVertically { return false }; turnPage(forward: false); return true   // ↑
        case 121: turnPage(forward: true); return true                        // Page Down
        case 116: turnPage(forward: false); return true                       // Page Up
        case 49: turnPage(forward: !event.modifierFlags.contains(.shift)); return true   // 空白鍵
        default: return false
        }
    }

    /// 觸控板雙指滑動（上下左右）在單頁／雙頁模式一律左右翻書。
    /// 翻書樣式下紙張跟著手指即時捲動，放開後依進度與速度完成或回彈。
    /// 頁面放大到需要捲動的方向，交還給 PDFView 捲動。
    func handleScroll(_ event: NSEvent) -> Bool {
        guard displayMode != .continuous, event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            if gesture.interactive && curl.isActive { curl.end(velocity: 0) }
            gesture = TurnGesture()
        }
        if !event.momentumPhase.isEmpty { return gesture.consumed }

        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if gesture.axis == nil {
            guard abs(dx) + abs(dy) > 0.5 else { return gesture.consumed }
            let horizontal = abs(dx) >= abs(dy)
            gesture.axis = horizontal ? .horizontal : .vertical
            gesture.passThrough = horizontal ? contentScrollsHorizontally : contentScrollsVertically
        }
        if gesture.passThrough { return false }

        let rtl = readingDirection == .rightToLeft
        gesture.accumulated += gesture.axis == .horizontal ? dx : dy
        // 自然捲動：手指往左（或往上）→ 數值為負 → 往後讀
        let towardForward = (gesture.axis == .horizontal && rtl) ? gesture.accumulated : -gesture.accumulated

        if gesture.forward == nil {
            gesture.consumed = true
            guard abs(towardForward) > 5 else { return true }
            let forward = towardForward > 0
            gesture.forward = forward
            if turnStyle == .curl {
                gesture.interactive = curl.begin(forward: forward)
            }
            if !gesture.interactive {
                turnPage(forward: forward)
                gesture.finished = true
            }
        }
        guard gesture.interactive, !gesture.finished, let forward = gesture.forward else { return true }

        let span = max(200, (gesture.axis == .horizontal ? (pdfView?.bounds.width ?? 800) * 0.5
                                                        : (pdfView?.bounds.height ?? 800) * 0.4))
        let progress = min(1, max(0, (forward ? towardForward : -towardForward) / span))
        let now = event.timestamp
        if let last = gesture.lastSample, now > last.time {
            let instant = (progress - last.progress) / CGFloat(now - last.time)
            gesture.velocity = gesture.velocity * 0.6 + instant * 0.4
        }
        gesture.lastSample = (now, progress)
        curl.update(progress: progress)

        if event.phase == .ended || event.phase == .cancelled {
            curl.end(velocity: event.phase == .cancelled ? 0 : gesture.velocity)
            gesture.finished = true
        }
        return true
    }

    // MARK: - 顯示

    func setDisplayMode(_ mode: DisplayMode) {
        finishTurnAnimation()
        curl.finishImmediately()
        guard let view = pdfView else { displayMode = mode; return }
        let page = view.currentPage
        displayMode = mode
        applyDisplayMode(to: view)
        if let page { view.go(to: page) }
        scheduleSave()
        scheduleVisibleUpdate(delay: 0.1)
    }

    /// 雙頁對頁調整：對頁錯位時切換「封面單獨顯示／從第一頁開始成對」，等於整體位移一頁。
    func setCoverAlone(_ value: Bool) {
        guard value != coverAlone else { return }
        coverAlone = value
        try? database?.setPreference("twoUp.coverAlone", value: value ? "1" : "0", scope: record.id)
        guard let view = pdfView else { return }
        curl.finishImmediately()
        let page = view.currentPage
        applyDisplayMode(to: view)
        if let page { view.go(to: page) }
        scheduleVisibleUpdate(delay: 0.1)
    }

    func setReadingDirection(_ direction: ReadingDirection) {
        readingDirection = direction
        if let view = pdfView { applyDisplayMode(to: view) }
        scheduleSave()
    }

    private func applyDisplayMode(to view: PDFView) {
        switch displayMode {
        case .singlePage:
            view.displayMode = .singlePage
            view.displaysAsBook = false
        case .twoUp:
            view.displayMode = .twoUp
            view.displaysAsBook = coverAlone
        case .continuous:
            view.displayMode = .singlePageContinuous
            view.displaysAsBook = false
        }
        view.displaysRTL = (readingDirection == .rightToLeft)
        view.displaysPageBreaks = true
    }

    // MARK: - 縮放

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }

    func actualSize() {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = 1.0
    }

    func fitWindow() {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = view.scaleFactorForSizeToFit
    }

    func fitWidth() {
        guard let view = pdfView, let page = view.currentPage else { return }
        let box = page.bounds(for: view.displayBox)
        let rotated = page.rotation % 180 != 0
        var pageWidth = rotated ? box.height : box.width
        if displayMode == .twoUp { pageWidth *= 2 }
        guard pageWidth > 0 else { return }
        let available = view.bounds.width - 40
        view.autoScales = false
        view.scaleFactor = max(view.minScaleFactor, min(view.maxScaleFactor, available / pageWidth))
    }

    func setScale(percent: Double) {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = CGFloat(percent / 100)
    }

    // MARK: - 書籤

    var isCurrentPageBookmarked: Bool {
        bookmarks.contains { $0.pageIndex == currentPageIndex }
    }

    func toggleBookmark() {
        if let existing = bookmarks.first(where: { $0.pageIndex == currentPageIndex }) {
            deleteBookmark(existing)
        } else {
            let label = document.page(at: currentPageIndex)?.label ?? "\(currentPageIndex + 1)"
            let draft = Bookmark(documentID: record.id, pageIndex: currentPageIndex, title: L("第 \(label) 頁", "Page \(label)"))
            if let db = database, let saved = try? db.addBookmark(draft) {
                bookmarks.append(saved)
            } else {
                bookmarks.append(draft)
            }
            bookmarks.sort { $0.pageIndex < $1.pageIndex }
        }
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        if let id = bookmark.id { try? database?.deleteBookmark(id: id) }
        bookmarks.removeAll { $0 == bookmark }
    }

    // MARK: - 選取翻譯

    func translateCurrentSelection() {
        guard let text = pdfView?.currentSelection?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        showTranslationPanel = true
        translation.translateSelection(text)
    }

    // MARK: - 定位與標示

    func reveal(_ result: SearchResult) {
        guard let page = document.page(at: result.pageIndex) else { return }
        if !result.isOCR, let selection = page.selection(for: result.bounds) {
            pdfView?.setCurrentSelection(selection, animate: false)
            pdfView?.go(to: selection)
        } else {
            highlight(rect: result.bounds, pageIndex: result.pageIndex)
        }
    }

    /// 在頁面上短暫標示某個區塊（掃描頁沒有文字層，用框線標示）。
    func highlight(rect: CGRect, pageIndex: Int) {
        guard let page = document.page(at: pageIndex) else { return }
        clearHighlight()
        let ann = PDFAnnotation(bounds: rect.insetBy(dx: -3, dy: -3), forType: .square, withProperties: nil)
        ann.color = NSColor.systemOrange
        ann.interiorColor = NSColor.systemYellow.withAlphaComponent(0.18)
        let border = PDFBorder()
        border.lineWidth = 1.5
        ann.border = border
        page.addAnnotation(ann)
        highlightAnnotation = (ann, page)
        pdfView?.go(to: rect, on: page)
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.clearHighlight()
        }
    }

    private func clearHighlight() {
        highlightTask?.cancel()
        if let h = highlightAnnotation { h.1.removeAnnotation(h.0) }
        highlightAnnotation = nil
    }

    // MARK: - 進度儲存（debounce）

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveProgressNow()
        }
    }

    func saveProgressNow() {
        saveTask?.cancel()
        guard let database else { return }
        let progress = ReadingProgress(documentID: record.id, pageIndex: currentPageIndex,
                                       scaleFactor: scaleFactor, autoScales: autoScales,
                                       displayMode: displayMode, readingDirection: readingDirection)
        try? database.saveProgress(progress)
    }

    func close() {
        saveProgressNow()
        clearHighlight()
        finishTurnAnimation()
        curl.finishImmediately()
        overlay.removeAll()
        translation.shutdown()
    }
}

/// 觸控板翻頁手勢的狀態。
struct TurnGesture {
    enum Axis { case horizontal, vertical }
    var axis: Axis?
    var passThrough = false
    var accumulated: CGFloat = 0
    var forward: Bool?
    var interactive = false
    var consumed = false
    var finished = false
    var velocity: CGFloat = 0
    var lastSample: (time: TimeInterval, progress: CGFloat)?
}

/// 翻頁動畫的承載層：不攔截滑鼠事件。
final class PageTurnHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct OutlineItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let children: [OutlineItem]?

    @MainActor
    static func children(of node: PDFOutline, in document: PDFDocument, depth: Int = 0) -> [OutlineItem] {
        guard depth < 12 else { return [] }
        return (0..<node.numberOfChildren).compactMap { i in
            guard let child = node.child(at: i) else { return nil }
            let page = child.destination?.page.map { document.index(for: $0) }
            let sub = children(of: child, in: document, depth: depth + 1)
            return OutlineItem(title: child.label ?? L("（未命名）", "(Untitled)"), pageIndex: page,
                               children: sub.isEmpty ? nil : sub)
        }
    }
}
