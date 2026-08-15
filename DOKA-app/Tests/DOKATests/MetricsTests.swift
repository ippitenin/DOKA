import XCTest
@testable import DOKA

/// Метрики дашборда и экрана производительности. Считаются из накопленных
/// агрегатов, поэтому ошибка деления даёт правдоподобное, но неверное число —
/// заметить его на глаз невозможно.
final class DashboardMetricsTests: XCTestCase {

    private func snapshot(words: Int = 0, duration: TimeInterval = 0, sessions: Int = 0,
                          speechWords: Int = 0, speechDuration: TimeInterval = 0) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.totalWords = words
        s.totalDuration = duration
        s.totalSessions = sessions
        s.totalSpeechWords = speechWords
        s.totalSpeechDuration = speechDuration
        return s
    }

    func testHasDataOnlyWithSessions() {
        XCTAssertFalse(DashboardMetrics(snapshot: snapshot(), typingSpeedWPM: 0).hasData)
        XCTAssertTrue(DashboardMetrics(snapshot: snapshot(sessions: 1), typingSpeedWPM: 0).hasData)
    }

    /// Тест печати не пройден — геро-метрики недоступны, вместо них призыв пройти тест.
    func testWithoutTypingTestHeroMetricsAreNil() {
        let m = DashboardMetrics(snapshot: snapshot(words: 100, duration: 60, sessions: 1),
                                 typingSpeedWPM: 0)
        XCTAssertFalse(m.hasTypingTest)
        XCTAssertNil(m.speedMultiplier)
        XCTAssertNil(m.timeSaved)
        XCTAssertNil(m.typingTimeSeconds)
    }

    /// Скорость речи считается по активной речи, а не по полной длительности:
    /// иначе паузы занижают темп.
    func testSpeechWPMUsesActiveSpeechWhenMeasured() {
        let m = DashboardMetrics(snapshot: snapshot(words: 200, duration: 600,
                                                   speechWords: 100, speechDuration: 60),
                                 typingSpeedWPM: 0)
        XCTAssertEqual(m.speechWPM, 100, accuracy: 0.001, "100 слов за минуту активной речи")
    }

    /// У старых записей активной речи нет — фолбэк на полную длительность,
    /// иначе получилось бы деление на ноль.
    func testSpeechWPMFallsBackToTotalDuration() {
        let m = DashboardMetrics(snapshot: snapshot(words: 120, duration: 120), typingSpeedWPM: 0)
        XCTAssertEqual(m.speechWPM, 60, accuracy: 0.001)
    }

    func testSpeechWPMIsZeroWithoutAnyDuration() {
        XCTAssertEqual(DashboardMetrics(snapshot: snapshot(words: 50), typingSpeedWPM: 0).speechWPM, 0)
    }

    func testSpeedMultiplierIsSpeechOverTyping() {
        let m = DashboardMetrics(snapshot: snapshot(words: 100, speechWords: 100, speechDuration: 60),
                                 typingSpeedWPM: 25)
        XCTAssertEqual(m.speedMultiplier ?? 0, 4, accuracy: 0.001, "100 слов/мин речи против 25 печати")
    }

    /// Множитель и сэкономленное время обязаны быть согласованы — оба от speechWPM.
    /// Расхождение даёт «в 4 раза быстрее», но абсурдную экономию.
    func testTimeSavedAgreesWithMultiplier() {
        let m = DashboardMetrics(snapshot: snapshot(words: 100, speechWords: 100, speechDuration: 60),
                                 typingSpeedWPM: 25)
        // Печатал бы 4 минуты, говорил 1 минуту → экономия 3 минуты.
        XCTAssertEqual(m.typingTimeSeconds ?? 0, 240, accuracy: 0.001)
        XCTAssertEqual(m.timeSaved ?? 0, 180, accuracy: 0.001)
    }

    /// Если пользователь печатает быстрее, чем говорит, экономия обнуляется,
    /// а не уходит в минус.
    func testTimeSavedNeverGoesNegative() {
        let m = DashboardMetrics(snapshot: snapshot(words: 100, speechWords: 100, speechDuration: 120),
                                 typingSpeedWPM: 200)
        XCTAssertEqual(m.timeSaved ?? -1, 0, accuracy: 0.001)
    }

    func testAverageWordsPerSession() {
        let m = DashboardMetrics(snapshot: snapshot(words: 300, sessions: 4), typingSpeedWPM: 0)
        XCTAssertEqual(m.avgWordsPerSession, 75, accuracy: 0.001)
    }

    func testAverageWordsWithoutSessionsIsZero() {
        XCTAssertEqual(DashboardMetrics(snapshot: snapshot(words: 10), typingSpeedWPM: 0).avgWordsPerSession, 0)
    }
}

final class PerformanceMetricsTests: XCTestCase {

    private func record(text: String = "раз два",
                        duration: TimeInterval,
                        transcriptionTime: TimeInterval?,
                        model: String? = "whisper-1",
                        provider: String? = "builtin") -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), text: text, date: Date(), duration: duration,
                            language: "ru", speechDuration: nil, model: model, provider: provider,
                            microphone: nil, transcriptionTime: transcriptionTime, audioFileName: nil)
    }

    /// Старые записи без latency не должны попадать в расчёт скорости —
    /// иначе средние искажаются нулями.
    func testAnalyzableExcludesRecordsWithoutLatency() {
        let metrics = PerformanceMetrics(records: [
            record(duration: 10, transcriptionTime: 2),
            record(duration: 10, transcriptionTime: nil),
            record(duration: 10, transcriptionTime: 0),
            record(duration: 0, transcriptionTime: 5)
        ])
        XCTAssertEqual(metrics.totalTranscripts, 4)
        XCTAssertEqual(metrics.analyzableCount, 1)
    }

    func testTotalWordsCountsAllRecords() {
        let metrics = PerformanceMetrics(records: [
            record(text: "раз два три", duration: 10, transcriptionTime: 1),
            record(text: "четыре", duration: 10, transcriptionTime: nil)
        ])
        XCTAssertEqual(metrics.totalWords, 4, "слова считаются по всем записям, не только анализируемым")
    }

    /// «Во сколько раз быстрее реального времени» = аудио / время распознавания.
    func testFasterThanRealtime() {
        let metrics = PerformanceMetrics(records: [
            record(duration: 60, transcriptionTime: 6, model: "parakeet")
        ])
        XCTAssertEqual(metrics.byModel.first?.fasterThanRealtime ?? 0, 10, accuracy: 0.001)
    }

    func testGroupsAggregateAndSortByCount() {
        let metrics = PerformanceMetrics(records: [
            record(duration: 10, transcriptionTime: 1, model: "whisper-1"),
            record(duration: 30, transcriptionTime: 3, model: "whisper-1"),
            record(duration: 20, transcriptionTime: 2, model: "parakeet")
        ])
        let groups = metrics.byModel
        XCTAssertEqual(groups.first?.name, "whisper-1", "группы сортируются по числу записей")
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(groups.first?.totalAudio ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(groups.first?.avgAudio ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(groups.first?.avgProcess ?? 0, 2, accuracy: 0.001)
    }

    func testMissingModelBecomesDash() {
        let metrics = PerformanceMetrics(records: [record(duration: 10, transcriptionTime: 1, model: nil)])
        XCTAssertEqual(metrics.byModel.first?.name, "—")
    }

    func testEmptyInputProducesNoGroups() {
        let metrics = PerformanceMetrics(records: [])
        XCTAssertTrue(metrics.byModel.isEmpty)
        XCTAssertTrue(metrics.byProvider.isEmpty)
        XCTAssertEqual(metrics.totalWords, 0)
    }
}
