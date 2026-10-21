import Foundation
import Synchronization
import Testing
@testable import ArhivarCore

/// Hızlı Bakış'ın motor seçimi: 7zz başlatılabilirse onun sonucu, başlatılamazsa (Quick Look kum havuzu
/// alt süreç başlatmayı yasaklar) süreç içi libarchive okuması kullanılır.
@Suite struct PreviewListingTests {
    private static let engineListing = """
    Listing archive: ornek.7z

    --
    Path = ornek.7z
    Type = 7z
    Physical Size = 4096

    ----------
    Path = belgeler/not.txt
    Size = 1200
    Packed Size = 3800
    Attributes = A -rw-r--r--
    Encrypted = -

    """

    private let archive = URL(fileURLWithPath: "/tmp/ornek.7z")

    /// Süreç içi okuyucunun çağrılıp çağrılmadığını sayar.
    private final class Calls: Sendable {
        let count = Mutex(0)
    }

    private func inProcess(_ calls: Calls, entries: [ArchiveEntry] = [ArchiveEntry(path: "libarchive.txt")]) -> @Sendable (URL, String) throws -> ArchiveListing {
        { _, _ in
            calls.count.withLock { $0 += 1 }
            return ArchiveListing(info: ArchiveInfo(type: "7z"), entries: entries)
        }
    }

    /// Bugünkü hatanın kendisi: motor başlatılamadığında ("7zz bulunamadı" ekranı yerine) libarchive kullanılır.
    @Test func fallsBackToInProcessReaderWhenEngineCannotLaunch() async throws {
        let calls = Calls()
        let listing = try await PreviewListing.load(archive: archive, runEngine: { _ in nil }, readInProcess: inProcess(calls))
        #expect(listing.entries.map(\.path) == ["libarchive.txt"])
        #expect(calls.count.withLock { $0 } == 1)
    }

    @Test func usesEngineOutputWhenItRuns() async throws {
        let calls = Calls()
        let output = ProcessResult(exitCode: 0, stdout: Self.engineListing, stderr: "")
        let listing = try await PreviewListing.load(archive: archive, runEngine: { _ in output }, readInProcess: inProcess(calls))
        #expect(listing.entries.map(\.path) == ["belgeler/not.txt"])
        #expect(listing.entries.first?.packedSize == 3800)
        #expect(calls.count.withLock { $0 } == 0)
    }

    @Test func engineEncryptedHeadersMapToPasswordScreen() async {
        let calls = Calls()
        let output = ProcessResult(exitCode: 2, stdout: "", stderr: "ERROR: Cannot open encrypted archive. Wrong password?")
        await #expect(throws: LibArchiveReader.ReadError.encryptedHeaders) {
            try await PreviewListing.load(archive: archive, runEngine: { _ in output }, readInProcess: inProcess(calls))
        }
        #expect(calls.count.withLock { $0 } == 0)
    }

    /// Motor çalıştı ama arşivi okuyamadıysa hatası geçerlidir; libarchive'e geçilip sonuç gizlenmez.
    @Test func engineFailureIsReportedNotMasked() async {
        let calls = Calls()
        let output = ProcessResult(exitCode: 2, stdout: "", stderr: "ERROR: ornek.7z : Can not open the file as archive")
        await #expect(throws: (any Error).self) {
            try await PreviewListing.load(archive: archive, runEngine: { _ in output }, readInProcess: inProcess(calls))
        }
        #expect(calls.count.withLock { $0 } == 0)
    }

    @Test func inProcessErrorsPropagate() async {
        await #expect(throws: LibArchiveReader.ReadError.encryptedHeaders) {
            try await PreviewListing.load(archive: archive, runEngine: { _ in nil }) { _, _ in
                throw LibArchiveReader.ReadError.encryptedHeaders
            }
        }
    }

    /// Tek akışlı biçimlerde (.gz) süreç içi okuyucuya 7zz ile aynı yedek ad verilir.
    @Test func inProcessReaderReceivesStreamFallbackName() async throws {
        let gzip = URL(fileURLWithPath: "/tmp/rapor.txt.gz")
        let received = Mutex<String?>(nil)
        _ = try await PreviewListing.load(archive: gzip, runEngine: { _ in nil }) { _, name in
            received.withLock { $0 = name }
            return ArchiveListing(info: ArchiveInfo(), entries: [])
        }
        #expect(received.withLock { $0 } == ArchiveNaming.streamItemName(for: gzip))
    }
}

/// Parolalı arşivler Hızlı Bakış'ta listelenmez, kilit ekranı gösterilir. Gerçek arşivlerle, iki okuyucuyla da
/// (Quick Look kum havuzunda libarchive; 7zz başlatılabildiğinde 7zz) denenir.
@Suite(.serialized) struct PasswordProtectedPreviewTests {
    static let sevenZip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/7-Zip/7zz")
    static let hasSevenZip = FileManager.default.isExecutableFile(atPath: sevenZip.path)

    enum Reader: String, CaseIterable { case libarchive, sevenZip }

    /// Ad → oluşturma komutu (çalışma klasörü: not.txt ve b.txt içeren kaynak) ve beklenen sonuç.
    static let fixtures: [(name: String, tool: String, arguments: [String], locked: Bool)] = [
        ("zipcrypto.zip", "/usr/bin/zip", ["-q", "-P", "Gizli-123", "ARCHIVE", "not.txt", "b.txt"], true),
        ("aes.zip", "7zz", ["a", "-bso0", "-tzip", "-pGizli-123", "-mem=AES256", "ARCHIVE", "not.txt", "b.txt"], true),
        ("icerik-sifreli.7z", "7zz", ["a", "-bso0", "-pGizli-123", "ARCHIVE", "not.txt", "b.txt"], true),
        ("baslik-sifreli.7z", "7zz", ["a", "-bso0", "-pGizli-123", "-mhe=on", "ARCHIVE", "not.txt", "b.txt"], true),
        ("normal.zip", "/usr/bin/zip", ["-q", "ARCHIVE", "not.txt", "b.txt"], false),
        ("normal.7z", "7zz", ["a", "-bso0", "ARCHIVE", "not.txt", "b.txt"], false),
    ]

    let workspace: URL

    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ArhivarLocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "gizli içerik\n".write(to: workspace.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)
        try "ikinci\n".write(to: workspace.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool == "7zz" ? Self.sevenZip.path : tool)
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " "))")
    }

    private func make(_ name: String) throws -> (URL, Bool) {
        let fixture = try #require(Self.fixtures.first { $0.name == name })
        let archive = workspace.appendingPathComponent(name)
        try run(fixture.tool, fixture.arguments.map { $0 == "ARCHIVE" ? archive.path : $0 })
        return (archive, fixture.locked)
    }

    private func engine(_ reader: Reader) -> PreviewListing.EngineRunner {
        switch reader {
        case .libarchive: { _ in nil }
        case .sevenZip: { url in try? await CommandRunner(executableURL: Self.sevenZip).run(SevenZipCommand.list(archive: url)) }
        }
    }

    @Test(.enabled(if: hasSevenZip, "7zz yok"), arguments: fixtures.map(\.name), Reader.allCases)
    func passwordProtectedArchivesShowLock(name: String, reader: Reader) async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (archive, expectLocked) = try make(name)
        let content = try await PreviewListing.content(archive: archive, runEngine: engine(reader))
        if expectLocked {
            #expect(content == .locked, "\(name) / \(reader.rawValue)")
        } else {
            guard case .listing(let listing) = content else {
                Issue.record("\(name) / \(reader.rawValue): liste bekleniyordu, \(content)")
                return
            }
            #expect(Set(listing.entries.map(\.path)) == ["not.txt", "b.txt"])
        }
    }

    /// Yalnızca bir dosyası parolalı zip: diğer adlar da gösterilmez.
    @Test(arguments: Reader.allCases)
    func singleEncryptedEntryLocksTheWholePreview(reader: Reader) async throws {
        try #require(reader == .libarchive || Self.hasSevenZip)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("karisik.zip")
        try run("/usr/bin/zip", ["-q", archive.path, "b.txt"])
        try run("/usr/bin/zip", ["-q", "-P", "Gizli-123", archive.path, "not.txt"])
        #expect(try await PreviewListing.content(archive: archive, runEngine: engine(reader)) == .locked)
    }
}
