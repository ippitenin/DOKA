import Foundation

extension StringProtocol {
    /// Единый подсчёт слов DOKA: разбивка по пробелам и переводам строк,
    /// пустые отброшены. Один источник для статистики диктовки и теста печати —
    /// чтобы «скорость речи» и «скорость печати» считались одинаково.
    var dokaWordCount: Int {
        split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

/// Человекочитаемая длительность для дашборда: «2 ч 14 мин» / «8 мин» / «43 с».
/// Единицы локализуются автоматически (учитывает язык интерфейса через `Locale.current`).
func formatStatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, seconds)
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.calendar = Calendar.current
    formatter.allowedUnits = total < 60 ? [.second] : [.hour, .minute]
    return formatter.string(from: total) ?? ""
}
