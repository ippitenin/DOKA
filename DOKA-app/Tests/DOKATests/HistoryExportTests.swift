import XCTest
@testable import DOKA

/// CSV-экспорт истории по RFC 4180. Ошибка экранирования ломает файл у
/// пользователя в Excel, а не у нас — воспроизвести потом трудно.
final class HistoryExportTests: XCTestCase {

    private func record(text: String,
                        duration: TimeInterval = 12.5,
                        language: String = "ru",
                        model: String? = "whisper-1",
                        provider: String? = "builtin",
                        transcriptionTime: TimeInterval? = 1.25) -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), text: text, date: Date(timeIntervalSince1970: 0),
                            duration: duration, language: language, speechDuration: nil,
                            model: model, provider: provider, microphone: nil,
                            transcriptionTime: transcriptionTime, audioFileName: nil)
    }

    // MARK: - Экранирование по RFC 4180

    func testPlainFieldIsNotQuoted() {
        XCTAssertEqual(HistoryExport.escapeCSVField("простой текст"), "простой текст")
    }

    func testFieldWithCommaIsQuoted() {
        XCTAssertEqual(HistoryExport.escapeCSVField("раз, два"), "\"раз, два\"")
    }

    /// Кавычка внутри поля удваивается — это и есть главное правило RFC 4180.
    func testQuoteIsDoubledAndFieldQuoted() {
        XCTAssertEqual(HistoryExport.escapeCSVField("он сказал \"да\""), "\"он сказал \"\"да\"\"\"")
    }

    func testNewlineForcesQuoting() {
        XCTAssertEqual(HistoryExport.escapeCSVField("первая\nвторая"), "\"первая\nвторая\"")
        XCTAssertEqual(HistoryExport.escapeCSVField("первая\rвторая"), "\"первая\rвторая\"")
    }

    // MARK: - Структура CSV

    func testCSVStartsWithHeaderRow() {
        let csv = HistoryExport.csv([])
        XCTAssertTrue(csv.hasPrefix("Text,Model,Provider,Transcription Time (s),Timestamp,Duration (s),Language,Words"))
    }

    /// RFC 4180 требует CRLF — Excel на Windows иначе показывает всё одной строкой.
    func testCSVUsesCRLFLineEndings() {
        let csv = HistoryExport.csv([record(text: "привет")])
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count - 1, 2, "заголовок и одна запись")
    }

    func testCSVCountsWords() {
        let csv = HistoryExport.csv([record(text: "раз два три")])
        XCTAssertTrue(csv.contains(",3\r\n"), "последняя колонка — число слов")
    }

    func testCSVEscapesTextWithCommaAndQuotes() {
        let csv = HistoryExport.csv([record(text: "привет, \"мир\"")])
        XCTAssertTrue(csv.contains("\"привет, \"\"мир\"\"\""))
    }

    /// У старых записей нет модели и latency — экспорт обязан деградировать
    /// в пустые поля, а не падать.
    func testCSVHandlesMissingMetadata() {
        let csv = HistoryExport.csv([record(text: "старая", model: nil, provider: nil, transcriptionTime: nil)])
        XCTAssertTrue(csv.contains("старая,,,"), "отсутствующие поля должны стать пустыми")
    }

    func testCSVFormatsDurationWithThreeDecimals() {
        XCTAssertTrue(HistoryExport.csv([record(text: "т", duration: 12.5)]).contains("12.500"))
    }

    func testISO8601HasNoFractionalSeconds() {
        let stamp = HistoryExport.iso8601(Date(timeIntervalSince1970: 0))
        XCTAssertFalse(stamp.contains("."))
        XCTAssertTrue(stamp.hasPrefix("1970-01-01"))
    }

    // MARK: - Объединённый текст

    func testCombinedTextJoinsWithSeparator() {
        let records = [record(text: "первая"), record(text: "вторая")]
        XCTAssertEqual(HistoryExport.combinedPlainText(records), "первая\n\n---\n\nвторая")
    }

    func testCombinedTextOfEmptyListIsEmpty() {
        XCTAssertEqual(HistoryExport.combinedPlainText([]), "")
    }
}
