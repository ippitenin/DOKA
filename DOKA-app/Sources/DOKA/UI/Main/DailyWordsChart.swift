import SwiftUI

/// Одна точка 30-дневного тренда: дата суток и число надиктованных слов.
struct DashboardBar: Identifiable {
    let date: Date
    let words: Int
    var id: Date { date }
}

/// 30-дневный бар-график «слова в день» на `Canvas` (без Swift Charts, как
/// волны рекордера). Статичный — без анимаций, дружит с Reduce Motion.
/// При наведении остальные столбики приглушаются и всплывает мини-подсказка.
struct DailyWordsChart: View {
    let bars: [DashboardBar]
    @State private var hoverIndex: Int? = nil

    private var maxWords: Int { max(1, bars.map(\.words).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let count = max(bars.count, 1)
                let slot = width / CGFloat(count)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let barWidth = min(10, slot * 0.62)
                        for (i, bar) in bars.enumerated() {
                            let h = max(2, CGFloat(bar.words) / CGFloat(maxWords) * size.height)
                            let x = slot * (CGFloat(i) + 0.5) - barWidth / 2
                            let rect = CGRect(x: x, y: size.height - h, width: barWidth, height: h)
                            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous)
                            let shading = GraphicsContext.Shading.linearGradient(
                                Gradient(colors: [DS.accent, DS.accent.opacity(0.5)]),
                                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                            )
                            ctx.opacity = (hoverIndex == nil || hoverIndex == i) ? 1 : 0.35
                            ctx.fill(path, with: shading)
                        }
                    }
                    if let i = hoverIndex, bars.indices.contains(i) {
                        tooltip(for: bars[i])
                            .offset(x: min(max(0, slot * CGFloat(i) - 28), max(0, width - 96)))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase, point.x >= 0, point.x <= width, slot > 0 {
                        hoverIndex = min(bars.count - 1, max(0, Int(point.x / slot)))
                    } else {
                        hoverIndex = nil
                    }
                }
            }
            .frame(height: 104)
            axis
        }
    }

    private func tooltip(for bar: DashboardBar) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(bar.date.formatted(.dateTime.day().month(.abbreviated)))
            Text(L("dashboard.trend.words", bar.words)).foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .allowsHitTesting(false)
    }

    private var axis: some View {
        HStack {
            Text(L("dashboard.trend.start"))
            Spacer()
            Text(L("dashboard.trend.today"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
