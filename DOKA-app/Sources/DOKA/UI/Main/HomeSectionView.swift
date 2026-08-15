import SwiftUI
import KeyboardShortcuts

/// Секция «Главная»: шаги первоначальной настройки, а когда всё готово —
/// приветственный экран с подсказкой хоткея и последней транскрипцией.
struct HomeSectionView: View {
    @ObservedObject var permissions = PermissionsManager.shared
    @ObservedObject var history = HistoryStore.shared
    @State private var apiKey: String = ""
    @State private var keyStatus: KeyStatus = .missing

    private enum KeyStatus: Equatable {
        case missing, checking, saved, invalid(String)
    }

    private var keyReady: Bool { keyStatus == .saved }
    private var allReady: Bool { permissions.allGranted && keyReady }

    var body: some View {
        Group {
            if allReady {
                readyView
            } else {
                setupView
            }
        }
        .onAppear {
            permissions.startPolling()
            permissions.registerAccessibility()
            // Сетевой сервис готов при сохранённом ключе, локальный — при
            // скачанной модели: онбординг не должен требовать ключ, которого
            // у локальной модели нет.
            if SettingsStore.shared.isServiceReady {
                keyStatus = .saved
            }
        }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: allReady) { _, ready in
            if ready {
                SettingsStore.shared.onboardingCompleted = true
                permissions.stopPolling()
            } else {
                permissions.startPolling()
            }
        }
    }

    // MARK: - Всё готово

    private var readyView: some View {
        ZStack {
            FloatingWordsView()
            readyContent
        }
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            Spacer()

            // Фирменный логотип — готовый цветной вектор из бандла.
            DokaBrandLogo(size: 132)
                .padding(.bottom, 18)

            Text(L("home.ready.title"))
                .font(.title.bold())
                .padding(.bottom, 6)
            Text(L("home.ready.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 22)

            hotkeyHint
                .padding(.bottom, 30)

            if let last = history.lastText {
                SectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("home.lastTranscription"))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            CopyButton(text: last)
                        }
                        Text(last)
                            .font(.callout)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                }
                .frame(maxWidth: 440)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// Подсказка хоткея: бейджи фактического сочетания,
    /// а если оно не задано — ссылка в раздел «Клавиши».
    @ViewBuilder
    private var hotkeyHint: some View {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            HStack(spacing: 8) {
                let keys = Self.splitKeys(shortcut.description)
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text("+").font(.title2).foregroundStyle(.secondary)
                    }
                    KeyCapBadge(symbol: key)
                }
            }
        } else {
            Button(L("home.noShortcut")) {
                WindowManager.shared.showMain(section: .hotkeys)
            }
            .buttonStyle(.link)
        }
    }

    /// Разбивает строку сочетания («⌃⌥F5») на клавиши: ведущие модификаторы —
    /// по одному бейджу, остаток (клавиша, возможно многосимвольная) — целиком.
    private static func splitKeys(_ description: String) -> [String] {
        let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var keys: [String] = []
        var rest = Substring(description)
        while let first = rest.first, modifierSymbols.contains(first) {
            keys.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty {
            keys.append(String(rest))
        }
        return keys
    }

    // MARK: - Шаги настройки

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: L("home.welcome.title"),
                    subtitle: L("home.welcome.subtitle")
                )

                SectionCard {
                    StepRow(
                        done: permissions.micAuthorized,
                        title: L("home.step.mic.title"),
                        subtitle: L("home.step.mic.subtitle")
                    ) {
                        // Системный промпт macOS показывает только один раз.
                        // После отказа остаётся лишь путь через Системные настройки.
                        if permissions.micDenied {
                            Button(L("home.openSettings")) {
                                permissions.openMicrophoneSettings()
                            }
                            .dsProminentButton()
                        } else {
                            Button(L("home.allow")) {
                                Task { _ = await permissions.requestMicrophone() }
                            }
                            .dsProminentButton()
                        }
                    }

                    Divider().padding(.horizontal, 14)

                    StepRow(
                        done: permissions.axTrusted,
                        title: L("home.step.ax.title"),
                        subtitle: L("home.step.ax.subtitle")
                    ) {
                        Button(L("home.openSettings")) {
                            permissions.openAccessibilitySettings()
                        }
                        .dsProminentButton()
                    }

                    Divider().padding(.horizontal, 14)

                    apiKeyStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
    }

    private var apiKeyStep: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: keyReady)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("home.step.key.title")).font(.headline)
                if !keyReady {
                    HStack {
                        SecureField(L("home.step.key.placeholder"), text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .onChange(of: apiKey) { _, _ in
                                if keyStatus != .checking { keyStatus = .missing }
                            }
                        Button(L("home.save")) { checkAndSave() }
                            .dsProminentButton()
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || keyStatus == .checking)
                    }
                    switch keyStatus {
                    case .checking:
                        Label(L("home.checkingKey"), systemImage: "hourglass")
                            .font(.caption).foregroundStyle(.secondary)
                    case .invalid(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                } else {
                    Text(L("home.keySaved"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func checkAndSave() {
        let settings = SettingsStore.shared
        guard let config = settings.providerConfig else {
            keyStatus = .invalid(TranscriptionClient.ClientError.notConfigured.localizedDescription)
            return
        }
        let account = settings.currentKeychainAccount
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keyStatus = .checking
        Task {
            let result = await TranscriptionClient().validateKey(key, config: config)
            switch result {
            case .success:
                keyStatus = KeychainHelper.setAPIKey(key, account: account)
                    ? .saved
                    : .invalid(L("error.keychainSaveFailed"))
            case .failure(let error):
                if case .noFunds = error, KeychainHelper.setAPIKey(key, account: account) {
                    keyStatus = .saved
                } else {
                    keyStatus = .invalid(error.localizedDescription)
                }
            }
        }
    }
}
