import XCTest
@testable import DOKA

/// Разбор ответов API транскрибации. Формы ответа три: плоский verbose_json,
/// конверт с LLM-анализом и конверт статуса async-задачи. Ошибка разбора
/// выглядит как «сервер сломался», хотя ответ пришёл корректный.
final class FileTranscriptionDecodingTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let verboseJSON = """
    {
      "text": "Привет мир. Как дела?",
      "language": "russian",
      "duration": 4.5,
      "segments": [
        {"start": 0.0, "end": 2.0, "text": "Привет мир."},
        {"start": 2.0, "end": 4.5, "text": "Как дела?"}
      ],
      "words": [
        {"word": "Привет", "start": 0.0, "end": 0.8},
        {"word": "мир.", "start": 0.8, "end": 2.0},
        {"word": "Как", "start": 2.0, "end": 2.6},
        {"word": "дела?", "start": 2.6, "end": 4.5}
      ]
    }
    """

    // MARK: - Плоский verbose_json

    func testDecodesFlatVerboseJSON() throws {
        let result = try FileTranscriptionClient.decode(data(verboseJSON), detail: .server)
        XCTAssertEqual(result.fullText, "Привет мир. Как дела?")
        XCTAssertEqual(result.language, "russian")
        XCTAssertEqual(result.duration ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.words.count, 4)
        XCTAssertNil(result.llmOutput, "без запроса анализа llm_output должен быть nil")
    }

    func testSegmentsCarryTimestamps() throws {
        let result = try FileTranscriptionClient.decode(data(verboseJSON), detail: .server)
        XCTAssertEqual(result.segments.first?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(result.segments.first?.end ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(result.segments.first?.text, "Привет мир.")
    }

    /// Диаризация кладёт speaker прямо в сегменты — тот же декодер, одна структура.
    func testDecodesSpeakersFromDiarization() throws {
        let json = """
        {"text": "Раз. Два.", "segments": [
          {"start": 0, "end": 1, "text": "Раз.", "speaker": "speaker_0"},
          {"start": 1, "end": 2, "text": "Два.", "speaker": "speaker_1"}]}
        """
        let result = try FileTranscriptionClient.decode(data(json), detail: .server)
        XCTAssertEqual(result.segments.map(\.speaker), ["speaker_0", "speaker_1"])
        XCTAssertTrue(result.hasSpeakers)
    }

    /// Деградация: сервер вернул текст без сегментов — результат всё равно
    /// пригоден, просто без тайм-кодов.
    func testDecodesResponseWithoutSegments() throws {
        let result = try FileTranscriptionClient.decode(data(#"{"text": "только текст"}"#), detail: .server)
        XCTAssertEqual(result.fullText, "только текст")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try FileTranscriptionClient.decode(data("не json вовсе"), detail: .server))
    }

    // MARK: - Конверт LLM-анализа

    func testDecodesLLMEnvelopeWithStringOutput() throws {
        let json = """
        {"transcription": \(verboseJSON), "llm_output": "## Протокол\\n\\nОбсудили сроки."}
        """
        let result = try FileTranscriptionClient.decode(data(json), detail: .server)
        XCTAssertEqual(result.fullText, "Привет мир. Как дела?", "транскрипция достаётся из поддерева")
        XCTAssertEqual(result.llmOutput, "## Протокол\n\nОбсудили сроки.")
    }

    /// В режиме json_schema модель отдаёт объект — он сериализуется в читаемый JSON,
    /// а не теряется.
    func testDecodesLLMEnvelopeWithObjectOutput() throws {
        let json = """
        {"transcription": \(verboseJSON), "llm_output": {"summary": "кратко", "tasks": ["раз", "два"]}}
        """
        let result = try FileTranscriptionClient.decode(data(json), detail: .server)
        let output = try XCTUnwrap(result.llmOutput)
        XCTAssertTrue(output.contains("summary"))
        XCTAssertTrue(output.contains("кратко"))
    }

    func testEmptyLLMOutputBecomesNil() throws {
        let json = """
        {"transcription": \(verboseJSON), "llm_output": null}
        """
        XCTAssertNil(try FileTranscriptionClient.decode(data(json), detail: .server).llmOutput)
    }

    // MARK: - Детализация тайм-кодов при разборе

    /// Уровень детализации применяется уже на разборе — сегменты режутся локально.
    func testDetailIsAppliedDuringDecoding() throws {
        let words = (0..<60).map {
            "{\"word\": \"слово\($0)\", \"start\": \(Double($0)), \"end\": \(Double($0) + 0.9)}"
        }.joined(separator: ",")
        let json = """
        {"text": "долгая речь", "duration": 60,
         "segments": [{"start": 0, "end": 60, "text": "долгая речь"}],
         "words": [\(words)]}
        """
        let server = try FileTranscriptionClient.decode(data(json), detail: .server)
        let fine = try FileTranscriptionClient.decode(data(json), detail: .fine)
        XCTAssertEqual(server.segments.count, 1)
        XCTAssertGreaterThan(fine.segments.count, 1)
        XCTAssertEqual(fine.rawSegments.count, 1, "rawSegments всегда хранят серверный вариант")
    }

    // MARK: - Статус async-задачи

    func testAsyncInProgress() throws {
        let poll = try FileTranscriptionClient.decodeAsyncStatus(
            data(#"{"job_id": "abc", "status": "in_progress"}"#), detail: .server)
        XCTAssertEqual(poll, .inProgress)
    }

    func testAsyncCompleteCarriesResult() throws {
        let json = """
        {"job_id": "abc", "status": "complete", "result": \(verboseJSON)}
        """
        let poll = try FileTranscriptionClient.decodeAsyncStatus(data(json), detail: .server)
        guard case let .complete(result) = poll else {
            return XCTFail("ожидался complete, получено \(poll)")
        }
        XCTAssertEqual(result.fullText, "Привет мир. Как дела?")
    }

    /// LLM-конверт лежит ВНУТРИ result — async отдаёт те же формы, что sync.
    func testAsyncCompleteWithLLMEnvelope() throws {
        let json = """
        {"job_id": "abc", "status": "complete",
         "result": {"transcription": \(verboseJSON), "llm_output": "итог"}}
        """
        let poll = try FileTranscriptionClient.decodeAsyncStatus(data(json), detail: .server)
        guard case let .complete(result) = poll else {
            return XCTFail("ожидался complete, получено \(poll)")
        }
        XCTAssertEqual(result.llmOutput, "итог")
    }

    func testAsyncErrorCarriesMessage() throws {
        let poll = try FileTranscriptionClient.decodeAsyncStatus(
            data(#"{"job_id": "abc", "status": "error", "error": "файл повреждён"}"#), detail: .server)
        XCTAssertEqual(poll, .failed("файл повреждён"))
    }

    /// Форма поля error не документирована — объект тоже должен дать сообщение.
    func testAsyncErrorAsObject() throws {
        let poll = try FileTranscriptionClient.decodeAsyncStatus(
            data(#"{"status": "error", "error": {"detail": "нет квоты"}}"#), detail: .server)
        guard case let .failed(message) = poll else {
            return XCTFail("ожидался failed, получено \(poll)")
        }
        XCTAssertTrue(message.contains("нет квоты"))
    }

    func testAsyncCompleteWithoutResultThrows() {
        XCTAssertThrowsError(try FileTranscriptionClient.decodeAsyncStatus(
            data(#"{"job_id": "abc", "status": "complete"}"#), detail: .server))
    }

    func testUnknownStatusThrows() {
        XCTAssertThrowsError(try FileTranscriptionClient.decodeAsyncStatus(
            data(#"{"job_id": "abc", "status": "нечто новое"}"#), detail: .server))
    }

    func testStatusWithoutStatusFieldThrows() {
        XCTAssertThrowsError(try FileTranscriptionClient.decodeAsyncStatus(
            data(#"{"job_id": "abc"}"#), detail: .server))
    }
}
