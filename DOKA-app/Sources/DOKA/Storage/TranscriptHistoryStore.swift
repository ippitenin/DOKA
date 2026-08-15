import Foundation

/// Компактная форма результата транскрибации для диска: без производного
/// `segments` — отображаемая нарезка восстанавливается `withDetail` при
/// открытии записи, хранить её значит удваивать JSON.
struct StoredTranscript: Codable, Equatable {
    let fullText: String
    let language: String?
    let duration: Double?
    let rawSegments: [TranscriptSegment]
    let words: [TranscriptWord]
    let llmOutput: String?

    init(_ result: TranscriptResult) {
        fullText = result.fullText
        language = result.language
        duration = result.duration
        rawSegments = result.rawSegments
        words = result.words
        llmOutput = result.llmOutput
    }

    /// Результат с нарезкой под запрошенную детализацию — тем же путём
    /// `withDetail`, что и живой ответ сервера.
    func toResult(detail: TimestampDetail) -> TranscriptResult {
        TranscriptResult(fullText: fullText, language: language, duration: duration,
                         segments: rawSegments, rawSegments: rawSegments, words: words,
                         llmOutput: llmOutput).withDetail(detail)
    }
}

/// Одна запись «Недавних транскрибаций». Запись со статусом `inProgress` и
/// `jobID` — одновременно элемент списка и точка восстановления async-задачи
/// после перезапуска приложения.
struct FileTranscriptRecord: Codable, Identifiable, Equatable {
    enum Status: Codable, Equatable {
        case inProgress
        case done
        case error(String)       // локализованный текст для показа
        case cancelled           // отменена пользователем: задачу на сервере
                                 // остановить нельзя, но результат не забираем
    }

    let id: UUID
    let fileName: String         // имя исходного файла: показ + база «Сохранить как…»
    let date: Date               // момент постановки; от него же дедлайн 12 ч
    var status: Status
    var result: StoredTranscript?    // только при .done
    let provider: String             // SettingsStore.providerTagForHistory
    var language: String?
    var duration: Double?
    var jobID: String?               // async-задача Nexara; nil — sync кастомного сервиса
}

/// «Недавние транскрибации»: журнал файловых транскрипций поверх JSON-файла
/// в папке данных. Намеренно ОТДЕЛЬНЫЙ от `HistoryStore` диктовки — пайплайны
/// изолированы (инвариант проекта). Хранит полный результат (сегменты, слова,
/// анализ): открытие записи полностью восстанавливает карточки «Транскрибация»
/// и «Анализ», включая смену детализации и все форматы экспорта.
@MainActor
final class TranscriptHistoryStore: ObservableObject {
    static let shared = TranscriptHistoryStore()
    private static let limit = 50

    /// Имя файла журнала в папке данных (показывается в «Расширенных» настройках).
    static let fileName = "transcripts.json"

    /// Срок жизни результата async-задачи на сервере Nexara: после него
    /// добирать нечего (результат удалён безвозвратно).
    static let serverResultLifetime: TimeInterval = 12 * 3_600

    @Published private(set) var records: [FileTranscriptRecord] = []

    private let fileURL: URL
    /// Задачи добора результатов после перезапуска, по id записи —
    /// удаление записи отменяет её опрос.
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]

    private init() {
        let dir = AppDataFolder.currentURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(Self.fileName)
        load()
    }

    // MARK: - Жизненный цикл записи

    @discardableResult
    func addPending(fileName: String, provider: String) -> UUID {
        let record = FileTranscriptRecord(id: UUID(), fileName: fileName, date: Date(),
                                          status: .inProgress, result: nil,
                                          provider: provider, language: nil,
                                          duration: nil, jobID: nil)
        records.insert(record, at: 0)
        trimToLimit()
        save()
        return record.id
    }

    /// job_id персистится сразу после сабмита: если приложение умрёт во время
    /// опроса, задача доберётся на следующем старте.
    func setJobID(_ id: UUID, jobID: String) {
        update(id) { $0.jobID = jobID }
    }

    func markDone(_ id: UUID, result: TranscriptResult) {
        update(id) {
            $0.status = .done
            $0.result = StoredTranscript(result)
            $0.language = result.language
            $0.duration = result.duration
        }
    }

    func markError(_ id: UUID, message: String) {
        update(id) { $0.status = .error(message) }
    }

    /// Отмена осмысленна только для выполняющейся записи: готовую/ошибочную
    /// не трогаем (гонка «задача завершилась в момент отмены»).
    func markCancelled(_ id: UUID) {
        update(id) {
            guard $0.status == .inProgress else { return }
            $0.status = .cancelled
        }
    }

    func delete(_ id: UUID) {
        recoveryTasks[id]?.cancel()
        recoveryTasks[id] = nil
        records.removeAll { $0.id == id }
        save()
    }

    /// Завершённые записи (done/error/cancelled) старше срока — удалить.
    /// Выполняющиеся не трогаем: их судьбу решает recovery/опрос.
    func prune(olderThanHours hours: Int) {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3_600)
        let before = records.count
        records.removeAll { $0.date < cutoff && $0.status != .inProgress }
        if records.count != before { save() }
    }

    // MARK: - Восстановление после перезапуска

    /// Добор незавершённых задач; один вызов на старте (AppDelegate).
    /// Sync-записи без jobID безнадёжны — запрос умер вместе с процессом;
    /// async-задачи старше 12 ч истекли на сервере; остальные опрашиваются
    /// в фоне, результат попадает только в стор (фаза контроллера остаётся
    /// idle — пользователь открывает запись из списка).
    func resumePendingJobs() {
        let pending = records.filter { $0.status == .inProgress }
        guard !pending.isEmpty else { return }

        // Безнадёжные записи гасим сразу, без сети и Keychain.
        let now = Date()
        var recoverable: [(id: UUID, jobID: String, deadline: Date)] = []
        for record in pending {
            guard let jobID = record.jobID else {
                markError(record.id, message: L("transcribe.async.interrupted"))
                continue
            }
            let deadline = record.date.addingTimeInterval(Self.serverResultLifetime)
            guard now < deadline else {
                markError(record.id, message: L("transcribe.async.jobNotFound"))
                continue
            }
            recoverable.append((record.id, jobID, deadline))
        }
        guard !recoverable.isEmpty,
              let endpoint = TranscriptionProvider.builtin.endpoint else { return }
        // Credentials всегда builtin, а не текущего сервиса: незавершённая
        // async-задача — нексаровская, даже если пользователь уже
        // переключился на кастомный пресет.
        let config = ProviderConfig(endpoint: endpoint,
                                    model: TranscriptionProvider.builtin.defaultModel)

        Task { [weak self] in
            // Ключ читается лениво и ВНЕ главного потока: Keychain может
            // показать диалог подтверждения (например, после пересборки
            // с новой подписью), и синхронное чтение в пути запуска
            // заморозило бы всё приложение до ответа пользователя.
            let apiKey = await Task.detached { KeychainHelper.getAPIKey(for: .builtin) }.value
            guard let self, !Task.isCancelled else { return }
            guard let apiKey else {
                for item in recoverable {
                    self.markError(item.id, message: L("error.noAPIKey"))
                }
                return
            }
            var startDelay: TimeInterval = 0
            for item in recoverable {
                let delay = startDelay
                startDelay += 0.5   // стаггер стартов: лимит Nexara — 10 запросов/с
                self.recoveryTasks[item.id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    do {
                        // Детализация не важна: в StoredTranscript уходят только
                        // rawSegments/words, нарезка выполняется при открытии.
                        let result = try await FileTranscriptionClient().waitForResult(
                            jobID: item.jobID, apiKey: apiKey, config: config,
                            detail: .server, deadline: item.deadline)
                        guard !Task.isCancelled else { return }
                        self?.markDone(item.id, result: result)
                    } catch {
                        guard !Task.isCancelled else { return }
                        let message = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                        self?.markError(item.id, message: message)
                    }
                    self?.recoveryTasks[item.id] = nil
                }
            }
        }
    }

    // MARK: - Служебное

    /// Точечное изменение записи; no-op, если записи уже нет (пользователь
    /// удалил её, пока задача завершалась).
    private func update(_ id: UUID, _ mutate: (inout FileTranscriptRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        save()
    }

    /// Вытеснение за лимит: с конца, пропуская выполняющиеся записи.
    private func trimToLimit() {
        var excess = records.count - Self.limit
        guard excess > 0 else { return }
        for index in stride(from: records.count - 1, through: 0, by: -1) where excess > 0 {
            if records[index].status != .inProgress {
                records.remove(at: index)
                excess -= 1
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([FileTranscriptRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
