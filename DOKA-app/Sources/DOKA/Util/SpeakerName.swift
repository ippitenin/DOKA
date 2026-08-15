import Foundation

/// Отображаемое имя спикера: серверный id «speaker_0» → локализованное
/// «Спикер 1». Сырые id показывать нельзя — выглядят как системный мусор.
/// Чистые детерминированные функции (как `TranscriptFormatter`).
enum SpeakerName {
    private static let prefix = "speaker_"
    /// Метка лишнего говорящего при разметке ролей: спикеров оказалось
    /// больше, чем задано ролей. Nexara нумерует unknown с единицы.
    private static let unknownPrefix = "unknown_"

    /// Индекс из сырого id: «speaker_0» → 0. nil, если формат не распознан.
    static func index(of raw: String) -> Int? {
        let lowered = raw.lowercased()
        guard lowered.hasPrefix(prefix) else { return nil }
        return Int(lowered.dropFirst(prefix.count))
    }

    /// «speaker_N» → «Спикер N+1» (нумерация для людей — с единицы),
    /// «unknown_N» → «Неизвестный N». Нераспознанный id (имя роли —
    /// «Клиент», «Агент») возвращается как есть.
    static func displayName(for raw: String) -> String {
        if let index = index(of: raw) {
            return L("transcribe.speaker.name", index + 1)
        }
        let lowered = raw.lowercased()
        if lowered.hasPrefix(unknownPrefix),
           let number = Int(lowered.dropFirst(unknownPrefix.count)) {
            return L("transcribe.speaker.unknownName", number)
        }
        return raw
    }
}
