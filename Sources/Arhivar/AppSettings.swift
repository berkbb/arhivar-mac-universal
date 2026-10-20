import AppKit
import ArhivarCore
import Foundation
import Observation
import SwiftUI

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

/// Hızlı Bakış kısayol tetikleyicisi tercihi.
enum QuickLookShortcut: String, CaseIterable, Identifiable {
    case spaceAndCmdY
    case spaceOnly
    case cmdYOnly

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .spaceAndCmdY: .shortcutQuickLookBoth
        case .spaceOnly: .shortcutQuickLookSpaceOnly
        case .cmdYOnly: .shortcutQuickLookCmdYOnly
        }
    }

    var allowsSpace: Bool {
        self == .spaceAndCmdY || self == .spaceOnly
    }

    var allowsCmdY: Bool {
        self == .spaceAndCmdY || self == .cmdYOnly
    }

    var displayBadge: String {
        switch self {
        case .spaceAndCmdY: "Space / ⌘Y"
        case .spaceOnly: "Space"
        case .cmdYOnly: "⌘Y"
        }
    }
}

/// Klavye kısayolu verisi (UserDefaults için Codable ve Sendable).
struct KeyboardShortcutData: Codable, Equatable, Sendable {
    var key: String
    var isSpecialKey: Bool
    var specialKeyCode: UInt16?
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(
        key: String,
        isSpecialKey: Bool = false,
        specialKeyCode: UInt16? = nil,
        command: Bool = true,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.key = key
        self.isSpecialKey = isSpecialKey
        self.specialKeyCode = specialKeyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var keyEquivalent: KeyEquivalent {
        if isSpecialKey, let code = specialKeyCode {
            switch code {
            case 126: return .upArrow
            case 125: return .downArrow
            case 123: return .leftArrow
            case 124: return .rightArrow
            case 36: return .return
            case 48: return .tab
            case 49: return .space
            case 51: return .delete
            default:
                if let char = key.lowercased().first {
                    return KeyEquivalent(char)
                }
                return .return
            }
        }
        guard let char = key.lowercased().first else { return KeyEquivalent("?") }
        return KeyEquivalent(char)
    }

    var eventModifiers: EventModifiers {
        var mods: EventModifiers = []
        if command { mods.insert(.command) }
        if shift { mods.insert(.shift) }
        if option { mods.insert(.option) }
        if control { mods.insert(.control) }
        return mods
    }

    var displayString: String {
        var str = ""
        if control { str += "⌃" }
        if option { str += "⌥" }
        if shift { str += "⇧" }
        if command { str += "⌘" }
        str += key.uppercased()
        return str
    }
}

/// Kullanıcı tarafından özelleştirilebilen eylemler.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newArchive
    case openArchive
    case extract
    case extractSelected
    case test
    case open
    case parent
    case info

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .newArchive: .shortcutActionNewArchive
        case .openArchive: .shortcutActionOpenArchive
        case .extract: .shortcutActionExtract
        case .extractSelected: .shortcutActionExtractSelected
        case .test: .shortcutActionTest
        case .open: .shortcutActionOpen
        case .parent: .shortcutActionParent
        case .info: .shortcutActionInfo
        }
    }

    var defaultShortcut: KeyboardShortcutData {
        switch self {
        case .newArchive:
            return KeyboardShortcutData(key: "N", command: true)
        case .openArchive:
            return KeyboardShortcutData(key: "O", command: true)
        case .extract:
            return KeyboardShortcutData(key: "E", command: true)
        case .extractSelected:
            return KeyboardShortcutData(key: "E", command: true, shift: true)
        case .test:
            return KeyboardShortcutData(key: "T", command: true)
        case .open:
            return KeyboardShortcutData(key: "↓", isSpecialKey: true, specialKeyCode: 125, command: true)
        case .parent:
            return KeyboardShortcutData(key: "↑", isSpecialKey: true, specialKeyCode: 126, command: true)
        case .info:
            return KeyboardShortcutData(key: "I", command: true)
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
        /// Eski (1.0.x) anahtar: Bool. `subfolderMode` yoksa geçiş için okunur.
        static let extractIntoSubfolder = "extractIntoSubfolder"
        static let subfolderMode = "subfolderMode"
        static let excludeMacMetadata = "excludeMacMetadata"
        static let storeSymlinks = "storeSymlinks"
        static let revealAfterOperation = "revealAfterOperation"
        static let overwriteMode = "overwriteMode"
        static let defaultFormat = "defaultFormat"
        static let defaultLevel = "defaultLevel"
        static let multithreaded = "multithreaded"
        static let customEnginePath = "customEnginePath"
        static let checkUpdatesAtLaunch = "checkUpdatesAtLaunch"
        static let updateConsentAsked = "updateConsentAsked"
        static let sandboxEngine = "sandboxEngine"
        /// AppModel'in kaydettiği görünüm tercihi; tümünü sıfırlarken o da silinir.
        static let browserMode = "browserMode"
        static let quickLookShortcut = "quickLookShortcut"
        static let customShortcuts = "customShortcuts"
        static let all = [
            language, appearance, extractLocation, customExtractFolder, extractIntoSubfolder, subfolderMode, revealAfterOperation,
            overwriteMode, defaultFormat, defaultLevel, multithreaded, excludeMacMetadata, storeSymlinks,
            customEnginePath, checkUpdatesAtLaunch, updateConsentAsked, sandboxEngine, browserMode, quickLookShortcut,
            customShortcuts,
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
    /// Çıkarırken arşiv adıyla klasör oluşturma kuralı (varsayılan: akıllı).
    var subfolderMode: SubfolderMode { didSet { defaults.set(subfolderMode.rawValue, forKey: Key.subfolderMode) } }
    var revealAfterOperation: Bool { didSet { defaults.set(revealAfterOperation, forKey: Key.revealAfterOperation) } }
    var overwriteMode: OverwriteMode { didSet { defaults.set(overwriteMode.rawValue, forKey: Key.overwriteMode) } }
    var defaultFormat: ArchiveFormat { didSet { defaults.set(defaultFormat.rawValue, forKey: Key.defaultFormat) } }
    var defaultLevel: CompressionLevel { didSet { defaults.set(defaultLevel.rawValue, forKey: Key.defaultLevel) } }
    var multithreaded: Bool { didSet { defaults.set(multithreaded, forKey: Key.multithreaded) } }
    /// Yeni arşivlerde ve eklemelerde .DS_Store, ._* ve __MACOSX dosyalarını dışarıda bırak.
    var excludeMacMetadata: Bool { didSet { defaults.set(excludeMacMetadata, forKey: Key.excludeMacMetadata) } }
    /// Sembolik bağlantıları bağlantı olarak sakla (-snl); varsayılan açık.
    var storeSymlinks: Bool { didSet { defaults.set(storeSymlinks, forKey: Key.storeSymlinks) } }
    var customEnginePath: String? { didSet { defaults.set(customEnginePath, forKey: Key.customEnginePath) } }
    /// Açılışta GitHub'a bağlanmak kullanıcının iznine bağlıdır; varsayılan kapalıdır.
    var checkUpdatesAtLaunch: Bool { didSet { defaults.set(checkUpdatesAtLaunch, forKey: Key.checkUpdatesAtLaunch) } }
    /// İlk açılışta izin bir kez sorulur.
    var updateConsentAsked: Bool { didSet { defaults.set(updateConsentAsked, forKey: Key.updateConsentAsked) } }
    /// 7zz'yi kum havuzunda (sandbox-exec) çalıştır; varsayılan açık.
    var sandboxEngine: Bool { didSet { defaults.set(sandboxEngine, forKey: Key.sandboxEngine) } }
    /// Hızlı Bakış kısayol tercihi (Boşluk ve ⌘Y, Yalnızca Boşluk, Yalnızca ⌘Y).
    var quickLookShortcut: QuickLookShortcut { didSet { defaults.set(quickLookShortcut.rawValue, forKey: Key.quickLookShortcut) } }
    /// Kullanıcının özelleştirdiği kısayollar; varsayılandan farklı olanlar saklanır.
    var customShortcuts: [String: KeyboardShortcutData] {
        didSet {
            if let data = try? JSONEncoder().encode(customShortcuts) {
                defaults.set(data, forKey: Key.customShortcuts)
            }
        }
    }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        strings = StringTable(bundle: bundle)
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .tr
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        extractLocation = ExtractLocation(rawValue: defaults.string(forKey: Key.extractLocation) ?? "") ?? .ask
        customExtractFolder = defaults.string(forKey: Key.customExtractFolder)
        subfolderMode = Self.loadSubfolderMode(from: defaults)
        revealAfterOperation = defaults.object(forKey: Key.revealAfterOperation) as? Bool ?? true
        overwriteMode = OverwriteMode(rawValue: defaults.string(forKey: Key.overwriteMode) ?? "") ?? .rename
        defaultFormat = ArchiveFormat(rawValue: defaults.string(forKey: Key.defaultFormat) ?? "") ?? .sevenZip
        defaultLevel = CompressionLevel(rawValue: defaults.object(forKey: Key.defaultLevel) as? Int ?? -1) ?? .normal
        multithreaded = defaults.object(forKey: Key.multithreaded) as? Bool ?? true
        excludeMacMetadata = defaults.object(forKey: Key.excludeMacMetadata) as? Bool ?? false
        storeSymlinks = defaults.object(forKey: Key.storeSymlinks) as? Bool ?? true
        customEnginePath = defaults.string(forKey: Key.customEnginePath)
        checkUpdatesAtLaunch = defaults.object(forKey: Key.checkUpdatesAtLaunch) as? Bool ?? false
        updateConsentAsked = defaults.object(forKey: Key.updateConsentAsked) as? Bool ?? false
        sandboxEngine = defaults.object(forKey: Key.sandboxEngine) as? Bool ?? true
        quickLookShortcut = QuickLookShortcut(rawValue: defaults.string(forKey: Key.quickLookShortcut) ?? "") ?? .spaceAndCmdY
        if let data = defaults.data(forKey: Key.customShortcuts),
           let decoded = try? JSONDecoder().decode([String: KeyboardShortcutData].self, from: data) {
            customShortcuts = decoded
        } else {
            customShortcuts = [:]
        }
    }

    /// Eski "extractIntoSubfolder" (Bool) tercihini yeni kurala çevirir: kapalı → hiçbir zaman, açık ya da yok → akıllı.
    static func loadSubfolderMode(from defaults: UserDefaults) -> SubfolderMode {
        if let mode = defaults.string(forKey: Key.subfolderMode).flatMap(SubfolderMode.init(rawValue:)) { return mode }
        return defaults.object(forKey: Key.extractIntoSubfolder) as? Bool == false ? .never : .smart
    }

    func resetAll() {
        language = .tr
        appearance = .system
        extractLocation = .ask
        customExtractFolder = nil
        subfolderMode = .smart
        revealAfterOperation = true
        overwriteMode = .rename
        defaultFormat = .sevenZip
        defaultLevel = .normal
        multithreaded = true
        excludeMacMetadata = false
        storeSymlinks = true
        customEnginePath = nil
        checkUpdatesAtLaunch = false
        updateConsentAsked = false
        sandboxEngine = true
        quickLookShortcut = .spaceAndCmdY
        customShortcuts = [:]
        // Özellik gözlemcileri değerleri yeniden yazdı; ilk kurulumdaki gibi hiçbir tercih kalmasın.
        // "AppleLanguages" en sonda silinir: dil atanırken yeniden yazılıyordu.
        Key.all.forEach(defaults.removeObject(forKey:))
        defaults.removeObject(forKey: "AppleLanguages")
    }

    // MARK: - Kısayol yönetimi

    func shortcut(for action: ShortcutAction) -> KeyboardShortcutData {
        customShortcuts[action.rawValue] ?? action.defaultShortcut
    }

    func setShortcut(_ shortcut: KeyboardShortcutData, for action: ShortcutAction) {
        if shortcut == action.defaultShortcut {
            customShortcuts.removeValue(forKey: action.rawValue)
        } else {
            customShortcuts[action.rawValue] = shortcut
        }
    }

    func resetShortcut(for action: ShortcutAction) {
        customShortcuts.removeValue(forKey: action.rawValue)
    }

    func resetAllShortcuts() {
        quickLookShortcut = .spaceAndCmdY
        customShortcuts = [:]
    }

    var isAllShortcutsDefault: Bool {
        quickLookShortcut == .spaceAndCmdY &&
        ShortcutAction.allCases.allSatisfy { isDefaultShortcut(for: $0) }
    }

    func isDefaultShortcut(for action: ShortcutAction) -> Bool {
        customShortcuts[action.rawValue] == nil || customShortcuts[action.rawValue] == action.defaultShortcut
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
