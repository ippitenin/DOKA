import AppKit

/// Перезапуск приложения: дочерний шелл ждёт фактического выхода текущего
/// процесса (kill -0) и лишь затем открывает новый экземпляр — фиксированная
/// задержка могла бы запустить вторую копию при медленном завершении.
/// Используется сменой языка интерфейса и переносом папки данных.
@MainActor
enum AppRelaunch {
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; " +
            "/usr/bin/open \"$0\"",
            Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
