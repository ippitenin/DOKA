import SwiftUI

/// Секция «Сервис»: встроенный сервис (рекомендуется), локальные модели
/// (Whisper/Parakeet — распознавание целиком на этом Mac, без сети и ключа)
/// и пользовательские OpenAI-совместимые пресеты. Проверенный «свой» сервис
/// сохраняется в выпадающий список — адрес/модель/ключ не нужно вводить
/// заново; корзина удаляет выбранный пресет (возврат на встроенный).
struct ServiceSectionView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var models = LocalModelStore.shared
    /// Режим добавления нового сервиса (пункт «Новый сервис…»);
    /// активный сервис не меняется, пока новый не проверен и не сохранён.
    @State private var isAdding = false
    @State private var endpointDraft = ""
    @State private var modelDraft = ""
    @State private var apiKey = ""
    @State private var status: Status = .unknown
    /// Подтверждение удаления файлов модели с диска (алерт живёт на карточке
    /// показанной модели — какая именно, известно из контекста карточки).
    @State private var confirmModelDelete = false

    private enum Status: Equatable {
        case unknown, checking, valid, invalid(String)
    }

    /// Пункт выпадающего списка. Явная модель вместо позиционной арифметики
    /// индексов: пункты разной природы (встроенный, локальные модели, пресеты,
    /// «Новый сервис…») перечисляются одним массивом, индекс — только позиция.
    private enum ServiceMenuItem: Equatable {
        case builtin
        case local(LocalModel)
        case custom(CustomService)
        case addCustom
    }

    private var showsCustomFields: Bool {
        isAdding || settings.selectedCustomService != nil
    }

    /// Показ карточки локальной модели (вместо карточки API-ключа).
    private var shownLocalModel: LocalModel? {
        guard !isAdding else { return nil }
        return settings.selectedLocalModel
    }

    var body: some View {
        SettingsForm(title: L("section.service")) {
            SettingsCard(footer: showsCustomFields ? L("service.customHint") : nil) {
                SettingsRow(title: L("service.provider")) {
                    HStack(spacing: 8) {
                        SettingsPopup(
                            titles: menuItems.map(title(for:)),
                            selectionIndex: Binding(
                                get: { selectionIndex },
                                set: { select(index: $0) }
                            ),
                            // Названия сервисов длинные — ширина по содержимому.
                            width: nil
                        )
                        if let service = settings.selectedCustomService, !isAdding {
                            Button {
                                deleteService(service)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L("service.deleteService"))
                        }
                    }
                }

                if showsCustomFields {
                    CardDivider()
                    SettingsRow(title: L("service.endpoint")) {
                        TextField("", text: $endpointDraft,
                                  prompt: Text("https://example.com/v1"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .onChange(of: endpointDraft) { _, _ in status = .unknown }
                    }
                    CardDivider()
                    SettingsRow(title: L("service.model")) {
                        TextField("", text: $modelDraft,
                                  prompt: Text(TranscriptionProvider.custom.defaultModel))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .onChange(of: modelDraft) { _, _ in status = .unknown }
                    }
                }
            }

            if let local = shownLocalModel {
                localModelCard(local)
            } else {
                keyCard
            }
        }
        .onAppear { reloadDrafts() }
        .onChange(of: settings.providerID) { _, _ in reloadDrafts() }
    }

    // MARK: - Карточка API-ключа (сетевые сервисы)

    private var keyCard: some View {
        SettingsCard {
            SettingsRow(title: L("service.apiKey")) {
                SecureField("", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onChange(of: apiKey) { _, _ in status = .unknown }
            }
            CardDivider()
            HStack(spacing: 12) {
                Button(L("service.checkAndSave")) {
                    checkAndSave()
                }
                .dsProminentButton()
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .checking)

                statusLabel
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 9)
        }
    }

    // MARK: - Карточка локальной модели

    /// На Intel-маках нейродвижка нет: Whisper работает через CPU в разы
    /// медленнее (предупреждаем), Parakeet не работает вовсе (блокируем;
    /// сам барьер — в `LocalModelStore.download`, тут только презентация).
    private func localModelCard(_ model: LocalModel) -> some View {
        SettingsCard(footer: L("service.local.offlineHint")) {
            SettingsRow(title: L("service.local.status")) {
                modelStatusControl(model)
            }
            if !LocalModel.isAppleSiliconMac {
                CardDivider()
                Label(model.requiresAppleSilicon
                        ? L("service.local.intelUnsupported")
                        : L("service.local.intelSlow"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Spacing.cardPadding)
                    .padding(.vertical, 9)
            }
        }
        .alert(L("service.local.deleteConfirmTitle"),
               isPresented: $confirmModelDelete) {
            Button(L("service.local.deleteModel"), role: .destructive) {
                models.delete(model)
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("service.local.deleteConfirmText"))
        }
    }

    @ViewBuilder
    private func modelStatusControl(_ model: LocalModel) -> some View {
        switch models.state(for: model) {
        case .notDownloaded:
            HStack(spacing: 12) {
                Text(L("service.local.notDownloaded",
                       Self.bytes(model.approxDownloadBytes)))
                    .foregroundStyle(.secondary)
                Button(L("service.local.download")) {
                    models.download(model)
                }
                .dsProminentButton()
                .disabled(model.requiresAppleSilicon && !LocalModel.isAppleSiliconMac)
            }
        case .downloading(let progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(width: 150)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("common.cancel")) {
                    models.cancelDownload(model)
                }
                .dsGlassButton()
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("service.local.preparing"))
                    .foregroundStyle(.secondary)
            }
        case .ready(let size):
            HStack(spacing: 12) {
                Label(L("service.local.ready", Self.bytes(size)),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(L("service.local.deleteModel")) {
                    confirmModelDelete = true
                }
                .dsGlassButton()
            }
        case .failed(let message):
            HStack(spacing: 12) {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("service.local.download")) {
                    models.download(model)
                }
                .dsProminentButton()
            }
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: - Пикер сервисов

    /// Порядок пунктов: встроенный → локальные модели → пресеты → «Новый сервис…».
    private var menuItems: [ServiceMenuItem] {
        [.builtin]
            + LocalModel.allCases.map { .local($0) }
            + settings.customServices.map { .custom($0) }
            + [.addCustom]
    }

    private func title(for item: ServiceMenuItem) -> String {
        switch item {
        case .builtin: return L("provider.builtin")
        case .local(let model): return model.title
        case .custom(let service): return service.name
        case .addCustom: return L("service.addCustom")
        }
    }

    /// Пункт, соответствующий текущему состоянию (режим добавления либо
    /// активный сервис).
    private var currentItem: ServiceMenuItem {
        if isAdding { return .addCustom }
        if let local = settings.selectedLocalModel { return .local(local) }
        if let service = settings.selectedCustomService { return .custom(service) }
        return .builtin
    }

    private var selectionIndex: Int {
        menuItems.firstIndex(of: currentItem) ?? 0
    }

    private func select(index: Int) {
        status = .unknown
        let items = menuItems
        guard items.indices.contains(index) else { return }
        let newID: String
        switch items[index] {
        case .builtin:
            newID = TranscriptionProvider.builtin.rawValue
        case .local(let model):
            newID = model.providerID
        case .custom(let service):
            newID = "custom:\(service.id.uuidString)"
        case .addCustom:
            // «Новый сервис…»: чистая форма, активный сервис пока прежний.
            isAdding = true
            endpointDraft = ""
            modelDraft = ""
            apiKey = ""
            return
        }
        isAdding = false
        settings.providerID = newID
        reloadDrafts()
    }

    private func reloadDrafts() {
        guard !isAdding else { return }
        if let service = settings.selectedCustomService {
            endpointDraft = service.endpoint
            modelDraft = service.model
        } else {
            endpointDraft = ""
            modelDraft = ""
        }
        apiKey = settings.currentAPIKey ?? ""
        status = .unknown
    }

    private func deleteService(_ service: CustomService) {
        settings.deleteCustomService(service.id)
        reloadDrafts()
    }

    // MARK: - Проверка и сохранение

    /// Статус проверки ключа; иконка подпрыгивает при смене результата.
    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            Label(L("service.keyWorks"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: status)
        case .invalid(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.bounce, value: status)
        }
    }

    private func checkAndSave() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let config: ProviderConfig
        if showsCustomFields {
            guard let url = ProviderConfig.normalizeEndpoint(endpointDraft) else {
                status = .invalid(TranscriptionClient.ClientError.notConfigured.localizedDescription)
                return
            }
            let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            config = ProviderConfig(endpoint: url,
                                    model: model.isEmpty ? TranscriptionProvider.custom.defaultModel : model)
        } else {
            guard let builtin = settings.providerConfig else { return }
            config = builtin
        }
        status = .checking
        Task {
            let result = await TranscriptionClient().validateKey(key, config: config)
            switch result {
            case .success:
                guard persist(key: key) else {
                    status = .invalid(L("error.keychainSaveFailed"))
                    return
                }
                status = .valid
            case .failure(let error):
                if case .noFunds = error {
                    // Ключ верный — сохраняем, но предупреждаем о балансе.
                    _ = persist(key: key)
                }
                status = .invalid(error.localizedDescription)
            }
        }
    }

    /// Сохраняет проверенную конфигурацию: новый пресет добавляется в список
    /// и выбирается, у существующего обновляются адрес/модель/имя, у
    /// встроенного — только ключ.
    private func persist(key: String) -> Bool {
        if isAdding {
            let service = CustomService(
                id: UUID(),
                name: CustomService.makeName(endpoint: endpointDraft, model: modelDraft),
                endpoint: endpointDraft,
                model: modelDraft
            )
            guard KeychainHelper.setAPIKey(key, account: service.keychainAccount) else { return false }
            settings.customServices.append(service)
            isAdding = false
            settings.providerID = "custom:\(service.id.uuidString)"
            return true
        }
        if let service = settings.selectedCustomService,
           let index = settings.customServices.firstIndex(of: service) {
            guard KeychainHelper.setAPIKey(key, account: service.keychainAccount) else { return false }
            var updated = service
            updated.endpoint = endpointDraft
            updated.model = modelDraft
            updated.name = CustomService.makeName(endpoint: endpointDraft, model: modelDraft)
            settings.customServices[index] = updated
            return true
        }
        return KeychainHelper.setAPIKey(key, account: settings.currentKeychainAccount)
    }
}
