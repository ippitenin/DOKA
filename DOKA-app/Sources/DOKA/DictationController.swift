import AppKit
import Foundation

/// Конечный автомат диктовки: idle → recording → transcribing → idle.
/// Управляет записью, обращением к сервису распознавания, заменами,
/// вставкой и историей.
///
/// Счётчик поколений `generation` инвалидирует «зависшие» задачи: любая смена
/// состояния увеличивает его, и задача транскрипции, захватившая старое значение,
/// не имеет права трогать автомат или вставлять текст.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
        case error(message: String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published var audioLevel: Float = 0

    /// Слабые ссылки: владеет всеми объектами AppDelegate.
    weak var hotkeys: HotkeyManager?
    weak var panelController: RecorderPanelController?
    /// Открытие онбординга, если не хватает разрешений или ключа.
    var onNeedsOnboarding: (() -> Void)?

    private let recorder = AudioRecorder()
    private let micBooster = MicrophoneVolumeBooster()
    private let client = TranscriptionClient()
    private let settings = SettingsStore.shared
    private let history = HistoryStore.shared
    private let stats = StatsStore.shared
    private var errorDismissTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var generation = 0

    /// Минимальная длительность записи, ниже которой API не вызывается.
    private static let minDuration: TimeInterval = 0.4

    init() {
        recorder.onLevel = { [weak self] level in
            self?.audioLevel = level
        }
        // Смена аудиоустройства во время записи: мягко завершаем с тем, что есть.
        recorder.onConfigurationChange = { [weak self] in
            guard let self, self.state.isRecording else { return }
            self.finishRecording()
        }
    }

    // MARK: - Действия хоткеев

    func toggle() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            finishRecording()
        case .transcribing:
            break // идёт запрос — отмена через Esc
        }
    }

    /// Push-to-talk: зажатие начинает запись (только из покоя — повторные
    /// авторепиты keyDown во время записи игнорируются)…
    func pushToTalkDown() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording, .transcribing:
            break
        }
    }

    /// …отпускание — завершает и отправляет на распознавание. Случайное
    /// короткое нажатие отсеет существующий порог minDuration.
    func pushToTalkUp() {
        guard state.isRecording else { return }
        finishRecording()
    }

    func cancel() {
        switch state {
        case .recording:
            recorder.cancelAndDelete()
            SoundPlayer.play(.cancel)
            transition(to: .idle)
        case .transcribing:
            transcriptionTask?.cancel()
            transcriptionTask = nil
            SoundPlayer.play(.cancel)
            transition(to: .idle)
        case .idle, .error:
            break
        }
    }

    func pasteLastTranscription() {
        // Во время записи/распознавания вставка ломала бы автомат — игнорируем.
        switch state {
        case .recording, .transcribing:
            return
        case .idle, .error:
            break
        }
        guard let text = history.lastText else {
            showError(L("error.historyEmpty"))
            return
        }
        Task {
            do {
                try await Paster.paste(text, restoreClipboard: settings.restoreClipboard)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Цикл записи

    private func startRecording() {
        let permissions = PermissionsManager.shared
        permissions.refresh()
        guard permissions.micAuthorized, permissions.axTrusted else {
            onNeedsOnboarding?()
            return
        }
        guard settings.isServiceReady else {
            // Локальный сервис не готов = модель не скачана; сетевой — нет ключа.
            showError(settings.isLocalService
                ? L("error.localModelMissing")
                : L("error.noAPIKey"))
            onNeedsOnboarding?()
            return
        }

        do {
            _ = try recorder.start()
        } catch {
            showError(error.localizedDescription)
            return
        }
        if settings.micAutoBoost {
            micBooster.beginBoost()
        }
        SoundPlayer.play(.recordStart)
        transition(to: .recording(startedAt: Date()))
    }

    private func finishRecording() {
        guard state.isRecording else { return }
        guard let result = recorder.stop() else {
            showError(L("error.saveRecordingFailed"))
            return
        }
        SoundPlayer.play(.recordStop)

        guard result.duration >= Self.minDuration else {
            try? FileManager.default.removeItem(at: result.url)
            transition(to: .idle)
            return
        }

        // Имя микрофона для метаданных истории — независимо от уже остановленного движка.
        let microphone = recorder.currentInputDeviceName
        transition(to: .transcribing)
        let gen = generation
        transcriptionTask = Task {
            await transcribeAndPaste(url: result.url, duration: result.duration,
                                     speechDuration: result.speechDuration,
                                     microphone: microphone, generation: gen)
        }
    }

    private func transcribeAndPaste(url: URL, duration: TimeInterval,
                                    speechDuration: TimeInterval,
                                    microphone: String?, generation gen: Int) async {
        defer { try? FileManager.default.removeItem(at: url) }

        // Маршрут распознавания: локальный движок или сетевой клиент.
        let route: ServiceRoute
        do {
            route = try settings.resolveRoute()
        } catch {
            if generation == gen { showError(error.localizedDescription) }
            return
        }
        let language = settings.language
        let providerRaw = settings.providerTagForHistory
        let modelTag = route.modelTag

        // Копия без тишины — только для отправки: история, статистика и m4a
        // работают с оригиналом. Обрезка — CPU-работа вне главного потока.
        var uploadURL = url
        if settings.silenceRemoval {
            let trimmed = await Task.detached(priority: .userInitiated) {
                SilenceRemover.process(url)
            }.value
            guard generation == gen else {
                if let trimmed { try? FileManager.default.removeItem(at: trimmed) }
                return
            }
            if let trimmed { uploadURL = trimmed }
        }
        defer {
            if uploadURL != url { try? FileManager.default.removeItem(at: uploadURL) }
        }

        do {
            let started = Date()
            let raw: String
            switch route {
            case .local(let localModel):
                // Загрузка движка — тоже await: после неё те же права на автомат,
                // что и после любого другого await (проверка generation ниже).
                let engine = try await LocalEngineManager.shared.engine(for: localModel)
                guard generation == gen else { return }
                raw = try await engine.transcribeDictation(
                    wavURL: uploadURL,
                    language: language == "auto" ? nil : language
                )
                LocalEngineManager.shared.touch()
            case .remote(let apiKey, let config):
                raw = try await client.transcribe(
                    fileURL: uploadURL,
                    language: language == "auto" ? nil : language,
                    apiKey: apiKey,
                    config: config
                )
            }
            let transcriptionTime = Date().timeIntervalSince(started)
            guard generation == gen else { return }   // отменено пользователем
            let text = ReplacementEngine.apply(raw, rules: settings.replacements)
            // Кодируем аудио в m4a ДО выхода (defer уберёт исходный WAV). id фиксируем заранее,
            // чтобы имя файла и запись истории гарантированно совпадали. Если сохранение аудио
            // выключено — кодирование пропускаем целиком, и вставка не ждёт его (быстрее).
            let recordID = UUID()
            let audioName = settings.saveAudio
                ? await AudioStore.shared.encode(wavURL: url, recordID: recordID)
                : nil
            // Отмена могла произойти во время кодирования (ещё один await) — устаревшая
            // задача не должна писать в историю и вставлять текст. Закодированный файл убираем.
            guard generation == gen else {
                if let audioName { AudioStore.shared.removeFile(named: audioName) }
                return
            }
            history.add(id: recordID, text: text, duration: duration, language: language,
                        speechDuration: speechDuration, model: modelTag, provider: providerRaw,
                        microphone: microphone, transcriptionTime: transcriptionTime,
                        audioFileName: audioName)
            stats.record(text: text, duration: duration, speechDuration: speechDuration)
            do {
                try await Paster.paste(text, restoreClipboard: settings.restoreClipboard)
                guard generation == gen else { return }
                transition(to: .idle)
            } catch {
                guard generation == gen else { return }
                // Текст уже в буфере обмена и в истории — сообщаем и живём дальше.
                showError(error.localizedDescription)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == gen else { return }
            showError(error.localizedDescription)
        }
    }

    // MARK: - Состояния

    private func transition(to newState: State) {
        generation += 1
        errorDismissTask?.cancel()
        errorDismissTask = nil
        // Уход из записи любым путём (стоп, отмена, ошибка, смена устройства) —
        // громкость микрофона возвращается к прежней. Без буста — no-op.
        if state.isRecording, !newState.isRecording {
            micBooster.endBoost()
        }
        state = newState
        audioLevel = 0
        // Esc активен при записи и при распознавании (отмена запроса).
        hotkeys?.setEscapeEnabled(newState.isRecording || newState == .transcribing)

        switch newState {
        case .idle:
            panelController?.hide()
        case .recording, .transcribing, .error:
            panelController?.show()
        }
    }

    private func showError(_ message: String) {
        SoundPlayer.play(.error)
        transition(to: .error(message: message))
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            if case .error = self?.state {
                self?.transition(to: .idle)
            }
        }
    }
}
