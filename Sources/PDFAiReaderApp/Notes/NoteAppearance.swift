import AppKit
import SwiftUI
import ReaderCore

private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: - 便利貼顏色

extension NoteColor {
    /// 紙張顏色（淺色系偏柔和、低飽和；石墨為深色）。
    var fill: NSColor {
        switch self {
        case .butter: return rgb(0xFFF3B4)
        case .peach: return rgb(0xFFDDCC)
        case .mint: return rgb(0xD5F0DC)
        case .sky: return rgb(0xD7E8FA)
        case .lavender: return rgb(0xE7DEF7)
        case .graphite: return rgb(0x3B4048)
        }
    }

    /// 頂端拖曳列的顏色（比紙張略深）。
    var header: NSColor {
        switch self {
        case .butter: return rgb(0xF8E38C)
        case .peach: return rgb(0xF8C7AF)
        case .mint: return rgb(0xB8E3C5)
        case .sky: return rgb(0xBBD6F2)
        case .lavender: return rgb(0xD3C5EE)
        case .graphite: return rgb(0x2D3138)
        }
    }

    var text: NSColor { isDark ? rgb(0xF5F6F7) : rgb(0x2E2B24) }
    var secondaryText: NSColor { isDark ? rgb(0xFFFFFF, 0.55) : rgb(0x2E2B24, 0.45) }
    var border: NSColor { isDark ? rgb(0x000000, 0.35) : rgb(0x000000, 0.10) }

    var swatch: Color { Color(nsColor: fill) }
    var swatchBorder: Color { Color(nsColor: isDark ? rgb(0x000000, 0.4) : rgb(0x000000, 0.15)) }

    var localizedName: String {
        switch self {
        case .butter: return L("奶油黃", "Butter")
        case .peach: return L("蜜桃", "Peach")
        case .mint: return L("薄荷", "Mint")
        case .sky: return L("天藍", "Sky")
        case .lavender: return L("薰衣草", "Lavender")
        case .graphite: return L("石墨", "Graphite")
        }
    }
}

// MARK: - 螢光筆顏色

extension HighlightColor {
    /// 螢光色（在頁面上以色彩增值混合，文字仍清楚）。
    var ink: NSColor {
        switch self {
        case .yellow: return rgb(0xFFE81F)
        case .red: return rgb(0xFF5C7C)
        case .blue: return rgb(0x45C4FF)
        }
    }

    /// PDFView 的 highlight 註解顏色。
    var annotationColor: NSColor { ink.withAlphaComponent(0.55) }

    var localizedName: String {
        switch self {
        case .yellow: return L("螢光黃", "Yellow")
        case .red: return L("螢光紅", "Red")
        case .blue: return L("螢光藍", "Blue")
        }
    }

    /// 選單與工具列用的色塊圖示（不受系統模板色影響）。
    func swatchImage(size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            self.ink.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 工具列的螢光筆圖示：筆的符號＋下方顏色條。
    func toolbarImage(active: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: active ? .semibold : .regular)
            if let symbol = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let tint = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    (active ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.85)).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let s = symbol.size
                tint.draw(in: NSRect(x: (rect.width - s.width) / 2, y: 4 + (rect.height - 4 - s.height) / 2,
                                     width: s.width, height: s.height))
            }
            let bar = NSBezierPath(roundedRect: NSRect(x: 3, y: 0.5, width: rect.width - 6, height: 3),
                                   xRadius: 1.5, yRadius: 1.5)
            self.ink.setFill()
            bar.fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - 字體

enum NoteFonts {
    /// 便利貼可選字體；空字串＝系統字體。只列出已安裝的。
    static let all: [FontChoice] = [
        .init("", "系統字體", "System"),
        .init("Yuanti TC", "圓體", "Yuanti"),
        .init("Songti TC", "宋體", "Songti"),
        .init("Kaiti TC", "楷體", "Kaiti"),
        .init("Hannotate TC", "手札體", "Hannotate"),
        .init("Libian TC", "隸變", "Libian"),
        .init("Menlo", "等寬", "Monospaced"),
    ]

    static var installed: [FontChoice] {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return all.filter { $0.family.isEmpty || families.contains($0.family) }
    }

    static let sizes: [(value: Double, zh: String, en: String)] = [(10, "小", "S"), (12, "中", "M"), (14, "大", "L")]

    static func font(family: String, size: CGFloat, bold: Bool = false) -> NSFont {
        if !family.isEmpty {
            let manager = NSFontManager.shared
            if bold, let members = manager.availableMembers(ofFontFamily: family) {
                // 取最接近半粗體的字重
                let best = members.compactMap { m -> (String, Int)? in
                    guard let name = m.first as? String, let weight = m[2] as? Int else { return nil }
                    return (name, weight)
                }.filter { $0.1 >= 6 }.min { abs($0.1 - 8) < abs($1.1 - 8) }
                if let best, let f = NSFont(name: best.0, size: size) { return f }
            }
            if let f = manager.font(withFamily: family, traits: [], weight: 5, size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
}

// MARK: - 版面（視圖與翻頁影像共用，確保一致）

/// 便利貼的版面計算。所有數值都是「未縮放」的頁面點數。
enum StickyNoteLayout {
    static let padding: CGFloat = 9
    static let stripHeight: CGFloat = 18
    static let cornerRadius: CGFloat = 7

    static func headerHeight(_ note: StickyNote) -> CGFloat {
        note.hasTitle ? max(22, CGFloat(note.fontSize) + 11) : 15
    }

    static func bodyAttributes(_ note: StickyNote) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(note.fontSize) * 0.22
        style.lineBreakMode = .byWordWrapping
        return [.font: NoteFonts.font(family: note.fontFamily, size: CGFloat(note.fontSize)),
                .foregroundColor: note.color.text, .paragraphStyle: style]
    }

    static func titleAttributes(_ note: StickyNote) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: NoteFonts.font(family: note.fontFamily, size: CGFloat(note.fontSize), bold: true),
                .foregroundColor: note.color.text, .paragraphStyle: style]
    }

    /// 內文需要的高度。
    static func textHeight(_ note: StickyNote, width: CGFloat) -> CGFloat {
        let text = note.body.isEmpty ? " " : (note.body.hasSuffix("\n") ? note.body + " " : note.body)
        let r = (text as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: bodyAttributes(note))
        return ceil(r.height)
    }

    /// 全部內容展開需要的總高度。
    static func fullHeight(_ note: StickyNote, width: CGFloat) -> CGFloat {
        headerHeight(note) + 4 + textHeight(note, width: width - padding * 2) + padding
    }

    /// 收合狀態下內容是否超出。
    static func overflows(_ note: StickyNote, width: CGFloat, height: CGFloat) -> Bool {
        fullHeight(note, width: width) > height + 0.5
    }

    /// 畫面上實際顯示的高度（展開時只往下長高，寬度不變）。
    static func displayHeight(_ note: StickyNote, width: CGFloat, baseHeight: CGFloat, growForEditing: Bool) -> CGFloat {
        guard note.expanded || growForEditing else { return baseHeight }
        let full = fullHeight(note, width: width)
        guard full > baseHeight else { return baseHeight }
        return full + (note.expanded && !growForEditing ? stripHeight - padding : 0)
    }

    enum Strip { case none, expand, collapse }

    static func strip(_ note: StickyNote, width: CGFloat, baseHeight: CGFloat, editing: Bool) -> Strip {
        if editing { return .none }
        if note.expanded { return fullHeight(note, width: width) > baseHeight + 0.5 ? .collapse : .none }
        return overflows(note, width: width, height: baseHeight) ? .expand : .none
    }

    /// 內文區域（翻轉座標，原點左上）。
    static func bodyRect(_ note: StickyNote, size: CGSize, strip: Strip) -> CGRect {
        let top = headerHeight(note) + 4
        let bottom: CGFloat = strip == .none ? padding : stripHeight
        return CGRect(x: padding, y: top, width: max(1, size.width - padding * 2),
                      height: max(1, size.height - top - bottom))
    }
}

// MARK: - 繪製（視圖與翻頁影像共用）

enum StickyNoteRenderer {
    /// 在「翻轉」的座標系（原點左上）中畫出便利貼。`includeBody` 為 false 時內文交給 NSTextView。
    static func draw(_ note: StickyNote, size: CGSize, strip: StickyNoteLayout.Strip,
                     hovering: Bool, includeBody: Bool) {
        let bounds = CGRect(origin: .zero, size: size)
        let radius = StickyNoteLayout.cornerRadius
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        note.color.fill.setFill()
        card.fill()

        // 頂端拖曳列
        let headerH = StickyNoteLayout.headerHeight(note)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        note.color.header.setFill()
        CGRect(x: 0, y: 0, width: size.width, height: headerH).fill()
        NSGraphicsContext.restoreGraphicsState()

        if note.hasTitle {
            let titleRect = CGRect(x: StickyNoteLayout.padding, y: (headerH - CGFloat(note.fontSize) * 1.25) / 2,
                                   width: size.width - StickyNoteLayout.padding * 2 - 18,
                                   height: CGFloat(note.fontSize) * 1.35)
            (note.trimmedTitle as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                 attributes: StickyNoteLayout.titleAttributes(note))
        } else if hovering {
            // 拖曳把手
            note.color.secondaryText.setFill()
            for i in -1...1 {
                NSBezierPath(ovalIn: CGRect(x: size.width / 2 + CGFloat(i) * 6 - 1.25, y: headerH / 2 - 1.25,
                                            width: 2.5, height: 2.5)).fill()
            }
        }

        if includeBody {
            let body = StickyNoteLayout.bodyRect(note, size: size, strip: strip)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: body).addClip()
            (note.body as NSString).draw(with: body, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: StickyNoteLayout.bodyAttributes(note))
            NSGraphicsContext.restoreGraphicsState()
        }

        if strip != .none {
            let h = StickyNoteLayout.stripHeight
            let stripRect = CGRect(x: 0, y: size.height - h, width: size.width, height: h)
            if strip == .expand {
                // 內文淡出到紙張顏色，暗示下面還有
                NSGraphicsContext.saveGraphicsState()
                card.addClip()
                let fade = NSGradient(starting: note.color.fill.withAlphaComponent(0), ending: note.color.fill)
                fade?.draw(in: CGRect(x: 0, y: stripRect.minY - 14, width: size.width, height: 14), angle: 90)
                note.color.fill.setFill()
                stripRect.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let label = strip == .expand ? L("展開", "More") : L("收合", "Less")
            let symbol = strip == .expand ? "chevron.down" : "chevron.up"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                        .foregroundColor: note.color.secondaryText]
            let textSize = (label as NSString).size(withAttributes: attrs)
            let iconW: CGFloat = 9
            let totalW = iconW + 3 + textSize.width
            var x = (size.width - totalW) / 2
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r)
                    note.color.secondaryText.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(x: x, y: stripRect.midY - img.size.height / 2, width: img.size.width,
                                       height: img.size.height), from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
            }
            x += iconW + 3
            (label as NSString).draw(at: CGPoint(x: x, y: stripRect.midY - textSize.height / 2), withAttributes: attrs)
        }

        note.color.border.setStroke()
        card.lineWidth = 0.75
        card.stroke()
    }

    /// 在頁面「顯示空間」（原點左下）的 CGContext 中畫出便利貼（翻頁影像用）。
    static func draw(_ note: StickyNote, in ctx: CGContext, displayRect rect: CGRect) {
        let base = CGFloat(note.rect?.height ?? Double(rect.height))
        let strip = StickyNoteLayout.strip(note, width: rect.width, baseHeight: base, editing: false)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 5, color: CGColor(gray: 0, alpha: 0.18))
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(note, size: rect.size, strip: strip, hovering: false, includeBody: true)
        ctx.endTransparencyLayer()
        NSGraphicsContext.current = previous
        ctx.restoreGState()
    }
}
