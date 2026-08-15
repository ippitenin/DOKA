import SwiftUI

/// Режим разметки ролей на странице «Транскрибация» (UI поверх `RolesSpec`).
enum RolesMode: String, CaseIterable, Identifiable {
    case off, auto, custom

    var id: String { rawValue }
    var title: String { L("transcribe.roles.\(rawValue)") }
}

/// Пресеты LLM-анализа расшифровки. Тексты промптов — ключи Localizable.strings:
/// промпт следует языку интерфейса, включая язык ответа модели.
enum LLMAnalysisPreset: String, CaseIterable, Identifiable {
    case off, meetingMinutes, summary, actionItems, custom

    var id: String { rawValue }
    var title: String { L("transcribe.llm.preset.\(rawValue)") }

    /// Готовый промпт пресета; off и custom промпта не имеют.
    var promptTemplate: String? {
        switch self {
        case .off, .custom: return nil
        case .meetingMinutes, .summary, .actionItems:
            return L("transcribe.llm.prompt.\(rawValue)")
        }
    }
}

/// Состояние страницы «Транскрибация»: выбор файла, прогресс, результат.
/// Полностью изолирован от пайплайна диктовки — не пишет в историю,
/// статистику и словарь, не вставляет текст в активное приложение.
@MainActor
final class FileTranscriptionController: ObservableObject {
    /// Синглтон: результат и выбранный файл переживают пересоздание вью при
    /// переключении секций (`MainWindowView` рендерит контент с `.id(section)`)
    /// и живут до закрытия приложения.
    static let shared = FileTranscriptionController()
    private init() {}

    enum Phase: Equatable {
        case idle
        case picked(name: String, sizeBytes: Int64)
        case transcribing
        case done(TranscriptResult)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Разделение по спикерам (task=diarize). По умолчанию выключено: дороже и медленнее.
    @Published var diarize = false
    /// Язык распознавания страницы. По умолчанию — как у диктовки, но меняется
    /// независимо (в общие настройки не пишем — это локальный выбор страницы).
    @Published var language: String = SettingsStore.shared.language
    /// Подсказка о числе говорящих (только Nexara). nil — авто.
    @Published var numSpeakers: Int? = nil
    /// Тип записи для диаризации (только Nexara).
    @Published var diarizationSetting: DiarizationSetting = .general
    /// Детализация тайм-кодов. Нарезка локальная, поэтому смена на готовом
    /// результате перенарезает его сразу, без повторного запроса.
    @Published var timestampDetail: TimestampDetail = .medium {
        didSet {
            guard timestampDetail != oldValue, case let .done(result) = phase else { return }
            phase = .done(result.withDetail(timestampDetail))
        }
    }
    /// Разметка ролей (только Nexara, только с диаризацией).
    @Published var rolesMode: RolesMode = .off
    /// Свой список ролей: имена через запятую («Клиент, Агент»).
    @Published var rolesText: String = ""
    /// LLM-анализ расшифровки (только Nexara).
    @Published var llmPreset: LLMAnalysisPreset = .off
    /// Свой промпт анализа (llmPreset == .custom).
    @Published var llmCustomPrompt: String = ""

    /// Ошибка валидации своего списка ролей; nil — всё валидно.
    /// Не-nil блокирует запуск (кнопка задизейблена в UI).
    var rolesValidationMessage: String? {
        guard diarize, isBuiltinService, rolesMode == .custom else { return nil }
        if case .failure(let error) = SpeakerRolesParser.parse(rolesText) {
            return error.message
        }
        return nil
    }

    /// Nexara-специфичные параметры (num_speakers, diarization_setting, роли)
    /// доступны только встроенному сервису: у кастомных OpenAI-совместимых
    /// API таких полей нет, строгий сервер ответит 400.
    var isBuiltinService: Bool {
        SettingsStore.shared.providerID == TranscriptionProvider.builtin.rawValue
    }

    /// Итоговый промпт LLM-анализа; nil — анализ выключен или недоступен.
    /// Жёсткий гейт builtin: у кастомных OpenAI-совместимых API `prompt` —
    /// контекстная подсказка Whisper, LLM-инструкция там молча исказила бы
    /// транскрипцию.
    var effectiveLLMPrompt: String? {
        guard isBuiltinService else { return nil }
        switch llmPreset {
        case .off:
            return nil
        case .custom:
            let trimmed = llmCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .meetingMinutes, .summary, .actionItems:
            return llmPreset.promptTemplate
        }
    }

    /// Разметка ролей для запроса с учётом гейтов (builtin + диаризация).
    private var rolesSpec: RolesSpec {
        guard diarize, isBuiltinService else { return .none }
        switch rolesMode {
        case .off:
            return .none
        case .auto:
            return .auto
        case .custom:
            guard case .success(let names) = SpeakerRolesParser.parse(rolesText) else { return .none }
            return .custom(names)
        }
    }

    private var pickedURL: URL?
    private var task: Task<Void, Never>?
    /// Запись «Недавних транскрибаций» текущей задачи (для done/error/cancel).
    private var currentRecordID: UUID?
    /// База имени для «Сохранить как…» у результата, открытого из «Недавних»:
    /// исходного файла может уже не быть, имя берётся из записи.
    private var restoredBaseName: String?

    /// Поддерживаемые форматы (белый список Nexara) — источник правды для drop,
    /// диалога выбора и валидации.
    static let audioExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "opus", "aiff", "asf"]
    static let videoExtensions = ["mp4", "mov", "avi", "mkv"]
    static var allExtensions: [String] { audioExtensions + videoExtensions }
    /// Лимит Nexara — 3 ГБ (тело запроса уходит потоково, память не зависит
    /// от размера файла — см. FileTranscriptionClient.writeMultipartBody).
    static let maxBytes: Int64 = 3_000_000_000

    /// Имя выбранного файла (для UI), если он выбран.
    var pickedFileName: String? {
        if case let .picked(name, _) = phase { return name }
        return nil
    }

    /// Идёт ли распознавание прямо сейчас.
    var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    /// Имя файла для зоны загрузки — и когда он выбран, и пока идёт
    /// распознавание (в .transcribing имени в phase нет, берём из pickedURL).
    var activeFileName: String? {
        switch phase {
        case let .picked(name, _): return name
        case .transcribing: return pickedURL?.lastPathComponent
        default: return nil
        }
    }

    /// Размер файла для зоны загрузки (см. `activeFileName`).
    var activeFileSize: Int64? {
        switch phase {
        case let .picked(_, size): return size
        case .transcribing: return pickedURL.map { fileSize(of: $0) }
        default: return nil
        }
    }

    /// Имя без расширения для дефолтного имени файла в диалоге «Сохранить как…».
    var suggestedBaseName: String {
        if let base = pickedURL?.deletingPathExtension().lastPathComponent, !base.isEmpty {
            return base
        }
        if let base = restoredBaseName, !base.isEmpty {
            return base
        }
        return "transcript"
    }

    /// Принять выбранный/перетащенный файл: проверить формат и размер.
    func accept(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard Self.allExtensions.contains(ext) else {
            phase = .error(L("transcribe.error.unsupportedFormat", ext.isEmpty ? "—" : ext))
            return
        }
        let size = fileSize(of: url)
        guard size <= Self.maxBytes else {
            phase = .error(L("transcribe.error.fileTooLarge"))
            return
        }
        task?.cancel()
        task = nil
        pickedURL = url
        restoredBaseName = nil
        phase = .picked(name: url.lastPathComponent, sizeBytes: size)
    }

    /// Запустить транскрипцию выбранного файла.
    func transcribe() {
        guard let url = pickedURL else { return }
        let route: ServiceRoute
        do {
            route = try SettingsStore.shared.resolveRoute()
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
        // Локальный сервис: без ключа и конфига, но модель должна быть скачана.
        if case .local(let model) = route, !LocalModelStore.shared.isDownloaded(model) {
            phase = .error(L("transcribe.local.modelMissing"))
            return
        }
        guard rolesValidationMessage == nil else { return }
        let options = FileTranscriptionOptions(
            language: language == "auto" ? nil : language,
            diarize: diarize,
            numSpeakers: isBuiltinService ? numSpeakers : nil,
            diarizationSetting: isBuiltinService ? diarizationSetting : .general,
            roles: rolesSpec,
            llmPrompt: effectiveLLMPrompt,
            timestampDetail: timestampDetail
        )
        phase = .transcribing
        let recordID = TranscriptHistoryStore.shared.addPending(
            fileName: url.lastPathComponent,
            provider: SettingsStore.shared.providerTagForHistory)
        currentRecordID = recordID
        let useAsync = isBuiltinService
        task = Task { [weak self] in
            do {
                let client = FileTranscriptionClient()
                let result: TranscriptResult
                switch route {
                case .local(let localModel):
                    // Локальный путь: движок + извлечение звука (в т.ч. из видео)
                    // + маппинг в TranscriptResult. Nexara-фичи (диаризация,
                    // роли, LLM) сюда не попадают — гейт isBuiltinService.
                    // Загрузка движка и декодирование независимы — перекрываем,
                    // чтобы холодный старт не ждал сумму двух операций.
                    async let engineLoading = LocalEngineManager.shared.engine(for: localModel)
                    let decoded = try await AudioFileDecoder.decodeToWav(url)
                    defer { try? FileManager.default.removeItem(at: decoded.url) }
                    let engine = try await engineLoading
                    guard !Task.isCancelled else { return }
                    let local = try await engine.transcribeFile(
                        wavURL: decoded.url,
                        language: options.language)
                    LocalEngineManager.shared.touch()
                    result = TranscriptResult(
                        fullText: local.fullText,
                        language: local.language ?? options.language,
                        duration: decoded.duration,
                        segments: local.segments,
                        rawSegments: local.segments,
                        words: local.words,
                        llmOutput: nil
                    ).withDetail(options.timestampDetail)
                case .remote(let apiKey, let config) where useAsync:
                    // Async-путь Nexara: сабмит сразу возвращает job_id,
                    // обработка идёт на сервере. job_id персистится до начала
                    // опроса — задача переживает перезапуск приложения
                    // (добор в TranscriptHistoryStore.resumePendingJobs).
                    let jobID = try await client.submitAsync(
                        fileURL: url, options: options, apiKey: apiKey, config: config)
                    guard !Task.isCancelled else { return }
                    TranscriptHistoryStore.shared.setJobID(recordID, jobID: jobID)
                    result = try await client.waitForResult(
                        jobID: jobID, apiKey: apiKey, config: config,
                        detail: options.timestampDetail,
                        deadline: Date().addingTimeInterval(TranscriptHistoryStore.serverResultLifetime))
                case .remote(let apiKey, let config):
                    result = try await client.transcribeRich(
                        fileURL: url, options: options, apiKey: apiKey, config: config)
                }
                guard !Task.isCancelled else { return }
                TranscriptHistoryStore.shared.markDone(recordID, result: result)
                self?.currentRecordID = nil
                self?.phase = .done(result)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                TranscriptHistoryStore.shared.markError(recordID, message: message)
                self?.currentRecordID = nil
                self?.phase = .error(message)
            }
        }
    }

    /// Отмена транскрипции: прервать запрос/опрос и вернуться к выбранному
    /// файлу. Async-задачу на сервере остановить нельзя (эндпоинта нет) —
    /// она доработает и тарифицируется, запись в «Недавних» честно остаётся
    /// со статусом «Отменена».
    func cancelTranscription() {
        task?.cancel()
        task = nil
        if let id = currentRecordID {
            TranscriptHistoryStore.shared.markCancelled(id)
            currentRecordID = nil
        }
        if let url = pickedURL {
            phase = .picked(name: url.lastPathComponent, sizeBytes: fileSize(of: url))
        } else {
            phase = .idle
        }
    }

    /// Открыть готовую запись «Недавних»: полный результат в карточки
    /// «Транскрибация»/«Анализ», перенарезка — от сохранённых rawSegments и
    /// words, так что смена детализации и все форматы экспорта работают.
    func restore(_ record: FileTranscriptRecord) {
        guard case .done = record.status, let stored = record.result,
              !isTranscribing else { return }
        task?.cancel()
        task = nil
        currentRecordID = nil
        pickedURL = nil
        restoredBaseName = (record.fileName as NSString).deletingPathExtension
        phase = .done(stored.toResult(detail: timestampDetail))
    }

    /// Скрыть показанный результат: вернуться к выбранному файлу либо к
    /// пустой странице (у результата, открытого из «Недавних», файла уже нет).
    /// Сам результат не теряется — он остаётся в «Недавних».
    func hideResult() {
        guard case .done = phase else { return }
        restoredBaseName = nil
        if let url = pickedURL {
            phase = .picked(name: url.lastPathComponent, sizeBytes: fileSize(of: url))
        } else {
            phase = .idle
        }
    }

    /// Сброс: убрать файл и результат.
    func clear() {
        task?.cancel()
        task = nil
        pickedURL = nil
        restoredBaseName = nil
        phase = .idle
    }

    private func fileSize(of url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return Int64(size)
        }
        if let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            return number.int64Value
        }
        return 0
    }
}
