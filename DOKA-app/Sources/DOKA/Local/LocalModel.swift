import Foundation

/// Локальная модель распознавания речи (on-device, без сети после скачивания).
/// В `SettingsStore.providerID` кодируется как `"local:<rawValue>"` — третий
/// формат рядом с `"builtin"` и `"custom:<uuid>"`.
enum LocalModel: String, CaseIterable, Identifiable {
    case whisper    // OpenAI Whisper large-v3-turbo через WhisperKit (CoreML/ANE)
    case parakeet   // NVIDIA Parakeet TDT 0.6b v3 через FluidAudio (CoreML/ANE)

    var id: String { rawValue }

    /// Значение для `SettingsStore.providerID`.
    var providerID: String { "local:\(rawValue)" }

    /// Название в UI и метка сервиса в истории. Намеренно не локализуется
    /// (как `AppLanguage.title`): имя собственное, одинаково на всех языках.
    /// Соответствует фактическим моделям: у Whisper вариант large-v3-turbo,
    /// у Parakeet — TDT 0.6B v3 (без «Turbo» — его у NVIDIA нет).
    var title: String {
        switch self {
        case .whisper: return "Whisper Large v3 Turbo (Local)"
        case .parakeet: return "Parakeet TDT 0.6B v3 (Local)"
        }
    }

    /// Имя модели для поля `model` записей истории и метаданных.
    var modelName: String {
        switch self {
        case .whisper: return "whisper-large-v3-turbo"
        case .parakeet: return "parakeet-tdt-0.6b-v3"
        }
    }

    /// Примерный размер скачивания — только для подписи в UI до скачивания
    /// (после — показывается реальный размер на диске).
    var approxDownloadBytes: Int64 {
        switch self {
        case .whisper: return 1_600_000_000
        case .parakeet: return 700_000_000
        }
    }

    /// Модель не работает на Intel (FluidAudio требует Apple Silicon).
    /// Единственный источник этого знания: и предупреждение в UI, и барьер
    /// в `LocalModelStore.download` смотрят сюда.
    var requiresAppleSilicon: Bool {
        switch self {
        case .whisper: return false
        case .parakeet: return true
        }
    }

    /// Архитектура текущего Mac — для гейтов моделей, требующих Apple Silicon.
    static let isAppleSiliconMac: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// Вариант в репозитории argmaxinc/whisperkit-coreml. «v20240930» — дата
    /// релиза large-v3-turbo, то есть это и есть турбо-версия (дефолт
    /// WhisperKit для M-маков, ~1.6 ГБ полной точности).
    static let whisperKitVariant = "openai_whisper-large-v3-v20240930"

    /// Разбор `providerID`; nil — не локальный сервис.
    static func from(providerID: String) -> LocalModel? {
        guard providerID.hasPrefix("local:") else { return nil }
        return LocalModel(rawValue: String(providerID.dropFirst("local:".count)))
    }
}
