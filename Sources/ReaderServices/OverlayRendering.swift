import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ReaderCore

public struct RGBColor: Sendable, Equatable {
    public var r: CGFloat
    public var g: CGFloat
    public var b: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let white = RGBColor(r: 1, g: 1, b: 1)
    public var luminance: CGFloat { 0.299 * r + 0.587 * g + 0.114 * b }
}

/// 一個譯文區塊在頁面上的繪製樣式（預先計算，繪製時不必再量測）。
public struct OverlayStyle: Sendable, Equatable {
    public var background: RGBColor
    public var fontSize: CGFloat
    public var fontFamily: String

    public init(background: RGBColor, fontSize: CGFloat, fontFamily: String) {
        self.background = background
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }
}

public struct OverlayItem: Sendable {
    public var bounds: PageRect
    public var kind: BlockKind
    public var text: String
    /// 對應的原文區塊 ID（螢光筆在原文／譯文間換算用）。
    public var blockID: String

    public init(bounds: PageRect, kind: BlockKind, text: String, blockID: String = "") {
        self.bounds = bounds
        self.kind = kind
        self.text = text
        self.blockID = blockID
    }
}

/// 在原頁面上以譯文取代原文的排版與繪製。匯出 PDF 與閱讀器畫面共用同一套規則。
public enum OverlayRenderer {
    /// 區塊在顯示空間中的繪製範圍（略微外擴以蓋住原文筆畫）。
    public static func displayRect(_ bounds: PageRect, geometry: PageGeometry) -> CGRect {
        geometry.toDisplay(bounds.cgRect).insetBy(dx: -1.5, dy: -1.5)
    }

    /// 計算整頁所有區塊的字級與背景色。內文字級以同頁內文的中位數為上限，避免大小不一。
    public static func styles(items: [OverlayItem], geometry: PageGeometry, page: PDFPage?,
                              fontFamily: String) -> [OverlayStyle] {
        guard !items.isEmpty else { return [] }
        let sampler = page.flatMap { BackgroundSampler(page: $0, geometry: geometry) }
        let rects = items.map { displayRect($0.bounds, geometry: geometry) }
        let fits = zip(items, rects).map { item, rect in
            TranslatedPDFExporter.bestFontSize(text: item.text, kind: item.kind, rect: rect,
                                               maxSize: item.kind == .heading ? 40 : 20, family: fontFamily)
        }
        let body = zip(items, fits).filter { $0.0.kind == .paragraph }.map(\.1).sorted()
        let cap = body.isEmpty ? 20 : body[body.count / 2]
        return zip(zip(items, rects), fits).map { pair, fit in
            let (item, rect) = pair
            var size = fit
            switch item.kind {
            case .paragraph: size = min(fit, cap)
            case .caption, .footnote: size = min(fit, cap * 0.9)
            default: break
            }
            let bg = sampler?.color(around: rect) ?? (1, 1, 1)
            return OverlayStyle(background: RGBColor(r: bg.0, g: bg.1, b: bg.2), fontSize: size, fontFamily: fontFamily)
        }
    }

    /// 在「頁面空間」的 context 上繪製一個譯文區塊（PDFAnnotation.draw 的座標系）。
    public static func drawInPageSpace(_ ctx: CGContext, item: OverlayItem, style: OverlayStyle, geometry: PageGeometry) {
        ctx.saveGState()
        ctx.concatenate(geometry.displayToPage)
        draw(ctx, item: item, style: style, rect: displayRect(item.bounds, geometry: geometry))
        ctx.restoreGState()
    }

    /// 在「顯示空間」的 context 上繪製（匯出 PDF 使用）。
    public static func draw(_ ctx: CGContext, item: OverlayItem, style: OverlayStyle, rect: CGRect) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let bg = style.background
        ctx.saveGState()
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [bg.r, bg.g, bg.b, 1])
                         ?? CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        ctx.fill(rect)
        let ink = bg.luminance > 0.5 ? CGColor(gray: 0.06, alpha: 1) : CGColor(gray: 0.97, alpha: 1)
        TranslatedPDFExporter.drawText(ctx: ctx, text: item.text, kind: item.kind, size: style.fontSize,
                                       rect: rect, color: ink, family: style.fontFamily)
        ctx.restoreGState()
    }
}

extension OverlayRenderer {
    /// 譯文每個字元在顯示空間的位置，與 `draw` 的排版完全相同（選取與螢光筆用）。
    /// 回傳的陣列與 `Array(item.text)` 一一對應；沒有排進框內的字元為 `.null`。
    public static func characterRects(item: OverlayItem, style: OverlayStyle, geometry: PageGeometry) -> [CGRect] {
        let rect = displayRect(item.bounds, geometry: geometry)
        let chars = Array(item.text)
        var result = [CGRect](repeating: .null, count: chars.count)
        guard !chars.isEmpty else { return result }
        let attr = TranslatedPDFExporter.attributed(item.text, kind: item.kind, size: style.fontSize, family: style.fontFamily)
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return result }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        // UTF-16 位移 → 字元索引
        var charAtUTF16: [Int] = []
        charAtUTF16.reserveCapacity(item.text.utf16.count)
        for (ci, c) in chars.enumerated() { for _ in 0..<String(c).utf16.count { charAtUTF16.append(ci) } }

        let lineHeight = style.fontSize * 1.25
        for (li, line) in lines.enumerated() {
            let range = CTLineGetStringRange(line)
            let origin = CGPoint(x: rect.minX + origins[li].x, y: rect.minY + origins[li].y)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            // 行高與繪製時的固定行高一致，讓相鄰行的標記剛好相接
            let extra = max(0, lineHeight - ascent - descent) / 2
            let bottom = origin.y - descent - extra, height = ascent + descent + extra * 2
            var u = range.location
            while u < range.location + range.length, u < charAtUTF16.count {
                let ci = charAtUTF16[u]
                let len = String(chars[ci]).utf16.count
                let x0 = CTLineGetOffsetForStringIndex(line, u, nil)
                let x1 = CTLineGetOffsetForStringIndex(line, min(u + len, range.location + range.length), nil)
                if !chars[ci].isNewline {
                    result[ci] = CGRect(x: origin.x + min(x0, x1), y: bottom, width: max(0.5, abs(x1 - x0)), height: height)
                }
                u += len
            }
        }
        return result
    }
}

extension TextExtractor {
    /// 以本 actor 自己的文件實例計算疊加樣式（背景取樣需要渲染頁面，不可在主執行緒的文件上做）。
    public func overlayStyles(pageIndex: Int, items: [OverlayItem],
                              fontFamily: String) -> (geometry: PageGeometry, styles: [OverlayStyle])? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        return (geometry, OverlayRenderer.styles(items: items, geometry: geometry, page: page, fontFamily: fontFamily))
    }
}
