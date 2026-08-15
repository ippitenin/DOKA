import Foundation

/// Чистые вычисления метрик дашборда из снимка `StatsStore` и измеренной
/// скорости печати. Value-type без зависимостей от UI — легко тестируется.
struct DashboardMetrics {
    let snapshot: StatsSnapshot
    /// Личная скорость печати (слов/мин). nil — тест ещё не пройден.
    let typingWPM: Double?

    init(snapshot: StatsSnapshot, typingSpeedWPM: Double) {
        self.snapshot = snapshot
        self.typingWPM = typingSpeedWPM > 0 ? typingSpeedWPM : nil
    }

    var hasData: Bool { snapshot.totalSessions > 0 }
    var hasTypingTest: Bool { typingWPM != nil }

    var totalWords: Int { snapshot.totalWords }
    var totalSessions: Int { snapshot.totalSessions }
    var totalDuration: TimeInterval { snapshot.totalDuration }

    /// Средняя скорость речи (слов/мин). По активной речи, если она измерена
    /// (новые записи), иначе — по полной длительности записи (старые данные).
    var speechWPM: Double {
        if snapshot.totalSpeechDuration > 1 {
            return Double(snapshot.totalSpeechWords) / (snapshot.totalSpeechDuration / 60)
        }
        let minutes = snapshot.totalDuration / 60
        return minutes > 0 ? Double(snapshot.totalWords) / minutes : 0
    }

    /// Среднее число слов за сессию.
    var avgWordsPerSession: Double {
        snapshot.totalSessions > 0 ? Double(snapshot.totalWords) / Double(snapshot.totalSessions) : 0
    }

    /// Сколько бы пользователь печатал весь корпус (сек). nil без теста.
    var typingTimeSeconds: TimeInterval? {
        guard let typingWPM, typingWPM > 0 else { return nil }
        return Double(snapshot.totalWords) / typingWPM * 60
    }

    /// Оценка времени активной речи на весь корпус в текущем темпе (сек).
    private var speakingTimeSeconds: Double? {
        let wpm = speechWPM
        guard wpm > 0 else { return nil }
        return Double(snapshot.totalWords) / wpm * 60
    }

    /// Множитель «в N× быстрее» = речь/печать. nil без теста или без речи.
    var speedMultiplier: Double? {
        guard let typingWPM, typingWPM > 0, speechWPM > 0 else { return nil }
        return speechWPM / typingWPM
    }

    /// Сэкономленное время (сек): печатал бы − говорил бы (в темпе активной речи).
    /// Согласовано с множителем (оба от `speechWPM`). nil без теста.
    var timeSaved: TimeInterval? {
        guard let typing = typingTimeSeconds, let speaking = speakingTimeSeconds else { return nil }
        return max(0, typing - speaking)
    }
}
