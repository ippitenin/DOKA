import AppKit

/// Звуковые сигналы приложения (системные звуки macOS).
@MainActor
enum SoundPlayer {
    enum Event {
        case recordStart, recordStop, cancel, error

        var systemSoundName: String {
            switch self {
            case .recordStart: return "Pop"
            case .recordStop: return "Tink"
            case .cancel: return "Funk"
            case .error: return "Basso"
            }
        }
    }

    /// Ссылка на играющий звук: без неё ARC освободит NSSound до конца
    /// проигрывания, и выставленная громкость не успеет прозвучать.
    private static var current: NSSound?

    static func play(_ event: Event) {
        guard SettingsStore.shared.soundsEnabled else { return }
        guard let sound = NSSound(named: event.systemSoundName) else { return }
        sound.volume = Float(SettingsStore.shared.soundVolume)
        current = sound
        sound.play()
    }
}
