import Foundation

/// Разбор пользовательского списка ролей «через запятую» и клиентская
/// валидация лимитов Nexara (≤10 ролей, имя непустое и ≤64 символов, без
/// дублей — см. DOCS/NEXARA/GUIDES/speakers-roles.md). Запятая — жёсткий
/// разделитель: имя роли с запятой внутри невозможно by design.
/// Чистые детерминированные функции (как `TranscriptFormatter`).
enum SpeakerRolesParser {
    static let maxRoles = 10
    static let maxNameLength = 64

    enum RolesError: Error, Equatable {
        case empty
        case tooMany(Int)
        case nameTooLong(String)
        case duplicate(String)

        var message: String {
            switch self {
            case .empty: return L("transcribe.roles.error.empty")
            case .tooMany(let count): return L("transcribe.roles.error.tooMany", count)
            case .nameTooLong(let name): return L("transcribe.roles.error.nameTooLong", name)
            case .duplicate(let name): return L("transcribe.roles.error.duplicate", name)
            }
        }
    }

    /// «Клиент, Агент» → ["Клиент", "Агент"]. Пустые элементы (лишние
    /// запятые, пробелы) молча выбрасываются; дубли сравниваются
    /// регистронезависимо — сервер отклоняет повторы.
    static func parse(_ text: String) -> Result<[String], RolesError> {
        let names = text
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return .failure(.empty) }
        guard names.count <= maxRoles else { return .failure(.tooMany(names.count)) }
        if let long = names.first(where: { $0.count > maxNameLength }) {
            return .failure(.nameTooLong(long))
        }
        var seen = Set<String>()
        for name in names {
            if !seen.insert(name.lowercased()).inserted {
                return .failure(.duplicate(name))
            }
        }
        return .success(names)
    }
}
