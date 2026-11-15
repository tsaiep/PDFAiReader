import Foundation
import CoreGraphics

/// 頁面空間（PDF user space，未旋轉、原點左下）與「顯示空間」（套用 cropBox 與 /Rotate 後、
/// 原點左下、左下角為 (0,0)）之間的轉換。OCR 渲染與匯出共用同一套轉換，確保座標一致。
public struct PageGeometry: Sendable, Equatable {
    public var cropBox: CGRect
    /// 0、90、180、270（順時針）
    public var rotation: Int

    public init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox
        let r = ((rotation % 360) + 360) % 360
        self.rotation = (r / 90) * 90
    }

    /// 顯示空間的尺寸。
    public var displaySize: CGSize {
        rotation % 180 == 0
            ? CGSize(width: cropBox.width, height: cropBox.height)
            : CGSize(width: cropBox.height, height: cropBox.width)
    }

    /// 頁面空間 → 顯示空間。
    public var pageToDisplay: CGAffineTransform {
        let cx = cropBox.minX, cy = cropBox.minY
        let w = cropBox.width, h = cropBox.height
        switch rotation {
        case 90:
            // u' = y - cy ; v' = w - (x - cx)
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -cy, ty: w + cx)
        case 180:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w + cx, ty: h + cy)
        case 270:
            // u' = h - (y - cy) ; v' = x - cx
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h + cy, ty: -cx)
        default:
            return CGAffineTransform(translationX: -cx, y: -cy)
        }
    }

    public var displayToPage: CGAffineTransform { pageToDisplay.inverted() }

    public func toDisplay(_ rect: CGRect) -> CGRect { rect.applying(pageToDisplay).standardized }
    public func toPage(_ rect: CGRect) -> CGRect { rect.applying(displayToPage).standardized }

    /// Vision 的正規化座標（相對於渲染影像，原點左下）→ 頁面空間。
    public func pageRect(fromNormalized r: CGRect) -> CGRect {
        let size = displaySize
        let display = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                             width: r.width * size.width, height: r.height * size.height)
        return toPage(display)
    }
}

extension PageRect {
    public init(_ r: CGRect) {
        self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
