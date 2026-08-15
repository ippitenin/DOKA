import AVFoundation
import Foundation

/// Воспроизведение аудио истории для SwiftUI-ползунка. Один активный плеер на всё
/// приложение (singleton): разворачивание второй карточки останавливает первую.
@MainActor
final class RecordingPlayer: NSObject, ObservableObject {
    static let shared = RecordingPlayer()

    /// id записи, чьё аудио сейчас загружено (для подсветки нужной карточки).
    @Published private(set) var currentRecordID: UUID?
    @Published private(set) var isPlaying = false
    /// Двусторонняя привязка к слайдеру. Пока тащим ползунок — тикер её не перетирает.
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Выставляется вью на время drag слайдера.
    var isScrubbing = false

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    private override init() { super.init() }

    /// Загружает (если ещё не та запись) и play/pause toggle.
    func toggle(url: URL, recordID: UUID) {
        if currentRecordID == recordID, player != nil {
            isPlaying ? pause() : play()
            return
        }
        load(url: url, recordID: recordID)
        play()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    /// Перемотка ползунком.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let t = min(max(0, time), duration)
        player.currentTime = t
        currentTime = t
    }

    /// Полная остановка и выгрузка — при сворачивании карточки / смене секции / удалении.
    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        isPlaying = false
        currentRecordID = nil
        currentTime = 0
        duration = 0
    }

    /// Остановить, только если загружена именно эта запись.
    func stopIfCurrent(_ recordID: UUID) {
        if currentRecordID == recordID { stop() }
    }

    private func load(url: URL, recordID: UUID) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        currentRecordID = recordID
        duration = p.duration
        currentTime = 0
    }

    private func startTicker() {
        stopTicker()
        // Таймер запланирован на главном runloop и срабатывает на главном потоке.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, !self.isScrubbing else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension RecordingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.stopTicker()
        }
    }
}
