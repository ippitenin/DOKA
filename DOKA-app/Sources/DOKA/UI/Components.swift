import AppKit
import SwiftUI

/// Мост к NSVisualEffectView — честный системный материал
/// (SwiftUI-материалы не дают .behindWindow-блюра в ручном NSWindow).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Крупный заголовок секции контент-области.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.bold())
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Стеклянная карточка-группа (бывший grouped-стиль Системных настроек).
struct SectionCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        // Контент (например, List) обрезается по форме стекла.
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .glassSurface()
    }
}

/// Иконка статуса шага (выполнен/не выполнен).
struct StatusIcon: View {
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }
}

/// Строка шага настройки: статус, заголовок, описание, действия.
struct StepRow<Actions: View>: View {
    let done: Bool
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: done)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    HStack { actions }
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

/// Кнопка копирования текста с понятным фидбэком: после нажатия ~1.5 с
/// показывает «Скопировано» с галочкой, затем возвращается к «Скопировать».
/// Решает проблему «копирование без подтверждения» — видно, что сработало.
/// С `html` кладёт в буфер оба представления (plain + HTML) — приложения с
/// rich-вставкой (Telegram, Notes, Word) получат таблицы таблицами.
struct CopyButton: View {
    let text: String
    var html: String? = nil
    @State private var copied = false
    /// Счётчик нажатий — повторный клик перезапускает авто-возврат.
    @State private var copyCount = 0

    var body: some View {
        Button {
            if let html {
                ClipboardManager.setRichText(plain: text, html: html)
            } else {
                ClipboardManager.setString(text)
            }
            copyCount += 1
            withAnimation(DS.Anim.control) { copied = true }
        } label: {
            Label(
                copied ? L("common.copied") : L("common.copy"),
                systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
            )
            .font(.caption)
            .foregroundStyle(copied ? Color.green : DS.accent)
            .symbolEffect(.bounce, value: copied)
            .animation(DS.Anim.control, value: copied)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(L("common.copy"))
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Anim.control) { copied = false }
        }
    }
}

/// Компактный кейкап «esc» для плашки записи (не путать с крупным `KeyCapBadge`).
struct EscKeyCap: View {
    var body: some View {
        Text("esc")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// Бэйдж клавиши для отображения сочетаний («⌥», «⇥»).
struct KeyCapBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 28, weight: .medium, design: .rounded))
            .frame(minWidth: 52, minHeight: 52)
            .glassSurface(radius: DS.Radius.badge)
    }
}

/// Обёртка сворачивания длинного контента: показывает не более
/// `collapsedHeight`, нижние строки затухают в фон, снизу — кнопка «Развернуть».
/// В развёрнутом виде — контент целиком и кнопка «Свернуть». Кнопка появляется,
/// только если контент заметно выше порога. Один `collapsedHeight` на карточки
/// «Анализ» и «Результат» держит их примерно одного размера в свёрнутом виде.
struct CollapsibleReveal<Content: View>: View {
    var collapsedHeight: CGFloat = 160
    /// Отступ вокруг контента и снизу под кнопкой — обёртка владеет им сама,
    /// чтобы карточки «Анализ» и «Результат» выглядели одинаково, а кнопка
    /// не прилипала к краю. Места вызова отдают контент БЕЗ своего паддинга.
    var contentPadding: CGFloat = DS.Spacing.cardPadding
    @ViewBuilder var content: Content

    @State private var isExpanded = false
    @State private var contentHeight: CGFloat = 0

    /// Сворачивать имеет смысл, только если контент заметно выше порога —
    /// иначе пары лишних строк ради кнопки не стоит.
    private var isCollapsible: Bool { contentHeight > collapsedHeight + 24 }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(heightReader)
                .frame(maxHeight: (isCollapsible && !isExpanded) ? collapsedHeight : nil,
                       alignment: .top)
                .clipped()
                .mask(fadeMask)

            if isCollapsible {
                toggleButton
            }
        }
    }

    /// Меряет натуральную высоту контента до ограничения `frame(maxHeight:)`.
    private var heightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.height, initial: true) { _, newValue in
                    contentHeight = newValue
                }
        }
    }

    /// В свёрнутом виде нижние ~28% затухают к прозрачности, иначе маска сплошная.
    @ViewBuilder
    private var fadeMask: some View {
        if isCollapsible && !isExpanded {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Rectangle().fill(.black)
        }
    }

    private var toggleButton: some View {
        Button {
            withAnimation(DS.Anim.section) { isExpanded.toggle() }
        } label: {
            Label(isExpanded ? L("common.collapse") : L("common.expand"),
                  systemImage: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.medium))
                .foregroundStyle(DS.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .padding(.bottom, contentPadding)
        .frame(maxWidth: .infinity)
    }
}
