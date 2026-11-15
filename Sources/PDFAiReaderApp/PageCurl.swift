import AppKit
import PDFKit
import CoreImage
import QuartzCore

/// 翻頁動畫：Core Image 頁面捲曲（柔軟、帶陰影）。
/// 單頁捲動該頁；雙頁把整個跨頁當成一張紙，從外側邊緣捲起、越過書脊，露出新的跨頁，與單頁同樣俐落。
/// 可由觸控板手勢即時驅動，放開後依進度與速度完成或回彈；鍵盤翻頁自動播放同一動畫。
@MainActor
final class PageCurlController: NSObject {
    weak var view: PDFView?
    /// 取得頁面影像（含譯文疊加）。
    var imageForPage: (PDFPage) -> CGImage? = { _ in nil }
    var isRTL: () -> Bool = { false }
    var isSpread: () -> Bool = { false }
    /// 實際切換 PDFView 頁面。
    var navigate: (Bool) -> Void = { _ in }

    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private var host: PageTurnHostView?
    private var session: Session?
    private var link: CADisplayLink?
    private var animation: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?
    private var lastRendered: CGFloat = -1

    private enum Mode {
        case curl(CurlState)
    }

    private struct CurlState {
        var layer: CALayer
        var front: CIImage
        var target: CIImage
        var extent: CGRect
        var angle: CGFloat
        var reversedTime: Bool
        var radius: CGFloat
    }

    private struct Session {
        var forward: Bool
        var mode: Mode
        var progress: CGFloat = 0
    }

    var isActive: Bool { session != nil }
    var progress: CGFloat { session?.progress ?? 0 }

    // MARK: - 開始

    /// 建立一次翻頁。回傳 false 表示無法翻（首／末頁、或此跨頁無法做動畫）。
    @discardableResult
    func begin(forward: Bool) -> Bool {
        if session != nil { finishImmediately() }
        guard let view, let document = view.document else { return false }
        guard forward ? view.canGoToNextPage : view.canGoToPreviousPage else { return false }

        let before = view.visiblePages
            .map { (page: $0, index: document.index(for: $0)) }
            .sorted { $0.index < $1.index }
        guard let first = before.first, let last = before.last else { return false }

        let rtl = isRTL()
        let spread = isSpread() && before.count == 2
        let newIndices: [Int]
        if spread {
            newIndices = (forward ? [last.index + 1, last.index + 2] : [first.index - 2, first.index - 1])
                .filter { $0 >= 0 && $0 < document.pageCount }
        } else {
            newIndices = [forward ? last.index + 1 : first.index - 1].filter { $0 >= 0 && $0 < document.pageCount }
        }
        let newPages = newIndices.compactMap { document.page(at: $0) }
        guard !newPages.isEmpty else { return false }
        // 雙頁的新跨頁只有一頁（封面、最後一頁）→ 交給呼叫端改用滑動
        if spread && newPages.count != 2 { return false }

        let hostView = PageTurnHostView(frame: view.bounds)
        hostView.autoresizingMask = [.width, .height]
        func rect(_ page: PDFPage) -> CGRect {
            hostView.convert(view.convert(page.bounds(for: view.displayBox), from: page), from: view)
        }

        let mode: Mode?
        if spread {
            // 整個跨頁合成一張圖；新跨頁沿用舊跨頁在畫面上的位置
            let oldRects = before.map { rect($0.page) }
            let union = oldRects.dropFirst().reduce(oldRects[0]) { $0.union($1) }
            let oldPairs = zip(before.map(\.page), oldRects).map { ($0, $1) }
            let newPairs = zip(newPages, oldRects).map { ($0, $1) }
            guard let oldImage = composite(oldPairs, in: union), let newImage = composite(newPairs, in: union) else {
                return false
            }
            mode = makeCurl(host: hostView, forward: forward, rtl: rtl, oldImage: oldImage, newImage: newImage,
                            region: union, sheetWidth: oldRects[0].width)
        } else {
            let region = rect(before[0].page)
            if let o = imageForPage(before[0].page), let n = imageForPage(newPages[0]) {
                mode = makeCurl(host: hostView, forward: forward, rtl: rtl, oldImage: o, newImage: n,
                                region: region, sheetWidth: region.width)
            } else {
                mode = nil
            }
        }
        guard let mode else { return false }

        view.addSubview(hostView)
        host = hostView
        session = Session(forward: forward, mode: mode)
        lastRendered = -1
        render(progress: 0)
        return true
    }

    // MARK: 單頁：Core Image 捲曲

    private func makeCurl(host: PageTurnHostView, forward: Bool, rtl: Bool, oldImage: CGImage, newImage: CGImage,
                          region: CGRect, sheetWidth: CGFloat) -> Mode? {
        guard region.width > 4, region.height > 4, let root = host.layer else { return nil }
        let scale: CGFloat = 1.5
        let extent = CGRect(x: 0, y: 0, width: (region.width * scale).rounded(), height: (region.height * scale).rounded())
        let oldCI = Self.fit(CIImage(cgImage: oldImage), to: extent.size)
        let newCI = Self.fit(CIImage(cgImage: newImage), to: extent.size)
        // 往前翻：從右緣捲起、往左移動；往回翻：從左緣捲起、往右移動（右至左閱讀時相反）。
        // 稍微傾斜，下角先離開。
        let tilt: CGFloat = 0.18
        let fromRightEdge = forward != rtl
        let angle: CGFloat = fromRightEdge ? (.pi - tilt) : tilt

        let layer = CALayer()
        layer.frame = region
        layer.contentsGravity = .resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(layer)
        CATransaction.commit()

        // 捲曲半徑以「一頁寬」為準，雙頁與單頁的紙張彎曲程度一致
        let radius = sheetWidth * scale * 0.22
        return .curl(CurlState(layer: layer, front: oldCI, target: newCI, extent: extent, angle: angle,
                               reversedTime: false, radius: radius))
    }

    /// 把數個頁面依畫面位置合成一張圖（頁面之間保持透明）。
    private func composite(_ pages: [(PDFPage, CGRect)], in union: CGRect) -> CGImage? {
        let scale: CGFloat = 1.5
        let w = Int((union.width * scale).rounded()), h = Int((union.height * scale).rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        for (page, r) in pages {
            guard let image = imageForPage(page) else { return nil }
            let dest = CGRect(x: (r.minX - union.minX) * scale, y: (r.minY - union.minY) * scale,
                              width: r.width * scale, height: r.height * scale)
            ctx.draw(image, in: dest)
        }
        return ctx.makeImage()
    }

    // MARK: - 互動

    /// 手勢進度（0 = 未翻，1 = 翻完）。
    func update(progress: CGFloat) {
        guard session != nil else { return }
        animation = nil
        render(progress: min(max(progress, 0), 1))
    }

    /// 放開手勢：依進度與速度（每秒進度）決定完成或回彈。
    func end(velocity: CGFloat) {
        guard let s = session else { return }
        let complete = velocity > -0.3 && (s.progress > 0.4 || velocity > 1.5 || (s.progress > 0.1 && velocity > 0.6))
        animate(to: complete ? 1 : 0)
    }

    /// 鍵盤或按鈕：自動播放完整翻頁。
    func play(forward: Bool) -> Bool {
        guard begin(forward: forward) else { return false }
        animate(to: 1)
        return true
    }

    // MARK: - 動畫

    private func animate(to target: CGFloat) {
        guard let s = session, let view else { return }
        let distance = abs(target - s.progress)
        // 雙頁紙張較寬，稍微放慢
        let full: Double = isSpread() ? 0.55 : 0.45
        animation = (s.progress, target, CACurrentMediaTime(), max(0.12, full * Double(distance)))
        if link == nil {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let a = animation else { return }
        let t = min(1, (CACurrentMediaTime() - a.start) / a.duration)
        // easeOutCubic：一開始快、結尾輕輕落下
        let eased = 1 - pow(1 - t, 3)
        render(progress: a.from + (a.to - a.from) * CGFloat(eased))
        if t >= 1 {
            animation = nil
            stopLink()
            if a.to >= 1 { commit() } else { cancel() }
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    // MARK: - 繪製

    private func render(progress p: CGFloat) {
        guard var s = session else { return }
        s.progress = p
        session = s
        guard abs(p - lastRendered) > 0.0005 else { return }
        lastRendered = p

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch s.mode {
        case .curl(let c):
            let time = c.reversedTime ? 1 - p : p
            if let cg = Self.frame(front: c.front, target: c.target, extent: c.extent, time: time,
                                   angle: c.angle, radius: c.radius, context: context) {
                c.layer.contents = cg
            }
        }
        CATransaction.commit()
    }

    private func commit() {
        guard let s = session else { return }
        navigate(s.forward)
        session = nil
        removeHost(afterDelay: 0.12)
    }

    private func cancel() {
        session = nil
        removeHost(afterDelay: 0)
    }

    /// 立即結束目前的翻頁（例如連續快速按鍵）。
    func finishImmediately() {
        let headingToEnd = animation?.to == 1
        stopLink()
        animation = nil
        guard let s = session else { removeHost(afterDelay: 0); return }
        session = nil
        if headingToEnd || s.progress >= 0.5 { navigate(s.forward) }
        removeHost(afterDelay: 0)
    }

    private func removeHost(afterDelay delay: Double) {
        let h = host
        host = nil
        guard let h else { return }
        if delay <= 0 {
            h.removeFromSuperview()
            return
        }
        // 讓 PDFView 先畫好新頁，再淡出覆蓋層，避免閃爍
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                h.animator().alphaValue = 0
            }, completionHandler: {
                h.removeFromSuperview()
            })
        }
    }

    // MARK: - helpers

    /// 產生一格捲曲畫面。
    static func frame(front: CIImage, target: CIImage, extent: CGRect, time: CGFloat, angle: CGFloat,
                      radius: CGFloat? = nil, context: CIContext) -> CGImage? {
        guard let filter = CIFilter(name: "CIPageCurlWithShadowTransition") else { return nil }
        filter.setValue(front, forKey: kCIInputImageKey)
        filter.setValue(target, forKey: kCIInputTargetImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        filter.setValue(time, forKey: kCIInputTimeKey)
        filter.setValue(angle, forKey: kCIInputAngleKey)
        // 半徑大 → 紙張彎曲較緩，看起來比較軟
        let r = radius ?? extent.width * 0.22
        filter.setValue(r, forKey: kCIInputRadiusKey)
        filter.setValue(r * 0.18, forKey: "inputShadowSize")
        filter.setValue(0.55, forKey: "inputShadowAmount")
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return context.createCGImage(output, from: extent)
    }

    static func fit(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height))
    }
}
