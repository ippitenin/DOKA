import Foundation

/// Сшивка расшифровки с результатом локальной диаризации: у ASR — текст со
/// словами и тайм-кодами, у диаризатора — интервалы «кто когда говорил»,
/// общего между ними только время. Чистые детерминированные функции
/// (как `TranscriptSegmentSplitter` и `TranscriptFormatter`).
///
/// У сетевой диаризации Nexara этого шага нет: там сервер сразу возвращает
/// `speaker` в каждом сегменте.
enum SpeakerAssignment {
    /// Проставляет спикеров сегментам расшифровки.
    ///
    /// Сегмент, целиком попавший в речь одного говорящего, сохраняет исходный
    /// текст сервера/движка — пересобирать его из слов незачем, потеряется
    /// пунктуация. Сегмент, внутри которого говорящий сменился, режется по
    /// словам на границе смены. Без слов (движок не дал пословных меток)
    /// спикер определяется по наибольшему перекрытию интервалов.
    static func apply(spans: [SpeakerSpan],
                      words: [TranscriptWord],
                      segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !spans.isEmpty, !segments.isEmpty else { return segments }

        let buckets = TranscriptSegmentSplitter.assignWords(words, to: segments)
        var result: [TranscriptSegment] = []

        for (index, segment) in segments.enumerated() {
            let segmentWords = index < buckets.count ? buckets[index] : []
            guard !segmentWords.isEmpty else {
                result.append(TranscriptSegment(speaker: dominantSpeaker(for: segment, spans: spans),
                                                start: segment.start,
                                                end: segment.end,
                                                text: segment.text))
                continue
            }

            let runs = speakerRuns(of: segmentWords, spans: spans)
            if runs.count == 1, let only = runs.first {
                result.append(TranscriptSegment(speaker: only.speaker,
                                                start: segment.start,
                                                end: segment.end,
                                                text: segment.text))
            } else {
                for run in runs {
                    guard let first = run.words.first, let last = run.words.last else { continue }
                    result.append(TranscriptSegment(speaker: run.speaker,
                                                    start: first.start,
                                                    end: last.end,
                                                    text: TranscriptSegmentSplitter.joinWords(run.words)))
                }
            }
        }
        return result
    }

    // MARK: - Внутренности

    private struct SpeakerRun {
        let speaker: String
        var words: [TranscriptWord]
    }

    /// Слова сегмента, разбитые на подряд идущие реплики одного говорящего.
    private static func speakerRuns(of words: [TranscriptWord],
                                    spans: [SpeakerSpan]) -> [SpeakerRun] {
        var runs: [SpeakerRun] = []
        for word in words {
            let speaker = self.speaker(for: word, spans: spans)
            if var last = runs.last, last.speaker == speaker {
                last.words.append(word)
                runs[runs.count - 1] = last
            } else {
                runs.append(SpeakerRun(speaker: speaker, words: [word]))
            }
        }
        return runs
    }

    /// Спикер слова — по средней точке слова (как раздача слов сегментам).
    /// Слово, не попавшее ни в один интервал (пауза между репликами, речь
    /// короче порога диаризатора), достаётся ближайшему интервалу: оставить
    /// его без спикера значило бы разорвать реплику надвое.
    private static func speaker(for word: TranscriptWord, spans: [SpeakerSpan]) -> String {
        let mid = (word.start + word.end) / 2
        if let containing = spans.first(where: { mid >= $0.start && mid <= $0.end }) {
            return containing.speaker
        }
        var best = spans[0]
        var bestDistance = Double.infinity
        for span in spans {
            let distance = mid < span.start ? span.start - mid : mid - span.end
            if distance < bestDistance {
                bestDistance = distance
                best = span
            }
        }
        return best.speaker
    }

    /// Спикер сегмента без слов — с наибольшим перекрытием по времени.
    /// Нулевое перекрытие со всеми (сегмент в тишине) оставляет спикера пустым:
    /// выдумывать его не на чем.
    private static func dominantSpeaker(for segment: TranscriptSegment,
                                        spans: [SpeakerSpan]) -> String? {
        var totals: [String: Double] = [:]
        for span in spans {
            let overlap = min(segment.end, span.end) - max(segment.start, span.start)
            if overlap > 0 {
                totals[span.speaker, default: 0] += overlap
            }
        }
        return totals.max { $0.value < $1.value }?.key
    }
}
