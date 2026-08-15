import Foundation

/// Сервис распознавания речи. Все пресеты — OpenAI-совместимые API
/// (эндпоинт /audio/transcriptions, multipart-запрос).
enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case builtin    // встроенный сервис DOKA
    case openai
    case groq
    case custom     // любой OpenAI-совместимый: свой сервер, локальный whisper и т.п.

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtin: return L("provider.builtin")
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .custom: return L("provider.custom")
        }
    }

    /// Эндпоинт транскрипции. Для .custom адрес задаёт пользователь в настройках.
    var endpoint: URL? {
        switch self {
        case .builtin: return URL(string: "https://api.nexara.ru/api/v1/audio/transcriptions")
        case .openai: return URL(string: "https://api.openai.com/v1/audio/transcriptions")
        case .groq: return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")
        case .custom: return nil
        }
    }

    var defaultModel: String {
        switch self {
        case .builtin, .openai, .custom: return "whisper-1"
        case .groq: return "whisper-large-v3"
        }
    }

    /// Аккаунт записи в Keychain — у каждого сервиса свой ключ.
    /// Для builtin сохранено историческое имя, чтобы не потерять
    /// уже введённые пользователями ключи.
    var keychainAccount: String {
        self == .builtin ? "nexara-api-key" : "api-key-\(rawValue)"
    }
}

/// Пользовательский OpenAI-совместимый сервис, сохранённый в списке
/// «Сервиса»: пользователь один раз проверяет адрес/модель/ключ — дальше
/// выбирает из выпадающего списка. Ключ — в Keychain под своим аккаунтом.
struct CustomService: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: String   // как ввёл пользователь; нормализуется при запросе
    var model: String      // пусто — модель по умолчанию

    var keychainAccount: String { "custom-\(id.uuidString)" }

    /// Отображаемое имя из адреса и модели: «api.example.com · whisper-1».
    static func makeName(endpoint: String, model: String) -> String {
        let host = ProviderConfig.normalizeEndpoint(endpoint)?.host ?? endpoint
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? host : "\(host) · \(trimmedModel)"
    }
}

/// Конфигурация запроса транскрипции: куда слать и какую модель просить.
struct ProviderConfig {
    let endpoint: URL
    let model: String

    /// Принимает базовый URL («https://host/v1») или полный адрес эндпоинта.
    static func normalizeEndpoint(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/audio/transcriptions") {
            s += "/audio/transcriptions"
        }
        guard let url = URL(string: s), url.scheme != nil, url.host != nil else { return nil }
        return url
    }
}
