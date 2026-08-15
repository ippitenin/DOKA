import Foundation
import WhisperKit
import FluidAudio

/// Скачивание и состояние локальных моделей. Модели живут в ФИКСИРОВАННОЙ
/// папке `Application Support/DOKA/Models` (`AppDataFolder.modelsURL`) и НЕ
/// переезжают вместе с «Папкой данных»: это перекачиваемый кеш, а не данные
/// пользователя — перенос 1.5+ ГБ сделал бы миграцию папки блокирующей.
@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(Double)   // прогресс 0…1
        case preparing             // прогрев: первая CoreML-компиляция под чип
        case ready(Int64)          // размер на диске в байтах
        case failed(String)
    }

    @Published private(set) var states: [LocalModel: ModelState] = [:]

    private var downloadTasks: [LocalModel: Task<Void, Never>] = [:]

    /// Последний известный размер модели на диске; считается фоном
    /// (`refreshSize`), до готовности показывается примерный размер скачивания.
    private var knownSizes: [LocalModel: Int64] = [:]

    private init() {
        for model in LocalModel.allCases {
            if Self.isOnDisk(model) {
                states[model] = .ready(readySize(model))
                refreshSize(model)
            } else {
                states[model] = .notDownloaded
            }
        }
        // Осиротевшие папки незавершённого фонового удаления (kill приложения
        // во время стирания модели) — подчищаем, они только занимают диск.
        Task.detached(priority: .utility) { Self.sweepDeleteLeftovers() }
    }

    // MARK: - Пути

    /// База скачивания WhisperKit; HubApi раскладывает внутрь по схеме
    /// `models/<владелец>/<репозиторий>/<вариант>`.
    nonisolated static let whisperBase = AppDataFolder.modelsURL
        .appendingPathComponent("whisper", isDirectory: true)

    /// Итоговая папка модели Whisper (файлы .mlmodelc + config).
    nonisolated static let whisperModelFolder = whisperBase
        .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        .appendingPathComponent(LocalModel.whisperKitVariant, isDirectory: true)

    /// Папка моделей Parakeet; структуру внутри ведёт FluidAudio.
    nonisolated static let parakeetFolder = AppDataFolder.modelsURL
        .appendingPathComponent("parakeet", isDirectory: true)

    private nonisolated static func rootFolder(for model: LocalModel) -> URL {
        switch model {
        case .whisper: return whisperBase
        case .parakeet: return parakeetFolder
        }
    }

    // MARK: - Состояние

    /// Файлы модели на месте (независимо от того, загружена ли она в память).
    func isDownloaded(_ model: LocalModel) -> Bool {
        switch states[model] {
        case .ready, .preparing: return true
        default: return false
        }
    }

    func state(for model: LocalModel) -> ModelState {
        states[model] ?? .notDownloaded
    }

    /// Проверка файлов на диске (без обращения к состоянию в памяти).
    private static func isOnDisk(_ model: LocalModel) -> Bool {
        switch model {
        case .whisper:
            // Ключевые компоненты варианта; частично скачанная папка не считается.
            let fm = FileManager.default
            return fm.fileExists(atPath: whisperModelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
                && fm.fileExists(atPath: whisperModelFolder.appendingPathComponent("TextDecoder.mlmodelc").path)
        case .parakeet:
            return AsrModels.modelsExist(at: parakeetFolder, version: .v3)
        }
    }

    /// Размер для состояния `.ready`: последний посчитанный, до него — оценка.
    private func readySize(_ model: LocalModel) -> Int64 {
        knownSizes[model] ?? model.approxDownloadBytes
    }

    /// Пересчитывает размер модели фоновым обходом папки: рекурсивный stat
    /// многогигабайтного дерева на главном потоке блокировал бы запуск
    /// приложения (первое обращение к синглтону — в `applicationDidFinishLaunching`).
    private func refreshSize(_ model: LocalModel) {
        Task.detached(priority: .utility) {
            let size = Self.sizeOnDisk(model)
            await MainActor.run {
                let store = LocalModelStore.shared
                store.knownSizes[model] = size
                if case .ready = store.state(for: model) {
                    store.states[model] = .ready(size)
                }
            }
        }
    }

    private nonisolated static func sizeOnDisk(_ model: LocalModel) -> Int64 {
        directorySize(rootFolder(for: model))
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Скачивание

    /// Прогресс-синк для Sendable-колбэков SDK: пропускает на главный актёр
    /// только смену целого процента — URLSession шлёт колбэки на каждый чанк,
    /// и без квантования перерисовка SwiftUI дёргалась бы сотни раз в секунду.
    /// Синглтон напрямую, без захвата слабого self из внешней задачи.
    private final class ProgressSink: @unchecked Sendable {
        private let model: LocalModel
        private let lock = NSLock()
        private var lastPercent = -1

        init(model: LocalModel) { self.model = model }

        /// Вход — уже извлечённая дробь: у WhisperKit прогресс `Foundation.Progress`,
        /// у FluidAudio — собственный `DownloadProgress`, общего типа нет.
        func report(fraction: Double) {
            let percent = Int(fraction * 100)
            lock.lock()
            let changed = percent != lastPercent
            if changed { lastPercent = percent }
            lock.unlock()
            guard changed else { return }
            Task { @MainActor [model] in
                LocalModelStore.shared.updateProgress(model, fraction)
            }
        }
    }

    func download(_ model: LocalModel) {
        // Барьер платформы здесь, а не только в `.disabled` кнопки: любой
        // другой путь к скачиванию не должен качать неподдерживаемую модель.
        guard !model.requiresAppleSilicon || LocalModel.isAppleSiliconMac else {
            states[model] = .failed(L("service.local.intelUnsupported"))
            return
        }
        if case .downloading = state(for: model) { return }
        states[model] = .downloading(0)

        let task = Task { [weak self] in
            do {
                let sink = ProgressSink(model: model)
                switch model {
                case .whisper:
                    _ = try await WhisperKit.download(
                        variant: LocalModel.whisperKitVariant,
                        downloadBase: Self.whisperBase,
                        progressCallback: { sink.report(fraction: $0.fractionCompleted) }
                    )
                case .parakeet:
                    _ = try await AsrModels.download(
                        to: Self.parakeetFolder,
                        progressHandler: { sink.report(fraction: $0.fractionCompleted) }
                    )
                }
                try Task.checkCancellation()
                self?.finishDownload(model)
            } catch {
                // SDK может обернуть отмену в свою ошибку — ловим оба вида.
                if error is CancellationError || Task.isCancelled {
                    self?.cleanupAfterCancel(model)
                } else {
                    NSLog("DOKA: скачивание модели \(model.rawValue) не удалось: \(error.localizedDescription)")
                    Self.removePartial(model)
                    self?.states[model] = .failed(error.localizedDescription)
                }
            }
            self?.downloadTasks[model] = nil
        }
        downloadTasks[model] = task
    }

    func cancelDownload(_ model: LocalModel) {
        downloadTasks[model]?.cancel()
    }

    private func updateProgress(_ model: LocalModel, _ fraction: Double) {
        // Не перетираем финальные состояния запоздавшим колбэком.
        if case .downloading = state(for: model) {
            states[model] = .downloading(min(max(fraction, 0), 1))
        }
    }

    private func finishDownload(_ model: LocalModel) {
        guard Self.isOnDisk(model) else {
            Self.removePartial(model)
            states[model] = .failed(L("service.local.downloadIncomplete"))
            return
        }
        states[model] = .ready(readySize(model))
        refreshSize(model)
        // Прогрев сразу после скачивания: первая CoreML-компиляция под чип
        // уходит в статус «Подготовка модели…», а не в первую диктовку.
        Task { await LocalEngineManager.shared.prewarm(model) }
    }

    private func cleanupAfterCancel(_ model: LocalModel) {
        // Частично скачанные файлы убираем, чтобы не притворялись готовой моделью.
        Self.removePartial(model)
        knownSizes[model] = nil
        states[model] = .notDownloaded
    }

    /// Убирает папку модели с диска: мгновенное переименование на том же томе
    /// плюс фоновое удаление — синхронное стирание многогигабайтного дерева
    /// на главном потоке замораживало бы UI ровно в момент клика.
    private static func removePartial(_ model: LocalModel) {
        let fm = FileManager.default
        let folder = rootFolder(for: model)
        guard fm.fileExists(atPath: folder.path) else { return }
        let trash = folder.deletingLastPathComponent()
            .appendingPathComponent("\(folder.lastPathComponent).deleting-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: folder, to: trash)
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: trash)
            }
        } catch {
            // Переименование не удалось — удаляем на месте (редкий путь).
            try? fm.removeItem(at: folder)
        }
    }

    /// Осиротевшие папки `*.deleting-*` после kill во время фонового удаления.
    private nonisolated static func sweepDeleteLeftovers() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: AppDataFolder.modelsURL.path) else { return }
        for name in items where name.contains(".deleting-") {
            try? fm.removeItem(at: AppDataFolder.modelsURL.appendingPathComponent(name))
        }
    }

    // MARK: - Прогрев и удаление

    /// Переводит модель в «Подготовка…» на время первой CoreML-компиляции
    /// (вызывается менеджером движков), затем обратно в «Готова».
    func markPreparing(_ model: LocalModel, _ preparing: Bool) {
        if preparing {
            if case .ready = state(for: model) { states[model] = .preparing }
        } else if case .preparing = state(for: model) {
            // Размер известен с прошлого `.ready` — файлы между «Готова» и
            // «Подготовка…» не менялись, пересчёт папки не нужен.
            states[model] = .ready(readySize(model))
        }
    }

    func delete(_ model: LocalModel) {
        cancelDownload(model)
        LocalEngineManager.shared.unloadIfCurrent(model)
        Self.removePartial(model)
        knownSizes[model] = nil
        states[model] = .notDownloaded
    }
}
