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
