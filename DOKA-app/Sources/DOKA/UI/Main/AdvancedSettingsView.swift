import AppKit
import SwiftUI

/// Под-страница «Расширенные» секции «Общие»: иконка в Dock, окно при
/// запуске и папка данных с полноценным переносом. Открывается плашкой
/// с шевроном, закрывается кнопкой «назад» (drill-in через @State родителя).
struct AdvancedSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    let onBack: () -> Void

    /// Текущий путь папки данных; обновляется после переноса.
    @State private var folderPath = AppDataFolder.currentURL.path
    @State private var isCustomFolder = AppDataFolder.isCustom
    @State private var migrationAlert: MigrationAlert?

    private enum MigrationAlert {
        case done(path: String)
        case failed(message: String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.cardPadding) {
                backButton
                SectionHeader(title: L("general.advanced"))
                    .padding(.bottom, 2)
                appCard
                dataFolderCard
                transcriptsCard
            }
            .padding(.horizontal, DS.Spacing.section)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
        // Смена срока — мгновенная чистка журнала (onChange, не .alert:
        // с migration-алертом ниже не конфликтует).
        .onChange(of: settings.transcriptRetention) { _, newValue in
            if let hours = newValue.hours {
                TranscriptHistoryStore.shared.prune(olderThanHours: hours)
            }
        }
        .alert(alertTitle, isPresented: alertPresented) {
            switch migrationAlert {
            case .done:
                Button(L("advanced.migrate.done.restart")) { AppRelaunch.relaunch() }
                Button(L("advanced.migrate.done.later"), role: .cancel) {}
            case .failed, .none:
                Button(L("common.ok"), role: .cancel) {}
            }
        } message: {
            switch migrationAlert {
            case .done(let path):
                Text(L("advanced.migrate.done.message", path))
            case .failed(let message):
                Text(message)
            case .none:
                Text("")
            }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                Text(L("advanced.back"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.accent)
    }

    private var appCard: some View {
        SettingsCard(header: L("advanced.appCard")) {
            SettingsRow(title: L("advanced.showDock"),
                        help: L("advanced.showDock.hint")) {
                SettingsSwitch(isOn: $settings.showDockIcon)
            }
            CardDivider()
            SettingsRow(title: L("advanced.openAtLaunch"),
                        help: L("advanced.openAtLaunch.hint")) {
                SettingsSwitch(isOn: $settings.openWindowAtLaunch)
            }
        }
    }

    private var dataFolderCard: some View {
        SettingsCard(header: L("advanced.dataFolder"),
                     footer: L("advanced.dataFolder.footer")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(folderPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button(L("advanced.revealInFinder")) { revealInFinder() }
                        .dsGlassButton()
                    Button(L("advanced.changeFolder")) { changeFolder() }
                        .dsGlassButton()
                    if isCustomFolder {
                        Button(L("advanced.resetFolder")) { resetFolder() }
                            .dsGlassButton()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 10)
        }
    }

    /// Карточка «Недавних транскрибаций»: срок хранения записей и адрес
    /// журнала на диске. Журнал лежит в общей «Папке данных» (карточка выше),
    /// поэтому отдельного переноса нет — перенос папки переносит и его.
    private var transcriptsCard: some View {
        SettingsCard(header: L("advanced.transcripts"),
                     footer: L("advanced.transcripts.footer")) {
            SettingsRow(title: L("advanced.transcripts.retention"),
                        help: L("advanced.transcripts.retention.help")) {
                SettingsPopup(
                    titles: TranscriptRetention.allCases.map(\.title),
                    selectionIndex: Binding(
                        get: { TranscriptRetention.allCases.firstIndex(of: settings.transcriptRetention) ?? 0 },
                        set: { settings.transcriptRetention = TranscriptRetention.allCases[$0] }
                    )
                )
            }
            CardDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text((folderPath as NSString).appendingPathComponent(TranscriptHistoryStore.fileName))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button(L("advanced.revealInFinder")) { revealTranscriptsInFinder() }
                        .dsGlassButton()
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Алерт (один на обе ветки: два .alert на одной вью конфликтуют)

    private var alertTitle: String {
        switch migrationAlert {
        case .done: return L("advanced.migrate.done.title")
        case .failed, .none: return L("advanced.migrate.failed.title")
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { migrationAlert != nil },
            set: { if !$0 { migrationAlert = nil } }
        )
    }

    // MARK: - Действия

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppDataFolder.currentURL])
    }

    /// Показать журнал транскрибаций; пока файла нет (записей не было) —
    /// саму папку данных.
    private func revealTranscriptsInFinder() {
        let url = AppDataFolder.currentURL.appendingPathComponent(TranscriptHistoryStore.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([AppDataFolder.currentURL])
        }
    }

    private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("advanced.changeFolder.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        migrate { try AppDataFolder.migrate(to: url) }
    }

    private func resetFolder() {
        migrate { try AppDataFolder.migrateToDefault() }
    }

    private func migrate(_ operation: () throws -> URL) {
        // Плеер может держать открытым m4a внутри переносимой папки.
        RecordingPlayer.shared.stop()
        do {
            let target = try operation()
            folderPath = target.path
            isCustomFolder = AppDataFolder.isCustom
            migrationAlert = .done(path: target.path)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            migrationAlert = .failed(message: message)
        }
    }
}
