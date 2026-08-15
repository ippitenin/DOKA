import XCTest
@testable import DOKA

/// Словарь автозамен применяется к каждой диктовке перед вставкой, поэтому
/// его ошибки портят текст молча — пользователь видит уже испорченный результат.
final class ReplacementEngineTests: XCTestCase {

    private func rule(_ from: String, _ to: String, enabled: Bool = true) -> ReplacementRule {
        ReplacementRule(from: from, to: to, enabled: enabled)
    }

    func testAppliesSimpleReplacement() {
        let result = ReplacementEngine.apply("привет мир", rules: [rule("мир", "земля")])
        XCTAssertEqual(result, "привет земля")
    }

    func testIsCaseInsensitive() {
        let result = ReplacementEngine.apply("Привет ПРИВЕТ привет", rules: [rule("привет", "hi")])
        XCTAssertEqual(result, "hi hi hi")
    }

    func testSkipsDisabledRules() {
        let result = ReplacementEngine.apply("привет", rules: [rule("привет", "hi", enabled: false)])
        XCTAssertEqual(result, "привет")
    }

    func testEmptyFromIsIgnored() {
        // Пустой шаблон при наивной реализации вставляется между каждым символом.
        let result = ReplacementEngine.apply("текст", rules: [rule("", "X")])
        XCTAssertEqual(result, "текст")
    }

    /// Ключевой инвариант: длинные шаблоны применяются первыми, иначе короткое
    /// правило разорвёт совпадение длинного и длинное больше не сработает.
    func testLongerPatternsWinOverShorter() {
        let rules = [rule("нью", "new"), rule("нью-йорк", "New York")]
        XCTAssertEqual(ReplacementEngine.apply("нью-йорк", rules: rules), "New York")
    }

    /// Замена, содержащая собственный шаблон, не должна зацикливаться:
    /// вставленный текст повторно не сканируется.
    func testReplacementContainingPatternDoesNotLoop() {
        let result = ReplacementEngine.apply("кот", rules: [rule("кот", "кот и пёс")])
        XCTAssertEqual(result, "кот и пёс")
    }

    func testMultipleOccurrencesAllReplaced() {
        let result = ReplacementEngine.apply("да да да", rules: [rule("да", "нет")])
        XCTAssertEqual(result, "нет нет нет")
    }

    func testRulesApplySequentially() {
        let rules = [rule("а", "б"), rule("б", "в")]
        // «а» → «б», затем «б» → «в»: обе замены проходят по всей строке.
        XCTAssertEqual(ReplacementEngine.apply("а", rules: rules), "в")
    }

    func testEmptyRulesReturnTextUnchanged() {
        XCTAssertEqual(ReplacementEngine.apply("текст без правил", rules: []), "текст без правил")
    }

    func testEmptyTextStaysEmpty() {
        XCTAssertEqual(ReplacementEngine.apply("", rules: [rule("а", "б")]), "")
    }

    /// Замена на пустую строку — легальный способ вычистить слово-паразит.
    func testReplacingWithEmptyStringDeletesMatch() {
        let result = ReplacementEngine.apply("это, э-э, работает", rules: [rule("э-э, ", "")])
        XCTAssertEqual(result, "это, работает")
    }
}
