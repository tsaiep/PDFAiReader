import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ReaderCore

public enum ExportMode: String, CaseIterable, Sendable, Identifiable {
    /// 在原頁面上以譯文覆蓋原文區塊，保留圖片與版面。
    case inPlace
    /// 每一頁原文後面接一頁譯文。
    case interleaved
    /// 只有譯文頁。
    case translationOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inPlace: return CoreStrings.L("原位翻譯（覆蓋原文，保留圖片與版面）", "In place (replace text, keep images and layout)")
        case .interleaved: return CoreStrings.L("對照（原頁＋譯文頁交錯）", "Bilingual (original page followed by translation)")
        case .translationOnly: return CoreStrings.L("純譯文", "Translation only")
        }
    }
}

public struct ExportBlock: Sendable {
    public var kind: BlockKind
    public var bounds: PageRect
    public var original: String
    public var translation: String?

    public init(kind: BlockKind, bounds: PageRect, original: String, translation: String?) {
        self.kind = kind
        self.bounds = bounds
        self.original = original
        self.translation = translation
    }
}

public struct ExportSummary: Sendable {
    public var pageCount: Int
    public var translatedPages: Int
    public var outputURL: URL
}

public enum ExportError: Error, LocalizedError {
    case cannotOpenSource
    case cannotCreateOutput
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotOpenSource: return CoreStrings.L("無法開啟原始 PDF", "Cannot open the original PDF")
        case .cannotCreateOutput: return CoreStrings.L("無法建立輸出檔案", "Cannot create the output file")
        case .cancelled: return CoreStrings.L("已取消匯出", "Export cancelled")
        }
    }
}

/// 產生翻譯版 PDF。原頁面以 PDF 形式嵌入（不重新點陣化），文字以 CoreText 繪製。
public enum TranslatedPDFExporter {
    public static func export(source: URL,
                              destination: URL,
                              mode: ExportMode,
                              pageRange: ClosedRange<Int>? = nil,
                              blocksByPage: [Int: [ExportBlock]],
                              fontFamily: String = TargetLanguage.zhHantTW.defaultFont,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in },
                              isCancelled: @Sendable () -> Bool = { false }) throws -> ExportSummary {
        guard let doc = PDFDocument(url: source) else { throw ExportError.cannotOpenSource }
        if doc.isLocked { _ = doc.unlock(withPassword: "") }
        let range = pageRange ?? 0...max(0, doc.pageCount - 1)

        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).pdf")
        guard let ctx = CGContext(tmp as CFURL, mediaBox: nil, [
            kCGPDFContextCreator: "AI PDF Reader",
            kCGPDFContextTitle: (destination.deletingPathExtension().lastPathComponent as CFString),
        ] as CFDictionary) else { throw ExportError.cannotCreateOutput }

        var translatedPages = 0
        let total = range.count
        var done = 0
        for index in range {
            if isCancelled() {
                ctx.closePDF()
                try? FileManager.default.removeItem(at: tmp)
                throw ExportError.cancelled
            }
            guard let page = doc.page(at: index), let pageRef = page.pageRef else { continue }
            let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
            let blocks = blocksByPage[index] ?? []
            let hasTranslation = blocks.contains { $0.translation?.isEmpty == false }
            if hasTranslation { translatedPages += 1 }

            switch mode {
            case .inPlace:
                drawOriginal(ctx: ctx, pageRef: pageRef, geometry: geometry) {
                    overlay(ctx: ctx, blocks: blocks, geometry: geometry, page: page, fontFamily: fontFamily)
                }
            case .interleaved:
                drawOriginal(ctx: ctx, pageRef: pageRef, geometry: geometry) {}
                if hasTranslation {
                    drawTranslationPages(ctx: ctx, size: geometry.displaySize, pageLabel: page.label ?? "\(index + 1)",
                                         blocks: blocks, fontFamily: fontFamily)
                }
            case .translationOnly:
                if hasTranslation {
                    drawTranslationPages(ctx: ctx, size: geometry.displaySize, pageLabel: page.label ?? "\(index + 1)",
                                         blocks: blocks, fontFamily: fontFamily)
                }
            }
            done += 1
            progress(done, total)
        }
        ctx.closePDF()

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
        return ExportSummary(pageCount: total, translatedPages: translatedPages, outputURL: destination)
    }

    // MARK: - 原頁

    private static func drawOriginal(ctx: CGContext, pageRef: CGPDFPage, geometry: PageGeometry,
                                     overlay: () -> Void) {
        var box = CGRect(origin: .zero, size: geometry.displaySize)
        let info = [kCGPDFContextMediaBox: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
        ctx.beginPDFPage(info)
        ctx.saveGState()
        ctx.concatenate(geometry.pageToDisplay)
        ctx.drawPDFPage(pageRef)
        ctx.restoreGState()
        overlay()
        ctx.endPDFPage()
    }

    // MARK: - 原位覆蓋

    /// 原位覆蓋：與閱讀器畫面上的譯文疊加使用同一套排版（OverlayRenderer）。
    static func overlay(ctx: CGContext, blocks: [ExportBlock], geometry: PageGeometry, page: PDFPage?, fontFamily: String) {
        let items = blocks.compactMap { b -> OverlayItem? in
            guard let t = b.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return OverlayItem(bounds: b.bounds, kind: b.kind, text: t)
        }
        guard !items.isEmpty else { return }
        let styles = OverlayRenderer.styles(items: items, geometry: geometry, page: page, fontFamily: fontFamily)
        for (item, style) in zip(items, styles) {
            OverlayRenderer.draw(ctx, item: item, style: style,
                                 rect: OverlayRenderer.displayRect(item.bounds, geometry: geometry))
        }
    }

    static func bestFontSize(text: String, kind: BlockKind, rect: CGRect, maxSize: CGFloat,
                             family: String = TargetLanguage.zhHantTW.defaultFont) -> CGFloat {
        var lo: CGFloat = 3, hi = max(3, min(maxSize, rect.height))
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            let attr = attributed(text, kind: kind, size: mid, family: family)
            let fs = CTFramesetterCreateWithAttributedString(attr)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: 0, length: 0), nil,
                CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            if suggested.height <= rect.height { lo = mid } else { hi = mid }
        }
        return lo
    }

    static func drawText(ctx: CGContext, text: String, kind: BlockKind, size: CGFloat, rect: CGRect,
                         color: CGColor = CGColor(gray: 0.06, alpha: 1),
                         family: String = TargetLanguage.zhHantTW.defaultFont) {
        let attr = attributed(text, kind: kind, size: size, color: color, family: family)
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
    }

    /// 以字體家族建立字型；標題使用粗體（該字體無粗體時維持原字重）。
    static func font(kind: BlockKind, size: CGFloat, family: String) -> CTFont {
        let base = CTFontCreateWithName(family as CFString, size, nil)
        guard kind == .heading else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    }

    static func attributed(_ text: String, kind: BlockKind, size: CGFloat,
                           color: CGColor = CGColor(gray: 0.05, alpha: 1),
                           paragraphSpacing: CGFloat = 0,
                           family: String = TargetLanguage.zhHantTW.defaultFont) -> CFAttributedString {
        var lineHeight = size * 1.25
        var spacing = paragraphSpacing
        let style: CTParagraphStyle = withUnsafeBytes(of: &lineHeight) { lh in
            withUnsafeBytes(of: &spacing) { sp in
                let settings = [
                    CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: lh.baseAddress!),
                    CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: lh.baseAddress!),
                    CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: sp.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font(kind: kind, size: size, family: family),
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: style,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
    }

    // MARK: - 譯文頁

    static func drawTranslationPages(ctx: CGContext, size: CGSize, pageLabel: String, blocks: [ExportBlock],
                                     fontFamily: String = TargetLanguage.zhHantTW.defaultFont) {
        let margin = max(28, min(size.width, size.height) * 0.08)
        let body = CFAttributedStringCreateMutable(nil, 0)!
        let base: CGFloat = min(12, max(9, size.width / 50))

        func append(_ text: String, kind: BlockKind) {
            let size: CGFloat
            let color: CGColor
            switch kind {
            case .heading: size = base * 1.35; color = CGColor(gray: 0.05, alpha: 1)
            case .caption, .footnote: size = base * 0.85; color = CGColor(gray: 0.35, alpha: 1)
            default: size = base; color = CGColor(gray: 0.08, alpha: 1)
            }
            let a = attributed(text + "\n", kind: kind, size: size, color: color, paragraphSpacing: base * 0.7,
                               family: fontFamily)
            CFAttributedStringReplaceAttributedString(body, CFRange(location: CFAttributedStringGetLength(body), length: 0), a)
        }
        for b in blocks {
            if let t = b.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                append(t, kind: b.kind)
            }
        }
        let fs = CTFramesetterCreateWithAttributedString(body)
        let length = CFAttributedStringGetLength(body)
        var location = 0
        var continuation = 0
        repeat {
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            // 頁首
            let header = continuation == 0 ? CoreStrings.L("第 \(pageLabel) 頁　譯文", "Page \(pageLabel) — Translation") : CoreStrings.L("第 \(pageLabel) 頁　譯文（續）", "Page \(pageLabel) — Translation (cont.)")
            let headerAttr = attributed(header, kind: .other, size: base * 0.8, color: CGColor(gray: 0.55, alpha: 1),
                                        family: fontFamily)
            let headerFrame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(headerAttr),
                                                       CFRange(location: 0, length: 0),
                                                       CGPath(rect: CGRect(x: margin, y: size.height - margin * 0.75,
                                                                           width: size.width - 2 * margin, height: base * 1.4),
                                                              transform: nil), nil)
            ctx.textMatrix = .identity
            CTFrameDraw(headerFrame, ctx)

            let rect = CGRect(x: margin, y: margin, width: size.width - 2 * margin,
                              height: size.height - margin * 2 - base * 0.8)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: location, length: 0),
                                                 CGPath(rect: rect, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            location += visible.length
            continuation += 1
        } while location < length && continuation < 20
    }
}

/// 取樣文字區塊周圍的紙色，讓覆蓋框與掃描頁背景融合。
struct BackgroundSampler {
    private let data: [UInt8]
    private let width: Int
    private let height: Int
    private let scale: CGFloat

    init?(page: PDFPage, geometry: PageGeometry) {
        let longSide: CGFloat = 900
        guard let image = TextExtractor.render(page: page, geometry: geometry, longSide: longSide) else { return nil }
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        data = buffer
        width = w
        height = h
        let size = geometry.displaySize
        scale = CGFloat(w) / max(1, size.width)
    }

    /// 回傳 (r, g, b)，0–1。取矩形外框一圈像素的中位數。
    func color(around rect: CGRect) -> (CGFloat, CGFloat, CGFloat) {
        let r = rect.insetBy(dx: -2, dy: -2)
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        func sample(_ x: CGFloat, _ y: CGFloat) {
            let px = Int(x * scale), py = height - 1 - Int(y * scale)   // 點陣資料第 0 列在上方
            guard px >= 0, px < width, py >= 0, py < height else { return }
            let i = (py * width + px) * 4
            rs.append(data[i]); gs.append(data[i + 1]); bs.append(data[i + 2])
        }
        let steps = 24
        for k in 0...steps {
            let t = CGFloat(k) / CGFloat(steps)
            sample(r.minX + t * r.width, r.minY)
            sample(r.minX + t * r.width, r.maxY)
            sample(r.minX, r.minY + t * r.height)
            sample(r.maxX, r.minY + t * r.height)
        }
        guard !rs.isEmpty else { return (1, 1, 1) }
        func med(_ a: [UInt8]) -> CGFloat { CGFloat(a.sorted()[a.count / 2]) / 255 }
        return (med(rs), med(gs), med(bs))
    }
}
