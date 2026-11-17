import AppKit
import PDFKit
import ReaderCore
import ReaderServices

// MARK: - 復原（⌘Z／⇧⌘Z）

extension NotesController {
    var undoManager: UndoManager? { pdfView?.undoManager }

    /// 記錄一次便利貼的修改。`before` 為 nil 表示修改前不存在（新增）。
    /// `coalesce` 為 true 時，同一張便利貼在短時間內的連續修改（例如打標題）合併成一次。
    func registerNoteUndo(id: String, before: StickyNote?, name: String, coalesce: Bool = false) {
        guard let um = undoManager else { return }
        if coalesce, !um.isUndoing, !um.isRedoing, let last = lastUndoKey, last.key == "note:\(id)",
           Date().timeIntervalSince(last.time) < 1.5 {
            lastUndoKey = (last.key, Date())
            return
        }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreNote(id: id, to: before, name: name) }
        }
        um.setActionName(name)
        lastUndoKey = coalesce ? ("note:\(id)", Date()) : nil
    }

    /// 把便利貼還原成某個狀態（nil＝刪除），並記錄反向操作供重做。
    func restoreNote(id: String, to state: StickyNote?, name: String) {
        let current = note(id: id)
        lastUndoKey = nil
        popover?.close()
        if let state {
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i] = state
                views[id]?.apply(state)
            } else {
                notes.append(state)
            }
            try? database?.saveNote(state)
            if state.rect == nil, let v = views.removeValue(forKey: id) { v.removeFromSuperview() }
        } else {
            notes.removeAll { $0.id == id }
            if editingNoteID == id { editingNoteID = nil }
            if let v = views.removeValue(forKey: id) {
                v.endEditing()
                v.removeFromSuperview()
            }
            try? database?.deleteNote(id: id)
        }
        if let s = state, !isVisible, s.isPlaced { setVisible(true) }
        relayout()
        if let p = state?.pageIndex ?? current?.pageIndex { onChange?(p) }
        registerNoteUndo(id: id, before: current, name: name)
    }

    func registerHighlightUndo(id: String, before: Highlight?, name: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreHighlight(id: id, to: before, name: name) }
        }
        um.setActionName(name)
        lastUndoKey = nil
    }

    func restoreHighlight(id: String, to state: Highlight?, name: String) {
        let current = highlights.first { $0.id == id }
        if let state {
            if let i = highlights.firstIndex(where: { $0.id == id }) { highlights[i] = state } else { highlights.append(state) }
            try? database?.saveHighlight(state)
        } else {
            highlights.removeAll { $0.id == id }
            try? database?.deleteHighlight(id: id)
        }
        relayout()
        if let p = state?.pageIndex ?? current?.pageIndex { onChange?(p) }
        registerHighlightUndo(id: id, before: current, name: name)
    }

    /// 一次還原多張便利貼（排序用）。
    func restoreNoteSet(_ states: [StickyNote], name: String) {
        let current = states.compactMap { note(id: $0.id) }
        for st in states {
            if let i = notes.firstIndex(where: { $0.id == st.id }) { notes[i] = st } else { notes.append(st) }
            try? database?.saveNote(st)
        }
        relayout()
        registerNoteSetUndo(before: current, name: name)
    }

    func registerNoteSetUndo(before: [StickyNote], name: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreNoteSet(before, name: name) }
        }
        um.setActionName(name)
        lastUndoKey = nil
    }

    /// 側邊欄拖曳排序：把 `id` 移到 `targetID` 之前（nil＝該頁最後）。不同頁時，無位置筆記改屬該頁。
    func moveNote(_ id: String, before targetID: String?, page: Int) {
        guard id != targetID, let moving = note(id: id) else { return }
        // 頁面上的便利貼不換頁（位置屬於原頁）
        let destPage = moving.isPlaced ? moving.pageIndex : page
        var list = notes(page: destPage).filter { $0.id != id }
        let insertAt = targetID.flatMap { t in list.firstIndex { $0.id == t } } ?? list.count
        var m = moving
        m.pageIndex = destPage
        list.insert(m, at: insertAt)
        let before = list.compactMap { note(id: $0.id) }
        for (k, n) in list.enumerated() {
            guard let i = notes.firstIndex(where: { $0.id == n.id }) else { continue }
            notes[i].pageIndex = destPage
            notes[i].sortOrder = Double(k)
            try? database?.saveNote(notes[i])
        }
        registerNoteSetUndo(before: before, name: L("調整筆記順序", "Reorder Notes"))
        onChange?(destPage)
    }

    /// 把筆記放到頁面上的某一點（頁面座標；從側邊欄拖到內容時用）。
    func placeNote(_ id: String, page index: Int, at pagePoint: CGPoint) {
        guard let n = note(id: id), let page = document?.page(at: index) else { return }
        let g = geometry(page)
        let size = g.displaySize
        let p = pagePoint.applying(g.pageToDisplay)
        let w = n.rect?.width ?? StickyNote.defaultSize.width
        let h = n.rect?.height ?? StickyNote.defaultSize.height
        let rect = StickyNote.clamp(PageRect(x: Double(p.x) - 14, y: Double(p.y) - h + 8, width: w, height: h),
                                    pageSize: (Double(size.width), Double(size.height)))
        lastUndoKey = nil
        update(id, undo: L("放到頁面上", "Place on Page")) {
            $0.pageIndex = index
            $0.rect = rect
        }
        if !isVisible { setVisible(true) }
        relayout()
        if focusedNoteID == id { focusedNoteID = nil }
    }

    /// 拖曳或縮放開始：記下原狀態，放開時記成一次可復原的修改。
    func beginInteraction(id: String) {
        interactionSnapshots[id] = note(id: id)
    }
}

// MARK: - 原文／譯文的字元版面

extension NotesController {
    /// 某頁目前畫面上是哪一種文字。
    func currentSide(_ index: Int) -> TextSide { overlayCovers(index) ? .translated : .original }

    /// 該頁沒有可用的文字層（掃描頁）。
    func isScannedPage(_ index: Int) -> Bool {
        if let cached = textLayer[index] { return !cached }
        guard let page = document?.page(at: index) else { return false }
        let has = TextExtractor.pageHasTextLayer(page)
        textLayer[index] = has
        return !has
    }

    private var provider: TextExtractor? {
        if lineProvider == nil, let url = documentURL { lineProvider = try? TextExtractor(url: url, documentID: documentID) }
        return lineProvider
    }

    /// 背景取得文字層頁面每個字元的位置（每頁只做一次）。
    func loadTextLayer(_ index: Int) {
        guard layerChars[index] == nil, layerLoading[index] == nil, !isScannedPage(index), let provider else { return }
        layerLoading[index] = Task { [weak self] in
            let chars = await provider.textLayerChars(pageIndex: index) ?? []
            guard let self, !Task.isCancelled else { return }
            self.layerChars[index] = chars
            self.layerLoading.removeValue(forKey: index)
            self.originalFlows.removeValue(forKey: index)
            self.relayout()
        }
    }

    /// 背景辨識掃描頁的文字行（每頁只做一次）。
    func loadScanLines(_ index: Int) {
        guard scanLines[index] == nil, scanLoading[index] == nil, isScannedPage(index), let provider else { return }
        scanLoading[index] = Task { [weak self] in
            let lines = (try? await provider.scanLines(pageIndex: index)) ?? nil
            guard let self else { return }
            self.scanLines[index] = lines ?? []
            self.scanLoading.removeValue(forKey: index)
            self.originalFlows.removeValue(forKey: index)
            // 辨識完成時使用者已經拖曳過：補算選取
            if let anchor = self.dragAnchor, anchor.page == index, let last = self.dragLastPoint {
                self.updateScanSelection(to: last)
                if self.dragEnded { self.finishSelection() }
            }
            self.relayout()
        }
    }

    /// 原文的字元版面。文字層頁面用 PDF 的字元位置；掃描頁用 OCR 文字行（辨識完成前為 nil）。
    func originalFlow(_ index: Int) -> TextFlow? { originalFlowEntry(index)?.flow }

    func originalFlowEntry(_ index: Int) -> (signature: Int, flow: TextFlow, sourceIndex: [Int: TextFlow.Position])? {
        guard let page = document?.page(at: index) else { return nil }
        let blocks = pageBlocks(index)
        var hasher = Hasher()
        for b in blocks { hasher.combine(b.id); hasher.combine(b.bounds.x); hasher.combine(b.bounds.y) }
        hasher.combine(scanLines[index]?.count ?? -1)
        hasher.combine(layerChars[index]?.count ?? -1)
        let signature = hasher.finalize()
        if let cached = originalFlows[index], cached.signature == signature { return cached }

        let g = geometry(page)
        let blockRects = blocks.map { (id: $0.id, rect: g.toDisplay($0.bounds.cgRect)) }
        let entry: (signature: Int, flow: TextFlow, sourceIndex: [Int: TextFlow.Position])
        if isScannedPage(index) {
            guard let lines = scanLines[index] else {
                loadScanLines(index)
                return nil
            }
            entry = (signature, TextFlow.fromLines(lines, blocks: blockRects), [:])
        } else {
            guard let chars = layerChars[index] else {
                loadTextLayer(index)
                return nil
            }
            let built = Self.textLayerFlow(chars: chars, blocks: blockRects)
            entry = (signature, built.flow, built.sourceIndex)
        }
        originalFlows[index] = entry
        return entry
    }

    /// 文字層頁面：字元依區塊分組（字元位置由背景的 TextExtractor 預先算好）。
    static func textLayerFlow(chars: [LayoutChar],
                              blocks: [(id: String, rect: CGRect)]) -> (flow: TextFlow, sourceIndex: [Int: TextFlow.Position]) {
        var groups: [String: (chars: [Character], rects: [CGRect], sources: [Int])] = [:]
        var order: [String] = blocks.map(\.id)
        let expanded = blocks.map { (id: $0.id, rect: $0.rect.insetBy(dx: -2, dy: -2)) }
        for lc in chars {
            let center = CGPoint(x: lc.rect.midX, y: lc.rect.midY)
            let id = expanded.first { $0.rect.contains(center) }?.id ?? "rest"
            if groups[id] == nil, !order.contains(id) { order.append(id) }
            groups[id, default: ([], [], [])].chars.append(lc.char)
            groups[id, default: ([], [], [])].rects.append(lc.rect)
            groups[id, default: ([], [], [])].sources.append(lc.source)
        }
        var flowBlocks: [TextFlow.Block] = []
        var sources: [[Int]] = []
        for id in order {
            guard let g = groups[id], !g.chars.isEmpty else { continue }
            flowBlocks.append(TextFlow.Block(id: id, chars: g.chars, rects: g.rects))
            sources.append(g.sources)
        }
        var map: [Int: TextFlow.Position] = [:]
        for (bi, list) in sources.enumerated() {
            for (ci, src) in list.enumerated() { map[src] = TextFlow.Position(block: bi, index: ci) }
        }
        return (TextFlow(blocks: flowBlocks), map)
    }

    /// 譯文的字元版面，與畫面上的譯文排版一致。
    func translatedFlow(_ index: Int) -> TextFlow? {
        let drawings = overlayDrawings(index)
        guard !drawings.isEmpty else { return nil }
        var hasher = Hasher()
        for d in drawings { hasher.combine(d.item.blockID); hasher.combine(d.item.text); hasher.combine(d.style.fontSize); hasher.combine(d.style.fontFamily) }
        let signature = hasher.finalize()
        if let cached = translatedFlows[index], cached.signature == signature { return cached.flow }
        let blocks = drawings.map { d -> TextFlow.Block in
            let chars = Array(d.item.text)
            var rects = OverlayRenderer.characterRects(item: d.item, style: d.style, geometry: d.geometry)
            // 沒排進框內的字元（換行等）給前一個字元右側的零寬位置，索引仍與譯文一致
            var last = CGRect(origin: OverlayRenderer.displayRect(d.item.bounds, geometry: d.geometry).origin, size: .zero)
            for i in rects.indices {
                if rects[i].isNull { rects[i] = CGRect(x: last.maxX, y: last.minY, width: 0, height: last.height) } else { last = rects[i] }
            }
            return TextFlow.Block(id: d.item.blockID, chars: chars, rects: rects)
        }
        let flow = TextFlow(blocks: blocks)
        translatedFlows[index] = (signature, flow)
        return flow
    }

    /// 點是否在某個譯文框內（框會蓋住原文）。
    func translatedBlockContains(_ index: Int, _ p: CGPoint) -> Bool {
        overlayDrawings(index).contains { OverlayRenderer.displayRect($0.item.bounds, geometry: $0.geometry).contains(p) }
    }

    func flow(_ index: Int, side: TextSide) -> TextFlow? {
        side == .translated ? translatedFlow(index) : originalFlow(index)
    }

    /// 某點（顯示空間）是否在目前畫面的文字上（游標用）。
    func textContains(page index: Int, displayPoint p: CGPoint) -> Bool {
        flow(index, side: currentSide(index))?.containsText(at: p) ?? false
    }
}

// MARK: - 選取（譯文、掃描頁）

extension NotesController {
    /// 正在拖曳選取的頁面。
    var scanSelectionPage: Int? { dragAnchor?.page ?? scanSelection?.page }

    /// 由閱讀器接手的選取：譯文蓋住的頁面（點在譯文上）、或掃描頁。回傳 false 交給 PDFKit。
    @discardableResult
    func beginScanSelection(page index: Int, displayPoint p: CGPoint) -> Bool {
        let side = currentSide(index)
        if side == .translated {
            // 在譯文區塊範圍內（含行距、留白）都算點在譯文上；原文被蓋住，不能讓 PDFKit 選到
            guard let tf = translatedFlow(index),
                  tf.position(at: p, maxDistance: 6) != nil || translatedBlockContains(index, p) else { return false }
        } else {
            guard isScannedPage(index) else { return false }
            loadScanLines(index)
        }
        clearScanSelection()
        dragAnchor = (index, side, p)
        dragLastPoint = p
        dragEnded = false
        return true
    }

    /// 連點：選取一個詞（中日韓文字為一個句子內的短語，以標點分隔）或整段。
    func selectUnit(page index: Int, displayPoint p: CGPoint, paragraph: Bool) -> Bool {
        let side = currentSide(index)
        guard side == .translated || isScannedPage(index), let flow = flow(index, side: side),
              let pos = flow.position(at: p, maxDistance: 6) else { return false }
        let b = flow.blocks[pos.block]
        var range = 0..<b.chars.count
        if !paragraph {
            let breaks: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", ",", ".", ";", ":", "!", "?", " ", "（", "）", "「", "」"]
            let i = min(max(0, pos.index), b.chars.count - 1)
            var lo = i, hi = i
            while lo > 0, !breaks.contains(b.chars[lo - 1]) { lo -= 1 }
            while hi < b.chars.count, !breaks.contains(b.chars[hi]) { hi += 1 }
            if hi > lo { range = lo..<hi }
        }
        let spans = [TextFlow.Span(blockID: b.id, range: range)]
        dragAnchor = nil
        scanSelection = FlowSelectionState(page: index, side: side, spans: spans, text: flow.text(for: spans))
        relayout()
        if highlighterMode { highlightSelection() }
        return true
    }

    func updateScanSelection(to p: CGPoint) {
        dragLastPoint = p
        guard let anchor = dragAnchor, let flow = flow(anchor.page, side: anchor.side),
              let start = flow.position(at: anchor.point, maxDistance: 40),
              let end = flow.position(at: p) else { return }
        let spans = flow.spans(from: start, to: end)
        let state = spans.isEmpty ? nil
            : FlowSelectionState(page: anchor.page, side: anchor.side, spans: spans, text: flow.text(for: spans))
        if state != scanSelection {
            scanSelection = state
            relayout()
        }
    }

    func endScanSelection() {
        dragEnded = true
        if scanLoading[dragAnchor?.page ?? -1] == nil { finishSelection() }
    }

    func finishSelection() {
        dragAnchor = nil
        if highlighterMode, scanSelection != nil { highlightSelection() }
    }

    func clearScanSelection() {
        guard scanSelection != nil else { return }
        scanSelection = nil
        relayout()
    }

    /// PDFView 的文字選取改變。譯文蓋住原文時 PDFKit 的反白看不到，改由標記圖層畫。
    func pdfSelectionChanged(_ selection: PDFSelection?) {
        var map: [Int: [CGRect]] = [:]
        if let selection, let document,
           !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let r = line.bounds(for: page)
                    guard r.width > 0.5, r.height > 0.5 else { continue }
                    map[document.index(for: page), default: []].append(geometry(page).toDisplay(r))
                }
            }
        }
        for p in map.keys { loadTextLayer(p) }
        guard map != pdfSelectionRects else { return }
        pdfSelectionRects = map
        relayout()
    }
}

// MARK: - 螢光筆

extension NotesController {
    /// 把目前選取的文字畫上螢光筆（標在選取時看到的那種文字上）。
    @discardableResult
    func highlightSelection(_ color: HighlightColor? = nil) -> Bool {
        let color = color ?? highlighterColor
        if let sel = scanSelection, let page = document?.page(at: sel.page), let flow = flow(sel.page, side: sel.side) {
            let spans = sel.spans.compactMap { s -> HighlightSpan? in
                guard let b = flow.block(id: s.blockID) else { return nil }
                return HighlightSpan(blockID: s.blockID, side: sel.side, start: s.range.lowerBound, end: s.range.upperBound,
                                     source: b.text)
            }
            var h = Highlight(documentID: documentID, pageIndex: sel.page, color: color, rects: [],
                              text: sel.text.trimmingCharacters(in: .whitespacesAndNewlines), spans: spans)
            // 原文位置（備援用）
            let g = geometry(page)
            h.rects = originalDisplayRects(for: h, page: sel.page).map { PageRect(g.toPage($0)) }
            commitNewHighlight(h)
            scanSelection = nil
            relayout()
            return true
        }
        guard let view = pdfView, let document, let selection = view.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var made = false
        for page in selection.pages {
            let index = document.index(for: page)
            var rects: [CGRect] = []
            for line in selection.selectionsByLine() where line.pages.contains(page) {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5,
                      !(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                rects.append(r)
            }
            guard !rects.isEmpty else { continue }
            // 文字層的字元索引 → 原文區塊與字元範圍
            var spans: [HighlightSpan] = []
            if let entry = originalFlowEntry(index) {
                var ranges: [Int: (lo: Int, hi: Int)] = [:]
                for k in 0..<selection.numberOfTextRanges(on: page) {
                    let r = selection.range(at: k, on: page)
                    guard r.location != NSNotFound else { continue }
                    for u in r.location..<(r.location + r.length) {
                        guard let pos = entry.sourceIndex[u] else { continue }
                        let cur = ranges[pos.block]
                        ranges[pos.block] = (min(cur?.lo ?? pos.index, pos.index), max(cur?.hi ?? pos.index + 1, pos.index + 1))
                    }
                }
                for (bi, r) in ranges.sorted(by: { $0.key < $1.key }) {
                    let b = entry.flow.blocks[bi]
                    spans.append(HighlightSpan(blockID: b.id, side: .original, start: r.lo, end: r.hi, source: b.text))
                }
            }
            let snippet = selection.pages.count == 1 ? (selection.string ?? "")
                : (page.selection(for: rects.reduce(rects[0]) { $0.union($1) })?.string ?? "")
            let h = Highlight(documentID: documentID, pageIndex: index, color: color, rects: rects.map { PageRect($0) },
                              text: snippet.trimmingCharacters(in: .whitespacesAndNewlines), spans: spans)
            commitNewHighlight(h)
            made = true
        }
        guard made else { return false }
        view.clearSelection()
        return true
    }

    private func commitNewHighlight(_ h: Highlight) {
        highlights.append(h)
        try? database?.saveHighlight(h)
        registerHighlightUndo(id: h.id, before: nil, name: L("螢光筆", "Highlight"))
        relayout()
        onChange?(h.pageIndex)
    }

    func removeHighlight(_ id: String) {
        guard let h = highlights.first(where: { $0.id == id }) else { return }
        highlights.removeAll { $0.id == id }
        try? database?.deleteHighlight(id: id)
        registerHighlightUndo(id: id, before: h, name: L("移除螢光標記", "Remove Highlight"))
        relayout()
        onChange?(h.pageIndex)
    }

    func recolorHighlight(_ id: String, _ color: HighlightColor) {
        guard let i = highlights.firstIndex(where: { $0.id == id }) else { return }
        let before = highlights[i]
        highlights[i].color = color
        try? database?.saveHighlight(highlights[i])
        registerHighlightUndo(id: id, before: before, name: L("螢光筆顏色", "Highlight Color"))
        relayout()
        onChange?(highlights[i].pageIndex)
    }

    /// 重新分析版面後區塊編號可能改變：在同一種文字裡找回標記的那段文字，重新定錨。
    func resolved(_ span: HighlightSpan, page index: Int) -> HighlightSpan {
        guard let flow = flow(index, side: span.side) else { return span }
        if let b = flow.block(id: span.blockID), b.text == span.source { return span }
        let src = Array(span.source)
        let lo = max(0, min(span.start, src.count)), hi = max(lo, min(span.end, src.count))
        let snippet = String(src[lo..<hi])
        guard snippet.count >= 2 else { return span }
        for b in flow.blocks {
            let text = b.text
            guard let r = text.range(of: snippet) else { continue }
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            return HighlightSpan(blockID: b.id, side: span.side, start: start, end: start + snippet.count, source: text)
        }
        return span
    }

    /// 錨點換算到某種文字的字元範圍。同一邊且文字沒變就直接用；否則以句子對齊換算。
    func mappedRange(_ span: HighlightSpan, to target: TextFlow.Block, side: TextSide) -> Range<Int> {
        if span.side == side, span.source == target.text {
            return max(0, span.start)..<min(target.chars.count, max(span.start, span.end))
        }
        return TextCorrespondence.map(span.start..<span.end, from: Array(span.source), to: target.chars)
    }

    /// 螢光筆在原文畫面的位置（顯示空間）。
    func originalDisplayRects(for h: Highlight, page index: Int) -> [CGRect] {
        guard let flow = originalFlow(index) else { return [] }
        var out: [CGRect] = []
        for span in h.spans.map({ resolved($0, page: index) }) {
            guard let b = flow.block(id: span.blockID) else { continue }
            out += flow.rects(for: .init(blockID: b.id, range: mappedRange(span, to: b, side: .original)))
        }
        return out
    }

    /// 螢光筆在目前畫面上的位置（顯示空間）：顯示譯文時標在譯文上，顯示原文時標在原文上。
    func displayRects(for h: Highlight, page index: Int) -> [CGRect] {
        guard let page = document?.page(at: index) else { return [] }
        let g = geometry(page)
        let stored = h.rects.map { g.toDisplay(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
        guard !h.spans.isEmpty else { return stored }
        let side = currentSide(index)
        let tflow = side == .translated ? translatedFlow(index) : nil
        let oflow = originalFlow(index)
        var out: [CGRect] = []
        var usedStored = false
        for span in h.spans.map({ resolved($0, page: index) }) {
            // 顯示譯文時，有譯文的區塊標在譯文上；沒有譯文的區塊照原文
            if let tf = tflow, let b = tf.block(id: span.blockID) {
                out += tf.rects(for: .init(blockID: b.id, range: mappedRange(span, to: b, side: .translated)))
            } else if let of = oflow, let b = of.block(id: span.blockID) {
                out += of.rects(for: .init(blockID: b.id, range: mappedRange(span, to: b, side: .original)))
            } else if !usedStored {
                // 原文版面還沒準備好（掃描頁辨識中）或區塊已重新辨識：用記下的原文位置
                out += stored
                usedStored = true
            }
        }
        return out
    }

    func highlight(at pagePoint: CGPoint, page index: Int) -> Highlight? {
        guard let page = document?.page(at: index) else { return nil }
        let p = pagePoint.applying(geometry(page).pageToDisplay)
        return highlights.last { h in
            h.pageIndex == index && displayRects(for: h, page: index).contains { $0.insetBy(dx: -1, dy: -1).contains(p) }
        }
    }

    /// 回到某個螢光標記，並在頁面上閃一下。
    func reveal(highlight id: String, flash: Bool = true) {
        guard let h = highlights.first(where: { $0.id == id }) else { return }
        showPage(h.pageIndex) { [weak self] in
            guard let self, flash else { return }
            self.flash(displayRects: self.displayRects(for: h, page: h.pageIndex), page: h.pageIndex)
        }
    }
}

// MARK: - 前往與標亮

extension NotesController {
    /// 頁面不在畫面上就翻過去，等版面穩定後再執行 `then`。
    func showPage(_ index: Int, then: @escaping () -> Void) {
        let visible = Set(pdfView?.visiblePages.compactMap { document?.index(for: $0) } ?? [])
        if visible.contains(index) {
            relayout()
            then()
            return
        }
        navigateToPage(index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                self?.relayout()
                then()
            }
        }
    }

    /// 前往便利貼所在頁並閃一下（無位置筆記只前往該頁）。
    func revealNote(_ id: String) {
        guard let n = note(id: id) else { return }
        if n.isPlaced, !isVisible { setVisible(true) }
        showPage(n.pageIndex) { [weak self] in
            guard let self, n.isPlaced, let v = self.views[id], let docView = v.superview else { return }
            self.bringToFront(v)
            self.flash(docRects: [v.frame], in: docView, cornerRadius: 9)
        }
    }

    /// 在頁面上的幾個位置（顯示空間）閃一下。
    func flash(displayRects rects: [CGRect], page index: Int) {
        guard let view = pdfView, let docView = view.documentView, let page = document?.page(at: index) else { return }
        let g = geometry(page)
        let docRects = rects.map { docView.convert(view.convert(g.toPage($0), from: page), from: view) }
        flash(docRects: docRects, in: docView, cornerRadius: 4)
    }

    func flash(docRects: [CGRect], in docView: NSView, cornerRadius: CGFloat) {
        for r in docRects where r.width > 0 && r.height > 0 {
            let v = FlashView(frame: r.insetBy(dx: -3, dy: -2), cornerRadius: cornerRadius)
            docView.addSubview(v, positioned: .above, relativeTo: nil)
            v.run()
        }
    }
}

/// 標亮：柔和的光暈，輕輕浮現一次後淡出並移除。不攔截滑鼠。
final class FlashView: NSView {
    init(frame: NSRect, cornerRadius: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        layer.borderWidth = 1
        layer.borderColor = accent.withAlphaComponent(0.45).cgColor
        // 外圍光暈
        layer.shadowColor = accent.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 9
        layer.shadowOffset = .zero
        layer.zPosition = 100
        layer.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func run() {
        guard let layer else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.22, 0.45, 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
                                CAMediaTimingFunction(name: .easeInEaseOut)]
        // 從稍大處收合到原位，像輕輕落下
        let grow = CABasicAnimation(keyPath: "shadowRadius")
        grow.fromValue = 16
        grow.toValue = 6
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = 1.1
        layer.add(group, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in self?.removeFromSuperview() }
    }
}

// MARK: - 標記圖層與翻頁影像

extension NotesController {
    /// 螢光筆與選取畫在獨立圖層（色彩增值混合），位於譯文之上，切到譯文時也看得到。
    func relayoutMarks(view: PDFView, document: PDFDocument, docView: NSView, continuous: Bool, visible: Set<Int>) {
        var pages = Set(highlights.map(\.pageIndex))
        if let s = scanSelection { pages.insert(s.page) }
        for p in pdfSelectionRects.keys where overlayCovers(p) { pages.insert(p) }
        var keep = Set<Int>()
        for index in pages {
            let shown = continuous ? (visible.contains(index) || abs(index - anchor) <= 4) : visible.contains(index)
            guard shown, let page = document.page(at: index) else { continue }
            let g = geometry(page)
            var marks: [PageMarksView.Mark] = highlights.filter { $0.pageIndex == index }.map { h in
                .init(rects: displayRects(for: h, page: index), color: h.color.ink.withAlphaComponent(0.6))
            }
            if let s = scanSelection, s.page == index, let flow = flow(index, side: s.side) {
                let color = highlighterMode ? highlighterColor.ink.withAlphaComponent(0.6)
                                            : NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55)
                marks.append(.init(rects: s.spans.flatMap { flow.rects(for: $0) }, color: color))
            }
            if let rects = pdfSelectionRects[index], overlayCovers(index) {
                marks.append(.init(rects: rects, color: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55)))
            }
            marks.removeAll { $0.rects.isEmpty }
            guard !marks.isEmpty else { continue }
            keep.insert(index)
            let mv = markViews[index] ?? PageMarksView()
            markViews[index] = mv
            if mv.superview !== docView {
                mv.removeFromSuperview()
                if let firstNote = docView.subviews.first(where: { $0 is StickyNoteView }) {
                    docView.addSubview(mv, positioned: .below, relativeTo: firstNote)
                } else {
                    docView.addSubview(mv, positioned: .above, relativeTo: nil)
                }
            }
            let frame = docView.convert(view.convert(page.bounds(for: view.displayBox), from: page), from: view).integral
            if mv.frame != frame { mv.frame = frame }
            mv.displaySize = g.displaySize
            if mv.marks != marks { mv.marks = marks }
        }
        for (i, v) in markViews where !keep.contains(i) {
            v.removeFromSuperview()
            markViews.removeValue(forKey: i)
        }
    }

    func decorations(page index: Int) -> PageDecorations {
        var d = PageDecorations()
        if let page = document?.page(at: index) {
            let g = geometry(page)
            for h in highlights where h.pageIndex == index {
                let color = h.color.ink.withAlphaComponent(0.55).usingColorSpace(.sRGB)?.cgColor ?? h.color.ink.cgColor
                d.highlights.append((displayRects(for: h, page: index).map { g.toPage($0) }, color))
            }
        }
        if isVisible {
            for n in notes where n.pageIndex == index {
                guard let r = n.rect else { continue }
                let w = CGFloat(r.width)
                let h = StickyNoteLayout.displayHeight(n, width: w, baseHeight: CGFloat(r.height), growForEditing: false)
                d.notes.append((n, CGRect(x: CGFloat(r.x), y: CGFloat(r.maxY) - h, width: w, height: h)))
            }
        }
        return d
    }
}
