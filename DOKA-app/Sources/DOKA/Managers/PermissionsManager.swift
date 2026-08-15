import AppKit
import AVFoundation

/// Состояние разрешений: микрофон и Универсальный доступ (Accessibility).
@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var micAuthorized: Bool
    /// Запрос уже был отклонён: системный промпт больше не покажется,
    /// доступ можно включить только в Системных настройках.
    @Published var micDenied: Bool
    @Published var axTrusted: Bool

    private var pollTimer: Timer?

    private init() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = status == .authorized
        micDenied = status == .denied || status == .restricted
        axTrusted = AXIsProcessTrusted()
    }

    var allGranted: Bool { micAuthorized && axTrusted }

    func refresh() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = status == .authorized
        micDenied = status == .denied || status == .restricted
        axTrusted = AXIsProcessTrusted()
    }

    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    /// Регистрирует приложение в списке Universal Access (тумблер появляется
    /// выключенным). Системный диалог macOS показывает максимум один раз
    /// за жизнь подписи; вызывается при показе онбординга, а не по кнопке —
    /// чтобы кнопка «Открыть настройки» не плодила два окна сразу.
    func registerAccessibility() {
        guard !axTrusted else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// Поллинг статусов на время онбординга.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                PermissionsManager.shared.refresh()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
