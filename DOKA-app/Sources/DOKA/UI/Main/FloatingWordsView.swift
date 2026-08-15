import SwiftUI

/// Эмбиент-слой «Главной»: слова на разных языках медленно всплывают вверх
/// по боковым полям (в стиле приветствий Apple). Центр остаётся свободным
/// под контент. Слова намеренно не локализуются — многоязычность и есть смысл.
struct FloatingWordsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let words: [String] = [
        "Привет", "Hello", "Hola", "Bonjour", "Ciao", "Hallo",
        "Olá", "你好", "こんにちは", "안녕", "Merhaba", "Hej",
        "Голос", "Voice", "Texte", "Слова", "Speak", "Текст"
    ]

    /// Полный цикл всплытия. Одинаков для всех слов: вместе с равномерно
    /// распределёнными фазами это даёт постоянные интервалы между словами —
    /// они никогда не съезжаются в плотную группу.
    private static let cycleDuration: Double = 26

    var body: some View {
        if !reduceMotion {
            // Полная частота дисплея: на 30 fps медленный дрейф текста
            // заметно дрожит.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    ForEach(Self.words.indices, id: \.self) { index in
                        let p = Self.particle(index)
                        // Фаза 0…1: всплытие снизу вверх с фейдом по синусу.
                        let phase = (t / Self.cycleDuration + p.offset)
                            .truncatingRemainder(dividingBy: 1)
                        let sway = sin(t * 0.18 + Double(index) * 1.7) * 6
                        Text(Self.words[index])
                            .font(.system(size: p.size, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .opacity(p.maxOpacity * sin(.pi * phase))
                            .blur(radius: p.blur)
                            .position(
                                x: p.x * geo.size.width + sway,
                                y: (1.08 - phase * 1.2) * geo.size.height
                            )
                    }
                }
                .drawingGroup()
            }
            .allowsHitTesting(false)
        }
    }

    private struct Particle {
        let x: Double          // относительная позиция по ширине
        let offset: Double     // фаза цикла (распределена равномерно)
        let size: CGFloat
        let maxOpacity: Double
        let blur: CGFloat
    }

    /// Детерминированный псевдослучайный параметр: один и тот же образ
    /// на каждом показе, без таймеров и состояния.
    private static func rand(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 127.1 + salt * 311.7) * 43758.5453
        return value - floor(value)
    }

    private static func particle(_ index: Int) -> Particle {
        // Поочерёдно левая/правая колонна, 6–24 % ширины от края.
        let band = 0.06 + rand(index, 1.3) * 0.18
        let leftSide = index % 2 == 0
        // Фазы внутри колонны распределены равномерно (плюс лёгкий джиттер),
        // правая колонна сдвинута на полшага относительно левой.
        let perColumn = Double(words.count / 2)
        let columnIndex = Double(index / 2)
        let offset = (columnIndex + (leftSide ? 0 : 0.5)) / perColumn
            + (rand(index, 3.9) - 0.5) * 0.04
        return Particle(
            x: leftSide ? band : 1 - band,
            offset: offset,
            size: 13 + rand(index, 5.1) * 9,
            maxOpacity: 0.10 + rand(index, 7.3) * 0.15,
            blur: rand(index, 9.7) * 1.5
        )
    }
}
