import Foundation

/// Hızlı Bakış eklentisinin arşiv listesini nasıl okuyacağına karar verir.
///
/// Önce 7zz denenir (en ayrıntılı liste: sıkıştırılmış boyut, yöntem, CRC). Quick Look kum havuzu
/// ("quicklook-preview") alt süreç başlatmayı yasakladığından 7zz çoğu zaman başlatılamaz; o zaman liste
/// macOS'un libarchive kitaplığıyla süreç içinde okunur. 7zz başlatıldıysa onun sonucu (hatası dahil) geçerlidir.
public enum PreviewListing {
    /// 7zz'yi `list` komutuyla çalıştırır; motor bulunamaz ya da başlatılamazsa nil döner.
    public typealias EngineRunner = @Sendable (URL) async -> ProcessResult?

    /// Parola olmadan dosya listesi okunamaz (7z -mhe); hata, listeleyenden bağımsız olarak bununla bildirilir.
    public static func load(
        archive url: URL,
        runEngine: EngineRunner = runEngineList,
        readInProcess: @escaping @Sendable (URL, String) throws -> ArchiveListing = { url, name in
            try LibArchiveReader.list(archive: url, fallbackName: name)
        }
    ) async throws -> ArchiveListing {
        let fallbackName = ArchiveNaming.streamItemName(for: url)
        if let result = await runEngine(url) {
            if SevenZipError.needsPassword(result) { throw LibArchiveReader.ReadError.encryptedHeaders }
            try SevenZipError.check(result)
            return ListingParser.parse(result.stdout, fallbackName: fallbackName)
        }
        return try await Task.detached { try readInProcess(url, fallbackName) }.value
    }

    /// 7zz ile listeler: önce çekirdek kum havuzunda, sandbox-exec kısıtlıysa doğrudan.
    @Sendable public static func runEngineList(_ url: URL) async -> ProcessResult? {
        guard let engineURL = EngineLocator.locate(customPath: nil) else { return nil }
        let profile = SandboxProfile.forOperation(archive: url, writable: [], protectPersonalData: true)
        if let result = try? await CommandRunner(executableURL: engineURL, sandbox: profile).run(SevenZipCommand.list(archive: url)) {
            return result
        }
        return try? await CommandRunner(executableURL: engineURL).run(SevenZipCommand.list(archive: url))
    }
}
