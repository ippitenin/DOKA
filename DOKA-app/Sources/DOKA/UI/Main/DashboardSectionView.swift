import SwiftUI

/// Секция «Дашборд»: статистика диктовки — сколько слов и времени надиктовано,
/// средняя скорость речи, 30-дневный тренд и (после теста скорости печати)
/// насколько пользователь быстрее и сколько времени сэкономил.
struct DashboardSectionView: View {
    @ObservedObject private var stats = StatsStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showTypingTest = false

    private var metrics: DashboardMetrics {
        DashboardMetrics(snapshot: stats.snapshot, typingSpeedWPM: settings.typingSpeedWPM)
    }

    private var bars: [DashboardBar] {
        stats.recentDays(30).map { DashboardBar(date: $0.date, words: $0.bucket.words) }
    }

    var body: some View {
        Group {
            if metrics.hasData {
                dataScroll
            } else {
                emptyLayout
            }
        }
        .sheet(isPresented: $showTypingTest) {
            TypingTestView()
        }
    }

    private var dataScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.cardPadding) {
                SectionHeader(title: L("section.dashboard"))
                    .padding(.bottom, 2)
                heroZone
                metricsGrid
                trendCard
                if metrics.hasTypingTest { retakeRow }
            }
            .padding(.horizontal, DS.Spacing.section)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
    }

    /// Пустое состояние: заголовок сверху, сообщение по центру оставшейся области.
    private var emptyLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: L("section.dashboard"))
                .padding(.bottom, 2)
            Spacer()
            emptyState
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, DS.Spacing.section)
        .padding(.top, 46)
        .padding(.bottom, 20)
    }

    // MARK: - Геро

    @ViewBuilder
    private var heroZone: some View {
        if let multiplier = metrics.speedMultiplier, let saved = metrics.timeSaved {
            heroResult(multiplier: multiplier, saved: saved)
        } else {
            heroCallout
        }
    }

    private func heroResult(multiplier: Double, saved: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("dashboard.hero.faster", formatMultiplier(multiplier)))
                .font(.system(size: 28, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("dashboard.hero.saved", formatStatDuration(saved)))
                .font(.title3)
                .foregroundStyle(DS.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassSurface(shadow: true)
    }

    private var heroCallout: some View {
        HStack(spacing: 16) {
            Image(systemName: "timer")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("dashboard.hero.callout.title")).font(.headline)
                Text(L("dashboard.hero.callout.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(L("dashboard.test.run")) { showTypingTest = true }
                .dsProminentButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(shadow: true)
    }

    // MARK: - Карточки метрик

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
            StatCard(symbol: "text.word.spacing",
                     value: groupedInt(metrics.totalWords),
                     caption: L("dashboard.metric.words"))
            StatCard(symbol: "waveform",
                     value: groupedInt(metrics.totalSessions),
                     caption: L("dashboard.metric.sessions"))
            StatCard(symbol: "gauge.medium",
                     value: "\(Int(metrics.speechWPM.rounded())) \(L("dashboard.unit.wpm"))",
                     caption: L("dashboard.metric.speechWPM"))
            StatCard(symbol: "text.alignleft",
                     value: "\(Int(metrics.avgWordsPerSession.rounded()))",
                     caption: L("dashboard.metric.avgWords"))
            StatCard(symbol: "clock",
                     value: formatStatDuration(metrics.totalDuration),
                     caption: L("dashboard.metric.totalTime"))
            if let typingTime = metrics.typingTimeSeconds {
                StatCard(symbol: "keyboard",
                         value: formatStatDuration(typingTime),
                         caption: L("dashboard.metric.typingTime"))
            } else {
                LockedTypingCard { showTypingTest = true }
            }
        }
    }

    // MARK: - 30-дневный тренд

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("dashboard.trend.title"))
                .font(.subheadline.weight(.semibold))
            DailyWordsChart(bars: bars)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.cardPadding)
        .glassSurface()
    }

    // MARK: - Повторное прохождение теста

    private var retakeRow: some View {
        HStack(spacing: 12) {
            Text(L("dashboard.test.lastResult", Int(settings.typingSpeedWPM.rounded())))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("dashboard.test.retake")) { showTypingTest = true }
                .dsGlassButton()
        }
    }

    // MARK: - Пустое состояние

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
                .dsBreathe()
            Text(L("dashboard.empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Форматирование

    /// Множитель «2,5» / «2.5» — десятичный разделитель по языку интерфейса.
    private func formatMultiplier(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.locale = .current
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// Целое с группировкой разрядов по локали («12 345»).
    private func groupedInt(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Карточка одной метрики: иконка, крупное значение, подпись. На стекле.
private struct StatCard: View {
    let symbol: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.accent)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.cardPadding)
        .glassSurface()
    }
}

/// Заблокированная карточка «Печатал бы» до прохождения теста печати: замок +
/// «скелетон» вместо значения + подсказка-CTA. Кликабельна — открывает тест.
private struct LockedTypingCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("00:00")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .redacted(reason: .placeholder)
                Text(L("dashboard.metric.typingLocked"))
                    .font(.caption)
                    .foregroundStyle(DS.accent)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.cardPadding)
            .glassSurface()
            .opacity(0.9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
