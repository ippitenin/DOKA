import Foundation

/// Экспорт записей истории. Чистые функции — без UI, тестопригодны.
enum HistoryExport {
    /// CSV по мотивам VoiceInk, адаптировано под DOKA (без Enhanced/Enhancement).
    /// Имена колонок — машинные (это data-формат, не локализуется).
    static func csv(_ records: [TranscriptionRecord]) -> String {
        let header = ["Text", "Model", "Provider", "Transcription Time (s)",
                      "Timestamp", "Duration (s)", "Language", "Words"]
        var rows = [header.map(escapeCSVField).joined(separator: ",")]
        for r in records {
            let cols = [
                r.text,
                r.model ?? "",
                r.provider ?? "",
                r.transcriptionTime.map { String(format: "%.3f", $0) } ?? "",
                iso8601(r.date),
                String(format: "%.3f", r.duration),
                r.language,
                String(r.text.dokaWordCount)
            ]
            rows.append(cols.map(escapeCSVField).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// Объединённый плоский текст: записи (в переданном порядке) через разделитель.
    static func combinedPlainText(_ records: [TranscriptionRecord]) -> String {
        records.map(\.text).joined(separator: "\n\n---\n\n")
    }

    /// Экранирование одного поля CSV по RFC 4180.
    static func escapeCSVField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// ISO 8601 без долей секунды.
    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
