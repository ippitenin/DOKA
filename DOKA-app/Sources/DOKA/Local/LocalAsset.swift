import Foundation

/// Скачиваемый ресурс, живущий в `Application Support/DOKA/Models`.
/// Речевые модели — это сервисы распознавания (попадают в `providerID` и в
/// пикер «Сервис»), диаризатор — нет: он вспомогательный движок, который
/// включается тумблером «Определять спикеров» при любом сервисе, кроме
/// встроенного. Поэтому расширять `LocalModel` нельзя (`allCases` строит меню
/// сервисов) — общий у них только механизм скачивания и хранения.
enum LocalAsset: Hashable {
    case speech(LocalModel)
    case diarizer

    /// Ассоциированные значения не дают синтезировать `CaseIterable`.
    static var allCases: [LocalAsset] {
        LocalModel.allCases.map { .speech($0) } + [.diarizer]
    }

    /// Примерный размер скачивания — только для подписи до скачивания
    /// (после — показывается реальный размер на диске).
    var approxDownloadBytes: Int64 {
        switch self {
        case .speech(let model): return model.approxDownloadBytes
        case .diarizer: return 23_000_000
        }
    }

    /// Ресурс не работает на Intel. У диаризатора (pyannote + WeSpeaker)
    /// гварда Apple Silicon нет ни в FluidAudio, ни в самих моделях —
    /// на Intel он идёт через CPU.
    var requiresAppleSilicon: Bool {
        switch self {
        case .speech(let model): return model.requiresAppleSilicon
        case .diarizer: return false
        }
    }

    /// Для логов; в UI ресурсы подписываются своими строками.
    var logName: String {
        switch self {
        case .speech(let model): return model.rawValue
        case .diarizer: return "diarizer"
        }
    }
}
