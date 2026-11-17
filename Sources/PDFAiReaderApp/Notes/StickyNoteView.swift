import AppKit
import ReaderCore

/// 便利貼內文的文字視圖：Esc 結束編輯。
final class NoteTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// 右鍵（未在編輯時）開啟便利貼選項；編輯中顯示文字選單並附上「便利貼選項…」。
    var onOptions: ((CGPoint) -> Void)?

    private var isFocused: Bool { window?.firstResponder === self }

    override func rightMouseDown(with event: NSEvent) {
        if isFocused { super.rightMouseDown(with: event); return }
        onOptions?(convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isFocused else { return nil }
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let item = ClosureMenuItem(title: L("便利貼選項…", "Note Options…")) { [weak self] in self?.onOptions?(point) }
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
}

/// 內容超出時，蓋在內文底部的淡出漸層（不攔截滑鼠）。
final class NoteFadeView: NSView {
    var color: NSColor = .white { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: color.withAlphaComponent(0), ending: color)?.draw(in: bounds, angle: 90)
    }
}

/// 頁面上的一張便利貼。
///
/// 視圖的 bounds 使用「未縮放」的頁面點數，frame 則是縮放後的大小；
/// 因此內部版面、字體與滑鼠座標都不受縮放影響，文字在任何縮放下都清晰。
///
/// 互動：
/// - 按住頂端拖曳列移動
/// - 點內文直接進入編輯，游標落在點擊位置
/// - 拖曳左、右、下緣（含下方兩角）調整大小
/// - 內容超出時，點底部「展開」往下展開（寬度不變），再點「收合」
final class StickyNoteView: NSView, NSTextViewDelegate {
    private(set) var note: StickyNote
    weak var controller: NotesController?

    let textView: NoteTextView
    private let fade = NoteFadeView()
    private var hovering = false { didSet { if hovering != oldValue { updateChrome() } } }
    private var tracking: NSTrackingArea?
    private var drag: Drag?
    private var isApplyingNote = false
    /// 文字框自己的復原紀錄：編輯中逐字復原，結束編輯後清掉，改由控制器記成一次修改。
    private let textUndo = UndoManager()

    private enum Edge: Hashable { case left, right, bottom }

    private enum Drag {
        case move(start: CGPoint, rect: PageRect)
        case resize(edges: Set<Edge>, start: CGPoint, rect: PageRect)
        case strip
    }

    /// 是否正在編輯（以控制器的狀態為準；結束編輯的通知送達時焦點還沒真正移走）。
    var isEditing: Bool { controller?.editingNoteID == note.id }
    private var hasFocus: Bool { window?.firstResponder === textView }

    init(note: StickyNote) {
        self.note = note
        textView = NoteTextView(usingTextLayoutManager: false)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.zPosition = 20
        // 小小的投影，讓便利貼浮在頁面上
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        self.shadow = shadow

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.focusRingType = .none
        // macOS 14 起視圖預設不裁切；內文超出便利貼範圍時要裁掉（由「展開」顯示）
        textView.clipsToBounds = true
        textView.onEscape = { [weak self] in self?.endEditing() }
        textView.onOptions = { [weak self] p in
            guard let self else { return }
            self.showOptions(at: self.convert(p, from: self.textView))
        }
        addSubview(textView)
        addSubview(fade)


        apply(note)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 內容

    /// 套用資料（不會打斷正在輸入的內容）。
    func apply(_ newNote: StickyNote) {
        let styleChanged = newNote.color != note.color || newNote.fontFamily != note.fontFamily
            || newNote.fontSize != note.fontSize || textView.string.isEmpty && !newNote.body.isEmpty
        note = newNote
        isApplyingNote = true
        if textView.string != newNote.body && !hasFocus { textView.string = newNote.body }
        if styleChanged || textView.font == nil { applyTextStyle() }
        isApplyingNote = false
        needsLayout = true
        needsDisplay = true
    }

    private func applyTextStyle() {
        // 跟著紙張深淺決定外觀，系統預設顏色（游標、選取、輸入法）才會配合
        appearance = NSAppearance(named: note.color.isDark ? .darkAqua : .aqua)
        let attrs = StickyNoteLayout.bodyAttributes(note)
        textView.font = attrs[.font] as? NSFont
        textView.textColor = note.color.text
        textView.insertionPointColor = note.color.text
        textView.defaultParagraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attrs
        // 注音等輸入法組字中的文字：用便利貼的文字顏色（預設會跟著系統深色模式變白）
        textView.markedTextAttributes = [
            .foregroundColor: note.color.text,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: note.color.secondaryText,
            .backgroundColor: note.color.isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06),
        ]
        if let storage = textView.textStorage {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
        textView.selectedTextAttributes = [.backgroundColor: note.color.isDark
            ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.12)]
        let placeholder = NSAttributedString(string: L("點一下輸入…", "Click to type…"), attributes: [
            .font: attrs[.font] as Any, .foregroundColor: note.color.secondaryText])
        textView.setValue(placeholder, forKey: "placeholderAttributedString")
    }

    var strip: StickyNoteLayout.Strip {
        StickyNoteLayout.strip(note, width: bounds.width, baseHeight: CGFloat(note.rect?.height ?? 0), editing: isEditing)
    }

    override func layout() {
        super.layout()
        let body = StickyNoteLayout.bodyRect(note, size: bounds.size, strip: strip)
        if textView.frame != body { textView.frame = body }
        fade.isHidden = strip != .expand
        fade.color = note.color.fill
        fade.frame = CGRect(x: 0, y: body.maxY - 16, width: bounds.width, height: 16)
        updateChrome()
    }

    private func updateChrome() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        StickyNoteRenderer.draw(note, size: bounds.size, strip: strip, hovering: hovering || isEditing, includeBody: false)
    }

    // MARK: - 編輯

    func beginEditing(at point: CGPoint? = nil) {
        guard let window else { return }
        window.makeFirstResponder(textView)
        if let point {
            let local = textView.convert(point, from: self)
            let index = textView.characterIndexForInsertion(at: local)
            textView.setSelectedRange(NSRange(location: index, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }

    func endEditing() {
        guard hasFocus else { return }
        // 焦點交還給 PDF，讓 C / N / 方向鍵等快捷鍵繼續有效
        window?.makeFirstResponder(controller?.pdfView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { textUndo }

    func textDidBeginEditing(_ notification: Notification) {
        controller?.noteDidBeginEditing(self)
        updateChrome()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingNote else { return }
        if !textView.hasMarkedText() { textView.typingAttributes = StickyNoteLayout.bodyAttributes(note) }
        // 貼上或輔助工具插入的文字可能帶別的樣式；統一成便利貼的字體與顏色（輸入法組字中不動）
        if !textView.hasMarkedText(), let storage = textView.textStorage, storage.length > 0 {
            let attrs = StickyNoteLayout.bodyAttributes(note)
            var uniform = true
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { a, _, stop in
                if (a[.foregroundColor] as? NSColor) != (attrs[.foregroundColor] as? NSColor)
                    || (a[.font] as? NSFont) != (attrs[.font] as? NSFont) { uniform = false; stop.pointee = true }
            }
            if !uniform {
                let selection = textView.selectedRanges
                storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
                textView.selectedRanges = selection
            }
        }
        note.body = textView.string
        controller?.noteBodyChanged(id: note.id, body: note.body)
    }

    func textDidEndEditing(_ notification: Notification) {
        // 離開編輯時取消文字反白，只留游標位置
        let caret = textView.selectedRange()
        textView.setSelectedRange(NSRange(location: caret.location + caret.length, length: 0))
        textUndo.removeAllActions()
        controller?.noteDidEndEditing(self)
        updateChrome()
    }

    // MARK: - 滑鼠

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { if drag == nil { hovering = false } }

    /// 邊緣的可拖曳寬度：畫面上至少約 7 點，縮小檢視時也容易抓到。
    private var edgeWidth: CGFloat {
        let scale = frame.width > 0 && bounds.width > 0 ? frame.width / bounds.width : 1
        return max(5, 7 / max(scale, 0.01))
    }

    /// 頂端拖曳區：畫面上至少約 12 點高。
    private var headerHitHeight: CGFloat {
        let scale = frame.width > 0 && bounds.width > 0 ? frame.width / bounds.width : 1
        return max(StickyNoteLayout.headerHeight(note), 12 / max(scale, 0.01))
    }

    private func edges(at p: CGPoint) -> Set<Edge> {
        var e = Set<Edge>()
        let w = edgeWidth
        let header = headerHitHeight
        if p.x <= w && p.y > header * 0.5 { e.insert(.left) }
        if p.x >= bounds.width - w && p.y > header * 0.5 { e.insert(.right) }
        if p.y >= bounds.height - w { e.insert(.bottom) }
        return e
    }

    private func zone(at p: CGPoint) -> (edges: Set<Edge>, header: Bool, strip: Bool) {
        let e = edges(at: p)
        if !e.isEmpty { return (e, false, false) }
        if p.y <= headerHitHeight { return ([], true, false) }
        if strip != .none && p.y >= bounds.height - StickyNoteLayout.stripHeight { return ([], false, true) }
        return ([], false, false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, !isHidden else { return nil }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        let z = zone(at: p)
        if !z.edges.isEmpty || z.header || z.strip { return self }
        // 內文（含邊距）交給文字視圖：點擊位置即游標位置
        return textView
    }

    override func resetCursorRects() {
        let w = edgeWidth
        let header = headerHitHeight
        addCursorRect(CGRect(x: w, y: 0, width: max(0, bounds.width - w * 2), height: header), cursor: .openHand)
        addCursorRect(CGRect(x: 0, y: header * 0.5, width: w, height: bounds.height - header * 0.5 - w), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: bounds.width - w, y: header * 0.5, width: w, height: bounds.height - header * 0.5 - w),
                      cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: w, y: bounds.height - w, width: bounds.width - w * 2, height: w), cursor: .resizeUpDown)
        let corner: NSCursor
        if #available(macOS 15.0, *) {
            corner = .frameResize(position: .bottomRight, directions: .all)
        } else {
            corner = .crosshair
        }
        addCursorRect(CGRect(x: 0, y: bounds.height - w, width: w, height: w), cursor: corner)
        addCursorRect(CGRect(x: bounds.width - w, y: bounds.height - w, width: w, height: w), cursor: corner)
        if strip != .none {
            addCursorRect(CGRect(x: w, y: bounds.height - StickyNoteLayout.stripHeight, width: bounds.width - w * 2,
                                 height: StickyNoteLayout.stripHeight - w), cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let rect = note.rect, let controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let z = zone(at: p)
        guard let start = controller.displayPoint(event: event, page: note.pageIndex) else { return }
        controller.bringToFront(self)
        controller.focusedNoteID = nil
        controller.sidebarEditingID = nil
        // 點便利貼的邊框或頂端：結束任何便利貼的文字編輯
        if window?.firstResponder is NSText { window?.makeFirstResponder(controller.pdfView) }
        if event.clickCount == 2 && z.header {
            controller.showOptions(for: note.id, from: self,
                                   rect: CGRect(x: 0, y: 0, width: bounds.width, height: StickyNoteLayout.headerHeight(note)))
            return
        }
        if !z.edges.isEmpty || !z.strip {
            controller.beginInteraction(id: note.id)
            controller.isDraggingNote = true
        }
        if !z.edges.isEmpty {
            drag = .resize(edges: z.edges, start: start, rect: rect)
        } else if z.strip {
            drag = .strip
        } else {
            drag = .move(start: start, rect: rect)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let controller, let p = controller.displayPoint(event: event, page: note.pageIndex) else { return }
        switch drag {
        case let .move(start, rect):
            var r = rect
            r.x += p.x - start.x
            r.y += p.y - start.y
            controller.setRect(r, for: note.id, live: true)
        case let .resize(edges, start, rect):
            var r = rect
            let dx = p.x - start.x, dy = p.y - start.y
            if edges.contains(.right) { r.width = max(StickyNote.minimumSize.width, rect.width + dx) }
            if edges.contains(.left) {
                let w = max(StickyNote.minimumSize.width, rect.width - dx)
                r.x = rect.maxX - w
                r.width = w
            }
            if edges.contains(.bottom) {
                // 上緣固定，往下拉變高
                let h = max(StickyNote.minimumSize.height, rect.height - dy)
                r.y = rect.maxY - h
                r.height = h
            }
            controller.setRect(r, for: note.id, live: true, collapse: edges.contains(.bottom))
        case .strip:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        if controller?.isDraggingNote == true {
            controller?.isDraggingNote = false
            controller?.relayout()
        }
        switch drag {
        case .move:
            NSCursor.pop()
            controller?.commitRect(for: note.id)
        case .resize:
            controller?.commitRect(for: note.id, resized: true)
        case .strip:
            let p = convert(event.locationInWindow, from: nil)
            if zone(at: p).strip { controller?.toggleExpanded(id: note.id) }
        case nil:
            break
        }
        let p = convert(event.locationInWindow, from: nil)
        if !bounds.contains(p) { hovering = false }
    }

    /// 右鍵：開啟便利貼選項（標題、顏色、字體、大小、移到側邊欄、刪除）。
    override func rightMouseDown(with event: NSEvent) {
        showOptions(at: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    func showOptions(at point: CGPoint) {
        guard let controller else { return }
        controller.bringToFront(self)
        controller.showOptions(for: note.id, from: self, rect: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
    }
}
