import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// .agents/context/roadmap.md, üçüncü tur (R3-1 … R3-4): ".." yolları, bağlantılar ve özel dosyalar.

private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ProcessInfo.processInfo.environment["ARHIVAR_7ZZ"],
        packageRoot.appendingPathComponent("Vendor/7-Zip/7zz").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

private func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - R3-1 Ara klasörlerin ham yolu

/// ".." bileşeni sayılmaz: "../a/b.txt" içindeki ara klasör "a", 7zz'ye ".." değil "../a" olarak verilir
/// (".." verilseydi onun altındaki her şey, ör. "../z" de çıkarılırdı).
@Test func rawPrefixSkipsParentComponents() {
    #expect(ArchiveTree.rawPrefix("../a/b.txt", components: 1) == "../a")
    #expect(ArchiveTree.rawPrefix("a/../b/c.txt", components: 2) == "a/../b")
    #expect(ArchiveTree.rawPrefix("./a//b/c.txt", components: 2) == "./a//b")
    let entries = [
        ArchiveEntry(path: ListingParser.normalizedPath("../a/b.txt"), archivePath: "../a/b.txt"),
        ArchiveEntry(path: ListingParser.normalizedPath("x/../y/c.txt"), archivePath: "x/../y/c.txt"),
    ]
    let index = ArchiveTree.index(ArchiveTree.build(from: entries))
    #expect(index["a"]?.archivePath == "../a")
    #expect(index["x/y"]?.archivePath == "x/../y")
}

// MARK: - Gerçek 7zz

@Suite(.enabled(if: engineURL != nil, "7zz bulunamadı"), .serialized)
struct EdgeCaseIntegrationTests {
    let runner = CommandRunner(executableURL: engineURL ?? URL(fileURLWithPath: "/usr/bin/false"))
    let workspace: URL

    init() throws {
        workspace = try temporaryFolder("ArhivarUc")
    }

    private func cleanUp() { StagedExtraction.removeTree(at: workspace) }

    /// R3-1: ".." ile başlayan girdilerin ara klasörü kendi ham yoluyla çıkarılır; yanındaki "../z" gelmez.
    @Test func parentPrefixedFolderExtractsOnlyItself() async throws {
        defer { cleanUp() }
        var tar = TarBuilder()
        tar.file("../a/b.txt", "b")
        tar.file("../z/q.txt", "q")
        let archive = workspace.appendingPathComponent("ust.tar")
        try tar.archive.write(to: archive)
        let listed = try await runner.run(SevenZipCommand.list(archive: archive), timeout: 30)
        try SevenZipError.check(listed)
        let index = ArchiveTree.index(ArchiveTree.build(from: ListingParser.parse(listed.stdout).entries))
        let folder = try #require(index["a"])
        #expect(folder.archivePath == "../a")

        let extractor = ItemExtractor(runner: runner, archive: archive, password: nil, root: workspace.appendingPathComponent("oturum"))
        let url = try await extractor.extract(folder.archivePath)
        #expect(url.lastPathComponent == "a")
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == ["b.txt"])
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("z").path))
    }

    /// R3-2: bağlantı listesi verilmese de tek başına çıkarılan bağlantı açık bir hatayla reddedilir ("kod 0" değil).
    @Test func standaloneLinkIsRefusedWithAClearError() async throws {
        defer { cleanUp() }
        let source = workspace.appendingPathComponent("k", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "f".write(to: source.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("iyi").path, withDestinationPath: "f.txt")
        let archive = workspace.appendingPathComponent("bag.7z")
        let options = CreateOptions(sources: [source], destination: archive, format: .sevenZip, level: .fast)
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(options), timeout: 30))

        let extractor = ItemExtractor(runner: runner, archive: archive, password: nil, root: workspace.appendingPathComponent("oturum"))
        await #expect(throws: ItemExtractor.SymbolicLinkError(paths: ["k/iyi"])) { try await extractor.extract("k/iyi") }
        // Klasörün içindeki güvenli bağlantı klasörle birlikte gelir.
        let folder = try await extractor.extract("k")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("iyi").path) == "f.txt")
    }

}
