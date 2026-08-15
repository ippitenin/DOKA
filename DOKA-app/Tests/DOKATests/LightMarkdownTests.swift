import XCTest
@testable import DOKA

/// Разбор Markdown из ответа LLM. Карточка «Анализ» рендерится из этих блоков,
/// а копирование кладёт в буфер plain и HTML — расхождение между ними означает,
/// что пользователь вставит не то, что видел.
final class LightMarkdownTests: XCTestCase {

    // MARK: - Разбор блоков

    func testParsesHeadings() {
        XCTAssertEqual(LightMarkdown.parse("# Заголовок"), [.heading(level: 1, text: "Заголовок")])
        XCTAssertEqual(LightMarkdown.parse("### Третий"), [.heading(level: 3, text: "Третий")])
    }

    func testParsesBulletsWithBothMarkers() {
        XCTAssertEqual(LightMarkdown.parse("- пункт"), [.bullet("пункт")])
        XCTAssertEqual(LightMarkdown.parse("* пункт"), [.bullet("пункт")])
    }

    func testParsesOrderedListKeepingNumbers() {
        XCTAssertEqual(LightMarkdown.parse("3. третий"), [.ordered(number: 3, text: "третий")])
    }

    func testParsesHorizontalRule() {
        XCTAssertEqual(LightMarkdown.parse("---"), [.rule])
    }

    func testParsesTable() {
        let md = """
        | Кто | Что |
        |---|---|
        | Иван | отчёт |
        """
        XCTAssertEqual(LightMarkdown.parse(md),
                       [.table(header: ["Кто", "Что"], rows: [["Иван", "отчёт"]])])
    }

    func testPlainParagraphSurvives() {
        XCTAssertEqual(LightMarkdown.parse("просто текст"), [.paragraph("просто текст")])
    }

    // MARK: - Обычный текст

    /// В обычном тексте не должно остаться сырой разметки — именно ради этого
    /// карточка рендерится нативно, а не показывает «**жирный**».
    func testPlainTextStripsInlineMarkup() {
        let plain = LightMarkdown.plainText("**жирный** и *курсив* и `код`")
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertTrue(plain.contains("жирный"))
        XCTAssertTrue(plain.contains("курсив"))
    }

    func testPlainTextRendersBulletsWithMarker() {
        XCTAssertEqual(LightMarkdown.plainText("- первый\n- второй"), "• первый\n• второй")
    }

    /// Таблица уходит в буфер таб-разделённой — так её принимают Excel и Numbers.
    func testPlainTextFlattensTableWithTabs() {
        let md = """
        | Кто | Что |
        |---|---|
        | Иван | отчёт |
        """
        XCTAssertEqual(LightMarkdown.plainText(md), "Кто\tЧто\nИван\tотчёт")
    }

    func testPlainTextTrimsAndCollapsesBlankLines() {
        let plain = LightMarkdown.plainText("\n\n# Заголовок\n\n\n\nабзац\n\n")
        XCTAssertEqual(plain, "Заголовок\n\nабзац")
    }

    // MARK: - HTML

    func testHTMLIsCompleteDocument() {
        let html = LightMarkdown.html("текст")
        XCTAssertTrue(html.contains("<body"), "HTML должен быть полным документом — иначе часть приложений его игнорирует")
        XCTAssertTrue(html.contains("</html>"))
    }

    func testHTMLRendersTableAsTable() {
        let md = """
        | Кто | Что |
        |---|---|
        | Иван | отчёт |
        """
        let html = LightMarkdown.html(md)
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("<th"))
        XCTAssertTrue(html.contains("<td"))
    }

    func testHTMLWrapsConsecutiveBulletsInSingleList() {
        let html = LightMarkdown.html("- один\n- два")
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 1,
                       "соседние пункты должны попасть в один список")
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 2)
    }

    /// Экранирование обязательно: текст от модели попадает в HTML буфера обмена.
    func testHTMLEscapesSpecialCharacters() {
        let html = LightMarkdown.html("5 < 6 & 7 > 4")
        XCTAssertTrue(html.contains("&lt;"))
        XCTAssertTrue(html.contains("&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
    }

    func testHTMLRendersEmphasis() {
        XCTAssertTrue(LightMarkdown.html("**жирный**").contains("<b>жирный</b>"))
        XCTAssertTrue(LightMarkdown.html("*курсив*").contains("<i>курсив</i>"))
        XCTAssertTrue(LightMarkdown.html("`код`").contains("<code>код</code>"))
    }

    func testHTMLRendersLinks() {
        XCTAssertTrue(LightMarkdown.html("[текст](https://example.com)")
            .contains("<a href=\"https://example.com\">текст</a>"))
    }

    // MARK: - Переносы <br> внутри ячеек

    /// Модель переносит строки внутри ячеек GFM-таблиц через <br>. В HTML это
    /// настоящий тег, а в обычном тексте — пробел, иначе строка рвётся посреди ячейки.
    func testLineBreakTagBecomesSpaceInPlainText() {
        let plain = LightMarkdown.plainText("первая<br>вторая")
        XCTAssertFalse(plain.contains("<br>"))
        XCTAssertTrue(plain.contains("первая вторая"))
    }

    func testLineBreakTagStaysTagInHTML() {
        XCTAssertTrue(LightMarkdown.html("первая<br>вторая").contains("<br"))
    }

    // MARK: - Устойчивость

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(LightMarkdown.parse("").isEmpty)
        XCTAssertEqual(LightMarkdown.plainText(""), "")
    }

    /// Обрубленная таблица не должна ронять разбор — LLM иногда не дописывает ответ.
    func testMalformedTableDoesNotCrash() {
        let blocks = LightMarkdown.parse("| Кто | Что |\n|---|")
        XCTAssertFalse(blocks.isEmpty)
    }
}
