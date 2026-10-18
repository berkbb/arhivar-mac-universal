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

// MARK: - R3-3 Özel dosyalar ve bağlantılı klasörler

/// Bağlantılar izlenirken (bağlantı olarak saklanmıyorken) 7zz klasörü gösteren bağlantının içine de iner;
/// oradaki FIFO da bağlantının yoluyla dışlanır. Döngüye giren bağlantı taramayı bitirmeyi engellemez.
@Test func specialFilesBehindSymlinkedFolders() throws {
    let root = try temporaryFolder("bagli")
    defer { StagedExtraction.removeTree(at: root) }
    let outside = root.appendingPathComponent("dis", isDirectory: true)
    let source = root.appendingPathComponent("k", isDirectory: true)
    for folder in [outside, source] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    #expect(mkfifo(outside.appendingPathComponent("boru").path, 0o644) == 0)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("bag").path, withDestinationPath: outside.path)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("ikinci").path, withDestinationPath: outside.path)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("geri").path, withDestinationPath: "..")

    #expect(SpecialFiles.archivePaths(in: [source]).isEmpty)
    // "geri" üst klasöre döner: oradan "dis/boru"ya da ulaşılır; "k"ye ikinci kez inilmez (döngü).
    #expect(SpecialFiles.archivePaths(in: [source], followingSymlinks: true).sorted() == ["k/bag/boru", "k/geri/dis/boru", "k/ikinci/boru"])
    // Kaynağın kendisi klasörü gösteren bir bağlantıysa da.
    let linkedSource = root.appendingPathComponent("kaynak-bag")
    try FileManager.default.createSymbolicLink(atPath: linkedSource.path, withDestinationPath: outside.path)
    #expect(SpecialFiles.archivePaths(in: [linkedSource], followingSymlinks: true) == ["kaynak-bag/boru"])
}

/// Kaynakların hepsi özel dosyaysa ekleme planı boş ad listesi (7zz'de "*") ya da boş klasör üretmez.
@Test func addPlanRefusesOnlySpecialSources() throws {
    let root = try temporaryFolder("bos")
    defer { StagedExtraction.removeTree(at: root) }
    let first = root.appendingPathComponent("a", isDirectory: true)
    let second = root.appendingPathComponent("b", isDirectory: true)
    for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let pipes = [first.appendingPathComponent("boru1"), second.appendingPathComponent("boru2")]
    for pipe in pipes { #expect(mkfifo(pipe.path, 0o644) == 0) }
    let stagingRoot = root.appendingPathComponent("hazirlik")

    #expect(throws: AddPlan.NothingToArchiveError()) { try AddPlan.make(sources: pipes, into: "", stagingRoot: stagingRoot) }
    #expect(throws: AddPlan.NothingToArchiveError()) { try AddPlan.make(sources: [pipes[0]], into: "", stagingRoot: stagingRoot) }
    #expect(throws: AddPlan.NothingToArchiveError()) { try AddPlan.make(sources: [pipes[0]], into: "alt", stagingRoot: stagingRoot) }
    // FIFO'yu gösteren bağlantı, bağlantılar izlenecekse FIFO gibi atlanır; saklanacaksa bağlantı olarak eklenir.
    let link = root.appendingPathComponent("bag")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: pipes[0].path)
    #expect(throws: AddPlan.NothingToArchiveError()) {
        try AddPlan.make(sources: [link], into: "", stagingRoot: stagingRoot, followingSymlinks: true)
    }
    #expect(try AddPlan.make(sources: [link], into: "", stagingRoot: stagingRoot).names == ["bag"])
    #expect((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? [] == [])
}

/// Kopyalama yarıda kalırsa önce kopyalanan salt okunur klasörler de silinir.
@Test func addPlanCleansUpReadOnlyCopiesOnFailure() throws {
    let root = try temporaryFolder("yarim")
    defer { StagedExtraction.removeTree(at: root) }
    let folder = root.appendingPathComponent("salt", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("ic"), withIntermediateDirectories: true)
    try "x".write(to: folder.appendingPathComponent("ic/f.txt"), atomically: true, encoding: .utf8)
    chmod(folder.appendingPathComponent("ic").path, 0o555)
    let stagingRoot = root.appendingPathComponent("hazirlik")
    #expect(throws: (any Error).self) {
        try AddPlan.make(sources: [folder, root.appendingPathComponent("yok.txt")], into: "hedef", stagingRoot: stagingRoot)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).isEmpty)
    chmod(folder.appendingPathComponent("ic").path, 0o755)
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

    /// R3-3: bağlantılar izlenirken (gz, ya da "bağlantıları sakla" kapalı) bağlı klasördeki FIFO 7zz'yi kilitlemez.
    @Test func fifoBehindSymlinkedFolderDoesNotHang() async throws {
        defer { cleanUp() }
        let outside = workspace.appendingPathComponent("dis", isDirectory: true)
        let source = workspace.appendingPathComponent("k", isDirectory: true)
        for folder in [outside, source] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "d".write(to: outside.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        #expect(mkfifo(outside.appendingPathComponent("boru").path, 0o644) == 0)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("bag").path, withDestinationPath: outside.path)

        var options = CreateOptions(sources: [source], destination: workspace.appendingPathComponent("bag.zip"), format: .zip, level: .fast, storeSymlinks: false)
        options.excludedPaths = SpecialFiles.archivePaths(in: [source], followingSymlinks: true)
        #expect(options.excludedPaths == ["k/bag/boru"])
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(options), timeout: 30))
        let listed = try await runner.run(SevenZipCommand.list(archive: options.destination), timeout: 30)
        #expect(ListingParser.parse(listed.stdout).entries.map(\.path).sorted() == ["k", "k/bag", "k/bag/d.txt"])
    }
}
