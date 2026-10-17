import SwiftUI

/// 共用外觀：深紫到藍的漸層背景、半透明「玻璃」卡片、會發光的漸層按鈕（類似 CleanMyMac 的風格）。
/// 翻譯視窗與單字卡複習視窗都用這裡的顏色，兩邊看起來是同一個 App。
enum Theme {
    // 背景
    static let bgTop = Color(red: 0.23, green: 0.11, blue: 0.42)
    static let bgBottom = Color(red: 0.07, green: 0.10, blue: 0.30)
    static let glowPink = Color(red: 0.95, green: 0.30, blue: 0.62)
    static let glowTeal = Color(red: 0.20, green: 0.78, blue: 0.86)

    // 強調色
    static let pink = Color(red: 1.00, green: 0.38, blue: 0.64)
    static let purple = Color(red: 0.58, green: 0.38, blue: 1.00)
    static let teal = Color(red: 0.25, green: 0.85, blue: 0.85)
    static let blue = Color(red: 0.30, green: 0.55, blue: 1.00)
    static let amber = Color(red: 1.00, green: 0.75, blue: 0.30)

    static let accent = LinearGradient(colors: [pink, purple], startPoint: .leading, endPoint: .trailing)
    static let accentCool = LinearGradient(colors: [teal, blue], startPoint: .leading, endPoint: .trailing)

    // 玻璃卡片
    static let glass = Color.white.opacity(0.07)
    static let glassStrong = Color.white.opacity(0.12)
    static let glassStroke = Color.white.opacity(0.13)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// 漸層背景＋兩團柔和光暈；opacity 小於 1 時可以透出後面的毛玻璃
struct ThemeBackground: View {
    var opacity: Double = 1

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Theme.glowPink.opacity(0.45), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Theme.glowTeal.opacity(0.28), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 420)
        }
        .opacity(opacity)
        .ignoresSafeArea()
    }
}

extension View {
    /// 半透明玻璃卡片
    func glassCard(cornerRadius: CGFloat = 16, fill: Color = Theme.glass, stroke: Color = Theme.glassStroke) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }

    /// 漸層外框的玻璃卡片（強調用，例如最新一句）
    func glowCard(cornerRadius: CGFloat = 16, gradient: LinearGradient = Theme.accent, glow: Color = Theme.pink) -> some View {
        background(Theme.glassStrong, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(gradient, lineWidth: 1.5))
            .shadow(color: glow.opacity(0.35), radius: 12, y: 2)
    }
}

/// 主要按鈕：漸層膠囊、白字、發光陰影，按下時縮小一點
struct GlowButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Theme.accent
    var glow: Color = Theme.pink
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        GlowButtonBody(configuration: configuration, gradient: gradient, glow: glow, height: height)
    }

    private struct GlowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let gradient: LinearGradient
        let glow: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.rounded(15, .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(gradient, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: glow.opacity(isEnabled ? 0.55 : 0), radius: configuration.isPressed ? 4 : 12, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}

/// 次要按鈕：玻璃膠囊
struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(13, .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .background(Color.white.opacity(configuration.isPressed ? 0.20 : 0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// 小圓形圖示按鈕（翻譯視窗上方工具列）
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, size: size)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
                .frame(width: size, height: size)
                .background(Color.white.opacity(configuration.isPressed ? 0.25 : hover ? 0.16 : 0.08), in: Circle())
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Circle())
                .onHover { hover = $0 }
        }
    }
}

/// 漸層進度條
struct GradientProgressBar: View {
    var value: Double  // 0...1

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(Theme.accent)
                    .frame(width: max(6, g.size.width * min(1, max(0, value))))
                    .shadow(color: Theme.pink.opacity(0.6), radius: 6)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

/// 小膠囊標籤
struct TagPill: View {
    let text: String
    var color: Color = Theme.purple

    var body: some View {
        Text(text)
            .font(Theme.rounded(11, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1))
    }
}
