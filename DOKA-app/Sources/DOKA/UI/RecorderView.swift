import SwiftUI

/// Содержимое плавающей панели: волновая визуализация, таймер, статусы.
/// Размер и состав зависят от выбранного стиля (classic/mini).
/// Подложка — адаптивное стекло со статусным тоном:
/// запись — красный, распознавание — синий, ошибка — жёлтый.
struct RecorderView: View {
    @ObservedObject var controller: DictationController
    let style: RecorderStyle

    /// EMA-сглаженный уровень микрофона (0…1) — волна не дёргается.
    @State private var smoothedLevel: Float = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func panelSize(for style: RecorderStyle) -> CGSize {
        switch style {
        case .classic, .hidden: return CGSize(width: 320, height: 72)
        case .mini: return CGSize(width: 200, height: 44)
        // Аврора — компактная пилюля (лого · волна · таймер · esc);
        // главное — свечение экрана.
        case .aurora: return CGSize(width: 380, height: 54)
        // Студия — компактная стеклянная плашка у нижней кромки экрана:
        // волна-спектр, таймер по центру, подпись esc снизу.
        case .studio: return CGSize(width: 460, height: 104)
        // Размер нотч-панели зависит от экрана и считается
        // в RecorderPanelController; здесь — резервное значение.
        case .notch: return CGSize(width: 320, height: 72)
        }
    }

    var body: some View {
        let size = Self.panelSize(for: style)
        surfaced(
            content
                .padding(.horizontal, style == .mini ? 14 : 18)
                .frame(width: size.width, height: size.height)
        )
        .onChange(of: controller.audioLevel) { _, level in
            smoothedLevel = smoothedLevel.smoothed(toward: level, response: 0.3)
        }
    }

    /// Дискриминатор состояния: переходы играются при смене фазы,
    /// но не на каждом тике таймера или обновлении уровня.
    private var stateKey: String {
        switch controller.state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .error: return "error"
        }
    }

    @ViewBuilder
    private func surfaced(_ view: some View) -> some View {
        let tint = DS.recorderTint(for: controller.state)
        if style == .mini {
            view.glassCapsule(tint: tint)
        } else {
            view.glassSurface(radius: 24, tint: tint)
        }
    }

    private var content: some View {
        HStack(spacing: style == .mini ? 8 : 12) {
            switch controller.state {
            case .recording(let startedAt):
                if style == .mini {
                    RecordingDot(diameter: 8)
                    WaveformBars(level: smoothedLevel, tint: DS.RecorderTone.recording,
                                 barCount: 9, maxHeight: 16)
                } else {
                    // Слева время, по центру волна, справа подсказка Esc.
                    TimerText(startedAt: startedAt)
                    WaveformBars(level: smoothedLevel, tint: DS.RecorderTone.recording,
                                 barCount: 15, maxHeight: 26)
                    Text(L("recorder.escHint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .transcribing:
                // «Дыхание» волны с фиксированным уровнем вместо спиннера.
                WaveformBars(level: 0.35, tint: DS.RecorderTone.transcribing,
                             barCount: style == .mini ? 9 : 15,
                             maxHeight: style == .mini ? 16 : 26)
                if style != .mini {
                    Text(L("common.transcribing"))
                        .font(.callout)
                }
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.RecorderTone.error)
                    .symbolEffect(.bounce, value: message)
                Text(message)
                    .font(style == .mini ? .caption : .callout)
                    .lineLimit(style == .mini ? 1 : 2)
            case .idle:
                EmptyView()
            }
        }
        .id(stateKey)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(reduceMotion ? nil : DS.Anim.section, value: stateKey)
    }
}

/// Пульсирующая точка записи.
struct RecordingDot: View {
    var diameter: CGFloat = 10
    var color: Color = DS.RecorderTone.recording
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .opacity(pulse ? 0.4 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear {
                if !reduceMotion { pulse = true }
            }
    }
}

/// Волновая визуализация: капсулы с синусоидой, фазовым смещением и
/// огибающей 1−x² (центральные столбики выше); высота масштабируется уровнем.
struct WaveformBars: View {
    let level: Float
    let tint: Color
    var barCount = 15
    var maxHeight: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: 3, height: barHeight(index: index, time: t))
                }
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let half = Double(barCount - 1) / 2
        let x = (Double(index) - half) / half                       // −1…1
        let envelope = 1 - x * x                                    // центр выше
        let wave = reduceMotion ? 1 : 0.5 + 0.5 * sin(time * 6 + Double(index) * 0.9)
        return max(4, 4 + CGFloat(envelope * Double(level) * wave) * maxHeight)
    }
}

/// Таймер длительности записи с плавной сменой цифр.
struct TimerText: View {
    let startedAt: Date
    var color: Color = .secondary
    var font: Font = .system(.callout, design: .monospaced)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(clockMMSS(TimeInterval(seconds)))
                .font(font)
                .foregroundStyle(color)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: false))
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: seconds)
        }
    }
}
