import Foundation

/// Пресет-фразы для теста скорости печати — короткие абзацы из двух-трёх
/// предложений (как в SuperWhisper). Намеренно без кавычек, тире и апострофов:
/// смарт-замены `NSTextField` (умные кавычки/дефисы) исказили бы посимвольное
/// сравнение. Точки и запятые безопасны. Так обычного `TextField` хватает без
/// NSViewRepresentable-обёртки.
enum TypingPhrases {
    static let ru: [String] = [
        "Пока ты дочитаешь это предложение до конца, голосом можно было бы надиктовать его трижды. Речь всегда быстрее самых ловких пальцев.",
        "Сегодня отличный день, чтобы перестать печатать вручную. Просто говори, а текст появится сам, ровно там, где он нужен.",
        "Каждое утро уходит уйма времени на набор писем и заметок. Диктовка возвращает эти минуты обратно, день за днём.",
        "Мысли приходят быстрее, чем пальцы успевают за ними. Когда не нужно печатать, идеи льются свободно и не теряются по дороге.",
        "Хорошая привычка экономит часы каждую неделю. Маленькие шаги складываются в большую разницу, если повторять их изо дня в день.",
        "Голос не устаёт так, как устают руки к вечеру. Длинные тексты даются легко, а запястья остаются свободными и здоровыми.",
        "Представь, что любую заметку можно надиктовать за пару секунд. Никакой возни с клавиатурой, только чистый поток слов.",
        "Скорость речи обгоняет скорость набора в несколько раз. Попробуй сам, и ты удивишься, сколько времени освобождается каждый день."
    ]
    static let en: [String] = [
        "By the time you finish typing this sentence, you could have said it three times over. Your voice is faster than your fingers will ever be.",
        "Today is a great day to stop typing by hand. Just speak, and the text appears on its own, exactly where you need it to be.",
        "Every morning you lose precious minutes typing emails and notes. Dictation gives those minutes back to you, day after day.",
        "Ideas arrive faster than fingers can keep up. When you do not have to type, your thoughts flow freely and nothing gets lost along the way.",
        "A good habit saves hours every single week. Small steps add up to a big difference when you repeat them every day.",
        "Your voice does not get tired the way your hands do by evening. Long texts come easily, and your wrists stay free and healthy.",
        "Imagine writing any note in just a couple of seconds. No typos, no fighting with the keyboard, only a clean stream of words.",
        "Speaking is several times faster than typing for most people. Try it yourself, and you will be amazed how much time you save each day."
    ]

    /// Фразы по языку интерфейса (тот же бандл, что у `L()`): ru → русские, иначе английские.
    static func forCurrentLocale() -> [String] {
        let code = Bundle.module.preferredLocalizations.first ?? "en"
        return code.hasPrefix("ru") ? ru : en
    }
}
