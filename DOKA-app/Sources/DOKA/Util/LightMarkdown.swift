import Foundation

/// Лёгкий разбор Markdown из LLM-анализа: в блоки для нативного рендера и в
/// чистый текст без символов разметки. Чистая логика без UI — тестопригодна
/// (scratchpad-harness), покрывает то, что реально присылает модель по нашим
/// промптам: заголовки, абзацы, маркированные и нумерованные списки, жирный/
/// курсив/код/ссылки внутри строки.
enum LightMarkdown {

    /// Блок разметки. Для `heading`/`paragraph`/`bullet`/`ordered` в `text`
    /// хранится исходная inline-разметка строки (без блочного маркера) —
    /// рендер разбирает её через ``inlineAttributed(_:)``.
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case ordered(number: Int, text: String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    // MARK: - Разбор в блоки

    /// Построчный разбор Markdown в блоки. Соседние текстовые строки
    /// склеиваются в один абзац; пустая строка — разделитель. Индексный обход,
    /// потому что таблице нужен lookahead на строку-разделитель.
    static func parse(_ md: String) -> [Block] {
        let lines = md.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            // Таблица: строка с `|` и следующая — разделитель `|---|---|`.
            if line.hasPrefix("|"), let (table, consumed) = parseTable(lines, from: i) {
                flushParagraph()
                blocks.append(table)
                i += consumed
                continue
            }
            if isRule(line) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }
            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }
            if let ordered = parseOrdered(line) {
                flushParagraph()
                blocks.append(ordered)
                i += 1
                continue
            }
            if let bullet = parseBullet(line) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                i += 1
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Чистый текст

    /// Текст без символов разметки — для копирования в буфер и сохранения в
    /// .txt. Заголовки и пункты становятся обычными строками; между смысловыми
    /// блоками остаётся пустая строка. **Единственный источник** и для кнопки
    /// «Скопировать», и для формата «Обычный текст».
    static func plainText(_ md: String) -> String {
        var out: [String] = []
        // Добавить блок с пустой строкой-отбивкой перед ним (если не первый).
        func appendSpaced(_ s: String) {
            if !out.isEmpty { out.append("") }
            out.append(s)
        }
        for block in parse(md) {
            switch block {
            case let .heading(_, text):
                appendSpaced(stripInline(text))
            case let .paragraph(text):
                appendSpaced(stripInline(text))
            case let .bullet(text):
                out.append("• " + stripInline(text))          // список идёт вплотную
            case let .ordered(number, text):
                out.append("\(number). " + stripInline(text))
            case let .table(header, rows):
                // Таб-разделение — наименее лоссиво при вставке в таблицы/доки.
                let flat = ([header] + rows).map { row in
                    row.map(stripInline).joined(separator: "\t")
                }.joined(separator: "\n")
                appendSpaced(flat)
            case .rule:
                if !out.isEmpty { out.append("") }
            }
        }
        // Схлопнуть повторные пустые строки, обрезать края.
        var result: [String] = []
        for line in out where !(line.isEmpty && (result.isEmpty || result.last == "")) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML

    /// HTML-представление для rich-копирования в буфер: приложения с богатой
    /// вставкой (Telegram, Notes, Word) получают таблицы таблицами, списки
    /// списками. Кладётся в буфер ВМЕСТЕ с ``plainText(_:)`` — обычные текстовые
    /// поля берут plain-представление.
    static func html(_ md: String) -> String {
        var out: [String] = []
        // Соседние пункты списка копятся и оборачиваются одним <ul>/<ol>.
        var listItems: [String] = []
        var listTag = ""
        var listStart = 1

        func flushList() {
            guard !listItems.isEmpty else { return }
            let start = (listTag == "ol" && listStart != 1) ? " start=\"\(listStart)\"" : ""
            out.append("<\(listTag)\(start)>"
                + listItems.map { "<li>\($0)</li>" }.joined()
                + "</\(listTag)>")
            listItems.removeAll()
        }

        for block in parse(md) {
            switch block {
            case let .heading(level, text):
                flushList()
                let h = min(max(level, 1), 6)
                out.append("<h\(h)>\(inlineHTML(text))</h\(h)>")
            case let .paragraph(text):
                flushList()
                out.append("<p>\(inlineHTML(text))</p>")
            case let .bullet(text):
                if listTag != "ul" { flushList(); listTag = "ul" }
                listItems.append(inlineHTML(text))
            case let .ordered(number, text):
                if listTag != "ol" { flushList(); listTag = "ol"; listStart = number }
                listItems.append(inlineHTML(text))
            case let .table(header, rows):
                flushList()
                var t = "<table><thead><tr>"
                t += header.map { "<th>\(inlineHTML($0))</th>" }.joined()
                t += "</tr></thead><tbody>"
                for row in rows {
                    t += "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>"
                }
                t += "</tbody></table>"
                out.append(t)
            case .rule:
                flushList()
            }
        }
        flushList()
        // Полный документ (не фрагмент): часть приложений распознаёт HTML в
        // буфере только с <html>/<body>. CSS — лишь базовый шрифт, чтобы
        // RTF-конверсия не давала Times New Roman.
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
            + "<style>body{font-family:-apple-system,'Helvetica Neue',sans-serif;font-size:13px;}</style>"
            + "</head><body>\n" + out.joined(separator: "\n") + "\n</body></html>"
    }

    /// Inline-разметка → HTML-теги. Сначала экранирование (текст от модели —
    /// данные, не разметка), затем ссылки и `код` — до жирного/курсива, чтобы
    /// `*` внутри них не съедался. `<br>` модели (перенос строки в ячейках
    /// GFM-таблиц) возвращается настоящим тегом после экранирования.
    private static func inlineHTML(_ s: String) -> String {
        var text = escapeHTML(s)
        text = replacingRegex(text, #"(?i)&lt;br\s*/?&gt;"#, "<br>")
        text = replacingRegex(text, #"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>")
        text = replacingRegex(text, #"`([^`]+)`"#, "<code>$1</code>")
        text = replacingRegex(text, #"\*\*([^*]+)\*\*"#, "<b>$1</b>")
        text = replacingRegex(text, #"~~([^~]+)~~"#, "<s>$1</s>")
        text = replacingRegex(text, #"\*([^*]+)\*"#, "<i>$1</i>")
        return text
    }

    /// `<br>`/`<br/>` от модели — легальный перенос строки внутри ячеек
    /// GFM-таблиц (Markdown-переносы там невозможны). Для рендера меняется на
    /// `\n`, для plain-текста — на пробел (перенос сломал бы таб-разделённые
    /// строки таблицы).
    private static func replacingHTMLBreaks(in s: String, with replacement: String) -> String {
        replacingRegex(s, #"(?i)<br\s*/?>"#, replacement)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replacingRegex(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    // MARK: - Inline-разметка → AttributedString

    /// Разбор inline-разметки строки (**жирный**, *курсив*, `код`, ссылки) в
    /// `AttributedString` для рендера. `inlineOnlyPreservingWhitespace` не трогает
    /// блочный синтаксис и сохраняет пробелы; при ошибке — plain-строка.
    static func inlineAttributed(_ s: String) -> AttributedString {
        let text = replacingHTMLBreaks(in: s, with: "\n")
        return (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Приватные хелперы

    /// Горизонтальная линия: `---`, `***`, `___` (три и более одинаковых знака).
    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    /// Заголовок: 1–6 решёток и пробел. Возвращает уровень и текст (с inline).
    private static func parseHeading(_ line: String) -> Block? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    /// Нумерованный пункт: «1. текст» или «1) текст».
    private static func parseOrdered(_ line: String) -> Block? {
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, idx < line.endIndex else { return nil }
        let sep = line[idx]
        guard sep == "." || sep == ")" else { return nil }
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .ordered(number: Int(digits) ?? 1, text: text)
    }

    /// Маркированный пункт: «- », «* », «+ », «• ».
    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// GFM-таблица: строка ячеек, строка-разделитель `|---|---|`, затем строки
    /// данных. Возвращает блок и число поглощённых строк; `nil` — если после
    /// шапки нет разделителя (тогда `|`-строка станет обычным абзацем).
    private static func parseTable(_ lines: [String], from start: Int) -> (Block, Int)? {
        // Собрать блок подряд идущих строк-ячеек.
        var end = start
        while end < lines.count,
              lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            end += 1
        }
        let count = end - start
        guard count >= 2 else { return nil }

        let separatorCells = splitCells(lines[start + 1])
        guard !separatorCells.isEmpty, separatorCells.allSatisfy(isSeparatorCell) else {
            return nil
        }

        let header = splitCells(lines[start])
        let width = header.count
        let rows = (start + 2 ..< end).map { normalize(splitCells(lines[$0]), to: width) }
        return (.table(header: header, rows: rows), count)
    }

    /// Разбить строку таблицы на ячейки: снять крайние `|`, split по `|`, trim.
    private static func splitCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Ячейка разделителя: только `-`/`:` и хотя бы один `-` (напр. `:---:`).
    private static func isSeparatorCell(_ cell: String) -> Bool {
        let c = cell.replacingOccurrences(of: " ", with: "")
        guard c.contains("-") else { return false }
        return c.allSatisfy { $0 == "-" || $0 == ":" }
    }

    /// Привести строку к нужному числу ячеек: добить пустыми / обрезать лишние.
    private static func normalize(_ cells: [String], to width: Int) -> [String] {
        if cells.count == width { return cells }
        if cells.count < width { return cells + Array(repeating: "", count: width - cells.count) }
        return Array(cells.prefix(width))
    }

    /// Убрать inline-разметку: `<br>` → пробел, ссылки `[текст](url)` → текст,
    /// затем маркеры `**`, `~~`, `*`, `` ` `` → пусто. Одиночный `_` не трогаем
    /// (частая часть слов вроде file_name, а курсив через `_` в ответах модели
    /// редок).
    private static func stripInline(_ s: String) -> String {
        var text = replacingHTMLBreaks(in: stripLinks(s), with: " ")
        for marker in ["**", "~~", "*", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `[текст](url)` → `текст`.
    private static func stripLinks(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
    }
}
