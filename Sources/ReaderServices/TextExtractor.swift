import Foundation
import AppKit
import PDFKit
import Vision
import CoreGraphics
import ReaderCore

/// 文字層的一個字元。
public struct LayoutChar: Sendable {
    public var char: Character
    public var rect: CGRect
    public var source: Int
}

public struct ExtractedPage: Sendable {
    public var pageIndex: Int
    public var geometry: PageGeometry
    public var source: TextSource
    public var lines: [TextLine]
    public var meanConfidence: Double
    public var blocks: [TextBlock]
    public var duration: TimeInterval
}

public enum TextExtractionError: Error, LocalizedError {
    case cannotOpenDocument
    case pageOutOfRange(Int)
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .cannotOpenDocument: return CoreStrings.L("無法開啟文件進行文字辨識", "Cannot open the document for text recognition")
        case .pageOutOfRange(let i): return CoreStrings.L("頁碼超出範圍：\(i + 1)", "Page out of range: \(i + 1)")
        case .renderFailed: return CoreStrings.L("頁面渲染失敗", "Failed to render page")
        }
    }
}

/// 從 PDF 頁面取得文字：優先使用內嵌文字層，品質不佳或不存在時以 Apple Vision OCR。
///
/// PDFDocument 非執行緒安全，因此本類別自行開啟一個獨立的文件實例，並以 actor 序列化存取。
public actor TextExtractor {
    let document: PDFDocument
    private let documentID: String
    private let analyzer = LayoutAnalyzer()

    /// OCR 渲染時影像長邊像素。
    public var renderLongSide: CGFloat = 2400

    public init(url: URL, documentID: String) throws {
        guard let doc = PDFDocument(url: url) else { throw TextExtractionError.cannotOpenDocument }
        if doc.isLocked { _ = doc.unlock(withPassword: "") }
        self.document = doc
        self.documentID = documentID
    }

    public var pageCount: Int { document.pageCount }

    public func extract(pageIndex: Int, forceOCR: Bool = false) throws -> ExtractedPage {
        let start = Date()
        guard let page = document.page(at: pageIndex) else { throw TextExtractionError.pageOutOfRange(pageIndex) }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)

        var source: TextSource = .embedded
        var lines: [TextLine] = []
        if !forceOCR, Self.hasUsableTextLayer(page) {
            lines = Self.embeddedLines(page: page, cropBox: geometry.cropBox)
        }
        if lines.isEmpty {
            source = .ocr
            lines = try ocrLines(page: page, geometry: geometry)
        }

        let mean = lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
        let result = analyzer.analyze(lines: lines, pageBounds: PageRect(geometry.cropBox),
                                      documentID: documentID, pageIndex: pageIndex, source: source)
        return ExtractedPage(pageIndex: pageIndex, geometry: geometry, source: source, lines: lines,
                             meanConfidence: mean, blocks: result.blocks,
                             duration: Date().timeIntervalSince(start))
    }

    /// 掃描頁選取文字用的 OCR 文字行（顯示空間）。有可用文字層的頁面回傳 nil（交給 PDFKit 選取）。
    public func scanLines(pageIndex: Int) throws -> [TextLine]? {
        guard let page = document.page(at: pageIndex) else { throw TextExtractionError.pageOutOfRange(pageIndex) }
        if Self.hasUsableTextLayer(page) { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        return try ocrLines(page: page, geometry: geometry).map { line in
            var l = line
            l.bounds = PageRect(geometry.toDisplay(CGRect(x: line.bounds.x, y: line.bounds.y,
                                                          width: line.bounds.width, height: line.bounds.height)))
            return l
        }
    }

    public static func pageHasTextLayer(_ page: PDFPage) -> Bool { hasUsableTextLayer(page) }

    /// 文字層每個字元的位置（顯示空間）與在 `page.string` 中的索引；沒有可用文字層時回傳 nil。
    /// 在本 actor 自己的文件實例上計算，不佔用主執行緒（逐字取位置一頁可能要數百毫秒）。
    public func textLayerChars(pageIndex: Int) -> [LayoutChar]? {
        guard let page = document.page(at: pageIndex), Self.hasUsableTextLayer(page),
              let string = page.string as NSString?, string.length > 0 else { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        var out: [LayoutChar] = []
        out.reserveCapacity(string.length)
        var i = 0
        while i < string.length {
            let r = string.rangeOfComposedCharacterSequence(at: i)
            i = r.location + r.length
            guard let c = string.substring(with: r).first, !c.isNewline else { continue }
            // 以選取取得字元位置：索引與 page.string 一致（characterBounds 的索引在部分 PDF 會錯位）
            guard let b = page.selection(for: r)?.bounds(for: page), b.width > 0, b.height > 0 else { continue }
            out.append(LayoutChar(char: c, rect: geometry.toDisplay(b), source: r.location))
        }
        return out
    }

    // MARK: - 內嵌文字層

    static func hasUsableTextLayer(_ page: PDFPage) -> Bool {
        guard let text = page.string else { return false }
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard scalars.count >= 20 else { return false }
        let letters = scalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.count
        // 亂碼（字型對應錯誤）通常字母比例很低
        return Double(letters) / Double(scalars.count) >= 0.6
    }

    static func embeddedLines(page: PDFPage, cropBox: CGRect) -> [TextLine] {
        guard let selection = page.selection(for: cropBox) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let b = line.bounds(for: page)
            guard b.width > 0, b.height > 0 else { return nil }
            return TextLine(text: text, bounds: PageRect(b), confidence: 1, isBold: isBoldFont(line))
        }
    }

    /// 內嵌文字：多數字元使用粗體字型即視為粗體。
    static func isBoldFont(_ selection: PDFSelection) -> Bool {
        guard let attributed = selection.attributedString, attributed.length > 0 else { return false }
        var bold = 0, total = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            let count = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            guard count > 0 else { return }
            total += count
            guard let font = value as? NSFont else { return }
            let name = font.fontName.lowercased()
            if font.fontDescriptor.symbolicTraits.contains(.bold)
                || ["bold", "black", "heavy", "semibold", "demi"].contains(where: { name.contains($0) }) {
                bold += count
            }
        }
        return total > 0 && Double(bold) / Double(total) > 0.6
    }

    // MARK: - OCR

    func ocrLines(page: PDFPage, geometry: PageGeometry) throws -> [TextLine] {
        guard let image = Self.render(page: page, geometry: geometry, longSide: renderLongSide) else {
            throw TextExtractionError.renderFailed
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        var lines: [TextLine] = []
        var densities: [Double] = []
        let ink = InkSampler(image: image)
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let rect = geometry.pageRect(fromNormalized: obs.boundingBox)
            lines.append(TextLine(text: candidate.string, bounds: PageRect(rect), confidence: Double(candidate.confidence)))
            densities.append(ink?.density(normalized: obs.boundingBox) ?? 0)
        }
        // 掃描頁：墨水濃度明顯高於同頁中位數的行視為粗體
        let valid = densities.filter { $0 > 0 }.sorted()
        if valid.count >= 4 {
            let median = valid[valid.count / 2]
            for i in lines.indices where densities[i] > median * 1.3 && lines[i].text.count >= 2 {
                lines[i].isBold = true
            }
        }
        return lines
    }

    /// 以顯示方向（套用旋轉）渲染頁面，白底。
    public static func render(page: PDFPage, geometry: PageGeometry, longSide: CGFloat) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let size = geometry.displaySize
        let scale = max(1, min(6, longSide / max(size.width, size.height)))
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(geometry.pageToDisplay)
        ctx.drawPDFPage(pageRef)
        return ctx.makeImage()
    }
}

/// 估計文字行的墨水濃度（深色像素比例），用來判斷掃描頁上的粗體。
struct InkSampler {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int

    init?(image: CGImage) {
        // 縮小到長邊約 1200 px 的灰階圖，足以判斷筆畫粗細
        let scale = min(1, 1200 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var buffer = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        pixels = buffer
        width = w
        height = h
    }

    /// Vision 正規化座標（原點左下）範圍內，深色像素佔比。
    func density(normalized r: CGRect) -> Double {
        // 只取中間 60% 高度，避開上下行的筆畫
        let x0 = max(0, Int(r.minX * Double(width))), x1 = min(width, Int(r.maxX * Double(width)))
        let yTop = r.maxY - r.height * 0.2, yBottom = r.minY + r.height * 0.2
        let row0 = max(0, Int((1 - yTop) * Double(height))), row1 = min(height, Int((1 - yBottom) * Double(height)))
        guard x1 > x0, row1 > row0 else { return 0 }
        var dark = 0, total = 0
        let step = max(1, (x1 - x0) / 400)
        for y in row0..<row1 {
            var x = x0
            while x < x1 {
                if pixels[y * width + x] < 110 { dark += 1 }
                total += 1
                x += step
            }
        }
        return total > 0 ? Double(dark) / Double(total) : 0
    }
}
