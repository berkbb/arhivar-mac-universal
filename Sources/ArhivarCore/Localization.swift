import Foundation

/// Arayüz dilleri. `system`, macOS'un tercih ettiği dili izler.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case en
    case tr
    case ro

    public static let supportedCodes = ["en", "tr", "ro"]

    public var id: String { rawValue }

    public var nativeName: String? {
        switch self {
        case .system: nil
        case .en: "English"
        case .tr: "Türkçe"
        case .ro: "Română"
        }
    }

    public var flag: String {
        switch self {
        case .system: "🌐"
        case .en: "🇬🇧"
        case .tr: "🇹🇷"
        case .ro: "🇷🇴"
        }
    }

    public func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if self != .system { return rawValue }
        for identifier in preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier ?? String(identifier.prefix(2))
            if Self.supportedCodes.contains(code) { return code }
        }
        return "en"
    }
}

/// Her dil için Localizable.strings tablolarını tutar; uygulama içinde anında dil değişimine izin verir.
public struct StringTable: Sendable {
    public let tables: [String: [String: String]]

    public init(tables: [String: [String: String]]) {
        self.tables = tables
    }

    public init(bundle: Bundle) {
        var loaded: [String: [String: String]] = [:]
        for code in AppLanguage.supportedCodes {
            if let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code),
               let table = Self.load(contentsOf: url) {
                loaded[code] = table
            }
        }
        self.init(tables: loaded)
    }

    public static func load(contentsOf url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
    }

    /// Eksik çeviride İngilizceye, o da yoksa anahtarın kendisine düşer.
    public func string(_ key: LKey, language code: String) -> String {
        tables[code]?[key.rawValue] ?? tables["en"]?[key.rawValue] ?? key.rawValue
    }
}

/// Tüm arayüz metinlerinin anahtarları. Her anahtar en/tr/ro tablolarında bulunmalıdır (testlerle denetlenir).
public enum LKey: String, CaseIterable, Sendable {
    case appName, appTagline
    case menuAbout, menuNewArchive, menuOpenArchive, menuCloseArchive, menuArchive
    case menuExtractAll, menuExtractSelected, menuTestArchive, menuShowInFinder, menuClearRecents
    case menuManual, menuWebsite, menuCheckUpdates
    case toolbarOpen, toolbarCreate, toolbarExtract, toolbarTest, toolbarInfo
    case searchPrompt
    case sidebarLibrary, sidebarHome, sidebarRecent, sidebarNoRecents, sidebarRemoveRecent
    case welcomeTitle, welcomeSubtitle, welcomeDropHint, welcomeSupportedFormats
    case engineReady, engineChecking, engineMissingTitle, engineMissingMessage, engineBlockedTitle, engineBlockedMessage
    case columnName, columnSize, columnPacked, columnModified, columnMethod
    case contextOpen, contextExtract
    case emptyArchive, noSearchResults
    case statusItems, statusSize, statusPacked, statusRatio, statusSelected, statusEncrypted
    case infoTitle, infoLocation, infoType, infoMethod, infoSolid, infoArchiveSize, infoFiles, infoFolders
    case infoUnpackedSize, infoRatio, infoEncrypted, yes, no
    case createTitle, createSources, createAddFiles, createRemove, createDropHint, createOutput
    case createArchiveName, createDestination, createOptions, createFormat, createLevel
    case createEncryption, createPassword, createPasswordConfirm, createEncryptNames
    case createPasswordMismatch, createEncryptionUnsupported, createSplit, createSplitNone
    case createSingleFileOnly, createExistsWarning, createButton
    case levelStore, levelFastest, levelFast, levelNormal, levelMaximum, levelUltra
    case buttonCancel, buttonOK, buttonChoose, buttonShowInFinder, buttonOpenSettings, buttonUnlock
    case panelOpenArchive, panelChooseDestination, panelExtract, panelAdd
    case progressReading, progressCreating, progressExtracting, progressTesting, progressPreparing
    case toastExtracted, toastCreated, toastTestPassed
    case passwordTitle, passwordMessage, passwordWrong
    case errorTitle, warningTitle, errorEngineNotFound, errorEngineTimeout, errorCancelled
    case errorWrongPassword, errorNotArchive, errorFailed
    case settingsGeneral, settingsCompression, settingsAdvanced, settingsLanguage, settingsLanguageNote, languageSystem
    case settingsAppearance, appearanceSystem, appearanceLight, appearanceDark
    case settingsExtraction, settingsExtractTo, extractToAsk, extractToNextTo, extractToCustom, settingsCustomFolder
    case settingsSubfolder, settingsReveal, settingsOverwrite, overwriteReplace, overwriteSkip, overwriteRename
    case settingsDefaults, settingsDefaultFormat, settingsDefaultLevel, settingsMultithread
    case settingsEngine, settingsEnginePath, settingsEngineVersion, settingsEngineCheck, settingsEngineNotFound
    case settingsEngineUseCustom, settingsReset, settingsResetConfirm
    case updateSection, updateCheck, updateInstall, updateChecking, updateInstalling, updateAvailable
    case updateUpToDate, updateInstalled, updateFailed, updateAutoCheck, updateSource
    case aboutVersion, aboutPoweredBy, aboutEngineCredit, aboutLicense, aboutAppLicense, aboutNotices, aboutCopyright
    case viewFolders, viewTree, viewModeLabel, navUp, contextQuickLook
    case toolbarAdd, editAddFiles, editDelete, editRename, buttonAdd, buttonDelete, buttonRename
    case deleteConfirmTitle, deleteConfirmMessage, renameTitle, renameField, addConfirmTitle
    case progressUpdating, toastUpdated, readOnlyArchive, readOnlyLocation
    case openRiskyTitle, openRiskyMessage, openAnyway, deceptiveNameReason, deceptiveNameHelp
    case appUpdateSection, appUpdateAvailable, appUpdateUpToDate, appUpdateDownload, appUpdateNoReleases, menuCheckAppUpdates
    case consentTitle, consentMessage, consentAllow, consentDeny, aboutRepository
    case errorDiskSpace
    case settingsSandbox, settingsSandboxNote
    case subfolderSmart, subfolderAlways, subfolderNever, excludeMacMetadata, settingsStoreSymlinks, settingsStoreSymlinksNote
    case duplicateNames, createPasswordConfirmHint, warningRemovedLinks, renameExists, symbolicLinkItem, nothingToArchive
    case editCut, editPaste, editPasteMatchStyle, editSelectAll
    case licenseAppSubtitle, licenseNoticesSubtitle, licenseReadOnly, licensePublisher, licenseLabel
    case licenseCopyText, licenseCopied, buttonClose
    case contextCopy, toastCopied, contextBrowse, navParentArchive, progressCopying
    case contextChecksums, checksumsTitle, buttonCopy, infoComment, infoBlocks, infoVolumes, progressChecksums
    case unknown
}
