import Foundation
import Testing
@testable import ArhivarCore

private let shell = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

@Test func runnerCapturesOutputAndExitCode() async throws {
    let result = try await shell.run(["-c", "echo merhaba; echo hata >&2; exit 3"])
    #expect(result.exitCode == 3)
    #expect(result.stdout == "merhaba\n")
    #expect(result.stderr == "hata\n")
}

@Test func runnerReportsProgress() async throws {
    let collected = Collected()
    _ = try await shell.run(["-c", "printf ' 10%%'; sleep 0.1; printf '\\b\\b\\b\\b 55%%'"]) { collected.add($0) }
    #expect(collected.values.last == 0.55)
}

@Test func runnerTimesOut() async {
    await #expect(throws: SevenZipError.timedOut) {
        _ = try await shell.run(["-c", "sleep 5"], timeout: 0.3)
    }
}

@Test func runnerCancels() async {
    let task = Task { try await shell.run(["-c", "sleep 5"]) }
    try? await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: SevenZipError.cancelled) {
        _ = try await task.value
    }
}

@Test func runnerReportsMissingExecutable() async {
    await #expect(throws: SevenZipError.engineNotFound) {
        _ = try await CommandRunner(executableURL: URL(fileURLWithPath: "/nonexistent/7zz")).run([])
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func add(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}

// MARK: - Yerelleştirme

private let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources")

private func table(_ code: String) throws -> [String: String] {
    try #require(StringTable.load(contentsOf: resources.appendingPathComponent("\(code).lproj/Localizable.strings")))
}

/// "%@", "%ld", "%1$@" gibi biçim belirteçleri.
private func specifiers(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|ld|d)")
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
}

@Test(arguments: AppLanguage.supportedCodes)
func everyKeyIsTranslated(code: String) throws {
    let strings = try table(code)
    let expected = Set(LKey.allCases.map(\.rawValue))
    let actual = Set(strings.keys)
    #expect(expected.subtracting(actual).sorted() == [], "\(code) dilinde eksik anahtarlar")
    #expect(actual.subtracting(expected).sorted() == [], "\(code) dilinde fazla anahtarlar")
    #expect(strings.values.allSatisfy { !$0.isEmpty })
}

@Test(arguments: ["tr", "ro"])
func formatSpecifiersMatchEnglish(code: String) throws {
    let english = try table("en")
    let other = try table(code)
    for key in LKey.allCases {
        let reference = specifiers(english[key.rawValue] ?? "")
        let translated = specifiers(other[key.rawValue] ?? "")
        #expect(reference == translated, "\(code): \(key.rawValue)")
    }
}

@Test func resolvesSystemLanguage() {
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["ro-RO", "en-US"]) == "ro")
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["de-DE", "tr-TR"]) == "tr")
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["de-DE"]) == "en")
    #expect(AppLanguage.tr.resolvedCode(preferredLanguages: ["en-US"]) == "tr")
}

@Test func eachSupportedLanguageHasDedicatedFile() throws {
    for code in AppLanguage.supportedCodes {
        let fileURL = resources.appendingPathComponent("\(code).lproj/Localizable.strings")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) && !isDir.boolValue, "Her dil kendi bağımsız Localizable.strings dosyasına sahip olmalıdır: \(code)")
        let data = try Data(contentsOf: fileURL)
        #expect(!data.isEmpty, "\(code).lproj/Localizable.strings dosyası boş olamaz")
    }
}

@Test func stringTableFallsBackToEnglish() {
    let strings = StringTable(tables: ["en": ["appName": "Arhivar", "yes": "Yes"], "tr": ["yes": "Evet"]])
    #expect(strings.string(.yes, language: "tr") == "Evet")
    #expect(strings.string(.appName, language: "tr") == "Arhivar")
    #expect(strings.string(.no, language: "tr") == "no")
}

/// Info.plist'teki Finder'a görünen metinler (ad, belge türü adları, tür açıklamaları) her dilin
/// InfoPlist.strings dosyasında birebir bulunmalıdır: uygulama (Resources) ve Hızlı Bakış eklentisi (Support/QuickLook).
@Test(arguments: [("Support/Info.plist", "Resources"), ("Support/QuickLook-Info.plist", "Support/QuickLook")])
func infoPlistStringsCoverEveryVisibleName(plistPath: String, stringsRoot: String) throws {
    let packageRoot = resources.deletingLastPathComponent()
    let data = try Data(contentsOf: packageRoot.appendingPathComponent(plistPath))
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    var expected: Set<String> = ["CFBundleDisplayName", "CFBundleName"]
    for type in plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
        if let name = type["CFBundleTypeName"] as? String { expected.insert(name) }
    }
    for type in plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [] {
        if let description = type["UTTypeDescription"] as? String { expected.insert(description) }
    }
    #expect(Set(plist["CFBundleLocalizations"] as? [String] ?? []) == Set(AppLanguage.supportedCodes))

    var keySets: [String: Set<String>] = [:]
    for code in AppLanguage.supportedCodes {
        let url = packageRoot.appendingPathComponent("\(stringsRoot)/\(code).lproj/InfoPlist.strings")
        let table = try #require(StringTable.load(contentsOf: url), "\(code): \(url.path)")
        #expect(expected.subtracting(table.keys).sorted() == [], "\(code) InfoPlist.strings eksik: \(stringsRoot)")
        #expect(table.values.allSatisfy { !$0.isEmpty })
        keySets[code] = Set(table.keys)
    }
    #expect(Set(keySets.values).count == 1, "InfoPlist.strings anahtarları diller arasında birebir aynı olmalı: \(stringsRoot)")
}

/// Hızlı Bakış hata ekranı ham İngilizce iletiyi değil, seçili dildeki açıklamayı gösterir.
@Test(arguments: AppLanguage.supportedCodes)
func previewErrorMessagesAreLocalized(code: String) throws {
    let strings = StringTable(tables: Dictionary([(code, try table(code)), ("en", try table("en"))]) { first, _ in first })
    let localized = try table(code)
    let notArchive = try #require(localized["errorNotArchive"])

    #expect(strings.previewErrorMessage(for: LibArchiveReader.ReadError.unreadable("Unrecognized archive format"), language: code) == notArchive)
    #expect(strings.previewErrorMessage(for: SevenZipError.notArchive, language: code) == notArchive)
    #expect(strings.previewErrorMessage(for: CocoaError(.fileNoSuchFile), language: code) == notArchive)
    #expect(strings.previewErrorMessage(for: SevenZipError.timedOut, language: code) == localized["errorEngineTimeout"])
    #expect(strings.previewErrorMessage(for: SevenZipError.cancelled, language: code) == localized["errorCancelled"])
    #expect(strings.previewErrorMessage(for: SevenZipError.engineNotFound, language: code) == localized["errorEngineNotFound"])

    let failed = strings.previewErrorMessage(for: SevenZipError.failed(code: 2, message: "Headers Error"), language: code)
    #expect(failed.contains("2"))
    #expect(!failed.contains("%ld"))
    #expect(!failed.contains("Headers Error"))
}

/// Parola hatası yalnızca 7zz'nin iletisinden anlaşılır; adında "wrong password" geçen dosya ya da arşivin başka bir
/// hatası (CRC, bozuk arşiv) parola hatası sayılmaz, yoksa yanlışlıkla parola sorulur ve gerçek hata gizlenirdi.
@Test(arguments: [
    ("ERROR: Wrong password : a.txt", true),
    ("ERROR: Wrong password : wrong password.txt", true),
    ("ERROR: Data Error in encrypted file. Wrong password? : b.txt", true),
    ("ERROR: t.7z : Cannot open encrypted archive. Wrong password?", true),
    ("ERROR: Cannot open encrypted archive. Wrong password?", true),
    ("Cannot open encrypted archive. Wrong password?", true),
    ("ERROR: CRC Failed : wrong password.txt", false),
    ("ERROR: Data Error : wrong password.txt", false),
    ("ERROR: wrong password.7z : Cannot open the file as archive", false),
    ("ERROR: wrong password.7z : Unexpected end of archive", false),
    ("Path = wrong password.txt", false),
    ("Wrong password list.txt", false),
])
func wrongPasswordIsDetectedOnlyFromTheMessage(line: String, expected: Bool) {
    #expect(SevenZipError.reportsWrongPassword(line) == expected, "\(line)")
}

@Test func crcErrorOnFileNamedWrongPasswordIsNotAPasswordError() {
    let result = ProcessResult(exitCode: 2, stdout: "", stderr: "ERROR: CRC Failed : wrong password.txt\n\nSub items Errors: 1\n")
    #expect(!SevenZipError.needsPassword(result))
    #expect(throws: SevenZipError.self) { try SevenZipError.check(result) }
    #expect((try? SevenZipError.check(result)) == nil)
    do { try SevenZipError.check(result) } catch let error as SevenZipError {
        #expect(error != .wrongPassword)
    } catch { Issue.record("beklenmeyen hata \(error)") }
}
