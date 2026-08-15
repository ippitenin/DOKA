import Foundation
import Security

/// Одноразовый перенос данных из прежней версии приложения (Whisper,
/// com.pitenin.whisper) в DOKA. Данные копируются, а не переносятся:
/// если старый Whisper.app ещё установлен, он продолжит работать.
enum LegacyMigration {
    private static let legacyDomain = "com.pitenin.whisper"
    private static let marker = "didMigrateFromWhisper"

    /// Вызывается до создания AppDelegate — настройки и горячие клавиши
    /// должны быть перенесены раньше, чем их прочитают SettingsStore
    /// и KeyboardShortcuts.
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }

        migrateDefaults(defaults)
        migrateAPIKey()
        migrateHistory()

        defaults.set(true, forKey: marker)
    }

    /// Настройки и горячие клавиши (KeyboardShortcuts хранит их в UserDefaults).
    private static func migrateDefaults(_ defaults: UserDefaults) {
        guard let old = defaults.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// API-ключ встроенного сервиса из записи Keychain старого приложения.
    /// macOS может показать запрос доступа к связке ключей — это ожидаемо.
    private static func migrateAPIKey() {
        guard KeychainHelper.getAPIKey(for: .builtin) == nil else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyDomain,
            kSecAttrAccount as String: "nexara-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return }
        KeychainHelper.setAPIKey(key, for: .builtin)
    }

    /// История транскрипций из Application Support/Whisper.
    private static func migrateHistory() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFile = appSupport.appendingPathComponent("Whisper/history.json")
        let newDir = AppDataFolder.currentURL
        let newFile = newDir.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: oldFile.path),
              !FileManager.default.fileExists(atPath: newFile.path) else { return }
        try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: oldFile, to: newFile)
    }
}
