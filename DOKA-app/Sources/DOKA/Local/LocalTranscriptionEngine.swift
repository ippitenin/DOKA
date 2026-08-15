import Foundation

/// Результат локальной файловой транскрипции до маппинга в `TranscriptResult`:
/// сегменты и слова в типах DOKA, чтобы работали перенарезка детализации
/// (`TranscriptSegmentSplitter`) и все экспорты (`TranscriptFormatter`).
struct LocalFileTranscription {
    let fullText: String
    let language: String?
    let segments: [TranscriptSegment]
    let words: [TranscriptWord]
}

/// Движок локальной транскрипции: загруженная в память модель одного типа.
/// Реализации держат тяжёлые CoreML-объекты; создание дешёвое, `load()` —
/// дорогая (первый раз — CoreML-компиляция под чип, минуты).
@MainActor
protocol LocalTranscriptionEngine: AnyObject {
    var model: LocalModel { get }
    func load() async throws
    /// Диктовка: WAV 16 кГц mono → чистый текст. Кооперативная отмена —
    /// результат отменённой задачи никому не нужен.
    func transcribeDictation(wavURL: URL, language: String?) async throws -> String
    /// Файловая транскрибация: WAV 16 кГц mono (после `AudioFileDecoder`) →
    /// сегменты с тайм-кодами и слова.
    func transcribeFile(wavURL: URL, language: String?) async throws -> LocalFileTranscription
    func unload()
}

enum LocalEngineError: LocalizedError {
    case modelMissing
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing: return L("error.localModelMissing")
        case .loadFailed(let reason): return L("error.localLoadFailed", reason)
        }
    }
}

/// Владелец загруженного движка: один на приложение, ленивая загрузка,
/// выгрузка после простоя (модель держит ~2 ГБ ОЗУ). Повторные диктовки в
/// окне простоя — мгновенные, без повторной загрузки с диска.
@MainActor
final class LocalEngineManager {
    static let shared = LocalEngineManager()

    /// Пауза простоя до выгрузки модели из памяти.
    static let idleUnloadDelay: Duration = .seconds(5 * 60)

    private var engine: LocalTranscriptionEngine?
    /// Идущая загрузка: модель и её задача меняются только вместе.
    private var loading: (model: LocalModel, task: Task<LocalTranscriptionEngine, Error>)?
    private var idleTask: Task<Void, Never>?

    /// Диаризатор живёт РЯДОМ с речевым движком, а не вместо него: разделение
    /// по спикерам идёт следом за распознаванием того же файла.
    private var diarizerEngine: LocalDiarizer?
    private var diarizerLoading: Task<LocalDiarizer, Error>?

    private init() {}

    /// Возвращает готовый движок, при необходимости загружая модель.
    /// Повторный вызов во время загрузки (прогрев + диктовка) ждёт ту же задачу.
    func engine(for model: LocalModel) async throws -> LocalTranscriptionEngine {
        if let engine, engine.model == model {
            touch()
            return engine
        }
        if let loading, loading.model == model {
            let shared = try await loading.task.value
            touch()
            return shared
        }
        unloadNow()
        guard LocalModelStore.shared.isDownloaded(model) else {
            throw LocalEngineError.modelMissing
        }

        let task = Task<LocalTranscriptionEngine, Error> {
            let newEngine: LocalTranscriptionEngine
            switch model {
            case .whisper: newEngine = WhisperLocalEngine()
            case .parakeet: newEngine = ParakeetLocalEngine()
            }
            // Статус «Подготовка модели…» на время загрузки/компиляции.
            LocalModelStore.shared.markPreparing(model, true)
            defer { LocalModelStore.shared.markPreparing(model, false) }
            do {
                try await newEngine.load()
            } catch {
                throw LocalEngineError.loadFailed(error.localizedDescription)
            }
            return newEngine
        }
        loading = (model, task)
        defer { loading = nil }
        let newEngine = try await task.value
        engine = newEngine
        touch()
        return newEngine
    }

    /// Прогрев сразу после скачивания: первая CoreML-компиляция под чип
    /// занимает минуты — прячем её за статусом «Подготовка модели…», чтобы
    /// первая диктовка не выглядела зависанием. Заодно WhisperKit кэширует
    /// токенайзер с HuggingFace (сеть нужна один раз — сразу после
    /// скачивания она точно есть).
    func prewarm(_ model: LocalModel) async {
        _ = try? await engine(for: model)
    }

    /// Готовый диаризатор, при необходимости загружая модели. Параллельные
    /// вызовы (прогрев после скачивания + запуск транскрибации) ждут одну задачу.
    func diarizer() async throws -> LocalDiarizer {
        if let diarizerEngine, diarizerEngine.isLoaded {
            touch()
            return diarizerEngine
        }
        if let diarizerLoading {
            let shared = try await diarizerLoading.value
            touch()
            return shared
        }
        guard LocalModelStore.shared.isDownloaded(.diarizer) else {
            throw LocalEngineError.modelMissing
        }

        let task = Task<LocalDiarizer, Error> {
            let engine = LocalDiarizer()
            LocalModelStore.shared.markPreparing(.diarizer, true)
            defer { LocalModelStore.shared.markPreparing(.diarizer, false) }
            do {
                try await engine.load()
            } catch {
                throw LocalEngineError.loadFailed(error.localizedDescription)
            }
            return engine
        }
        diarizerLoading = task
        defer { diarizerLoading = nil }
        let engine = try await task.value
        diarizerEngine = engine
        touch()
        return engine
    }

    func prewarmDiarizer() async {
        _ = try? await diarizer()
    }

    func unloadDiarizer() {
        diarizerEngine?.unload()
        diarizerEngine = nil
    }

    /// Продлевает окно простоя; вызывать после каждого использования движка.
    func touch() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.unloadNow()
        }
    }

    func unloadNow() {
        idleTask?.cancel()
        idleTask = nil
        engine?.unload()
        engine = nil
        unloadDiarizer()
    }

    /// Выгрузка, если в памяти именно эта модель (удаление файлов, смена сервиса).
    func unloadIfCurrent(_ model: LocalModel) {
        if engine?.model == model { unloadNow() }
    }
}
