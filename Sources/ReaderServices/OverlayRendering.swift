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
}

public struct OverlayItem: Sendable {
    public var bounds: PageRect
    public var kind: BlockKind
    public var text: String

    public init(bounds: PageRect, kind: BlockKind, text: String) {
        self.bounds = bounds
        self.kind = kind
        self.text = text
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

extension TextExtractor {
    /// 以本 actor 自己的文件實例計算疊加樣式（背景取樣需要渲染頁面，不可在主執行緒的文件上做）。
    public func overlayStyles(pageIndex: Int, items: [OverlayItem],
                              fontFamily: String) -> (geometry: PageGeometry, styles: [OverlayStyle])? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        return (geometry, OverlayRenderer.styles(items: items, geometry: geometry, page: page, fontFamily: fontFamily))
    }
}
