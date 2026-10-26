import Foundation
import Testing
@testable import ArhivarCore

// Liste maddesi 20: 7zz'yi sandbox-exec ile yalıtma.

@Test func profileDeniesNetworkAndUnlistedWrites() {
    let profile = SandboxProfile(
        writableDirectories: [URL(fileURLWithPath: "/private/tmp/hedef")],
        deniedReadDirectories: [URL(fileURLWithPath: "/Users/x/.ssh")]
    )
    let text = profile.profileText
    #expect(text.contains("(deny network*)"))
    #expect(text.contains("(deny file-write*)"))
    #expect(text.contains("(allow file-write* (subpath \"/dev\") (subpath (param \"W0\")))"))
    #expect(text.contains("(deny file-read* (subpath (param \"R0\")))"))

    let args = profile.launchArguments(executable: URL(fileURLWithPath: "/a/7zz"), arguments: ["l", "--", "x.7z"])
    #expect(args.first == "-p")
    #expect(args.contains("W0=/private/tmp/hedef"))
    #expect(args.contains("R0=/Users/x/.ssh"))
    #expect(args.suffix(4) == ["/a/7zz", "l", "--", "x.7z"])
}

@Test func resolvesPrivateAliases() {
    // Foundation'ın resolvingSymlinksInPath'i "/private" önekini siler; çekirdek ise gerçek yolu görür.
    #expect(SandboxProfile.resolved(URL(fileURLWithPath: "/var/tmp")).path == "/private/var/tmp")
    #expect(SandboxProfile.resolved(URL(fileURLWithPath: "/tmp/henuz-yok/alt")).path == "/private/tmp/henuz-yok/alt")
}

@Test func personalFoldersAreProtectedOnlyWhenReadingArchives() {
    let home = URL(fileURLWithPath: "/Users/ornek")
    let archive = URL(fileURLWithPath: "/Users/ornek/Downloads/a.zip")
    let reading = SandboxProfile.forOperation(archive: archive, writable: [], protectPersonalData: true, home: home)
    #expect(reading.deniedReadDirectories.contains { $0.path.hasSuffix("/.ssh") })
    #expect(reading.deniedReadDirectories.contains { $0.path.hasSuffix("/Library/Keychains") })
    let creating = SandboxProfile.forOperation(archive: archive, writable: [], protectPersonalData: false, home: home)
    #expect(creating.deniedReadDirectories.isEmpty)
    // Kullanıcı açıkça kişisel bir klasördeki arşivle çalışıyorsa o klasör yasaklanmaz.
    let inside = SandboxProfile.forOperation(
        archive: URL(fileURLWithPath: "/Users/ornek/.ssh/yedek.zip"), writable: [], protectPersonalData: true, home: home
    )
    // Arşiv kişisel bir klasörün içindeyse (ör. Mail eki) klasör yasaklı KALIR; yalnızca arşivin kendisi okunabilir.
    #expect(inside.deniedReadDirectories.contains { $0.path.hasSuffix("/.ssh") })
    #expect(inside.readableFiles.map(\.path) == ["/Users/ornek/.ssh/yedek.zip"])
}

private let engine: URL? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Vendor/7-Zip/7zz")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

@Test(.enabled(if: engine != nil && SandboxProfile.isAvailable))
func sandboxedEngineWritesOnlyWhereAllowed() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("sandbox-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root.appendingPathComponent("kaynak"), withIntermediateDirectories: true)
    try "gizli olmayan\n".write(to: root.appendingPathComponent("kaynak/a.txt"), atomically: true, encoding: .utf8)
    let plain = CommandRunner(executableURL: try #require(engine))
    let archive = root.appendingPathComponent("t.7z")
    try SevenZipError.check(try await plain.run(SevenZipCommand.create(CreateOptions(
        sources: [root.appendingPathComponent("kaynak")], destination: archive, format: .sevenZip, level: .fast
    ))))

    let allowed = root.appendingPathComponent("izinli", isDirectory: true)
    let forbidden = root.appendingPathComponent("yasak", isDirectory: true)
    try fileManager.createDirectory(at: allowed, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: forbidden, withIntermediateDirectories: true)
    let confined = plain.sandboxed(.forOperation(archive: archive, writable: [allowed], protectPersonalData: true))
    #expect(confined.sandbox != nil)

    try SevenZipError.check(try await confined.run(SevenZipCommand.extract(ExtractOptions(archive: archive, destination: allowed, overwrite: .replace))))
    #expect(fileManager.fileExists(atPath: allowed.appendingPathComponent("kaynak/a.txt").path))

    let denied = try await confined.run(SevenZipCommand.extract(ExtractOptions(archive: archive, destination: forbidden, overwrite: .replace)))
    #expect(denied.exitCode != 0)
    #expect(!fileManager.fileExists(atPath: forbidden.appendingPathComponent("kaynak/a.txt").path))

    // Okuma işlemleri yazma izni olmadan çalışır.
    let listed = try await plain.sandboxed(.forOperation(archive: archive, writable: [], protectPersonalData: true)).run(SevenZipCommand.list(archive: archive))
    try SevenZipError.check(listed)
    #expect(ListingParser.parse(listed.stdout).entries.contains { $0.path == "kaynak/a.txt" })
}

/// Kum havuzu istenip sandbox-exec çalıştırılamıyorsa program korumasız başlatılmaz (eskiden sessizce doğrudan
/// çalışırdı). Kullanıcı kum havuzunu ayarlardan kapattıysa (profil yok) program her zamanki gibi çalışır.
@Test func missingSandboxLauncherFailsClosed() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArhivarSandboxClosed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let marker = folder.appendingPathComponent("calisti")
    let touch = URL(fileURLWithPath: "/usr/bin/touch")
    let missing = folder.appendingPathComponent("sandbox-exec-yok")
    let profile = SandboxProfile.forOperation(archive: folder.appendingPathComponent("a.zip"), writable: [folder])

    let confined = CommandRunner(executableURL: touch, sandbox: nil, sandboxLauncher: missing).sandboxed(profile)
    #expect(confined.sandbox != nil)
    await #expect(throws: SevenZipError.sandboxUnavailable) { try await confined.run([marker.path]) }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(AppLog.shared.entries.contains { $0.level == .error && $0.message.hasPrefix("touch: 7zz was not started because its sandbox") })

    // Kum havuzu kapalı: profil yok, program çalışır.
    let open = CommandRunner(executableURL: touch, sandbox: nil, sandboxLauncher: missing).sandboxed(nil)
    #expect(open.sandbox == nil)
    #expect(try await open.run([marker.path]).exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: marker.path))
}
