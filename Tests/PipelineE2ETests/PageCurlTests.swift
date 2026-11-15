import XCTest
import CoreImage
import AppKit
@testable import PDFAiReaderApp

/// 翻書捲曲畫格：輸出接觸印樣（contact sheet）供檢查方向與質感，並量測每格耗時。
@MainActor
final class PageCurlTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func page(_ label: String, color: NSColor, size: CGSize) -> CIImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            (label as NSString).draw(in: rect.insetBy(dx: 0, dy: rect.height * 0.35),
                                     withAttributes: [.font: NSFont.boldSystemFont(ofSize: size.width * 0.35),
                                                      .foregroundColor: NSColor.black, .paragraphStyle: para])
            NSColor.black.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return CIImage(cgImage: cg)
    }

    func testCurlFramesContactSheet() throws {
        let size = CGSize(width: 900, height: 1275)   // 600×850 pt × 1.5
        let extent = CGRect(origin: .zero, size: size)
        let a = PageCurlController.fit(page("A", color: NSColor(calibratedRed: 1, green: 0.93, blue: 0.85, alpha: 1), size: size), to: size)
        let b = PageCurlController.fit(page("B", color: NSColor(calibratedRed: 0.85, green: 0.92, blue: 1, alpha: 1), size: size), to: size)
        let ctx = CIContext(options: [.cacheIntermediates: false])

        let forwardAngle: CGFloat = .pi - 0.18     // 與 PageCurlController 往前翻（紙張在右側）相同
        let times: [CGFloat] = [0.15, 0.35, 0.55, 0.75]
        var frames: [CGImage] = []
        for t in times {
            frames.append(try XCTUnwrap(PageCurlController.frame(front: a, target: b, extent: extent, time: t,
                                                                 angle: forwardAngle, context: ctx)))
        }
        // 往回翻：上一頁（B）為正面、時間反向
        for p in [CGFloat(0.35), 0.65] {
            frames.append(try XCTUnwrap(PageCurlController.frame(front: b, target: a, extent: extent, time: 1 - p,
                                                                 angle: forwardAngle, context: ctx)))
        }

        // 效能：連續 30 格
        let start = Date()
        for i in 0..<30 {
            _ = PageCurlController.frame(front: a, target: b, extent: extent, time: CGFloat(i) / 30,
                                         angle: forwardAngle, context: ctx)
        }
        let ms = Date().timeIntervalSince(start) / 30 * 1000
        print("捲曲每格平均 \(String(format: "%.1f", ms)) ms")
        XCTAssertLessThan(ms, 40, "每格太慢，動畫會不流暢")

        // 拼成一張圖
        let thumbW = 300, thumbH = 425
        let sheet = NSImage(size: NSSize(width: thumbW * frames.count, height: thumbH), flipped: false) { _ in
            NSColor.darkGray.setFill()
            NSRect(x: 0, y: 0, width: thumbW * frames.count, height: thumbH).fill()
            for (i, f) in frames.enumerated() {
                NSImage(cgImage: f, size: .zero).draw(in: NSRect(x: i * thumbW, y: 0, width: thumbW - 6, height: thumbH))
            }
            return true
        }
        let dir = root.appendingPathComponent(".dev/artifacts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("curl-frames.png"))
        try "\(ms)".write(to: dir.appendingPathComponent("curl-ms.txt"), atomically: true, encoding: .utf8)
    }
}
