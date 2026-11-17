import Foundation
import CoreGraphics

/// 頁面上一種文字（原文或譯文）的「字元級」版面：每個區塊的每個字元在顯示空間（已旋轉、原點左下）的位置。
///
/// 用來做文字選取、螢光筆標記與原文／譯文之間的位置對應。
public struct TextFlow: Sendable {
    public struct Block: Sendable, Equatable {
        public var id: String
        public var chars: [Character]
        public var rects: [CGRect]

        public init(id: String, chars: [Character], rects: [CGRect]) {
            self.id = id
            self.chars = chars
            self.rects = rects
        }

        public var text: String { String(chars) }
    }

    /// 文字中的一個位置：第幾個區塊、字元之間的第幾個間隙（0...count）。
    public struct Position: Sendable, Comparable, Hashable {
        public var block: Int
        public var index: Int
        public init(block: Int, index: Int) { self.block = block; self.index = index }
        public static func < (a: Position, b: Position) -> Bool {
            a.block != b.block ? a.block < b.block : a.index < b.index
        }
    }

    /// 選取或標記的一段：區塊 ID 與字元範圍。
    public struct Span: Sendable, Equatable, Hashable {
        public var blockID: String
        public var range: Range<Int>
        public init(blockID: String, range: Range<Int>) { self.blockID = blockID; self.range = range }
    }

    /// 一行（同一區塊中連續、在同一水平列的字元）。
    struct Line: Sendable {
        var block: Int
        var range: Range<Int>
        var rect: CGRect
    }

    public let blocks: [Block]
    let lines: [Line]
    private let indexByID: [String: Int]

    public init(blocks: [Block]) {
        let cleaned = blocks.filter { !$0.chars.isEmpty && $0.chars.count == $0.rects.count }
        self.blocks = cleaned
        var map: [String: Int] = [:]
        for (i, b) in cleaned.enumerated() where map[b.id] == nil { map[b.id] = i }
        indexByID = map
        lines = Self.makeLines(cleaned)
    }

    public var isEmpty: Bool { blocks.isEmpty }

    public func block(id: String) -> Block? { indexByID[id].map { blocks[$0] } }
    public func blockIndex(id: String) -> Int? { indexByID[id] }

    // MARK: - 命中測試

    /// 最接近某點的文字位置。`maxDistance` 以外視為沒有點在文字上。
    public func position(at p: CGPoint, maxDistance: CGFloat = .greatestFiniteMagnitude) -> Position? {
        guard !lines.isEmpty else { return nil }
        let rowMatches = lines.filter { p.y >= $0.rect.minY - 1 && p.y <= $0.rect.maxY + 1 }
        let pool = rowMatches.isEmpty ? lines : rowMatches
        guard let line = pool.min(by: { distance($0.rect, p) < distance($1.rect, p) }),
              distance(line.rect, p) <= maxDistance else { return nil }
        let rects = blocks[line.block].rects
        for i in line.range where p.x < rects[i].midX {
            return Position(block: line.block, index: i)
        }
        return Position(block: line.block, index: line.range.upperBound)
    }

    /// 點是否落在文字上（游標用）。
    public func containsText(at p: CGPoint, tolerance: CGFloat = 2) -> Bool {
        lines.contains { $0.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
    }

    /// 兩個位置之間（依閱讀順序）的各區塊範圍。
    public func spans(from a: Position, to b: Position) -> [Span] {
        let (s, e) = a <= b ? (a, b) : (b, a)
        guard s.block < blocks.count, e.block < blocks.count else { return [] }
        var out: [Span] = []
        for i in s.block...e.block {
            let lo = i == s.block ? s.index : 0
            let hi = i == e.block ? e.index : blocks[i].chars.count
            if hi > lo { out.append(Span(blockID: blocks[i].id, range: lo..<hi)) }
        }
        return out
    }

    // MARK: - 位置與文字

    /// 一段文字在畫面上的矩形（每行合併成一個，略加上下邊距）。
    public func rects(for span: Span) -> [CGRect] {
        guard let bi = indexByID[span.blockID] else { return [] }
        let b = blocks[bi]
        let lo = max(0, span.range.lowerBound), hi = min(b.chars.count, span.range.upperBound)
        guard hi > lo else { return [] }
        var out: [CGRect] = []
        for line in lines where line.block == bi {
            let a = max(lo, line.range.lowerBound), z = min(hi, line.range.upperBound)
            guard z > a else { continue }
            var r = b.rects[a]
            for i in (a + 1)..<z { r = r.union(b.rects[i]) }
            // 一行的高度以整行為準，選取看起來整齊
            r = CGRect(x: r.minX, y: line.rect.minY, width: r.width, height: line.rect.height)
            let pad = min(1.5, r.height * 0.1)
            out.append(r.insetBy(dx: 0, dy: -pad))
        }
        return out
    }

    public func text(for span: Span) -> String {
        guard let b = block(id: span.blockID) else { return "" }
        let lo = max(0, span.range.lowerBound), hi = min(b.chars.count, span.range.upperBound)
        return hi > lo ? String(b.chars[lo..<hi]) : ""
    }

    /// 多段文字接起來（中日韓文字直接相連，其他語言補空格）。
    public func text(for spans: [Span]) -> String {
        var out = ""
        for s in spans {
            let t = text(for: s).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let l = out.last, let f = t.first, !(Self.isCJK(l) && Self.isCJK(f)) { out += " " }
            out += t
        }
        return out
    }

    // MARK: - 建立

    /// 由文字行建立（例如 OCR 的行，或沒有區塊資訊時）。字元位置以平均字寬估計。
    /// `blocks` 為區塊 ID 與範圍（顯示空間）；行的中心落在哪個區塊就歸哪個，其餘每行各自成一塊。
    public static func fromLines(_ lines: [TextLine], blocks: [(id: String, rect: CGRect)] = []) -> TextFlow {
        var grouped: [String: (chars: [Character], rects: [CGRect], order: Int)] = [:]
        var order = 0
        let sorted = lines.sorted { a, b in
            let ra = a.bounds, rb = b.bounds
            let sameRow = min(ra.maxY, rb.maxY) - max(ra.minY, rb.minY) > min(ra.height, rb.height) * 0.5
            return sameRow ? ra.minX < rb.minX : ra.minY + ra.height / 2 > rb.minY + rb.height / 2
        }
        for (li, line) in sorted.enumerated() {
            let r = CGRect(x: line.bounds.x, y: line.bounds.y, width: line.bounds.width, height: line.bounds.height)
            let chars = Array(line.text)
            guard !chars.isEmpty, r.width > 0 else { continue }
            let center = CGPoint(x: r.midX, y: r.midY)
            let id = blocks.first { $0.rect.insetBy(dx: -2, dy: -2).contains(center) }?.id ?? "line:\(li)"
            let w = r.width / CGFloat(chars.count)
            var entry = grouped[id] ?? ([], [], order)
            if grouped[id] == nil { order += 1 }
            for (i, c) in chars.enumerated() {
                entry.chars.append(c)
                entry.rects.append(CGRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w, height: r.height))
            }
            grouped[id] = entry
        }
        // 區塊順序：有區塊資訊時照區塊的閱讀順序，其餘照出現順序
        let blockOrder = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
        let result = grouped.sorted { a, b in
            switch (blockOrder[a.key], blockOrder[b.key]) {
            case let (x?, y?): return x < y
            default: return a.value.order < b.value.order
            }
        }.map { Block(id: $0.key, chars: $0.value.chars, rects: $0.value.rects) }
        return TextFlow(blocks: result)
    }

    private static func makeLines(_ blocks: [Block]) -> [Line] {
        var out: [Line] = []
        for (bi, b) in blocks.enumerated() {
            var start = 0
            var rect = b.rects[0]
            for i in 1..<max(1, b.chars.count + 1) {
                let breakHere: Bool
                if i == b.chars.count {
                    breakHere = true
                } else {
                    let r = b.rects[i]
                    let overlap = min(r.maxY, rect.maxY) - max(r.minY, rect.minY)
                    breakHere = overlap < min(r.height, rect.height) * 0.5 || r.minX < b.rects[i - 1].minX - 1
                }
                if breakHere {
                    out.append(Line(block: bi, range: start..<i, rect: rect))
                    if i < b.chars.count {
                        start = i
                        rect = b.rects[i]
                    }
                } else {
                    rect = rect.union(b.rects[i])
                }
            }
        }
        return out
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(s) || (0xAC00...0xD7AF).contains(s) || (0xF900...0xFFEF).contains(s)
    }
}

/// 原文與譯文之間的位置對應：先以句子對齊，句數不同時退回整段等比例。
public enum TextCorrespondence {
    /// 把來源文字的一段範圍對應到目標文字。
    public static func map(_ range: Range<Int>, from source: [Character], to target: [Character]) -> Range<Int> {
        guard !source.isEmpty, !target.isEmpty else { return 0..<0 }
        let lo = min(max(0, range.lowerBound), source.count)
        let hi = min(max(lo, range.upperBound), source.count)
        if lo == 0 && hi == source.count { return 0..<target.count }
        let s = sentences(source), t = sentences(target)
        func point(_ x: Int, end: Bool) -> Int {
            if s.count == t.count, s.count > 1 {
                // 落在第幾句、句中的相對位置
                var k = s.firstIndex { x < $0.upperBound } ?? (s.count - 1)
                if end, k > 0, x == s[k].lowerBound { k -= 1 }
                let src = s[k], dst = t[k]
                let f = src.count > 0 ? Double(x - src.lowerBound) / Double(src.count) : 0
                return dst.lowerBound + Int((f * Double(dst.count)).rounded())
            }
            return Int((Double(x) / Double(source.count) * Double(target.count)).rounded())
        }
        var a = point(lo, end: false), b = point(hi, end: true)
        a = min(max(0, a), target.count)
        b = min(max(a, b), target.count)
        if b == a { b = min(target.count, a + max(1, (hi - lo) * target.count / max(1, source.count))) }
        if b == a, a > 0 { a -= 1 }
        // 英文等以空白分詞的文字：擴到完整單字，不切在字中間
        func isWord(_ c: Character) -> Bool { (c.isLetter && !TextFlow.isCJK(c)) || c.isNumber || c == "'" || c == "’" }
        while a > 0, a < target.count, isWord(target[a - 1]), isWord(target[a]) { a -= 1 }
        while b > 0, b < target.count, isWord(target[b - 1]), isWord(target[b]) { b += 1 }
        // 頭尾的空白去掉
        while a < b, target[a].isWhitespace { a += 1 }
        while b > a, target[b - 1].isWhitespace { b -= 1 }
        return a..<b
    }

    /// 句子範圍（含結尾標點）。
    static func sentences(_ chars: [Character]) -> [Range<Int>] {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n", "…"]
        var out: [Range<Int>] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var isEnd = enders.contains(c)
            // 英文句點：後面是結尾、空白或大寫字母才算句末（避免 3.14、e.g.；原文字元版面不含空白）
            if c == "." { isEnd = i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1].isUppercase }
            if isEnd {
                var j = i + 1
                while j < chars.count, ["」", "』", "”", "\"", ")", "）", " "].contains(chars[j]) { j += 1 }
                if j > start { out.append(start..<j) }
                start = j
                i = j
                continue
            }
            i += 1
        }
        if start < chars.count { out.append(start..<chars.count) }
        // 去掉只有空白的句子
        return out.filter { r in chars[r].contains { !$0.isWhitespace } }
    }
}
