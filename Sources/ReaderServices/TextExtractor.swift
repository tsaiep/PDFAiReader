import Foundation
import PDFKit
import Vision
import CoreGraphics
import ReaderCore

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
            return TextLine(text: text, bounds: PageRect(b), confidence: 1)
        }
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
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let rect = geometry.pageRect(fromNormalized: obs.boundingBox)
            return TextLine(text: candidate.string, bounds: PageRect(rect), confidence: Double(candidate.confidence))
        }
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
