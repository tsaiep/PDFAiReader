import AppKit
import PDFKit
import CoreImage
import QuartzCore

/// 翻頁動畫：
/// - 單頁：Core Image 頁面捲曲（柔軟、帶陰影）
/// - 雙頁：以書脊為軸，整張紙翻到對頁；紙張由多條紙條串成，翻動時自然彎曲，正面是舊頁、背面是新頁
/// 兩者都可由觸控板手勢即時驅動，放開後依進度與速度完成或回彈；鍵盤翻頁自動播放同一動畫。
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
        case flip(FlipRig)
    }

    private struct CurlState {
        var layer: CALayer
        var front: CIImage
        var target: CIImage
        var extent: CGRect
        var angle: CGFloat
        var reversedTime: Bool
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
            // 畫面上由左到右
            let screenOld = (rtl ? Array(before.reversed()) : before).map(\.page)
            let screenNew = rtl ? Array(newPages.reversed()) : newPages
            mode = makeFlip(host: hostView, forward: forward, rtl: rtl, screenOld: screenOld, screenNew: screenNew,
                            rect: rect)
        } else {
            mode = makeCurl(host: hostView, forward: forward, rtl: rtl, old: before[0].page, new: newPages[0],
                            region: rect(before[0].page))
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

    private func makeCurl(host: PageTurnHostView, forward: Bool, rtl: Bool, old: PDFPage, new: PDFPage,
                          region: CGRect) -> Mode? {
        guard region.width > 4, region.height > 4,
              let oldImage = imageForPage(old), let newImage = imageForPage(new), let root = host.layer else { return nil }
        let scale: CGFloat = 1.5
        let extent = CGRect(x: 0, y: 0, width: (region.width * scale).rounded(), height: (region.height * scale).rounded())
        let oldCI = Self.fit(CIImage(cgImage: oldImage), to: extent.size)
        let newCI = Self.fit(CIImage(cgImage: newImage), to: extent.size)
        // 從閱讀方向前方的邊緣翻起；稍微傾斜，下角先離開
        let tilt: CGFloat = 0.18
        let angle: CGFloat = (forward != rtl) ? (.pi - tilt) : tilt

        let layer = CALayer()
        layer.frame = region
        layer.contentsGravity = .resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(layer)
        CATransaction.commit()

        // 往回翻：上一頁為正面、時間反向 → 上一頁從另一側攤平蓋回來
        let state = forward
            ? CurlState(layer: layer, front: oldCI, target: newCI, extent: extent, angle: angle, reversedTime: false)
            : CurlState(layer: layer, front: newCI, target: oldCI, extent: extent, angle: angle, reversedTime: true)
        return .curl(state)
    }

    // MARK: 雙頁：整張紙繞書脊翻到對頁

    private func makeFlip(host: PageTurnHostView, forward: Bool, rtl: Bool, screenOld: [PDFPage], screenNew: [PDFPage],
                          rect: (PDFPage) -> CGRect) -> Mode? {
        guard screenOld.count == 2, screenNew.count == 2, let root = host.layer else { return nil }
        // 往前讀翻動閱讀方向前方那張：左至右 → 右頁往左翻；右至左 → 左頁往右翻
        let sheetOnRight = forward != rtl
        let sheetPage = sheetOnRight ? screenOld[1] : screenOld[0]
        let staticOld = sheetOnRight ? screenOld[0] : screenOld[1]   // 對頁（之後被翻過來的紙蓋住）
        let landing = sheetOnRight ? screenNew[0] : screenNew[1]      // 紙張背面＝落在對頁的新頁
        let revealed = sheetOnRight ? screenNew[1] : screenNew[0]     // 紙張底下露出的新頁

        let leftRect = rect(screenOld[0]), rightRect = rect(screenOld[1])
        let sheetRect = rect(sheetPage)
        guard sheetRect.width > 4,
              let front = imageForPage(sheetPage), let back = imageForPage(landing),
              let under = imageForPage(revealed), let opposite = imageForPage(staticOld) else { return nil }

        let spineX = (leftRect.maxX + rightRect.minX) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 底層：對頁（舊）＋紙張下方的新頁
        for (image, frame) in [(opposite, rect(staticOld)), (under, sheetRect)] {
            let l = CALayer()
            l.frame = frame
            l.contents = image
            l.contentsGravity = .resize
            root.addSublayer(l)
        }
        // 透視中心放在書脊
        let container = CALayer()
        container.frame = root.bounds
        let dx = spineX - root.bounds.midX, dy = sheetRect.midY - root.bounds.midY
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 2200
        container.sublayerTransform = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0), perspective),
            CATransform3DMakeTranslation(dx, dy, 0))
        let rig = FlipRig(spine: CGPoint(x: spineX, y: sheetRect.midY), sheetSize: sheetRect.size,
                          extendsRight: sheetOnRight, front: front, back: back)
        container.addSublayer(rig.root)
        root.addSublayer(container)
        CATransaction.commit()
        return .flip(rig)
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
        let full: Double
        if case .flip = s.mode { full = 0.6 } else { full = 0.45 }
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
                                   angle: c.angle, context: context) {
                c.layer.contents = cg
            }
        case .flip(let rig):
            rig.apply(progress: p)
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
                      context: CIContext) -> CGImage? {
        guard let filter = CIFilter(name: "CIPageCurlWithShadowTransition") else { return nil }
        filter.setValue(front, forKey: kCIInputImageKey)
        filter.setValue(target, forKey: kCIInputTargetImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        filter.setValue(time, forKey: kCIInputTimeKey)
        filter.setValue(angle, forKey: kCIInputAngleKey)
        // 半徑大 → 紙張彎曲較緩，看起來比較軟
        filter.setValue(extent.width * 0.22, forKey: kCIInputRadiusKey)
        filter.setValue(extent.width * 0.04, forKey: "inputShadowSize")
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

/// 雙頁翻頁的紙張：以書脊為軸，由多條紙條串成，每條相對前一條再多轉一點，
/// 翻到一半時紙張自然彎曲；翻完回到平整並落在對頁。正面是舊頁、背面是對頁的新頁。
@MainActor
final class FlipRig {
    let root = CATransformLayer()
    private var nodes: [CATransformLayer] = []
    private var frontShades: [CALayer] = []
    private var backShades: [CALayer] = []
    private let direction: CGFloat
    private let count: Int

    /// - Parameter extendsRight: 紙張在書脊右側（往左翻）為 true
    init(spine: CGPoint, sheetSize: CGSize, extendsRight: Bool, front: CGImage, back: CGImage, strips: Int = 16) {
        direction = extendsRight ? 1 : -1
        count = strips
        let w = sheetSize.width / CGFloat(strips)
        let h = sheetSize.height
        root.bounds = .zero
        root.position = spine

        var parent: CALayer = root
        for i in 0..<strips {
            let node = CATransformLayer()
            node.bounds = .zero
            node.position = i == 0 ? .zero : CGPoint(x: direction * w, y: 0)
            parent.addSublayer(node)

            // 稍微重疊避免紙條之間出現細縫
            let frame = CGRect(x: extendsRight ? 0 : -w, y: -h / 2, width: w + 0.6, height: h)
            // 正面切片：紙條在頁面上由左往右的序號
            let frontSlice = extendsRight ? i : strips - 1 - i
            // 背面切片：翻過去後落在對頁的位置
            let backSlice = extendsRight ? strips - 1 - i : i

            let f = makeStrip(frame: frame, image: front, slice: frontSlice, of: strips)
            let b = makeStrip(frame: frame, image: back, slice: backSlice, of: strips)
            b.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)

            node.addSublayer(f)
            node.addSublayer(b)
            nodes.append(node)
            frontShades.append(f.sublayers![0])
            backShades.append(b.sublayers![0])
            parent = node
        }
    }

    private func makeStrip(frame: CGRect, image: CGImage, slice: Int, of strips: Int) -> CALayer {
        let l = CALayer()
        l.frame = frame
        l.contents = image
        l.contentsGravity = .resize
        l.contentsRect = CGRect(x: CGFloat(slice) / CGFloat(strips), y: 0, width: 1 / CGFloat(strips), height: 1)
        l.isDoubleSided = false
        let shade = CALayer()
        shade.frame = l.bounds
        shade.backgroundColor = CGColor(gray: 0, alpha: 1)
        shade.opacity = 0
        l.addSublayer(shade)
        return l
    }

    /// 進度 0 = 紙張平放在原位；1 = 翻到對頁平放。
    func apply(progress p: CGFloat) {
        let base = -direction * p * .pi
        // 彎曲量：翻到一半時最大，外緣領先（像用手從邊緣掀起），頭尾回到平整
        let curve = sin(p * .pi)
        let perStrip = -direction * curve * 0.85 / CGFloat(count)
        for (i, node) in nodes.enumerated() {
            node.transform = CATransform3DMakeRotation(i == 0 ? base : perStrip, 0, 1, 0)
        }
        // 光影：正面越翻越暗；背面剛翻過來較暗、落下時變亮；彎曲處略暗增加立體感
        for i in 0..<count {
            let edge = CGFloat(i) / CGFloat(max(1, count - 1))
            frontShades[i].opacity = Float(min(0.55, p * 0.45 + curve * edge * 0.12))
            backShades[i].opacity = Float(min(0.55, (1 - p) * 0.4 + curve * (1 - edge) * 0.12))
        }
    }
}
