import ArhivarCore
import Foundation

/// Hızlı Bakış eklentisinin arayüz metinleri ve biçimlendirme yerel ayarı.
///
/// Eklenti kum havuzunda çalışır ve uygulamanın dil tercihini (UserDefaults) okuyamaz; bu yüzden macOS'un tercih
/// edilen dilini izler. Tablolar eklenti paketine kopyalanan `<dil>.lproj/Localizable.strings` dosyalarıdır.
struct QuickLookStrings {
    static let shared = QuickLookStrings()

    let strings: StringTable
    let languageCode: String
    let locale: Locale

    init(bundle: Bundle = .main, preferredLanguages: [String] = Locale.preferredLanguages) {
        strings = StringTable(bundle: bundle)
        languageCode = AppLanguage.system.resolvedCode(preferredLanguages: preferredLanguages)
        locale = Locale(identifier: languageCode)
    }

    func t(_ key: LKey) -> String {
        strings.string(key, language: languageCode)
    }

    func t(_ key: LKey, _ arguments: any CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: arguments)
    }

    func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(locale))
    }

    func percent(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
