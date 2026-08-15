import Foundation

extension BinaryFloatingPoint {
    /// EMA-сглаживание: тянет текущее значение к `target`. `response` — доля
    /// нового значения (0…1; больше — отзывчивее, меньше — инертнее).
    /// Единый источник для сглаживания уровня микрофона в панелях записи и
    /// в подсветке краёв (там — с разным response на подъём/затухание).
    func smoothed(toward target: Self, response: Self) -> Self {
        self * (1 - response) + target * response
    }
}
