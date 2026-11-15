import Foundation

/// OCR 或內嵌文字層的一行（頁面空間座標）。
public struct TextLine: Sendable, Equatable {
    public var text: String
    public var bounds: PageRect
    public var confidence: Double

    public init(text: String, bounds: PageRect, confidence: Double = 1) {
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
    }
}

/// 將行整理為段落、判斷種類並重建閱讀順序。
/// v1 範圍：單欄與標準雙欄（含跨欄標題）。不規則排版列為後續版本。
public struct LayoutAnalyzer: Sendable {
    public init() {}

    public struct Result: Sendable, Equatable {
        public var blocks: [TextBlock]
        public var columnCount: Int
    }

    public func analyze(lines rawLines: [TextLine], pageBounds: PageRect, documentID: String,
                        pageIndex: Int, source: TextSource) -> Result {
        let lines = rawLines
            .map { var l = $0; l.text = l.text.trimmingCharacters(in: .whitespacesAndNewlines); return l }
            .filter { !$0.text.isEmpty && $0.bounds.width > 0 && $0.bounds.height > 0 }
        guard !lines.isEmpty else { return Result(blocks: [], columnCount: 1) }

        let medianHeight = Self.median(lines.map(\.bounds.height))
        let split = Self.columnSplit(lines: lines, pageBounds: pageBounds)
        let ordered = Self.readingOrder(lines: lines, pageBounds: pageBounds, split: split)

        // 合併成段落
        var groups: [[TextLine]] = []
        for item in ordered {
            if let last = groups.last?.last,
               Self.continuesParagraph(prev: last, next: item.line, medianHeight: medianHeight),
               groups[groups.count - 1].count < 200,
               item.startsNewRegion == false {
                groups[groups.count - 1].append(item.line)
            } else {
                groups.append([item.line])
            }
        }

        var blocks: [TextBlock] = []
        for (order, group) in groups.enumerated() {
            let bounds = group.map(\.bounds).reduce(group[0].bounds) { Self.union($0, $1) }
            let text = Self.join(group.map(\.text))
            let confidence = group.map(\.confidence).reduce(0, +) / Double(group.count)
            let kind = Self.classify(group: group, bounds: bounds, text: text,
                                     medianHeight: medianHeight, pageBounds: pageBounds)
            blocks.append(TextBlock(id: TextBlock.makeID(documentID: documentID, pageIndex: pageIndex, order: order),
                                    documentID: documentID, pageIndex: pageIndex, readingOrder: order,
                                    kind: kind, text: text, bounds: bounds, confidence: confidence,
                                    source: source))
        }
        return Result(blocks: blocks, columnCount: split == nil ? 1 : 2)
    }

    // MARK: - 欄位偵測

    /// 回傳雙欄的分隔 x（頁面空間）；單欄回傳 nil。
    static func columnSplit(lines: [TextLine], pageBounds: PageRect) -> Double? {
        let width = pageBounds.width
        guard width > 0 else { return nil }
        let narrow = lines.filter { $0.bounds.width < width * 0.55 }
        guard narrow.count >= 6 else { return nil }

        let bins = 100
        var coverage = [Int](repeating: 0, count: bins)
        for line in narrow {
            let a = Int(((line.bounds.minX - pageBounds.minX) / width * Double(bins)).rounded(.down))
            let b = Int(((line.bounds.maxX - pageBounds.minX) / width * Double(bins)).rounded(.up))
            let lo = max(0, min(a, bins))
            let hi = min(bins, max(lo, b))
            for i in lo..<hi { coverage[i] += 1 }
        }
        // 在 30%–70% 之間找最長的空白帶
        let tolerance = max(0, narrow.count / 50)
        var bestStart = -1, bestLen = 0, curStart = -1
        for i in 30...70 {
            if coverage[i] <= tolerance {
                if curStart < 0 { curStart = i }
                let len = i - curStart + 1
                if len > bestLen { bestLen = len; bestStart = curStart }
            } else {
                curStart = -1
            }
        }
        guard bestLen >= 1, bestStart >= 0 else { return nil }
        let splitX = pageBounds.minX + (Double(bestStart) + Double(bestLen) / 2) / Double(bins) * width
        let left = narrow.filter { $0.bounds.maxX <= splitX }.count
        let right = narrow.filter { $0.bounds.minX >= splitX }.count
        guard left >= 3, right >= 3 else { return nil }
        return splitX
    }

    // MARK: - 閱讀順序

    struct OrderedLine {
        var line: TextLine
        /// 進入新的欄或新的跨欄區段時為 true（不得與前一行合併段落）
        var startsNewRegion: Bool
    }

    static func readingOrder(lines: [TextLine], pageBounds: PageRect, split: Double?) -> [OrderedLine] {
        let topDown = lines.sorted { a, b in
            if abs(a.bounds.maxY - b.bounds.maxY) > 0.5 { return a.bounds.maxY > b.bounds.maxY }
            return a.bounds.minX < b.bounds.minX
        }
        guard let split else {
            return topDown.enumerated().map { OrderedLine(line: $0.element, startsNewRegion: $0.offset == 0) }
        }

        // 跨越分隔線的行（標題、跨欄圖說）切出水平區段；區段內先左欄再右欄。
        var result: [OrderedLine] = []
        var band: [TextLine] = []
        func flushBand() {
            guard !band.isEmpty else { return }
            let left = band.filter { $0.bounds.midX < split }
            let right = band.filter { $0.bounds.midX >= split }
            for (i, l) in left.enumerated() { result.append(OrderedLine(line: l, startsNewRegion: i == 0)) }
            for (i, l) in right.enumerated() { result.append(OrderedLine(line: l, startsNewRegion: i == 0)) }
            band.removeAll()
        }
        for line in topDown {
            let spans = line.bounds.minX < split - 4 && line.bounds.maxX > split + 4
            if spans {
                flushBand()
                result.append(OrderedLine(line: line, startsNewRegion: true))
            } else {
                band.append(line)
            }
        }
        flushBand()
        return result
    }

    // MARK: - 段落合併

    static func continuesParagraph(prev: TextLine, next: TextLine, medianHeight: Double) -> Bool {
        let h1 = prev.bounds.height, h2 = next.bounds.height
        let ratio = max(h1, h2) / max(0.01, min(h1, h2))
        guard ratio < 1.35 else { return false }
        let gap = prev.bounds.minY - next.bounds.maxY
        let lineHeight = max(h1, h2, medianHeight * 0.5)
        guard gap > -lineHeight * 0.5, gap < lineHeight * 0.9 else { return false }
        // 水平需重疊（同一欄）
        let overlap = min(prev.bounds.maxX, next.bounds.maxX) - max(prev.bounds.minX, next.bounds.minX)
        guard overlap > 0 else { return false }
        // 上一行明顯很短且以句號結尾 → 段落結束
        if prev.bounds.width < next.bounds.width * 0.6,
           let last = prev.text.last, ".!?。！？:：\"”".contains(last) {
            return false
        }
        return true
    }

    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            if out.isEmpty { out = part; continue }
            if out.hasSuffix("-"), let first = part.first, first.isLowercase {
                out.removeLast()
                out += part
            } else if let a = out.last, let b = part.first, a.isCJK || b.isCJK {
                out += part
            } else {
                out += " " + part
            }
        }
        return out
    }

    // MARK: - 種類判斷

    static func classify(group: [TextLine], bounds: PageRect, text: String,
                         medianHeight: Double, pageBounds: PageRect) -> BlockKind {
        let avgHeight = group.map(\.bounds.height).reduce(0, +) / Double(group.count)
        let lower = text.lowercased()
        let captionPrefixes = ["fig.", "fig ", "figure", "plate", "pl.", "圖", "圖片", "abb.", "ill."]
        if captionPrefixes.contains(where: { lower.hasPrefix($0) }) && text.count < 400 {
            return .caption
        }
        if avgHeight > medianHeight * 1.3 && group.count <= 3 && text.count < 200 {
            return .heading
        }
        // 單行、字級略大、沒有句末標點 → 小標題
        if group.count == 1 && avgHeight > medianHeight * 1.15 && text.count < 100,
           let last = text.last, !".,;:!?。，；：！？".contains(last) {
            return .heading
        }
        let relY = (bounds.maxY - pageBounds.minY) / max(1, pageBounds.height)
        if relY < 0.15 && avgHeight < medianHeight * 0.92 {
            return .footnote
        }
        if avgHeight < medianHeight * 0.85 && text.count < 300 {
            return .caption
        }
        return .paragraph
    }

    // MARK: - helpers

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func union(_ a: PageRect, _ b: PageRect) -> PageRect {
        let minX = min(a.minX, b.minX), minY = min(a.minY, b.minY)
        let maxX = max(a.maxX, b.maxX), maxY = max(a.maxY, b.maxY)
        return PageRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF,
             0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}

extension TextBlock {
    /// 需要翻譯的區塊：至少有兩個字母（排除頁碼、單一符號）。
    public var needsTranslation: Bool {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2
    }
}
