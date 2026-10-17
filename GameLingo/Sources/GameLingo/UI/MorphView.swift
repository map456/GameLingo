import SwiftUI

/// 字根拆解的色塊：[dis- 不、相反] + [appear 出現] + [-ance 狀態]
/// 字首藍、字根橘、字尾綠。
struct MorphChips: View {
    let morph: MorphInfo
    var compact = false

    var body: some View {
        if let parts = morph.parts, morph.isUseful {
            FlowRow(spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    if i > 0 {
                        Text("+").font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                    }
                    chip(p)
                }
            }
        }
    }

    private func chip(_ p: MorphInfo.Part) -> some View {
        HStack(spacing: 4) {
            Text(p.display).font(.system(size: compact ? 11 : 13, weight: .semibold))
            if !p.meaning.isEmpty {
                Text(p.meaning).font(.system(size: compact ? 10 : 12)).lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 1 : 3)
        .background(Self.color(p.type).opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Self.color(p.type).opacity(0.5), lineWidth: 1))
    }

    static func color(_ type: String) -> Color {
        switch type {
        case "prefix": return .blue
        case "suffix": return .green
        default: return .orange
        }
    }
}

/// 簡單的自動換行排列（macOS 14 沒有內建 FlowLayout）
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y + (rowH > 0 ? 0 : 0)), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
