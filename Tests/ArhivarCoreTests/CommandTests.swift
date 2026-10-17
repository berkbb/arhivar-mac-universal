import Foundation
import Testing
@testable import ArhivarCore

private let archive = URL(fileURLWithPath: "/tmp/ornek.7z")
private let destination = URL(fileURLWithPath: "/tmp/cikti")

@Test func extractAllArguments() {
    let args = SevenZipCommand.extract(ExtractOptions(archive: archive, destination: destination, overwrite: .rename))
    #expect(args == ["x", "-o/tmp/cikti", "-aou", "-bsp1", "-bb0", "-y", "-sccUTF-8", "--", "/tmp/ornek.7z"])
}

@Test func extractSelectedItemsDisablesWildcards() {
    let args = SevenZipCommand.extract(ExtractOptions(
        archive: archive, destination: destination, items: ["a*b.txt", "-klasor"], password: "gizli", overwrite: .replace
    ))
    #expect(args.contains("-spd"))
    // Parola komut satırında görünmemeli (ps ile okunabilirdi); stdin'den verilir.
    #expect(!args.contains { $0.contains("gizli") || $0.hasPrefix("-p") })
    #expect(args.contains("-aoa"))
    // Dosya adları "--" ayıracından sonra gelmeli; "-" ile başlayan ad anahtar sanılmasın.
    let separator = try! #require(args.firstIndex(of: "--"))
    #expect(Array(args[(separator + 1)...]) == ["/tmp/ornek.7z", "a*b.txt", "-klasor"])
}

@Test func createSevenZipWithEncryptedHeaders() {
    let options = CreateOptions(
        sources: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b.txt")],
        destination: archive, format: .sevenZip, level: .ultra,
        password: "p", encryptFileNames: true, volumeSizeMB: 100, multithreaded: false
    )
    let args = SevenZipCommand.create(options)
    #expect(args.starts(with: ["a", "-t7z"]))
    #expect(args.contains("-mx=9"))
    #expect(args.contains("-mmt=1"))
    #expect(args.contains("-p"))
    #expect(!args.contains("-pp"))
    #expect(args.contains("-mhe=on"))
    #expect(args.contains("-v100m"))
    #expect(!args.contains("-mem=AES256"))
    #expect(args.suffix(4) == ["--", "/tmp/ornek.7z", "/tmp/a", "/tmp/b.txt"])
}

@Test func createZipUsesAES() {
    let options = CreateOptions(sources: [URL(fileURLWithPath: "/tmp/a")], destination: archive, format: .zip, level: .normal, password: "p", encryptFileNames: true)
    let args = SevenZipCommand.create(options)
    #expect(args.contains("-mem=AES256"))
    #expect(!args.contains("-mhe=on"))
}

@Test func createTarIgnoresUnsupportedOptions() {
    let options = CreateOptions(sources: [URL(fileURLWithPath: "/tmp/a")], destination: archive, format: .tar, level: .ultra, password: "p")
    let args = SevenZipCommand.create(options)
    #expect(!args.contains { $0.hasPrefix("-mx") })
    #expect(!args.contains { $0.hasPrefix("-p") })
    #expect(!args.contains { $0.hasPrefix("-mmt") })
}

@Test func listAndTestArguments() {
    #expect(SevenZipCommand.list(archive: archive) == ["l", "-slt", "-bd", "-sccUTF-8", "--", "/tmp/ornek.7z"])
    #expect(!SevenZipCommand.test(archive: archive).contains { $0.hasPrefix("-p") })
}

@Test func classifiesResults() throws {
    #expect(try SevenZipError.check(ProcessResult(exitCode: 0, stdout: "Everything is Ok", stderr: "")) == nil)
    #expect(throws: SevenZipError.wrongPassword) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: "", stderr: "ERROR: Wrong password : a.txt"))
    }
    #expect(throws: SevenZipError.notArchive) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: "", stderr: "ERROR: x.txt\nCan not open the file as archive"))
    }
    let warning = try SevenZipError.check(ProcessResult(exitCode: 1, stdout: "WARNING: Cannot find 1 file", stderr: ""))
    #expect(warning?.contains("WARNING") == true)
    #expect(throws: SevenZipError.self) {
        try SevenZipError.check(ProcessResult(exitCode: 8, stdout: "", stderr: "ERROR: Can't allocate required memory!"))
    }
}

@Test func parsesProgressPercentages() {
    #expect(ProgressParser.lastPercentage(in: "  5% 3 + a\u{8}\u{8}\u{8} 42% 7 + b") == 42)
    #expect(ProgressParser.lastPercentage(in: "100%") == 100)
    #expect(ProgressParser.lastPercentage(in: "no progress") == nil)
    #expect(ProgressParser.lastPercentage(in: "1234%") == nil)
}

@Test func parsesEngineVersion() {
    #expect(EngineLocator.parseVersion("\n7-Zip (z) 26.04 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-10-05\n") == "26.04")
    #expect(EngineLocator.parseVersion("p7zip Version 16.02\n7-Zip [64] 16.02 : Copyright") == "16.02")
    #expect(EngineLocator.parseVersion("hello") == nil)
}

@Test func enginePrefersCustomThenManagedPath() {
    let managed = URL(fileURLWithPath: "/tmp/managed", isDirectory: true)
    let candidates = EngineLocator.candidates(customPath: "/opt/custom/7zz", managedDirectory: managed)
    #expect(candidates.first?.path == "/opt/custom/7zz")
    #expect(candidates[1].path == "/tmp/managed/7zz")
    #expect(candidates.suffix(2).map(\.path) == EngineLocator.homebrewPaths)
}

@Test func parsesUpdaterOutput() throws {
    let output = "LATEST=26.05\nCURRENT=26.04\nSOURCE=https://github.com/ip7z/7zip/releases/tag/26.05\nSTATUS=update-available\n"
    let result = try #require(EngineUpdateResult.parse(output))
    #expect(result.status == .updateAvailable)
    #expect(result.latestVersion == "26.05")
    #expect(result.currentVersion == "26.04")

    let none = try #require(EngineUpdateResult.parse("LATEST=26.04\nCURRENT=none\nSTATUS=update-available"))
    #expect(none.currentVersion == nil)
    #expect(EngineUpdateResult.parse("garbage") == nil)
}

@Test func comparesVersions() {
    #expect(EngineUpdater.isNewer("26.10", than: "26.04"))
    #expect(EngineUpdater.isNewer("27.00", than: "26.99"))
    #expect(!EngineUpdater.isNewer("26.04", than: "26.04"))
    #expect(!EngineUpdater.isNewer("25.01", than: "26.04"))
    #expect(EngineUpdater.isNewer("26.04", than: nil))
}

@Test func archiveNaming() {
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/fotograflar.tar.gz")) == "fotograflar")
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/veri.7z.001")) == "veri")
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/rapor.v2.zip")) == "rapor.v2")
    #expect(ArchiveNaming.isArchive(URL(fileURLWithPath: "/x/a.RAR")))
    #expect(ArchiveNaming.isArchive(URL(fileURLWithPath: "/x/a.7z.002")))
    #expect(!ArchiveNaming.isArchive(URL(fileURLWithPath: "/x/a.txt")))

    let folder = URL(fileURLWithPath: "/x/Proje")
    let file = URL(fileURLWithPath: "/x/Proje/notlar.txt")
    #expect(ArchiveNaming.suggestedName(for: [folder], isDirectory: { $0 == folder }) == "Proje")
    #expect(ArchiveNaming.suggestedName(for: [file], isDirectory: { _ in false }) == "notlar")
    #expect(ArchiveNaming.suggestedName(for: [file, URL(fileURLWithPath: "/x/Proje/b.txt")], isDirectory: { _ in false }) == "Proje")
    #expect(ArchiveNaming.suggestedName(for: [], isDirectory: { _ in false }) == "Archive")
}

@Test func passwordsGoToStandardInput() throws {
    let input = try #require(SevenZipCommand.passwordInput("Gizli Şifre"))
    #expect(String(decoding: input, as: UTF8.self) == String(repeating: "Gizli Şifre\n", count: 4))
    #expect(SevenZipCommand.passwordInput(nil) == nil)
    #expect(SevenZipCommand.passwordInput("") == nil)
    // Satır sonu içeren parola ilk satırla sınırlanır; ek satırlar sahte yanıt gibi okunamaz.
    #expect(String(decoding: try #require(SevenZipCommand.passwordInput("a\nb")), as: UTF8.self).hasPrefix("a\na\n"))
    let options = ExtractOptions(archive: archive, destination: destination, password: "x", overwrite: .replace)
    #expect(options.input == SevenZipCommand.passwordInput("x"))
    #expect(CreateOptions(sources: [], destination: archive, format: .tar, level: .normal, password: "x").input == nil)
}

@Test func passwordPromptIsNotAnError() throws {
    // Doğru parola stdin'den verildiğinde istem metni çıktıda kalır; başka bir hata parola hatası sayılmamalı.
    #expect(throws: SevenZipError.failed(code: 2, message: "ERROR: CRC Failed : a.txt")) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: "Enter password (will not be echoed):\nERROR: CRC Failed : a.txt", stderr: ""))
    }
    // Parola bilinmiyorsa stdin boştur; 7zz "Break signaled" ile durur.
    #expect(throws: SevenZipError.wrongPassword) {
        try SevenZipError.check(ProcessResult(exitCode: 255, stdout: "Enter password (will not be echoed):", stderr: "\n\nBreak signaled"))
    }
    #expect(throws: SevenZipError.wrongPassword) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: "ERROR: t.7z : Cannot open encrypted archive. Wrong password?", stderr: ""))
    }
}
