import SwiftUI
import AppKit

// MARK: - 工具列外觀元件
// 上方工具列的按鈕、選單標籤、分隔線：平時沒有底色、滑過淡淡一層，選取中只用中性灰底。

struct BarDivider: View {
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.13))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }
}

/// 工具列圖示：統一大小，排起來才整齊。
struct BarIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13.5))
            .frame(width: 18, height: 18)
    }
}

/// 工具列按鈕：平時沒有底色，滑過淡淡一層；「選取中」只用一層中性灰底，不用強調色，免得太搶眼。
struct BarButtonStyle: ButtonStyle {
    var isOn = false
    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(configuration: configuration, isOn: isOn)
    }
}

private struct BarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(isEnabled ? (isOn ? 0.95 : 0.78) : 0.3))
            .padding(.horizontal, 5)
            .frame(minWidth: 28, minHeight: 28)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: isOn)
    }

    private var fill: Color {
        if isOn { return Color.primary.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.16 : 0.12)) }
        if configuration.isPressed { return Color.primary.opacity(0.15) }
        return hovering ? Color.primary.opacity(0.08) : .clear
    }
}

/// 選單按鈕的外觀（Menu 的標籤用）：與 BarButtonStyle 相同的滑過效果。
struct BarMenuLabel: ViewModifier {
    var horizontalPadding: CGFloat = 5
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.primary.opacity(0.82))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 28)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// 統一的工具列選單樣式：不顯示系統箭頭，標籤完全自訂。
    func barMenuStyle() -> some View {
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// 分離式按鈕旁邊的小箭頭（打開該功能的選單）。
struct BarChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .frame(width: 10, height: 18)
            .modifier(BarMenuLabel(horizontalPadding: 2))
    }
}
