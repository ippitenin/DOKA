import SwiftUI

/// Стиль панели записи «Аврора»: компактная светящаяся «капелька» снизу экрана
/// плюс полноэкранная персиковая подсветка краёв (`ScreenGlowView`,
/// показывается отдельной клик-сквозной панелью из RecorderPanelController).
///
/// Вся графика капельки — Metal-шейдеры (`Shaders/AuroraDrop.metal`): волна во
/// время записи, жидкие точки во время распознавания и стеклянная оболочка,
/// преломляющая содержимое у кромки. На SwiftUI-примитивах такое не собирается —
/// это попиксельное свечение, ему нужен шейдер.

// MARK: - Доступ к шейдерам

/// Обёртка над скомпилированной библиотекой шейдеров.
///
/// `default.metallib` собирается ОТДЕЛЬНЫМ шагом (`scripts/build-shaders.sh`,
/// зовётся из `build.sh`): SwiftPM .metal не компилирует, а build-tool-плагин
/// ломает universal-сборку. Если библиотеки в бандле нет (забыли прогнать
/// скрипт перед голым `swift build`) — капелька рисуется без эффекта, а не
/// падает и не показывает мусор.
enum DropShaders {
    static let isAvailable: Bool = {
        let found = Bundle.module.url(forResource: "default", withExtension: "metallib") != nil
        if !found {
            NSLog("[DOKA] default.metallib не найден — панель «Аврора» без эффекта. "
                  + "Прогоните scripts/build-shaders.sh")
        }
        return found
    }()

    private static var library: ShaderLibrary { ShaderLibrary.bundle(.module) }

    /// Волна записи. `phase` интегрируется снаружи: скорость бега зависит от голоса.
    static func wave(size: CGSize, phase: Double, level: Float) -> Shader {
        library.dokaDropWave(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(phase)),
            .float(level),
            .color(DS.accent),
            .color(DS.glow),
            .color(DS.Aurora.indigo),
            .color(DS.Aurora.waveHighlight)
        )
    }

    /// Точки распознавания: кольцо жидких капель, `appear` — появление 0…1.
    static func dots(size: CGSize, time: Double, appear: Double) -> Shader {
        library.dokaDropDots(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(time)),
            .float(Float(appear)),
            .color(DS.RecorderTone.transcribing),
            .color(DS.Aurora.indigo),
            .color(DS.Aurora.dotHighlight)
        )
    }

    /// Стеклянная оболочка: преломление содержимого у кромки + светящийся блик.
    static func glass(size: CGSize, level: Float) -> Shader {
        library.dokaDropGlass(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(DropGeometry.refraction)),
            .float(0.42 + 0.28 * min(max(level, 0), 1)),   // блик разгорается под голос
            .float(1.2),
            .color(DS.glow),
            .color(DS.Aurora.indigo)
        )
    }
}

// MARK: - Геометрия и движение

/// Габариты капельки — единственный источник размеров для обоих стилей,
/// которые её используют. Форма волны от ширины НЕ зависит: она считается от
/// опорного аспекта (`kRefAspect` в шейдере), поэтому узкая капелька получает
/// ту же картинку, просто сжатую по ширине.
struct DropGeometry {
    /// Капсула во время записи.
    let recording: CGSize
    /// Окно панели: запас вокруг капельки под ореол, блик и перелёт пружин.
    let panel: CGSize

    /// «Аврора» — широкая капелька плюс подсветка краёв экрана.
    static let wide = DropGeometry(
        recording: CGSize(width: 180, height: 63),
        panel: CGSize(width: 260, height: 119)
    )
    /// «Мини» — та же капелька вдвое уже и БЕЗ подсветки экрана.
    static let compact = DropGeometry(
        recording: CGSize(width: 90, height: 63),
        panel: CGSize(width: 170, height: 119)
    )

    /// Во время распознавания капсула стягивается в круг — общий для обоих стилей.
    static let transcribing = CGSize(width: 63, height: 63)
    /// Волна рисуется крупнее капсулы и обрезается ею — свет «забегает» за кромку.
    static let waveOverscan: CGFloat = 1.18
    /// Сдвиг сэмпла у кромки в стекле (точки).
    static let refraction: CGFloat = 6
}

/// Фаза волны и пружина ширины капсулы.
///
/// Ссылочный тип намеренно: значения пересчитываются на каждом кадре внутри
/// `TimelineView`, а мутация `@State`-значения прямо в `body` — ошибка.
@MainActor final class DropMotion {
    private(set) var phase: Double = 0
    private(set) var width: Double = DropGeometry.wide.recording.width
    /// Появление: 0 — точка, 1 — полный размер. Пружина даёт лёгкий перелёт,
    /// поэтому капелька «надувается» пузырём, а не просто возникает.
    private(set) var appear: Double = 0
    private var velocity: Double = 0
    private var appearVelocity: Double = 0
    private var last: Date?

    /// Скорость бега волны: в тишине спокойная, на голосе втрое быстрее.
    /// Коэффициенты — 95% от эталонных (2.5 и 12): на полной скорости волна
    /// бежала суетливо, а заметное замедление читалось как вялость.
    private static func waveSpeed(level: Double) -> Double {
        2.375 + 11.4 * min(1, 0.4 * level)
    }

    /// Пружина ширины: недодемпфированная (ζ ≈ 0.45) — капсула стягивается
    /// в круг плавно и с лёгким отскоком, как капля на батуте.
    private static let stiffness: Double = 400
    private static let damping: Double = 18

    /// Пружина появления помягче (ζ ≈ 0.6): перелёт около 10% — заметный,
    /// но капелька не выпрыгивает за пределы окна панели.
    private static let appearStiffness: Double = 320
    private static let appearDamping: Double = 21

    /// Полный оборот фазы держим малым числом: `Float` в шейдере не вытянет
    /// секунды от точки отсчёта (~8·10⁸) — волна начнёт дёргаться.
    private static let phaseWrap: Double = 2 * .pi * 10

    func advance(to date: Date, level: Double, targetWidth: Double, animated: Bool) {
        defer { last = date }
        guard animated else {                 // Reduce Motion — сразу готовый кадр
            width = targetWidth
            appear = 1
            return
        }
        // Первый кадр только фиксирует время: dt от него посчитать не из чего.
        guard let previous = last else { return }
        // Кадр после сна/скрытой панели может быть длинным — иначе пружина взорвётся.
        let dt = min(max(date.timeIntervalSince(previous), 0), 0.1)
        guard dt > 0 else { return }

        phase = (phase + Self.waveSpeed(level: level) * dt)
            .truncatingRemainder(dividingBy: Self.phaseWrap)

        let acceleration = (width - targetWidth) * -Self.stiffness + velocity * -Self.damping
        velocity += acceleration * dt
        width += velocity * dt

        let appearForce = (appear - 1) * -Self.appearStiffness + appearVelocity * -Self.appearDamping
        appearVelocity += appearForce * dt
        appear += appearVelocity * dt
    }

    /// Сброс при появлении панели: без него первый кадр получит огромный dt.
    func reset(width targetWidth: Double) {
        last = nil
        velocity = 0
        width = targetWidth
        appear = 0
        appearVelocity = 0
    }
}

// MARK: - Капелька

/// Оболочка капельки: космическая подложка, шейдерное содержимое и стекло.
/// Используется и живой панелью, и миниатюрой в пикере — вид стиля задаётся
/// в одном месте.
private struct DropSurface: View {
    let size: CGSize
    let content: Shader?
    let level: Float

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: DS.Aurora.cosmic,
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            if let content {
                Rectangle()
                    .fill(.white)
                    .colorEffect(content)
                    .frame(width: size.width * DropGeometry.waveOverscan,
                           height: size.height * DropGeometry.waveOverscan)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(Capsule(style: .continuous))
        .glassShell(size: size, level: level)
        // Преломление уводит сэмплы за границу капсулы — без повторной обрезки
        // вокруг капельки остаётся размытый ореол чужого цвета.
        .clipShape(Capsule(style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func glassShell(size: CGSize, level: Float) -> some View {
        if DropShaders.isAvailable {
            layerEffect(
                DropShaders.glass(size: size, level: level),
                maxSampleOffset: CGSize(width: DropGeometry.refraction * 2,
                                        height: DropGeometry.refraction * 2)
            )
        } else {
            overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.glow.opacity(0.5), lineWidth: 1)
            )
        }
    }
}

/// Статичная миниатюра капельки для пикера стилей (`RecorderStylePicker`).
struct DropPreview: View {
    let size: CGSize

    var body: some View {
        DropSurface(
            size: size,
            content: DropShaders.isAvailable
                ? DropShaders.wave(size: size, phase: 1.6, level: 0.7)
                : nil,
            level: 0.7
        )
    }
}

// MARK: - Панель «Аврора»

/// Окно панели заметно больше самой капельки: ореол вокруг неё рисуется
/// ВНУТРИ окна. Внешних теней у корня по-прежнему нет — окно borderless
/// обрезало бы их своей квадратной границей (тёмные углы в светлой теме).
///
/// Одна и та же вью обслуживает два стиля: «Аврора» (широкая капелька плюс
/// полноэкранная подсветка краёв) и «Мини» (та же капелька вдвое уже, без
/// подсветки). Отличает их только `geometry` и то, поднимает ли контроллер
/// панель со `ScreenGlowView`.
struct DropRecorderView: View {
    @ObservedObject var controller: DictationController
    let size: CGSize
    let geometry: DropGeometry

    /// Появление точек распознавания: кольцо разлетается из центра.
    @State private var dotsAppear: Double = 0
    @State private var motion = DropMotion()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let level = Double(min(max(controller.audioLevel, 0), 1))
            let target = isTranscribing
                ? DropGeometry.transcribing.width
                : geometry.recording.width
            let _ = motion.advance(to: context.date, level: level,
                                   targetWidth: target, animated: !reduceMotion)
            let capsule = CGSize(width: motion.width, height: geometry.recording.height)

            ZStack {
                if isRecording || isTranscribing {
                    halo(capsule: capsule, level: level)
                    DropSurface(size: capsule, content: content(capsule: capsule, level: level),
                                level: Float(level))
                }
            }
            .frame(width: size.width, height: size.height)
            // Прозрачность набирается быстрее размера: точка не должна
            // мелькать полупрозрачным пятном, пока пузырь раздувается.
            .scaleEffect(max(motion.appear, 0))
            .opacity(min(1, max(motion.appear, 0) * 1.6))
        }
        .onChange(of: isTranscribing) { _, transcribing in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.45)) {
                dotsAppear = transcribing ? 1 : 0
            }
        }
        .onAppear { motion.reset(width: geometry.recording.width) }
        .onChange(of: isRecording) { _, recording in
            // Панель переживает цикл диктовки: без сброса новая запись
            // начнётся с чужой фазы импульса и уже разогнанной пружины.
            if recording { motion.reset(width: geometry.recording.width) }
        }
    }

    private func content(capsule: CGSize, level: Double) -> Shader? {
        guard DropShaders.isAvailable else { return nil }
        let field = CGSize(width: capsule.width * DropGeometry.waveOverscan,
                           height: capsule.height * DropGeometry.waveOverscan)
        switch controller.state {
        case .recording:
            return DropShaders.wave(size: field, phase: motion.phase, level: Float(level))
        case .transcribing:
            return DropShaders.dots(size: field, time: motion.phase, appear: dotsAppear)
        case .idle, .error:
            // Ошибка в капельку не помещается — её показывает классическая
            // панель (см. RecorderPanelController.show).
            return nil
        }
    }

    /// Тёплый ореол вокруг капельки, разгорается под голос.
    private func halo(capsule: CGSize, level: Double) -> some View {
        Capsule(style: .continuous)
            .fill(isTranscribing ? DS.RecorderTone.transcribing : DS.glow)
            .frame(width: capsule.width * 0.92, height: capsule.height * 0.8)
            .blur(radius: 22)
            .opacity(0.20 + 0.35 * level)
    }

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var isTranscribing: Bool {
        if case .transcribing = controller.state { return true }
        return false
    }
}

// MARK: - Полноэкранная подсветка краёв

/// Только для стиля «Аврора» (в «Мини» капелька живёт без неё).
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
            // Быстрый подъём, медленное затухание — общая огибающая панелей.
            level = level.envelope(toward: Double(min(max(raw, 0), 1)), attack: 0.45, release: 0.12)
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
