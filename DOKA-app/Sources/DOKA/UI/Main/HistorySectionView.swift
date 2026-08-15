import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Секция «История»: карточки транскрипций с разворачиванием, плеером оригинала,
/// инспектором деталей, мультивыбором (экспорт/удаление/Analyze) и подтверждениями.
struct HistorySectionView: View {
    @ObservedObject var history = HistoryStore.shared
    @ObservedObject private var player = RecordingPlayer.shared
    @State private var search = ""
    @State private var expanded: Set<UUID> = []
    @State private var selection: Set<UUID> = []
    @State private var inspectorRecord: TranscriptionRecord?
    @State private var confirmClearAll = false
    @State private var pendingDeleteOne: TranscriptionRecord?
    @State private var confirmDeleteBatch = false
    @State private var showAnalyze = false
    @State private var analyzeRecords: [TranscriptionRecord] = []

    private var filtered: [TranscriptionRecord] {
        guard !search.isEmpty else { return history.records }
        return history.records.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    private var allVisibleSelected: Bool {
        !filtered.isEmpty && filtered.allSatisfy { selection.contains($0.id) }
    }

    private var selectedRecords: [TranscriptionRecord] {
        history.records.filter { selection.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            if let record = inspectorRecord {
                HistoryDetailInspector(record: record) { closeInspector() }
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Anim.section, value: inspectorRecord?.id)
        .animation(DS.Anim.control, value: selection.isEmpty)
        .onDisappear { player.stop() }
        .sheet(isPresented: $showAnalyze) {
            PerformanceAnalysisView(records: analyzeRecords)
        }
    }

    // MARK: - Основной столбец

    /// Три подтверждения висят на РАЗНЫХ постоянных вью: несколько `.alert`
    /// на одной вью конфликтуют (срабатывает только последний).
    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L("section.history"))
                .alert(L("history.multi.deleteConfirm.title"), isPresented: $confirmDeleteBatch) {
                    Button(L("history.delete"), role: .destructive) { deleteSelected() }
                    Button(L("common.cancel"), role: .cancel) {}
                } message: {
                    Text(L("history.multi.deleteConfirm.message", selection.count))
                }

            searchRow
                .alert(L("history.clearAll.title"), isPresented: $confirmClearAll) {
                    Button(L("history.delete"), role: .destructive) {
                        player.stop()
                        history.clear()
                        selection.removeAll()
                        expanded.removeAll()
                        inspectorRecord = nil
                    }
                    Button(L("common.cancel"), role: .cancel) {}
                } message: {
                    Text(L("history.clearAll.message", history.records.count))
                }

            content
                .alert(L("history.deleteOne.title"),
                       isPresented: Binding(get: { pendingDeleteOne != nil },
                                            set: { if !$0 { pendingDeleteOne = nil } }),
                       presenting: pendingDeleteOne) { record in
                    Button(L("history.delete"), role: .destructive) { delete(record) }
                    Button(L("common.cancel"), role: .cancel) {}
                } message: { _ in
                    Text(L("history.deleteOne.message"))
                }
        }
        .padding(.horizontal, 24)
        .padding(.top, 46)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if !selection.isEmpty { multiSelectBar }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("history.search"), text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .glassCapsule()

            Button {
                confirmClearAll = true
            } label: {
                Label(L("history.clear"), systemImage: "trash")
                    .foregroundStyle(history.records.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .glassCapsule(interactive: true)
            .disabled(history.records.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
                .padding(.bottom, 20)
        } else {
            scrollList
        }
    }

    /// Высота зоны растворения карточек у верхней кромки ленты.
    private static let topFade: CGFloat = 28

    /// Лента карточек тянется до самой нижней кромки окна (обрезка краем окна,
    /// а не «в воздухе»), а сверху при прокрутке карточки плавно растворяются
    /// градиентной маской. Верхний отступ контента равен высоте зоны фейда,
    /// чтобы в покое (скролл в самом верху) первая карточка под маску не попадала.
    /// Ловушка: системный scrollEdgeEffectStyle(.soft) тут НЕ работает — без
    /// настоящего safe-area-бара над скроллом macOS 26 эффект не рисует, а
    /// safeAreaPadding(.top) вдобавок опускает скроллбар «в воздух».
    private var scrollList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filtered) { record in
                    HistoryCard(
                        record: record,
                        isExpanded: expanded.contains(record.id),
                        isSelected: selection.contains(record.id),
                        player: player,
                        onToggleSelect: { toggleSelect(record.id) },
                        onToggleExpand: { toggleExpand(record) },
                        onInfo: { openInspector(record) },
                        onDelete: { pendingDeleteOne = record },
                        onSaveTxt: { saveTxt(record) }
                    )
                }
            }
            .padding(.top, Self.topFade)
            .padding(.bottom, selection.isEmpty ? 20 : 76)
        }
        .scrollContentBackground(.hidden)
        // Overlay-скроллер macOS ездит поверх карточек — по просьбе пользователя
        // индикатор выключен совсем (.never, а не .hidden — иначе система
        // всё равно показывает его при прокрутке колесом).
        .scrollIndicators(.never)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.topFade)
                Color.black
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: history.records.isEmpty ? "waveform.slash" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .dsBreathe()
            Text(history.records.isEmpty ? L("history.empty") : L("history.notFound"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .glassSurface()
    }

    // MARK: - Панель мультивыбора

    private var multiSelectBar: some View {
        HStack(spacing: 12) {
            Text(L("history.multi.count", selection.count))
                .font(.callout.weight(.medium))
                .monospacedDigit()
            Spacer(minLength: 8)
            Button(allVisibleSelected ? L("history.multi.deselectAll") : L("history.multi.selectAll")) {
                if allVisibleSelected { selection.removeAll() }
                else { selection = Set(filtered.map(\.id)) }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(DS.accent)

            Menu {
                Button(L("history.export.csv")) { exportCSV() }
                Button(L("history.export.txt")) { exportCombinedTxt() }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassCapsule(interactive: true)
            .help(L("history.multi.export"))

            barIconButton("chart.bar.xaxis", help: L("history.multi.analyze")) {
                analyzeRecords = selectedRecords
                showAnalyze = true
            }
            barIconButton("trash", help: L("history.multi.delete"), tint: .red) {
                confirmDeleteBatch = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(shadow: true)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func barIconButton(_ symbol: String, help: String,
                               tint: Color = DS.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
        .help(help)
    }

    // MARK: - Действия

    private func toggleSelect(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleExpand(_ record: TranscriptionRecord) {
        withAnimation(DS.Anim.section) {
            if expanded.contains(record.id) {
                expanded.remove(record.id)
                player.stopIfCurrent(record.id)
            } else {
                expanded.insert(record.id)
            }
        }
    }

    private func openInspector(_ record: TranscriptionRecord) {
        inspectorRecord = record
    }

    private func closeInspector() {
        inspectorRecord = nil
    }

    private func delete(_ record: TranscriptionRecord) {
        if inspectorRecord?.id == record.id { inspectorRecord = nil }
        player.stopIfCurrent(record.id)
        history.delete(record)
        selection.remove(record.id)
        expanded.remove(record.id)
    }

    private func deleteSelected() {
        if let record = inspectorRecord, selection.contains(record.id) { inspectorRecord = nil }
        for id in selection { player.stopIfCurrent(id) }
        let ids = selection
        history.delete(ids)
        expanded.subtract(ids)
        selection.removeAll()
    }

    // MARK: - Сохранение / экспорт (приложение не в песочнице — пишем напрямую)

    private func saveTxt(_ record: TranscriptionRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedBaseName(record)).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(record.text, to: url)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DOKA-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(HistoryExport.csv(selectedRecords), to: url)
    }

    private func exportCombinedTxt() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DOKA-history.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(HistoryExport.combinedPlainText(selectedRecords), to: url)
    }

    private func write(_ text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("DOKA: не удалось сохранить файл истории: \(error.localizedDescription)")
        }
    }

    private func suggestedBaseName(_ record: TranscriptionRecord) -> String {
        let words = record.text.split { $0.isWhitespace || $0.isNewline }.prefix(5).joined(separator: " ")
        let trimmed = String(words.prefix(40)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "DOKA" : trimmed
    }
}

// MARK: - Карточка записи

private struct HistoryCard: View {
    let record: TranscriptionRecord
    let isExpanded: Bool
    let isSelected: Bool
    @ObservedObject var player: RecordingPlayer
    @ObservedObject var settings = SettingsStore.shared
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    let onInfo: () -> Void
    let onDelete: () -> Void
    let onSaveTxt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { expandedBody }
        }
        .padding(DS.Spacing.cardPadding)
        // forceMaterial: Liquid Glass у пачки карточек в скролле рисует общий
        // серый бэкдроп на весь viewport с резкими углами (особенно заметен
        // в светлой теме) — материал такого слоя не создаёт.
        .glassSurface(radius: DS.Radius.card, forceMaterial: true)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.accent, lineWidth: 1.5)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            // Селектор строки виден всегда — запись можно отметить сразу, без наведения.
            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? DS.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L("history.select"))

            // Текст-заголовок всегда в верхней строке рядом с контролами. Свёрнуто —
            // превью в 2 строки (тап разворачивает); развёрнуто — полный выделяемый текст.
            if isExpanded {
                Text(record.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(record.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleExpand() }
            }

            HStack(spacing: 8) {
                Text(clockMMSS(record.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                iconButton(isExpanded ? "chevron.up" : "chevron.down",
                           help: isExpanded ? L("history.collapse") : L("history.expand")) {
                    onToggleExpand()
                }
                iconButton("info.circle", help: L("history.info")) { onInfo() }
                iconButton("trash", help: L("history.delete"), tint: .red) { onDelete() }
            }
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Аудио показываем только если сохранение включено и файл существует.
            if settings.saveAudio, let url = record.audioURL {
                AudioPlayerBar(url: url, recordID: record.id,
                               fallbackDuration: record.duration, player: player)
            }

            CardDivider()
            footer
        }
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            metaItem("clock", clockMMSS(record.duration))
            if let model = record.model { metaItem("cpu", model) }
            if let t = record.transcriptionTime {
                metaItem("timer", String(format: "%.1f\u{00A0}\(L("history.unit.seconds"))", t))
            }
            Spacer(minLength: 8)
            CopyButton(text: record.text)
            Button(action: onSaveTxt) {
                Label(L("history.saveTxt"), systemImage: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(DS.accent)
            }
            .buttonStyle(.plain)
            .help(L("history.saveTxt"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metaItem(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(value).lineLimit(1)
        }
    }

    private func iconButton(_ symbol: String, help: String,
                            tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Плеер оригинала

private struct AudioPlayerBar: View {
    let url: URL
    let recordID: UUID
    let fallbackDuration: TimeInterval
    @ObservedObject var player: RecordingPlayer

    private var isCurrent: Bool { player.currentRecordID == recordID }
    private var dur: TimeInterval { isCurrent && player.duration > 0 ? player.duration : fallbackDuration }
    private var time: TimeInterval { isCurrent ? player.currentTime : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(url: url, recordID: recordID)
            } label: {
                Image(systemName: (isCurrent && player.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.accent)
            }
            .buttonStyle(.plain)

            Text(clockMMSS(time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            Slider(value: sliderBinding, in: 0...max(dur, 0.01)) { editing in
                guard isCurrent else { return }
                if editing {
                    player.isScrubbing = true
                } else {
                    player.isScrubbing = false
                    player.seek(to: player.currentTime)
                }
            }
            .controlSize(.small)
            .disabled(!isCurrent)

            Text(clockMMSS(dur))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isCurrent ? player.currentTime : 0 },
            set: { newValue in if isCurrent { player.currentTime = newValue } }
        )
    }
}

// MARK: - Инспектор «recorded details»

private struct HistoryDetailInspector: View {
    let record: TranscriptionRecord
    let onClose: () -> Void
    @ObservedObject var settings = SettingsStore.shared

    private var languageLabel: String {
        TranscriptionLanguage.all.first { $0.id == record.language }?.title ?? record.language
    }

    private var providerLabel: String {
        guard let raw = record.provider else { return "—" }
        return TranscriptionProvider(rawValue: raw)?.title ?? raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("history.inspector.title")).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("common.close"))
            }

            VStack(spacing: 0) {
                detailRow(L("history.inspector.dateTime"),
                          record.date.formatted(date: .long, time: .shortened))
                CardDivider()
                detailRow(L("history.inspector.language"), languageLabel)
                CardDivider()
                detailRow(L("history.inspector.microphone"), record.microphone ?? "—")
                CardDivider()
                detailRow(L("history.inspector.model"), record.model ?? "—")
                CardDivider()
                detailRow(L("history.inspector.provider"), providerLabel)
            }
            .glassSurface()

            // Кнопка есть только когда сохранение включено и файл на месте — иначе показывать нечего.
            if settings.saveAudio, let url = record.audioURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(L("history.inspector.showInFinder"), systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .dsGlassButton()
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) { Divider() }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

