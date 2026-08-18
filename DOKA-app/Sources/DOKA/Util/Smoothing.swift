import Foundation

extension BinaryFloatingPoint {
    /// EMA-сглаживание: тянет текущее значение к `target`. `response` — доля
    /// нового значения (0…1; больше — отзывчивее, меньше — инертнее).
    /// Единый источник для сглаживания уровня микрофона в панелях записи и
    /// в подсветке краёв (там — с разным response на подъём/затухание).
    func smoothed(toward target: Self, response: Self) -> Self {
        self * (1 - response) + target * response
    }

    /// Асимметричное сглаживание уровня микрофона: подъём быстрый, спад
    /// медленный. Симметричная EMA либо съедает пики голоса, либо дёргается
    /// на паузах между словами — панели должны «выстреливать» и мягко гаснуть.
    /// Значения по умолчанию совпадают с огибающей в `AudioRecorder`.
    func envelope(toward target: Self, attack: Self = 0.5, release: Self = 0.18) -> Self {
        smoothed(toward: target, response: target > self ? attack : release)
    }
}
