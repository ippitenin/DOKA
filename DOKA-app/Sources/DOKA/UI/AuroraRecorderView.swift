import SwiftUI

/// Стиль панели записи «Аврора»: широкая светящаяся «космическая» пилюля
/// снизу экрана с текучей световой волной, реагирующей на уровень микрофона,
/// плюс полноэкранная персиковая подсветка краёв (`ScreenGlowView`,
/// показывается отдельной клик-сквозной панелью из RecorderPanelController).
/// Стилистика: фирменный персик + лёгкий космос (глубокий индиго, звёзды).

// MARK: - Форма волны

/// Синусоида по ширине с огибающей `sin(πx)` (концы сходят на нет к краям).
/// Используется и в анимированной `AuroraWave`, и в статичном превью пикера.
struct AuroraWaveShape: Shape {
    var phase: Double
    /// 0…1 относительно полувысоты прямоугольника.
    var amplitude: Double
    var frequency: Double = 1.4

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let midY = rect.midY
        let amp = rect.height / 2 * CGFloat(min(max(amplitude, 0), 1))
        let steps = 64
        for i in 0...steps {
            let fx = Double(i) / Double(steps)
            let env = sin(fx * .pi)              // 0 на краях → 1 в центре
            let y = midY - CGFloat(sin(fx * frequency * 2 * .pi + phase) * env) * amp
            let x = rect.minX + CGFloat(fx) * rect.width
            if i == 0 {
                p.move(to: CGPoint(x: x, y: y))
            } else {
                p.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return p
    }
}

// MARK: - Анимированная аврора-волна

/// Несколько наложенных синусоид с фазосдвигом, штрих градиентом
/// персик→коралл→индиго, аддитивное свечение. Амплитуда — от уровня
/// микрофона; движение — `TimelineView`. Reduce Motion: статичная кривая,
/// реакция только амплитудой.
struct AuroraWave: View {
    var level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Ribbon {
        let freq: Double
        let speed: Double
        let phase: Double
        let colors: [Color]
        let width: CGFloat
        let opacity: Double
    }

    private let ribbons: [Ribbon] = [
        Ribbon(freq: 1.3, speed: 1.0, phase: 0.0,
               colors: [DS.accent, DS.glow, DS.accent], width: 3.0, opacity: 0.95),
        Ribbon(freq: 2.0, speed: -1.5, phase: 1.7,
               colors: [DS.Logo.markLight, DS.glow], width: 2.0, opacity: 0.70),
        Ribbon(freq: 0.9, speed: 0.6, phase: 3.4,
               colors: [DS.Aurora.indigo, DS.glow], width: 2.0, opacity: 0.50)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let amp = 0.22 + Double(min(max(level, 0), 1)) * 0.78
            ZStack {
                ForEach(ribbons.indices, id: \.self) { i in
                    let r = ribbons[i]
                    AuroraWaveShape(phase: t * r.speed * 1.8 + r.phase,
                                    amplitude: amp,
                                    frequency: r.freq)
                        .stroke(
                            LinearGradient(colors: r.colors,
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: r.width, lineCap: .round)
                        )
                        .opacity(r.opacity)
                }
            }
            .blur(radius: 1.3)
            .compositingGroup()
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Звёздная пыль

/// Несколько мелких мерцающих «звёзд» на детерминированных псевдослучайных
/// позициях (хеш по индексу — стабилен между кадрами, без рандома).
private struct StarField: View {
    var count: Int = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    ForEach(0..<count, id: \.self) { i in
                        let p = Self.position(i)
                        let twinkle = reduceMotion
                            ? 0.45
                            : 0.25 + 0.5 * (0.5 + 0.5 * sin(t * 1.3 + Double(i) * 1.7))
                        Circle()
                            .fill(.white)
                            .frame(width: Self.size(i), height: Self.size(i))
                            .opacity(twinkle)
                            .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func position(_ i: Int) -> CGPoint {
        let x = (sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let y = (sin(Double(i) * 78.233) * 96321.123).truncatingRemainder(dividingBy: 1)
        return CGPoint(x: abs(x), y: abs(y))
    }

    private static func size(_ i: Int) -> CGFloat { i % 4 == 0 ? 1.8 : 1.1 }
}

// MARK: - Плашка «Аврора»

struct AuroraRecorderView: View {
    @ObservedObject var controller: DictationController
    let size: CGSize

    /// EMA-сглаженный уровень микрофона — волна не дёргается.
    @State private var smoothedLevel: Float = 0

    var body: some View {
        ZStack {
            cosmicBase
            StarField(count: 14)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .opacity(0.5)
            content
                .padding(.horizontal, 16)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(rimGradient, lineWidth: 1.2)
        )
        // Внешних теней нет намеренно: окно панели размером ровно с пилюлю,
        // тень обрезалась бы его квадратной границей (тёмные углы в светлой
        // теме). Свечение даёт полноэкранный оверлей ScreenGlowView.
        .onChange(of: controller.audioLevel) { _, level in
            smoothedLevel = smoothedLevel.smoothed(toward: level, response: 0.3)
        }
        .onChange(of: isRecording) { _, recording in
            if !recording { smoothedLevel = 0 }
        }
    }

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    /// Космическая подложка: глубокий индиго-градиент + тёплое персиковое ядро.
    private var cosmicBase: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: DS.Aurora.cosmic,
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                Ellipse()
                    .fill(DS.glow)
                    .frame(width: size.width * 0.55, height: size.height * 1.5)
                    .blur(radius: 44)
                    .opacity(0.30)
            )
            .clipShape(Capsule(style: .continuous))
    }

    private var rimGradient: LinearGradient {
        LinearGradient(
            colors: [DS.glow.opacity(0.85), DS.accent.opacity(0.35),
                     DS.Aurora.indigo.opacity(0.5)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Контент плашки одним аккуратным рядом: логотип · волна (в своей
    /// центральной зоне) · таймер · мини-кейкап Esc — ничего не перекрывается.
    @ViewBuilder private var content: some View {
        switch controller.state {
        case .recording(let startedAt):
            HStack(spacing: 12) {
                // Слева время, по центру волна, справа кейкап Esc.
                TimerText(startedAt: startedAt, color: .white.opacity(0.92))
                AuroraWave(level: smoothedLevel)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                EscKeyCap()
            }
        case .transcribing:
            HStack(spacing: 12) {
                AuroraWave(level: 0.32)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                Text(L("common.transcribing"))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
            }
        case .error(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Полноэкранная подсветка краёв

/// Полноэкранная подсветка в духе Claude/Siri с акцентом у НИЖНЕГО края:
/// широкий тёплый «герой» вдоль низа экрана (растёт высотой и яркостью под
/// голос) + размытые орбы в нижних углах; верх почти чист. Пульсирует под
/// уровень микрофона (быстрый подъём, медленное затухание) — низ «вздымается»
/// волнами света, когда говоришь. Рисуется в клик-сквозной панели: не
/// перехватывает мышь и не забирает фокус. Окно накладывается на экран
/// обычной альфой (sourceOver) — смешение нормальное, без plusLighter.
/// Reduce Motion — статично; Reduce Transparency — приглушённо.
struct ScreenGlowView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Уровень с envelope-сглаживанием: быстрый attack, медленный decay.
    @State private var level: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let breathe = reduceMotion ? 0.0 : (0.5 + 0.5 * sin(t * 0.8))
            let lvl = reduceMotion ? 0.35 : level   // рост «героя» под голос
            let shaped = pow(lvl, 0.5)              // чувствительнее к тихой речи
            // Низкая база (тишина заметно тусклее) → яркий пик «пока говоришь».
            let intensity = reduceMotion
                ? 0.6
                : min(1.0, 0.30 + 0.70 * shaped + breathe * 0.04)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let m = min(w, h)
                let d1 = reduceMotion ? 0 : CGFloat(sin(t * 0.13)) * w * 0.02
                let d2 = reduceMotion ? 0 : CGFloat(cos(t * 0.17)) * w * 0.02
                // Граница, выше которой свет уходит в прозрачность; поднимается под голос.
                let clearTo = 0.74 - 0.30 * lvl
                ZStack {
                    // Нижний вертикальный wash: тёплый низ → плавно в прозрачность
                    // вверх (без резкой кромки), на всю ширину экрана.
                    Rectangle()
                        .fill(LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: clearTo),
                            .init(color: DS.ScreenGlow.peach.opacity(0.28),
                                  location: clearTo + (1 - clearTo) * 0.55),
                            .init(color: DS.ScreenGlow.amber.opacity(0.60), location: 1.0)
                        ], startPoint: .top, endPoint: .bottom))
                    // Центр-низ — «герой», растёт под голос.
                    orb(DS.ScreenGlow.amber, 0.55, x: w * 0.5 + d1, y: h, r: m * (0.50 + 0.38 * lvl))
                    // Низ-лево — доминанта.
                    orb(DS.ScreenGlow.peach, 0.90, x: w * 0.04 + d2, y: h, r: m * 0.60)
                    // Низ-право.
                    orb(DS.ScreenGlow.coral, 0.62, x: w * 0.99 - d2, y: h, r: m * 0.50)
                    // Подсветка нижних частей боковых краёв.
                    orb(DS.ScreenGlow.peach, 0.40, x: w * -0.02, y: h * 0.82, r: m * 0.42)
                    orb(DS.ScreenGlow.coral, 0.34, x: w * 1.02, y: h * 0.80, r: m * 0.42)
                }
                .frame(width: w, height: h)
                .opacity(intensity * (reduceTransparency ? 0.55 : 1.0))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: controller.audioLevel) { _, raw in
            let x = Double(min(max(raw, 0), 1))
            if x > level { level = level.smoothed(toward: x, response: 0.45) }  // быстрый подъём
            else { level = level.smoothed(toward: x, response: 0.12) }          // медленное затухание
        }
    }

    /// Мягкий радиальный орб с ярким ядром.
    private func orb(_ c: Color, _ peak: Double, x: CGFloat, y: CGFloat, r: CGFloat) -> some View {
        RadialGradient(
            colors: [c.opacity(peak), c.opacity(peak * 0.45), .clear],
            center: .center, startRadius: 0, endRadius: r / 2
        )
        .frame(width: r, height: r)
        .blur(radius: r * 0.12)
        .position(x: x, y: y)
    }
}
