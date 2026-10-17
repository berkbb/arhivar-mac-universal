import AppKit
import ArhivarCore
import Foundation
import Observation

/// Açık, koyu veya sistemi izleyen (otomatik) görünüm.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .system: .appearanceSystem
        case .light: .appearanceLight
        case .dark: .appearanceDark
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum ExtractLocation: String, CaseIterable, Identifiable {
    case ask
    case nextToArchive
    case custom

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .ask: .extractToAsk
        case .nextToArchive: .extractToNextTo
        case .custom: .extractToCustom
        }
    }
}

/// Kullanıcı tercihleri (UserDefaults) ve yerelleştirilmiş metinler için tek kaynak.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let language = "language"
        static let appearance = "appearance"
        static let extractLocation = "extractLocation"
        static let customExtractFolder = "customExtractFolder"
        static let extractIntoSubfolder = "extractIntoSubfolder"
        static let revealAfterOperation = "revealAfterOperation"
        static let overwriteMode = "overwriteMode"
        static let defaultFormat = "defaultFormat"
        static let defaultLevel = "defaultLevel"
        static let multithreaded = "multithreaded"
        static let customEnginePath = "customEnginePath"
        static let checkUpdatesAtLaunch = "checkUpdatesAtLaunch"
        static let all = [
            language, appearance, extractLocation, customExtractFolder, extractIntoSubfolder, revealAfterOperation,
            overwriteMode, defaultFormat, defaultLevel, multithreaded, customEnginePath, checkUpdatesAtLaunch,
        ]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let strings: StringTable

    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            applySystemLanguage()
        }
    }
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }
    var extractLocation: ExtractLocation { didSet { defaults.set(extractLocation.rawValue, forKey: Key.extractLocation) } }
    var customExtractFolder: String? { didSet { defaults.set(customExtractFolder, forKey: Key.customExtractFolder) } }
    var extractIntoSubfolder: Bool { didSet { defaults.set(extractIntoSubfolder, forKey: Key.extractIntoSubfolder) } }
    var revealAfterOperation: Bool { didSet { defaults.set(revealAfterOperation, forKey: Key.revealAfterOperation) } }
    var overwriteMode: OverwriteMode { didSet { defaults.set(overwriteMode.rawValue, forKey: Key.overwriteMode) } }
    var defaultFormat: ArchiveFormat { didSet { defaults.set(defaultFormat.rawValue, forKey: Key.defaultFormat) } }
    var defaultLevel: CompressionLevel { didSet { defaults.set(defaultLevel.rawValue, forKey: Key.defaultLevel) } }
    var multithreaded: Bool { didSet { defaults.set(multithreaded, forKey: Key.multithreaded) } }
    var customEnginePath: String? { didSet { defaults.set(customEnginePath, forKey: Key.customEnginePath) } }
    var checkUpdatesAtLaunch: Bool { didSet { defaults.set(checkUpdatesAtLaunch, forKey: Key.checkUpdatesAtLaunch) } }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        strings = StringTable(bundle: bundle)
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .tr
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        extractLocation = ExtractLocation(rawValue: defaults.string(forKey: Key.extractLocation) ?? "") ?? .ask
        customExtractFolder = defaults.string(forKey: Key.customExtractFolder)
        extractIntoSubfolder = defaults.object(forKey: Key.extractIntoSubfolder) as? Bool ?? true
        revealAfterOperation = defaults.object(forKey: Key.revealAfterOperation) as? Bool ?? true
        overwriteMode = OverwriteMode(rawValue: defaults.string(forKey: Key.overwriteMode) ?? "") ?? .rename
        defaultFormat = ArchiveFormat(rawValue: defaults.string(forKey: Key.defaultFormat) ?? "") ?? .sevenZip
        defaultLevel = CompressionLevel(rawValue: defaults.object(forKey: Key.defaultLevel) as? Int ?? -1) ?? .normal
        multithreaded = defaults.object(forKey: Key.multithreaded) as? Bool ?? true
        customEnginePath = defaults.string(forKey: Key.customEnginePath)
        checkUpdatesAtLaunch = defaults.object(forKey: Key.checkUpdatesAtLaunch) as? Bool ?? true
    }

    func resetAll() {
        Key.all.forEach(defaults.removeObject(forKey:))
        defaults.removeObject(forKey: "AppleLanguages")
        language = .tr
        appearance = .system
        extractLocation = .ask
        customExtractFolder = nil
        extractIntoSubfolder = true
        revealAfterOperation = true
        overwriteMode = .rename
        defaultFormat = .sevenZip
        defaultLevel = .normal
        multithreaded = true
        customEnginePath = nil
        checkUpdatesAtLaunch = true
    }

    /// Tüm pencerelere (Ayarlar ve Hakkında dahil) seçilen görünümü uygular.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// AppKit'in sistem menüleri bir sonraki açılışta seçilen dili kullansın.
    private func applySystemLanguage() {
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    // MARK: - Yerelleştirme ve biçimlendirme

    var languageCode: String { language.resolvedCode() }
    var locale: Locale { Locale(identifier: languageCode) }

    func t(_ key: LKey) -> String {
        strings.string(key, language: languageCode)
    }

    func t(_ key: LKey, _ arguments: any CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: arguments)
    }

    func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    func date(_ value: Date?) -> String {
        guard let value else { return "" }
        return value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    }
}
