import XCTest
@testable import DOKA

/// Подсчёт слов — общий источник для статистики диктовки и теста скорости
/// печати. Разойдутся реализации — «в N раз быстрее» станет враньём.
final class WordCountTests: XCTestCase {

    func testCountsWordsSeparatedBySpaces() {
        XCTAssertEqual("раз два три".dokaWordCount, 3)
    }

    func testCollapsesRepeatedWhitespace() {
        XCTAssertEqual("раз    два\t\tтри".dokaWordCount, 3)
    }

    func testCountsAcrossNewlines() {
        XCTAssertEqual("раз\nдва\r\nтри".dokaWordCount, 3)
    }

    func testEmptyAndBlankStringsAreZero() {
        XCTAssertEqual("".dokaWordCount, 0)
        XCTAssertEqual("   \n\t ".dokaWordCount, 0)
    }

    func testPunctuationDoesNotSplitWords() {
        XCTAssertEqual("привет, мир!".dokaWordCount, 2)
    }

    func testHyphenatedWordCountsAsOne() {
        XCTAssertEqual("что-то".dokaWordCount, 1)
    }
}

/// Сырые id спикеров показывать нельзя — выглядят как системный мусор.
final class SpeakerNameTests: XCTestCase {

    func testIndexParsedFromRawId() {
        XCTAssertEqual(SpeakerName.index(of: "speaker_0"), 0)
        XCTAssertEqual(SpeakerName.index(of: "speaker_7"), 7)
    }

    func testIndexIsCaseInsensitive() {
        XCTAssertEqual(SpeakerName.index(of: "SPEAKER_2"), 2)
    }

    func testIndexIsNilForUnknownFormat() {
        XCTAssertNil(SpeakerName.index(of: "Клиент"))
        XCTAssertNil(SpeakerName.index(of: "unknown_1"))
        XCTAssertNil(SpeakerName.index(of: "speaker_abc"))
    }

    /// Имя роли, заданное пользователем, показывается как есть — его незачем
    /// переводить в «Спикер N».
    func testCustomRoleNamePassesThroughUnchanged() {
        XCTAssertEqual(SpeakerName.displayName(for: "Клиент"), "Клиент")
        XCTAssertEqual(SpeakerName.displayName(for: "Agent"), "Agent")
    }

    /// Нумерация для людей начинается с единицы: speaker_0 — первый спикер.
    /// Текст локализован, поэтому проверяем номер, а не перевод.
    func testDisplayNameShiftsNumberingToOne() {
        XCTAssertTrue(SpeakerName.displayName(for: "speaker_0").contains("1"))
        XCTAssertTrue(SpeakerName.displayName(for: "speaker_4").contains("5"))
    }
}

/// Клиентская валидация ролей: сервер отклоняет неверные списки, но лучше
/// сказать об этом до загрузки файла, чем после.
final class SpeakerRolesParserTests: XCTestCase {

    func testParsesCommaSeparatedNames() {
        XCTAssertEqual(try? SpeakerRolesParser.parse("Клиент, Агент").get(), ["Клиент", "Агент"])
    }

    func testTrimsWhitespaceAndSkipsEmptyEntries() {
        XCTAssertEqual(try? SpeakerRolesParser.parse("  Клиент ,, Агент ,  ").get(), ["Клиент", "Агент"])
    }

    func testEmptyInputIsRejected() {
        XCTAssertEqual(SpeakerRolesParser.parse("   ,, "), .failure(.empty))
        XCTAssertEqual(SpeakerRolesParser.parse(""), .failure(.empty))
    }

    func testTooManyRolesRejectedWithCount() {
        let names = (1...11).map { "Роль\($0)" }.joined(separator: ",")
        XCTAssertEqual(SpeakerRolesParser.parse(names), .failure(.tooMany(11)))
    }

    func testMaxRolesIsAccepted() {
        let names = (1...SpeakerRolesParser.maxRoles).map { "Роль\($0)" }.joined(separator: ",")
        XCTAssertEqual(try? SpeakerRolesParser.parse(names).get().count, SpeakerRolesParser.maxRoles)
    }

    func testTooLongNameRejected() {
        let long = String(repeating: "я", count: SpeakerRolesParser.maxNameLength + 1)
        XCTAssertEqual(SpeakerRolesParser.parse(long), .failure(.nameTooLong(long)))
    }

    func testNameAtLengthLimitIsAccepted() {
        let name = String(repeating: "я", count: SpeakerRolesParser.maxNameLength)
        XCTAssertEqual(try? SpeakerRolesParser.parse(name).get(), [name])
    }

    /// Сервер считает «Клиент» и «клиент» одним и тем же — ловим заранее.
    func testDuplicatesDetectedCaseInsensitively() {
        XCTAssertEqual(SpeakerRolesParser.parse("Клиент, клиент"), .failure(.duplicate("клиент")))
    }
}

/// Адрес сервиса пользователь вводит руками: и базовый URL, и полный эндпоинт.
final class ProviderConfigTests: XCTestCase {

    func testAppendsEndpointPathToBaseURL() {
        XCTAssertEqual(ProviderConfig.normalizeEndpoint("https://api.example.com/v1")?.absoluteString,
                       "https://api.example.com/v1/audio/transcriptions")
    }

    func testFullEndpointIsLeftAsIs() {
        let full = "https://api.example.com/v1/audio/transcriptions"
        XCTAssertEqual(ProviderConfig.normalizeEndpoint(full)?.absoluteString, full)
    }

    func testTrailingSlashesAreTrimmed() {
        XCTAssertEqual(ProviderConfig.normalizeEndpoint("https://api.example.com/v1///")?.absoluteString,
                       "https://api.example.com/v1/audio/transcriptions")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(ProviderConfig.normalizeEndpoint("  https://api.example.com/v1  ")?.absoluteString,
                       "https://api.example.com/v1/audio/transcriptions")
    }

    func testInvalidInputIsRejected() {
        XCTAssertNil(ProviderConfig.normalizeEndpoint(""))
        XCTAssertNil(ProviderConfig.normalizeEndpoint("   "))
        XCTAssertNil(ProviderConfig.normalizeEndpoint("не адрес вовсе"))
        XCTAssertNil(ProviderConfig.normalizeEndpoint("/v1"), "путь без схемы и хоста — не адрес")
    }
}

/// Формат mm:ss используется таймером записи и плеером истории.
final class TimeFormatTests: XCTestCase {

    /// Минуты без ведущего нуля, секунды — всегда двузначные.
    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(clockMMSS(0), "0:00")
        XCTAssertEqual(clockMMSS(9), "0:09")
        XCTAssertEqual(clockMMSS(75), "1:15")
    }

    func testMinutesKeepGrowingBeyondHour() {
        XCTAssertEqual(clockMMSS(3661), "61:01", "часы отдельно не выделяются — это таймер записи")
    }

    /// Отрицательное время и NaN не должны давать «-1:-1».
    func testInvalidTimeIsClampedToZero() {
        XCTAssertEqual(clockMMSS(-5), "0:00")
        XCTAssertEqual(clockMMSS(.nan), "0:00")
        XCTAssertEqual(clockMMSS(.infinity), "0:00")
    }
}

/// EMA-сглаживание уровня микрофона — общий хелпер всех панелей рекордера.
final class SmoothingTests: XCTestCase {

    func testMovesTowardTarget() {
        let smoothed = Float(0).smoothed(toward: 1, response: 0.5)
        XCTAssertGreaterThan(smoothed, 0)
        XCTAssertLessThan(smoothed, 1, "сглаживание не должно прыгать сразу в цель")
    }

    func testRepeatedApplicationConverges() {
        var value: Float = 0
        for _ in 0..<200 { value = value.smoothed(toward: 1, response: 0.3) }
        XCTAssertEqual(value, 1, accuracy: 0.01)
    }

    func testStaysAtTargetWhenAlreadyThere() {
        XCTAssertEqual(Float(0.5).smoothed(toward: 0.5, response: 0.4), 0.5, accuracy: 0.0001)
    }
}
