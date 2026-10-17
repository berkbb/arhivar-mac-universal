import CryptoKit
import Foundation
import Testing
@testable import ArhivarCore

/// ROADMAP.md maddeleri için gerçek 7zz ile uçtan uca senaryolar. Vendor/7-Zip/7zz yoksa atlanır.
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
struct RoadmapIntegrationTests {
    let runner = CommandRunner(executableURL: engineURL ?? URL(fileURLWithPath: "/usr/bin/false"))
    let workspace: URL
    let fileManager = FileManager.default

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArhivarRoadmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("kaynak/alt"), withIntermediateDirectories: true)
        try "merhaba\n".write(to: workspace.appendingPathComponent("kaynak/not.txt"), atomically: true, encoding: .utf8)
        try "alt\n".write(to: workspace.appendingPathComponent("kaynak/alt/b.txt"), atomically: true, encoding: .utf8)
    }

    private func cleanUp() { try? fileManager.removeItem(at: workspace) }

    private func create(_ options: CreateOptions) async throws {
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(options), input: options.input))
    }

    private func list(_ archive: URL, password: String? = nil) async throws -> ArchiveListing {
        let result = try await runner.run(SevenZipCommand.list(archive: archive), input: SevenZipCommand.passwordInput(password))
        try SevenZipError.check(result)
        return ListingParser.parse(result.stdout, fallbackName: ArchiveNaming.streamItemName(for: archive))
    }

    /// P0-1: adları şifreli 7z parolasız listelenemez; adları açık olan listelenebilir.
    @Test func detectsEncryptedHeaders() async throws {
        defer { cleanUp() }
        let hidden = workspace.appendingPathComponent("gizli.7z")
        let open = workspace.appendingPathComponent("acik.7z")
        let source = [workspace.appendingPathComponent("kaynak")]
        try await create(CreateOptions(sources: source, destination: hidden, format: .sevenZip, level: .fast, password: "p", encryptFileNames: true))
        try await create(CreateOptions(sources: source, destination: open, format: .sevenZip, level: .fast, password: "p", encryptFileNames: false))
        #expect(SevenZipError.needsPassword(try await runner.run(SevenZipCommand.list(archive: hidden))))
        #expect(!SevenZipError.needsPassword(try await runner.run(SevenZipCommand.list(archive: open))))
    }

    /// P0-3: şifreli zip'e eklenen dosya da AES-256 ile şifrelenir.
    @Test func addToEncryptedZipUsesAES() async throws {
        defer { cleanUp() }
        let archive = workspace.appendingPathComponent("sifreli.zip")
        try await create(CreateOptions(sources: [workspace.appendingPathComponent("kaynak")], destination: archive, format: .zip, level: .fast, password: "p"))
        let extra = workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)
        let command = SevenZipCommand.add(archive: archive, names: ["ek.txt"], password: "p", archiveType: "zip")
        try SevenZipError.check(try await runner.run(command, workingDirectory: workspace, input: SevenZipCommand.passwordInput("p")))
        let added = try #require(try await list(archive, password: "p").entries.first { $0.path == "ek.txt" })
        #expect(added.isEncrypted)
        #expect(added.method?.contains("AES") == true)
        #expect(added.method?.contains("ZipCrypto") == false)
    }

    /// P0-5: .app/.framework bağlantıları bağlantı olarak saklanır ve geri çıkar.
    @Test func storesSymlinksAsLinks() async throws {
        defer { cleanUp() }
        let bundle = workspace.appendingPathComponent("Uygulama.app/Contents/Frameworks/F.framework", isDirectory: true)
        try fileManager.createDirectory(at: bundle.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: bundle.appendingPathComponent("Versions/A/F"))
        try fileManager.createSymbolicLink(atPath: bundle.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fileManager.createSymbolicLink(atPath: bundle.appendingPathComponent("F").path, withDestinationPath: "Versions/Current/F")
        // Kopuk göreli bağlantı oluşturmayı bozmamalı.
        try fileManager.createSymbolicLink(atPath: bundle.appendingPathComponent("Kopuk").path, withDestinationPath: "Versions/Yok")

        for format in [ArchiveFormat.sevenZip, .zip, .tar] {
            let archive = workspace.appendingPathComponent("uygulama.\(format.fileExtension)")
            try await create(CreateOptions(sources: [workspace.appendingPathComponent("Uygulama.app")], destination: archive, format: format, level: .fast))
            let output = workspace.appendingPathComponent("cikti-\(format.rawValue)", isDirectory: true)
            let options = ExtractOptions(archive: archive, destination: output, overwrite: .replace)
            try SevenZipError.check(try await runner.run(SevenZipCommand.extract(options)))
            let link = output.appendingPathComponent("Uygulama.app/Contents/Frameworks/F.framework/F").path
            #expect(try fileManager.destinationOfSymbolicLink(atPath: link) == "Versions/Current/F", "\(format)")
            // İçerik tek kez saklanır (bağlantı izlenip kopyalanmaz).
            let sizes = try await list(archive).entries.filter { !$0.isDirectory }.compactMap(\.size)
            #expect(sizes.filter { $0 == 4096 }.count == 1, "\(format)")
        }
    }

    /// P0-6: adında "*" geçen kaynak joker sayılmaz; benzer adlı başka klasör arşive girmez.
    @Test func wildcardSourceNamesAreLiteral() async throws {
        defer { cleanUp() }
        for name in ["İş*Yedek", "İşXYedek"] {
            let folder = workspace.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try name.write(to: folder.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
        let archive = workspace.appendingPathComponent("yildiz.7z")
        try await create(CreateOptions(sources: [workspace.appendingPathComponent("İş*Yedek")], destination: archive, format: .sevenZip, level: .fast))
        let paths = try await list(archive).entries.map(\.path)
        #expect(paths.contains("İş*Yedek/İş*Yedek.txt"))
        #expect(!paths.contains { $0.hasPrefix("İşXYedek") })
    }

    /// Özellik 2: .DS_Store, ._* ve __MACOSX arşive girmez.
    @Test func excludesMacMetadata() async throws {
        defer { cleanUp() }
        let source = workspace.appendingPathComponent("kaynak")
        try fileManager.createDirectory(at: source.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        for name in [".DS_Store", "._not.txt", "alt/._b.txt", "alt/.DS_Store", "__MACOSX/x"] {
            try Data("m".utf8).write(to: source.appendingPathComponent(name))
        }
        let archive = workspace.appendingPathComponent("temiz.zip")
        try await create(CreateOptions(sources: [source], destination: archive, format: .zip, level: .fast, excludeMacMetadata: true))
        let paths = Set(try await list(archive).entries.map(\.path))
        #expect(paths == ["kaynak", "kaynak/alt", "kaynak/not.txt", "kaynak/alt/b.txt"])
    }

    /// Özellik 4: tek adımda .tar.gz / .tar.xz; içteki tar arşivin adını taşır.
    @Test func createsCompressedTar() async throws {
        defer { cleanUp() }
        for format in [ArchiveFormat.tarGzip, .tarXz, .tarBzip2] {
            let destination = workspace.appendingPathComponent("yedek.\(format.fileExtension)")
            let stageDirectory = workspace.appendingPathComponent("stage-\(format.rawValue)", isDirectory: true)
            try fileManager.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
            let options = CreateOptions(sources: [workspace.appendingPathComponent("kaynak")], destination: destination, format: format, level: .normal)
            let stage = SevenZipCommand.tarStage(for: destination, in: stageDirectory)
            try SevenZipError.check(try await runner.run(SevenZipCommand.create(options, tarStage: stage)))
            try SevenZipError.check(try await runner.run(try #require(SevenZipCommand.compressTarStage(options, tarStage: stage))))

            #expect(try await list(destination).entries.map(\.path) == ["yedek.tar"], "\(format)")
            let output = workspace.appendingPathComponent("cikti-\(format.rawValue)", isDirectory: true)
            let inner = try await ItemExtractor(runner: runner, archive: destination, password: nil).extract("yedek.tar", into: output)
            #expect(Set(try await list(inner).entries.map(\.path)) == ["kaynak", "kaynak/alt", "kaynak/not.txt", "kaynak/alt/b.txt"])
        }
    }

    /// P1-8: "./" önekli tar'da öğe ham yoluyla çıkarılır.
    @Test func extractsDotPrefixedTarEntries() async throws {
        defer { cleanUp() }
        let archive = workspace.appendingPathComponent("nokta.tar")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--no-mac-metadata", "-cf", archive.path, "-C", workspace.appendingPathComponent("kaynak").path, "."]
        try tar.run()
        tar.waitUntilExit()

        let listing = try await list(archive)
        let tree = ArchiveTree.build(from: listing.entries)
        #expect(Set(tree.map(\.id)) == ["alt", "not.txt"])
        let node = try #require(ArchiveTree.index(tree)["alt/b.txt"])
        #expect(node.archivePath == "./alt/b.txt")
        let extracted = try await ItemExtractor(runner: runner, archive: archive, password: nil)
            .extract(node.archivePath, into: workspace.appendingPathComponent("gecici"))
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "alt\n")
    }

    /// Özellik 6: 7zz h gerçek değerleri.
    @Test func computesChecksums() async throws {
        defer { cleanUp() }
        let result = try await runner.run(SevenZipCommand.hash(file: workspace.appendingPathComponent("kaynak/not.txt")))
        try SevenZipError.check(result)
        let sums = ChecksumParser.parse(result.stdout)
        let expected = SHA256.hash(data: Data("merhaba\n".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(sums.first { $0.algorithm == "SHA256" }?.value.lowercased() == expected)
        #expect(sums.map(\.algorithm) == ["CRC32", "SHA256", "BLAKE2sp"])
        #expect(sums.allSatisfy { !$0.value.isEmpty })
    }

    /// Özellik 1: tek kök öğeli arşiv, akıllı kuralla doğrudan hedefe çıkar.
    @Test func smartSubfolderWithRealArchive() async throws {
        defer { cleanUp() }
        let single = workspace.appendingPathComponent("tek.zip")
        let multiple = workspace.appendingPathComponent("cok.zip")
        try await create(CreateOptions(sources: [workspace.appendingPathComponent("kaynak")], destination: single, format: .zip, level: .fast))
        try await create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak/not.txt"), workspace.appendingPathComponent("kaynak/alt")],
            destination: multiple, format: .zip, level: .fast
        ))
        let base = workspace.appendingPathComponent("hedef", isDirectory: true)
        for archive in [single, multiple] {
            let staging = try StagedExtraction.makeStagingDirectory(for: base)
            defer { try? fileManager.removeItem(at: staging) }
            try SevenZipError.check(try await runner.run(SevenZipCommand.extract(ExtractOptions(archive: archive, destination: staging, overwrite: .replace))))
            let destination = StagedExtraction.destination(for: staging, base: base, archiveName: ArchiveNaming.baseName(of: archive), mode: .smart)
            try StagedExtraction.merge(from: staging, into: destination, policy: .rename)
        }
        #expect(fileManager.fileExists(atPath: base.appendingPathComponent("kaynak/not.txt").path))
        #expect(!fileManager.fileExists(atPath: base.appendingPathComponent("tek").path))
        #expect(fileManager.fileExists(atPath: base.appendingPathComponent("cok/not.txt").path))
        #expect(fileManager.fileExists(atPath: base.appendingPathComponent("cok/alt/b.txt").path))
    }
}
