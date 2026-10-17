import Foundation
import Testing
@testable import ArhivarCore

/// Gerçek 7zz ile uçtan uca senaryolar. Vendor/7-Zip/7zz yoksa atlanır (ARHIVAR_7ZZ ile başka yol verilebilir).
private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ProcessInfo.processInfo.environment["ARHIVAR_7ZZ"],
        packageRoot.appendingPathComponent("Vendor/7-Zip/7zz").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

@Suite(.enabled(if: engineURL != nil, "7zz bulunamadı"), .serialized)
struct EngineIntegrationTests {
    let runner = CommandRunner(executableURL: engineURL ?? URL(fileURLWithPath: "/usr/bin/false"))
    let workspace: URL

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArhivarTests-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("kaynak/alt", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "merhaba dünya\n".write(to: workspace.appendingPathComponent("kaynak/not.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "veri ", count: 2000).write(to: source.appendingPathComponent("çok-büyük.txt"), atomically: true, encoding: .utf8)
    }

    @Test func encryptedSevenZipRoundTrip() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("test.7z")
        let create = CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: archive,
            format: .sevenZip, level: .maximum, password: "Gizli-123", encryptFileNames: true
        )
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(create)))

        // Adlar şifreli olduğu için parolasız liste parola hatası vermeli.
        await #expect(throws: SevenZipError.wrongPassword) {
            try SevenZipError.check(try await runner.run(SevenZipCommand.list(archive: archive)))
        }
        await #expect(throws: SevenZipError.wrongPassword) {
            try SevenZipError.check(try await runner.run(SevenZipCommand.list(archive: archive, password: "yanlis")))
        }

        let result = try await runner.run(SevenZipCommand.list(archive: archive, password: "Gizli-123"))
        try SevenZipError.check(result)
        let listing = ListingParser.parse(result.stdout)
        #expect(listing.info.type == "7z")
        #expect(Set(listing.entries.map(\.path)) == ["kaynak", "kaynak/alt", "kaynak/not.txt", "kaynak/alt/çok-büyük.txt"])
        #expect(listing.entries.contains { $0.isEncrypted })

        try SevenZipError.check(try await runner.run(SevenZipCommand.test(archive: archive, password: "Gizli-123")))

        // Yalnızca seçili klasör çıkarılır.
        let output = workspace.appendingPathComponent("cikti", isDirectory: true)
        let progress = ProgressBox()
        let extract = ExtractOptions(archive: archive, destination: output, items: ["kaynak/alt"], password: "Gizli-123", overwrite: .replace)
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(extract)) { progress.last = $0 })
        let extracted = output.appendingPathComponent("kaynak/alt/çok-büyük.txt")
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("kaynak/not.txt").path))
    }

    @Test func zipCreateAndExtractAll() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("test.zip")
        let create = CreateOptions(sources: [workspace.appendingPathComponent("kaynak/not.txt")], destination: archive, format: .zip, level: .fast)
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(create)))

        let output = workspace.appendingPathComponent("zip-cikti", isDirectory: true)
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(
            ExtractOptions(archive: archive, destination: output, overwrite: .rename)
        )))
        let text = try String(contentsOf: output.appendingPathComponent("not.txt"), encoding: .utf8)
        #expect(text == "merhaba dünya\n")

        // İkinci çıkarma "ikisini de sakla" ile yeni adla yazmalı.
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(
            ExtractOptions(archive: archive, destination: output, overwrite: .rename)
        )))
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
        #expect(names.count == 2)
    }

    @Test func rejectsNonArchive() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let notArchive = workspace.appendingPathComponent("kaynak/not.txt")
        await #expect(throws: SevenZipError.notArchive) {
            try SevenZipError.check(try await runner.run(SevenZipCommand.list(archive: notArchive)))
        }
    }


    @Test func editsArchiveInPlace() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("duzenle.7z")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: archive, format: .sevenZip, level: .fast
        ))))

        // Alt klasöre ekleme.
        let extra = workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)
        let plan = try AddPlan.make(sources: [extra], into: "kaynak/alt", stagingRoot: workspace.appendingPathComponent("staging"))
        try SevenZipError.check(try await runner.run(
            SevenZipCommand.add(archive: archive, names: plan.names), workingDirectory: plan.workingDirectory
        ))
        var paths = try await listPaths(archive)
        #expect(paths.contains("kaynak/alt/ek.txt"))

        // Klasörü yeniden adlandırma alt öğeleri de taşır.
        try SevenZipError.check(try await runner.run(SevenZipCommand.rename(archive: archive, from: "kaynak/alt", to: "kaynak/yeni")))
        paths = try await listPaths(archive)
        #expect(paths.contains("kaynak/yeni/ek.txt"))
        #expect(!paths.contains { $0.hasPrefix("kaynak/alt") })

        // Silme.
        try SevenZipError.check(try await runner.run(SevenZipCommand.delete(archive: archive, items: ["kaynak/yeni"])))
        paths = try await listPaths(archive)
        #expect(paths == ["kaynak", "kaynak/not.txt"])

        // Tek öğeyi geçici klasöre çıkarma (Hızlı Bakış / sürükleme).
        let extracted = try await ItemExtractor(runner: runner, archive: archive, password: nil)
            .extract("kaynak/not.txt", into: workspace.appendingPathComponent("gecici"))
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "merhaba dünya\n")
    }

    private func listPaths(_ archive: URL) async throws -> [String] {
        let result = try await runner.run(SevenZipCommand.list(archive: archive))
        try SevenZipError.check(result)
        return ListingParser.parse(result.stdout).entries.map(\.path).sorted()
    }


    @Test func tarXzListsAndExtractsInnerTar() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", workspace.appendingPathComponent("yedek.tar.xz").path, "-C", workspace.path, "kaynak"]
        try tar.run()
        tar.waitUntilExit()
        let archive = workspace.appendingPathComponent("yedek.tar.xz")

        let result = try await runner.run(SevenZipCommand.list(archive: archive))
        try SevenZipError.check(result)
        let listing = ListingParser.parse(result.stdout, fallbackName: ArchiveNaming.streamItemName(for: archive))
        #expect(listing.entries.map(\.path) == ["yedek.tar"])

        let extracted = try await ItemExtractor(runner: runner, archive: archive, password: nil)
            .extract("yedek.tar", into: workspace.appendingPathComponent("gecici"))
        #expect(FileManager.default.fileExists(atPath: extracted.path))
    }

    @Test func extractsIntoFolderWithStarInName() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("yildiz.zip")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak/not.txt")], destination: archive, format: .zip, level: .fast
        ))))
        let destination = workspace.appendingPathComponent("İş*Yedek", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let options = ExtractOptions(archive: archive, destination: destination, overwrite: .replace)
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(options), workingDirectory: options.workingDirectory))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("not.txt").path))
    }

    @Test func readsEngineVersion() async throws {
        let result = try await runner.run([], timeout: 15)
        #expect(EngineLocator.parseVersion(result.stdout) != nil)
    }
}

private final class ProgressBox: @unchecked Sendable {
    var last: Double = 0
}
