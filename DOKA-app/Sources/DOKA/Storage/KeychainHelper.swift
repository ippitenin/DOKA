import Foundation
import Security

/// Хранение API-ключей сервисов распознавания в Связке ключей macOS.
/// У каждого сервиса своя запись — переключение между ними не теряет ключи.
enum KeychainHelper {
    private static let service = "com.pitenin.doka"

    // Обёртки для встроенных сервисов; произвольный account — для
    // пользовательских пресетов (у каждого свой ключ).
    static func getAPIKey(for provider: TranscriptionProvider) -> String? {
        getAPIKey(account: provider.keychainAccount)
    }

    @discardableResult
    static func setAPIKey(_ key: String, for provider: TranscriptionProvider) -> Bool {
        setAPIKey(key, account: provider.keychainAccount)
    }

    static func deleteAPIKey(for provider: TranscriptionProvider) {
        deleteAPIKey(account: provider.keychainAccount)
    }

    static func getAPIKey(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key.isEmpty ? nil : key
    }

    @discardableResult
    static func setAPIKey(_ key: String, account: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey(account: account)
            return true
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess {
            // Не только «не найден»: update может падать из-за ACL записи,
            // созданной другой подписью бинарника. Пересоздаём запись.
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("DOKA: ошибка Keychain при сохранении ключа: \(status)")
        }
        return status == errSecSuccess
    }

    static func deleteAPIKey(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
