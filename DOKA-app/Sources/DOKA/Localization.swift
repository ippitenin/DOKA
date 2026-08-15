import Foundation

/// Локализованная строка из бандла модуля
/// (Resources/<язык>.lproj/Localizable.strings).
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

/// Локализованная строка с printf-подстановками.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
