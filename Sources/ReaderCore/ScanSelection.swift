import Foundation
import CoreGraphics

/// 掃描頁（沒有文字層）的文字選取：依 OCR 的文字行，像一般文字一樣從起點「流」到終點。
///
/// 所有座標都用頁面的顯示空間（已旋轉、原點左下），文字行是水平的。
public enum ScanSelection {
    public struct Piece: Sendable, Equatable {
        public var rect: CGRect
        public var text: String
    }

    /// - Parameters:
    ///   - lines: OCR 文字行（顯示空間）
    ///   - start: 按下滑鼠的位置
    ///   - end: 目前滑鼠位置
    public static func pieces(lines: [TextLine], from start: CGPoint, to end: CGPoint) -> [Piece] {
        let rects = lines.map { CGRect(x: $0.bounds.x, y: $0.bounds.y, width: $0.bounds.width, height: $0.bounds.height) }
        guard !lines.isEmpty,
              let s = nearestLine(rects, to: start), let e = nearestLine(rects, to: end) else { return [] }
        // 起點與終點都離文字很遠：不選
        if distance(rects[s], start) > 40 && distance(rects[e], end) > 40 { return [] }

        // 閱讀順序：由上而下，同一列由左而右
        var first = s, last = e, from = start, to = end
        if isBefore(rects[e], rects[s]) || (s == e && end.x < start.x) {
            swap(&first, &last)
            swap(&from, &to)
        }
        if first == last {
            let line = lines[first]
            let (a, ia) = snap(line, rects[first], x: min(from.x, to.x))
            let (b, ib) = snap(line, rects[first], x: max(from.x, to.x))
            guard b - a > 0.5, ib > ia else { return [] }
            return [piece(line, rects[first], a, b, ia, ib)]
        }

        // 同欄：與起訖行水平重疊的行
        let column = rects[first].union(rects[last])
        let middle = rects.indices.filter { i in
            guard i != first, i != last else { return false }
            let r = rects[i]
            let overlap = min(r.maxX, column.maxX) - max(r.minX, column.minX)
            guard overlap > min(r.width, column.width) * 0.3 else { return false }
            return isBefore(rects[first], r) && isBefore(r, rects[last])
        }.sorted { isBefore(rects[$0], rects[$1]) }

        var result: [Piece] = []
        let fl = lines[first]
        let (a, ia) = snap(fl, rects[first], x: from.x)
        if rects[first].maxX - a > 0.5 { result.append(piece(fl, rects[first], a, rects[first].maxX, ia, count(fl))) }
        for i in middle { result.append(piece(lines[i], rects[i], rects[i].minX, rects[i].maxX, 0, count(lines[i]))) }
        let ll = lines[last]
        let (b, ib) = snap(ll, rects[last], x: to.x)
        if b - rects[last].minX > 0.5 { result.append(piece(ll, rects[last], rects[last].minX, b, 0, ib)) }
        return result
    }

    /// 選取的文字（行與行之間：中日韓文字直接相連，其他語言補空格）。
    public static func text(of pieces: [Piece]) -> String {
        var out = ""
        for p in pieces {
            let t = p.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let lastChar = out.last, let firstChar = t.first, !isCJK(lastChar) || !isCJK(firstChar) {
                out += " "
            }
            out += t
        }
        return out
    }

    // MARK: - 內部

    private static func count(_ line: TextLine) -> Int { line.text.count }

    /// 把 x 對齊到字元邊界（以平均字寬估計），回傳 x 與字元索引。
    private static func snap(_ line: TextLine, _ r: CGRect, x: CGFloat) -> (CGFloat, Int) {
        let n = max(1, count(line))
        let w = r.width / CGFloat(n)
        let i = min(n, max(0, Int(((x - r.minX) / w).rounded())))
        return (r.minX + CGFloat(i) * w, i)
    }

    private static func piece(_ line: TextLine, _ r: CGRect, _ a: CGFloat, _ b: CGFloat, _ ia: Int, _ ib: Int) -> Piece {
        let chars = Array(line.text)
        let lo = min(max(0, ia), chars.count), hi = min(max(lo, ib), chars.count)
        let pad = min(2, r.height * 0.12)
        return Piece(rect: CGRect(x: a, y: r.minY - pad, width: max(0, b - a), height: r.height + pad * 2),
                     text: String(chars[lo..<hi]))
    }

    /// a 在 b 之前（閱讀順序）。
    private static func isBefore(_ a: CGRect, _ b: CGRect) -> Bool {
        let sameRow = min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) * 0.5
        return sameRow ? a.minX < b.minX : a.midY > b.midY
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 優先選垂直方向包含該點的行；否則取最近的行。
    private static func nearestLine(_ rects: [CGRect], to p: CGPoint) -> Int? {
        let containing = rects.indices.filter { p.y >= rects[$0].minY - 2 && p.y <= rects[$0].maxY + 2 }
        let pool = containing.isEmpty ? Array(rects.indices) : containing
        return pool.min { distance(rects[$0], p) < distance(rects[$1], p) }
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(s) || (0xAC00...0xD7AF).contains(s) || (0xF900...0xFFEF).contains(s)
    }
}
