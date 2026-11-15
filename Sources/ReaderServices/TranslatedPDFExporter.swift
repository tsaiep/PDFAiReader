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
        case .inPlace: return "原位翻譯（覆蓋原文，保留圖片與版面）"
        case .interleaved: return "對照（原頁＋譯文頁交錯）"
        case .translationOnly: return "純譯文"
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
        case .cannotOpenSource: return "無法開啟原始 PDF"
        case .cannotCreateOutput: return "無法建立輸出檔案"
        case .cancelled: return "已取消匯出"
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
                let sampler = hasTranslation ? BackgroundSampler(page: page, geometry: geometry) : nil
                drawOriginal(ctx: ctx, pageRef: pageRef, geometry: geometry) {
                    overlay(ctx: ctx, blocks: blocks, geometry: geometry, sampler: sampler)
                }
            case .interleaved:
                drawOriginal(ctx: ctx, pageRef: pageRef, geometry: geometry) {}
                if hasTranslation {
                    drawTranslationPages(ctx: ctx, size: geometry.displaySize, pageLabel: page.label ?? "\(index + 1)",
                                         blocks: blocks)
                }
            case .translationOnly:
                if hasTranslation {
                    drawTranslationPages(ctx: ctx, size: geometry.displaySize, pageLabel: page.label ?? "\(index + 1)",
                                         blocks: blocks)
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

    static func overlay(ctx: CGContext, blocks: [ExportBlock], geometry: PageGeometry, sampler: BackgroundSampler? = nil) {
        let items: [(rect: CGRect, block: ExportBlock, text: String)] = blocks.compactMap { b in
            guard let t = b.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let r = geometry.toDisplay(b.bounds.cgRect).insetBy(dx: -1.5, dy: -1.5)
            return (r, b, t)
        }
        guard !items.isEmpty else { return }

        // 第一輪：每個區塊可容納的最大字級
        let fits = items.map { item in
            bestFontSize(text: item.text, kind: item.block.kind, rect: item.rect,
                         maxSize: item.block.kind == .heading ? 40 : 20)
        }
        // 內文字級統一：取內文區塊的中位數為上限，避免中文較短時字級忽大忽小
        let bodySizes = zip(items, fits).filter { $0.0.block.kind == .paragraph }.map(\.1).sorted()
        let bodyCap = bodySizes.isEmpty ? 20 : bodySizes[bodySizes.count / 2]

        for (item, fit) in zip(items, fits) {
            var size = fit
            if item.block.kind == .paragraph || item.block.kind == .footnote || item.block.kind == .caption {
                size = min(fit, item.block.kind == .paragraph ? bodyCap : bodyCap * 0.9)
            }
            let bg = sampler?.color(around: item.rect) ?? (1, 1, 1)
            let luminance = 0.299 * bg.0 + 0.587 * bg.1 + 0.114 * bg.2
            let ink = luminance > 0.5 ? CGColor(gray: 0.06, alpha: 1) : CGColor(gray: 0.97, alpha: 1)
            ctx.saveGState()
            // 取樣是在 sRGB 點陣上做的，填色也必須用 sRGB，否則會出現淡淡的色差方框
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            ctx.setFillColor(CGColor(colorSpace: srgb, components: [bg.0, bg.1, bg.2, 1])
                             ?? CGColor(red: bg.0, green: bg.1, blue: bg.2, alpha: 1))
            ctx.fill(item.rect)
            drawText(ctx: ctx, text: item.text, kind: item.block.kind, size: size, rect: item.rect, color: ink)
            ctx.restoreGState()
        }
    }

    static func bestFontSize(text: String, kind: BlockKind, rect: CGRect, maxSize: CGFloat) -> CGFloat {
        var lo: CGFloat = 3, hi = max(3, min(maxSize, rect.height))
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            let attr = attributed(text, kind: kind, size: mid)
            let fs = CTFramesetterCreateWithAttributedString(attr)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: 0, length: 0), nil,
                CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            if suggested.height <= rect.height { lo = mid } else { hi = mid }
        }
        return lo
    }

    static func drawText(ctx: CGContext, text: String, kind: BlockKind, size: CGFloat, rect: CGRect,
                         color: CGColor = CGColor(gray: 0.06, alpha: 1)) {
        let attr = attributed(text, kind: kind, size: size, color: color)
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
    }

    static func font(kind: BlockKind, size: CGFloat) -> CTFont {
        let name = kind == .heading ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    static func attributed(_ text: String, kind: BlockKind, size: CGFloat,
                           color: CGColor = CGColor(gray: 0.05, alpha: 1),
                           paragraphSpacing: CGFloat = 0) -> CFAttributedString {
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
            kCTFontAttributeName: font(kind: kind, size: size),
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: style,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
    }

    // MARK: - 譯文頁

    static func drawTranslationPages(ctx: CGContext, size: CGSize, pageLabel: String, blocks: [ExportBlock]) {
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
            let a = attributed(text + "\n", kind: kind, size: size, color: color, paragraphSpacing: base * 0.7)
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
            let header = continuation == 0 ? "第 \(pageLabel) 頁　譯文" : "第 \(pageLabel) 頁　譯文（續）"
            let headerAttr = attributed(header, kind: .other, size: base * 0.8, color: CGColor(gray: 0.55, alpha: 1))
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
