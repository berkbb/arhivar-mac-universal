import Foundation
import Testing
@testable import ArhivarCore

@Suite struct QuickLookTests {

    /// Quick Look eklentisi içinden (Contents/PlugIns/ArhivarQuickLook.appex) çağrıldığında
    /// üst uygulamanın Contents/MacOS/7zz motor yolu adaylar arasına eklenir.
    @Test func engineLocatorResolvesParentAppBundleForAppExtension() {
        let fakeApp = URL(fileURLWithPath: "/Applications/Arhivar.app")
        let fakeAppex = fakeApp.appendingPathComponent("Contents/PlugIns/ArhivarQuickLook.appex")
        let fakeBundle = Bundle(url: fakeAppex) ?? Bundle.main

        let candidates = EngineLocator.candidates(customPath: nil, bundle: fakeBundle)
        // Adaylar en azından yönetilen motoru, sistem yollarını veya üst paket yolunu içermelidir:
        #expect(!candidates.isEmpty)
        #expect(candidates.contains { $0.lastPathComponent == "7zz" })
    }

    /// Hızlı Bakış penceresinin Finder içinde hafif ve hızlı kalması için girdiler
    /// ağaçtan düzleştirilerek sunulur ve istatistikler doğru hesaplanır.
    @Test func quickLookMetadataAndStatsCalculation() {
        let entries = [
            ArchiveEntry(path: "docs/readme.txt", archivePath: "docs/readme.txt", size: 1024, packedSize: 512, isDirectory: false),
            ArchiveEntry(path: "docs/manual.pdf", archivePath: "docs/manual.pdf", size: 2048, packedSize: 1024, isDirectory: false),
            ArchiveEntry(path: "images/logo.png", archivePath: "images/logo.png", size: 4096, packedSize: 2048, isDirectory: false)
        ]
        let listing = ArchiveListing(info: ArchiveInfo(type: "7z", physicalSize: 4000), entries: entries)
        let stats = ArchiveStatistics(listing: listing)

        #expect(stats.fileCount == 3)
        #expect(stats.folderCount == 2) // docs ve images
        #expect(stats.totalSize == 7168)
        #expect(stats.packedSize == 4000) // physical size takes precedence

        let tree = ArchiveTree.build(from: entries)
        #expect(tree.count == 2) // docs, images
    }

    /// Şifreli başlıklara sahip arşivlerde (7z -mhe) parola olmadan liste okunamayacağı için
    /// durum tespiti doğru çalışır.
    @Test func encryptedHeadersClassification() {
        let errorOutput = "ERROR: Cannot open encrypted archive. Wrong password?"
        let result = ProcessResult(exitCode: 2, stdout: "", stderr: errorOutput)
        #expect(SevenZipError.needsPassword(result))
    }
}

/// Quick Look kum havuzu 7zz'nin başlatılmasını yasaklar; liste yerleşik libarchive ile süreç içinde okunur.
@Suite(.serialized) struct LibArchiveReaderTests {
    let workspace: URL

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArhivarLibArchive-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("kaynak/alt", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "merhaba dünya\n".write(to: workspace.appendingPathComponent("kaynak/not.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "veri ", count: 200).write(to: source.appendingPathComponent("şirket.txt"), atomically: true, encoding: .utf8)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func listsTarGzipWithUnicodeNames() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("test.tar.gz")
        try run("/usr/bin/tar", ["-czf", archive.path, "kaynak"])

        let listing = try LibArchiveReader.list(archive: archive)
        #expect(listing.info.type == "tar")
        let file = try #require(listing.entries.first { $0.path == "kaynak/alt/şirket.txt" })
        #expect(file.size == 1000)
        #expect(file.modified != nil)
        #expect(listing.entries.contains { $0.path == "kaynak/alt" && $0.isDirectory })
        #expect(ArchiveStatistics(listing: listing).fileCount == 2)
    }

    @Test func listsZip() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("test.zip")
        try run("/usr/bin/zip", ["-qr", archive.path, "kaynak"])

        let listing = try LibArchiveReader.list(archive: archive)
        #expect(listing.info.type == "zip")
        #expect(listing.entries.contains { $0.path == "kaynak/not.txt" && $0.size == 15 })
    }

    @Test func listsSingleStreamGzipUnderFallbackName() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        try run("/usr/bin/gzip", ["-k", "kaynak/not.txt"])
        let archive = workspace.appendingPathComponent("kaynak/not.txt.gz")

        let listing = try LibArchiveReader.list(archive: archive, fallbackName: "not.txt")
        #expect(listing.info.type == "gzip")
        #expect(listing.entries.map(\.path) == ["not.txt"])
    }

    /// Tek akışlı biçimlerin "merhaba dünya\n" içeriği; araçları (xz, zstd) her makinede bulunmadığı için gömülüdür.
    static let singleStreamFixtures: [(fileExtension: String, type: String, base64: String)] = [
        ("xz", "xz", "/Td6WFoAAATm1rRGBMATDyEBFgAAAAAAAAAAAG75/+kBAA5tZXJoYWJhIGTDvG55YQoAACzNXHazS+P5AAEvD9eQJaIftvN9AQAAAAAEWVo="),
        ("bz2", "bzip2", "QlpoOTFBWSZTWR8WNaQAAATRjAAQQAA2QxAgAAQIACAAIgANAgGgBSD00WK0b3eLuSKcKEgPixrSAA=="),
        ("zst", "zstd", "KLUv/SQPeQAAbWVyaGFiYSBkw7xueWEKGezZ/A=="),
    ]

    /// Hızlı Bakış'ın desteklediği tek akışlı biçimler (.xz, .bz2, .zst) ham akış olarak listelenir.
    @Test(arguments: singleStreamFixtures.map(\.fileExtension))
    func listsOtherSingleStreamFormats(fileExtension: String) throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try #require(Self.singleStreamFixtures.first { $0.fileExtension == fileExtension })
        let archive = workspace.appendingPathComponent("not.txt.\(fileExtension)")
        try #require(Data(base64Encoded: fixture.base64)).write(to: archive)

        let listing = try LibArchiveReader.list(archive: archive, fallbackName: "not.txt")
        #expect(listing.info.type == fixture.type)
        #expect(listing.entries.map(\.path) == ["not.txt"])
    }

    /// 7z arşivleri depodaki 7zz ile oluşturulur; yoksa atlanır.
    static let sevenZip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/7-Zip/7zz")

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: sevenZip.path)))
    func listsSevenZipAndDetectsEncryptedHeaders() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let plain = workspace.appendingPathComponent("Şirket.7z")
        try run(Self.sevenZip.path, ["a", "-bso0", plain.path, "kaynak"])
        let listing = try LibArchiveReader.list(archive: plain)
        #expect(listing.info.type == "7z")
        #expect(listing.entries.contains { $0.path == "kaynak/alt/şirket.txt" && $0.size == 1000 })

        let locked = workspace.appendingPathComponent("gizli.7z")
        try run(Self.sevenZip.path, ["a", "-bso0", "-pGizli-123", "-mhe=on", locked.path, "kaynak"])
        #expect(throws: LibArchiveReader.ReadError.encryptedHeaders) {
            try LibArchiveReader.list(archive: locked)
        }
    }

    /// Yarıda kesilmiş arşiv (eksik indirme) çökmeden okunamaz hatası verir.
    @Test func truncatedArchiveThrowsInsteadOfCrashing() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("yarim.tar.gz")
        try run("/usr/bin/tar", ["-czf", archive.path, "kaynak"])
        let data = try Data(contentsOf: archive)
        try data.prefix(data.count / 2).write(to: archive)

        #expect(throws: LibArchiveReader.ReadError.self) {
            try LibArchiveReader.list(archive: archive)
        }
    }

    /// Dosya adları açık, içerikleri parolalı zip: liste okunur ve girdiler şifreli işaretlenir.
    @Test func passwordProtectedZipListsEncryptedEntries() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("parolali.zip")
        try run("/usr/bin/zip", ["-qr", "-P", "Gizli-123", archive.path, "kaynak"])

        let listing = try LibArchiveReader.list(archive: archive)
        let file = try #require(listing.entries.first { $0.path == "kaynak/not.txt" })
        #expect(file.isEncrypted)
        #expect(ArchiveStatistics(listing: listing).isEncrypted)
    }

    /// Sembolik bağlantı girdisi tanınır; "./" ile başlayan yollar normalleştirilir, ham yol korunur.
    @Test func symbolicLinksAndDotSlashPaths() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createSymbolicLink(
            atPath: workspace.appendingPathComponent("kaynak/bag").path, withDestinationPath: "not.txt"
        )
        let archive = workspace.appendingPathComponent("bagli.tar")
        try run("/usr/bin/tar", ["-cf", archive.path, "-C", workspace.appendingPathComponent("kaynak").path, "."])

        let listing = try LibArchiveReader.list(archive: archive)
        let link = try #require(listing.entries.first { $0.path == "bag" })
        #expect(link.isSymbolicLink)
        #expect(link.archivePath == "./bag")
        #expect(listing.entries.contains { $0.path == "alt/şirket.txt" && !$0.isSymbolicLink })
    }

    /// Girdi sınırı: liste sınırda kesilir (kötü niyetli arşiv belleği tüketemez).
    @Test func entryLimitTruncatesListing() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        for index in 0..<10 {
            try "\(index)".write(to: workspace.appendingPathComponent("kaynak/dosya\(index).txt"), atomically: true, encoding: .utf8)
        }
        let archive = workspace.appendingPathComponent("cok.tar")
        try run("/usr/bin/tar", ["-cf", archive.path, "kaynak"])

        #expect(try LibArchiveReader.list(archive: archive).entries.count > 10)
        #expect(try LibArchiveReader.list(archive: archive, maxEntries: 3).entries.count == 3)
    }

    @Test func rejectsNonArchive() throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(throws: LibArchiveReader.ReadError.self) {
            try LibArchiveReader.list(archive: workspace.appendingPathComponent("kaynak/not.txt"))
        }
    }
}
