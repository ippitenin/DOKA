import Foundation

/// Формат mm:ss для таймера записи и плееров истории.
/// Не путать с `formatStatDuration` (человекочитаемая длительность для дашборда)
/// и `TranscriptFormatter.clock` (тайм-коды субтитров HH:MM:SS,mmm).
func clockMMSS(_ seconds: TimeInterval) -> String {
    let total = Int((seconds.isFinite && seconds > 0) ? seconds : 0)
    return String(format: "%d:%02d", total / 60, total % 60)
}
