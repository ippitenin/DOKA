import Foundation

/// Правило словаря замен: «что» → «на что».
struct ReplacementRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
    var enabled = true
}

/// Применяет словарь замен к готовой транскрипции перед вставкой.
enum ReplacementEngine {
    static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        var result = text
        // Длинные шаблоны первыми, чтобы короткие не разрывали длинные.
        let active = rules
            .filter { $0.enabled && !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
        for rule in active {
            // Пересборка строки без переиспользования индексов после мутации:
            // вставленный текст не сканируется повторно — нет ни крашей на
            // устаревших индексах, ни бесконечных циклов при to ⊇ from.
            var output = ""
            var remaining = Substring(result)
            while let found = remaining.range(of: rule.from, options: [.caseInsensitive]) {
                output += remaining[..<found.lowerBound]
                output += rule.to
                remaining = remaining[found.upperBound...]
            }
            output += remaining
            result = output
        }
        return result
    }
}
