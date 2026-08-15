import AVFoundation
import Foundation

/// Запись с микрофона: AVAudioEngine tap → AVAudioConverter → 16 кГц mono Int16 WAV.
///
/// Tap-колбэк приходит на внутреннем потоке AVAudioEngine, а start/stop/cancel —
/// с главного. Всё состояние сессии (конвертер, writer, уровень) живёт в Session
/// и доступно ТОЛЬКО на последовательной очереди `queue` — это устраняет гонку
/// между дозаписью хвостовых буферов и финализацией файла.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return L("error.noInputDevice")
            case .engineStartFailed: return L("error.recordingStartFailed")
            }
        }
    }

    /// Колбэки вызываются на главном потоке.
    var onLevel: ((Float) -> Void)?
    var onConfigurationChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.pitenin.doka.audio")
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?

    /// Порог нормализованного уровня (0…1), выше которого буфер считается «речью».
    /// Тишина/фоновый шум (~−50…−40 дБ) даёт уровень ниже, реальный голос — выше.
    /// Нужен для оценки активного времени речи без пауз (статистика дашборда).
    private static let speechLevelThreshold: Float = 0.2

    /// Состояние одной сессии записи. Доступ только на `queue`.
    private final class Session {
        let converter: AVAudioConverter
        let writer: WavWriter
        let targetFormat: AVAudioFormat
        var smoothedLevel: Float = 0
        /// Накопленное время, когда реально звучал голос (сек), без тишины и пауз.
        var speechTime: TimeInterval = 0
        var finished = false

        init(converter: AVAudioConverter, writer: WavWriter, targetFormat: AVAudioFormat) {
            self.converter = converter
            self.writer = writer
            self.targetFormat = targetFormat
        }
    }

    private var session: Session?   // мутируется только внутри queue.sync

    var isRecording: Bool { engine != nil }

    /// Имя текущего системного устройства ввода по умолчанию — для метаданных истории.
    /// Best-effort: может быть nil (нет устройства/прав). Читать на главном потоке.
    var currentInputDeviceName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// Стартует запись во временный WAV-файл, возвращает его URL.
    func start() throws -> URL {
        teardownEngine()
        discardSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.noInputDevice
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url)
        let newSession = Session(converter: converter, writer: writer, targetFormat: targetFormat)
        queue.sync { session = newSession }

        let queue = self.queue
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Сессия захвачена по значению: «хвостовые» колбэки старой сессии
            // после finished=true просто отбрасываются.
            queue.async { self?.process(buffer: buffer, in: newSession) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            discardSession()
            throw RecorderError.engineStartFailed(error)
        }
        self.engine = engine

        // Смена/пропажа аудиоустройства (подключили AirPods и т.п.).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
        return url
    }

    /// Останавливает запись, дожимает хвост конвертера и финализирует WAV.
    /// `speechDuration` — время активной речи (сек) без тишины и пауз.
    func stop() -> (url: URL, duration: TimeInterval, speechDuration: TimeInterval)? {
        teardownEngine()
        var result: (url: URL, duration: TimeInterval, speechDuration: TimeInterval)?
        queue.sync {
            guard let s = session, !s.finished else {
                session = nil
                return
            }
            s.finished = true
            drain(s)
            let duration = s.writer.duration
            let speechDuration = s.speechTime
            do {
                try s.writer.finalize()
                result = (s.writer.url, duration, speechDuration)
            } catch {
                NSLog("DOKA: ошибка финализации WAV: \(error.localizedDescription)")
                s.writer.cancelAndDelete()
            }
            session = nil
        }
        return result
    }

    /// Отмена: остановить и удалить файл.
    func cancelAndDelete() {
        teardownEngine()
        discardSession()
    }

    private func teardownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func discardSession() {
        queue.sync {
            session?.finished = true
            session?.writer.cancelAndDelete()
            session = nil
        }
    }

    // Выполняется на queue.
    private func process(buffer: AVAudioPCMBuffer, in session: Session) {
        guard !session.finished else { return }

        // Уровень: RMS по первому каналу исходного float-буфера.
        if let channel = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            if frames > 0 {
                var sum: Float = 0
                for i in 0..<frames { sum += channel[i] * channel[i] }
                let rms = sqrt(sum / Float(frames))
                // Логарифмическое масштабирование в 0…1 и сглаживание.
                let db = 20 * log10(max(rms, 1e-7))
                let normalized = max(0, min(1, (db + 50) / 50))
                // Активная речь: буфер выше порога — добавляем его реальную длительность.
                if normalized >= Self.speechLevelThreshold {
                    session.speechTime += Double(frames) / buffer.format.sampleRate
                }
                session.smoothedLevel = session.smoothedLevel * 0.7 + normalized * 0.3
                let level = session.smoothedLevel
                DispatchQueue.main.async { [weak self] in
                    self?.onLevel?(level)
                }
            }
        }

        // Ресемплинг в 16 кГц mono Int16.
        let ratio = session.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: session.targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        let status = session.converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, convError == nil else { return }
        append(outBuffer, to: session)
    }

    // Выполняется на queue: дожимает остаток сэмплов из конвертера.
    private func drain(_ session: Session) {
        for _ in 0..<8 {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: session.targetFormat, frameCapacity: 4096) else { return }
            var convError: NSError?
            let status = session.converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            append(outBuffer, to: session)
            if status != .haveData || outBuffer.frameLength == 0 { return }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to session: Session) {
        guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        session.writer.append(Data(bytes: samples, count: byteCount))
    }
}
