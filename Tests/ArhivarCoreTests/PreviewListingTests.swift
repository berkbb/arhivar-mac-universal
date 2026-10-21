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
