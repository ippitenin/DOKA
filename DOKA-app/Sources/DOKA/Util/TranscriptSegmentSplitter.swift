import Foundation

/// Локальное разбиение длинных сегментов транскрипции на подсегменты по
/// границам предложений. Диаризация Nexara отдаёт один сегмент на всю
/// непрерывную речь спикера (бывает 2+ минуты) — такие тайм-коды бесполезны
/// для навигации. Пословные тайм-коды (`timestamp_granularities[]=word`)
/// позволяют резать сегменты локально, без дополнительных запросов к API.
/// Чистые детерминированные функции (как `PerformanceMetrics`).
enum TranscriptSegmentSplitter {
    /// Пороги нарезки. Пресеты — уровни `TimestampDetail`; внутри каждого
    /// пропорции 1 : 1.25 : 1.5 сохранены от исходных констант.
    struct Config: Equatable {
        /// Целевая длительность подсегмента: предложения группируются,
        /// пока блок не превысит её.
        let targetChunkDuration: Double
        /// Сегменты короче порога проходят насквозь с серверным текстом:
        /// их не пересобираем из слов.
        let splitThreshold: Double
        /// Речь без пунктуации дольше этого рвётся принудительно —
        /// на самой длинной межсловной паузе куска.
        let hardBreakDuration: Double

        static let coarse = Config(targetChunkDuration: 60, splitThreshold: 75, hardBreakDuration: 90)
        static let medium = Config(targetChunkDuration: 30, splitThreshold: 37.5, hardBreakDuration: 45)
        static let fine = Config(targetChunkDuration: 10, splitThreshold: 12.5, hardBreakDuration: 15)
    }

    /// Пауза, подтверждающая конец предложения, когда следующее слово
    /// не начинается с заглавной буквы. От детализации не зависит.
    static let sentencePauseThreshold: Double = 0.5

    /// Точка входа: длинные сегменты заменяются цепочкой подсегментов,
    /// короткие и «бессловные» проходят без изменений. Пустые `words` —
    /// деградация в исходные сегменты (сервер не отдал пословные тайм-коды).
    static func split(segments: [TranscriptSegment],
                      words: [TranscriptWord],
                      config: Config = .medium) -> [TranscriptSegment] {
        guard !words.isEmpty, !segments.isEmpty else { return segments }
        let assigned = assignWords(words, to: segments)
        var result: [TranscriptSegment] = []
        for (segment, segmentWords) in zip(segments, assigned) {
            if segment.end - segment.start <= config.splitThreshold || segmentWords.isEmpty {
                result.append(segment)
            } else {
                result.append(contentsOf: subsegments(of: segment, words: segmentWords, config: config))
            }
        }
        return result
    }

    /// Раздаёт слова сегментам по средней точке слова (линейный merge двух
    /// отсортированных списков): одно назначение на слово, устойчиво к
    /// выходу слова за границу сегмента на доли секунды. Слова до первого
    /// сегмента достаются первому, после последнего — последнему.
    static func assignWords(_ words: [TranscriptWord],
                            to segments: [TranscriptSegment]) -> [[TranscriptWord]] {
        var buckets = [[TranscriptWord]](repeating: [], count: segments.count)
        var index = 0
        for word in words {
            let mid = (word.start + word.end) / 2
            while index < segments.count - 1, mid >= segments[index].end {
                index += 1
            }
            buckets[index].append(word)
        }
        return buckets
    }

    /// Конец ли предложения после слова: слово (без замыкающих кавычек и
    /// скобок) оканчивается на `.!?…`, И следующее начинается с заглавной
    /// или цифры ЛИБО отделено паузой. Числа «2.5» отсекаются сами (точка не
    /// в конце), «т.д.» — строчной буквой следующего слова; редкая ложная
    /// граница на инициалах — приемлемая цена простоты.
    static func isSentenceBoundary(after word: TranscriptWord,
                                   next: TranscriptWord?) -> Bool {
        guard let last = lastMeaningfulCharacter(of: word.text),
              sentenceTerminators.contains(last) else { return false }
        guard let next else { return true }
        if let first = next.text.first, first.isUppercase || first.isNumber {
            return true
        }
        return next.start - word.end > sentencePauseThreshold
    }

    // MARK: - Внутренности

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let trailingClosers: Set<Character> = ["»", "\"", "'", ")", "]", "”", "’"]

    private static func lastMeaningfulCharacter(of text: String) -> Character? {
        var characters = Array(text)
        while let last = characters.last, trailingClosers.contains(last) {
            characters.removeLast()
        }
        return characters.last
    }

    /// Режет слова сегмента на предложения, группирует их в блоки
    /// до `config.targetChunkDuration` и собирает подсегменты. Спикер
    /// наследуется, тайм-код блока — start его первого слова.
    private static func subsegments(of segment: TranscriptSegment,
                                    words: [TranscriptWord],
                                    config: Config) -> [TranscriptSegment] {
        var sentences: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for (offset, word) in words.enumerated() {
            current.append(word)
            let next = offset + 1 < words.count ? words[offset + 1] : nil
            if isSentenceBoundary(after: word, next: next) {
                sentences.append(current)
                current.removeAll()
            } else if let first = current.first, word.end - first.start > config.hardBreakDuration {
                let head = breakAtWidestPause(current)
                sentences.append(head)
                current.removeFirst(head.count)
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var chunks: [[TranscriptWord]] = []
        var chunk: [TranscriptWord] = []
        for sentence in sentences {
            if chunk.isEmpty {
                chunk = sentence
            } else if let first = chunk.first, let last = sentence.last,
                      last.end - first.start <= config.targetChunkDuration {
                chunk.append(contentsOf: sentence)
            } else {
                chunks.append(chunk)
                chunk = sentence
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }

        return chunks.compactMap { chunkWords in
            guard let first = chunkWords.first, let last = chunkWords.last else { return nil }
            return TranscriptSegment(
                speaker: segment.speaker,
                start: first.start,
                end: last.end,
                text: joinWords(chunkWords)
            )
        }
    }

    /// Принудительный разрыв куска без пунктуации: голова до самой длинной
    /// межсловной паузы. Если пауз нет (слова впритык) — рвётся как есть,
    /// по текущей длине.
    private static func breakAtWidestPause(_ words: [TranscriptWord]) -> [TranscriptWord] {
        guard words.count > 1 else { return words }
        var bestIndex = words.count
        var bestPause = -Double.infinity
        for index in 1..<words.count {
            let pause = words[index].start - words[index - 1].end
            if pause > bestPause {
                bestPause = pause
                bestIndex = index
            }
        }
        return Array(words.prefix(bestIndex))
    }

    /// Склейка текста из слов: одиночная пунктуация (мусорные токены)
    /// приклеивается к предыдущему слову без пробела. Не private —
    /// тем же способом собирает текст `SpeakerAssignment`, когда режет
    /// сегмент на репликах разных спикеров.
    static func joinWords(_ words: [TranscriptWord]) -> String {
        var parts: [String] = []
        for word in words {
            let isPunctuationOnly = word.text.allSatisfy { $0.isPunctuation || $0.isSymbol }
            if isPunctuationOnly, !parts.isEmpty {
                parts[parts.count - 1] += word.text
            } else {
                parts.append(word.text)
            }
        }
        return parts.joined(separator: " ")
    }
}

/// Уровень детализации тайм-кодов результата: управляет ТОЛЬКО локальной
/// нарезкой сегментов (пословные метки запрашиваются у сервера всегда),
/// поэтому его можно менять на готовом результате без повторного запроса.
/// UI-агностичен, титулы через L() — по образцу `DiarizationSetting`.
enum TimestampDetail: String, CaseIterable, Identifiable {
    case server, coarse, medium, fine

    var id: String { rawValue }
    var title: String { L("transcribe.detail.\(rawValue)") }

    /// Конфиг сплиттера. nil — «как отдаёт сервер»: нарезка не выполняется
    /// (при диаризации сегменты могут длиться минутами).
    var config: TranscriptSegmentSplitter.Config? {
        switch self {
        case .server: return nil
        case .coarse: return .coarse
        case .medium: return .medium
        case .fine: return .fine
        }
    }
}
