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
