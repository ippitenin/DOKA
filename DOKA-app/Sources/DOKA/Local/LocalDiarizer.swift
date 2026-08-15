import Foundation
import FluidAudio

/// Интервал речи одного говорящего. `speaker` уже приведён к формату Nexara
/// (`speaker_0`, `speaker_1`, …) — весь показ и экспорт спикеров в проекте
/// разбирает именно его (`SpeakerName`, `TranscriptFormatter.bySpeaker`).
struct SpeakerSpan: Equatable {
    let speaker: String
    let start: Double
    let end: Double
}

/// Локальное разделение по спикерам поверх офлайнового (VBx) диаризатора
/// FluidAudio: pyannote-сегментация + WeSpeaker-эмбеддинги + кластеризация.
/// Модели ~22 МБ, распознавания текста не делают — только «кто когда говорил»,
/// поэтому диаризатор одинаково пригоден и для локальных движков, и для
/// текста, полученного от пользовательского сетевого сервиса.
///
/// Импорт FluidAudio намеренно ограничен файлами движков в `Local/`.
@MainActor
final class LocalDiarizer {
    /// Загруженные модели; менеджер создаётся на каждый прогон, потому что
    /// подсказка о числе спикеров живёт в его конфиге, а не в вызове.
    private var models: OfflineDiarizerModels?

    var isLoaded: Bool { models != nil }

    func load() async throws {
        guard models == nil else { return }
        models = try await OfflineDiarizerModels.load(from: LocalModelStore.diarizerFolder)
    }

    /// Разбор WAV 16 кГц mono (то, что отдаёт `AudioFileDecoder`) на интервалы
    /// говорящих. `numSpeakers` — подсказка «ровно столько человек»: она не
    /// выдумывает спикеров там, где их не слышно, но не даёт разбить одного
    /// на нескольких (проверено стендом).
    func diarize(wavURL: URL,
                 numSpeakers: Int?,
                 progress: @escaping @MainActor (Double) -> Void) async throws -> [SpeakerSpan] {
        guard let models else { throw LocalEngineError.modelMissing }

        var config = OfflineDiarizerConfig.default
        if let numSpeakers {
            config = config.withSpeakers(exactly: numSpeakers)
        }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        let sink = ProgressSink(report: progress)
        let result = try await manager.process(wavURL) { done, total in
            sink.report(done: done, total: total)
        }
        try Task.checkCancellation()
        return Self.spans(from: result.segments)
    }

    func unload() {
        models = nil
    }

    /// `S1`, `S2` → `speaker_0`, `speaker_1` по порядку первого появления.
    /// Порядок именно первого появления, а не сортировки строк: у Nexara
    /// нумерация тоже идёт по ходу записи, и цвет бэйджа в UI считается так же.
    private static func spans(from segments: [TimedSpeakerSegment]) -> [SpeakerSpan] {
        var mapping: [String: String] = [:]
        var result: [SpeakerSpan] = []
        for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let mapped: String
            if let known = mapping[segment.speakerId] {
                mapped = known
            } else {
                mapped = "speaker_\(mapping.count)"
                mapping[segment.speakerId] = mapped
            }
            result.append(SpeakerSpan(speaker: mapped,
                                      start: Double(segment.startTimeSeconds),
                                      end: Double(segment.endTimeSeconds)))
        }
        return result
    }

    /// Колбэк прогресса приходит с произвольного потока и обязан быть
    /// `@Sendable`; квантуем до целых процентов, как у скачивания моделей,
    /// и прыгаем на главный актёр.
    private final class ProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -1
        private let report: @MainActor (Double) -> Void

        init(report: @escaping @MainActor (Double) -> Void) {
            self.report = report
        }

        func report(done: Int, total: Int) {
            guard total > 0 else { return }
            let fraction = min(max(Double(done) / Double(total), 0), 1)
            let percent = Int(fraction * 100)
            lock.lock()
            let changed = percent > lastPercent
            if changed { lastPercent = percent }
            lock.unlock()
            guard changed else { return }
            Task { @MainActor [report] in report(fraction) }
        }
    }
}
