import Foundation
import Testing
@testable import Arhivar
@testable import ArhivarCore

/// Projedeki Vendor/7-Zip/7zz (yoksa ARHIVAR_7ZZ).
private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ProcessInfo.processInfo.environment["ARHIVAR_7ZZ"],
        packageRoot.appendingPathComponent("Vendor/7-Zip/7zz").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

/// Her test kendi geçici klasörü, kendi UserDefaults alanı ve gerçek 7zz ile çalışan bir AppModel kurar.
@MainActor
private final class Fixture {
    let workspace: URL
    let defaults: UserDefaults
    let suiteName = "ArhivarAppTests-\(UUID().uuidString)"
    let settings: AppSettings
    let model: AppModel
    let runner: CommandRunner

    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("kaynak/alt"), withIntermediateDirectories: true)
        try "merhaba\n".write(to: workspace.appendingPathComponent("kaynak/not.txt"), atomically: true, encoding: .utf8)
        try "alt\n".write(to: workspace.appendingPathComponent("kaynak/alt/b.txt"), atomically: true, encoding: .utf8)

        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults, bundle: .main)
        settings.customEnginePath = engineURL?.path
        settings.revealAfterOperation = false
        settings.extractIntoSubfolder = true
        model = AppModel(settings: settings, defaults: defaults)
        runner = CommandRunner(executableURL: engineURL ?? URL(fileURLWithPath: "/usr/bin/false"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workspace)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Kaynak klasörden arşiv oluşturur (ayarlar parola ve ad şifrelemesi içerebilir).
    func makeArchive(_ name: String, format: ArchiveFormat, password: String? = nil, encryptNames: Bool = false) async throws -> URL {
        let url = workspace.appendingPathComponent(name)
        let options = CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: url, format: format,
            level: .fast, password: password, encryptFileNames: encryptNames
        )
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(options), input: options.input))
        return url
    }

    func settle() async {
        await model.operationTask?.value
    }
}

@Suite(.enabled(if: engineURL != nil, "7zz bulunamadı"), .serialized)
@MainActor
struct AppModelTests {
    @Test func opensArchiveAndRemembersRecent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("a.7z", format: .sevenZip)

        fixture.model.openArchive(archive)
        await fixture.settle()

        #expect(fixture.model.archiveURL == archive)
        #expect(fixture.model.isEditable)
        #expect(fixture.model.recentArchives.first == archive)
        // Son kullanılanlar enjekte edilen UserDefaults'a yazılır.
        #expect(fixture.defaults.stringArray(forKey: "recentArchives")?.first == archive.path)
    }

    /// Hata 10: düzenlenebilir bir arşiv açıkken Finder'dan gelen arşiv eklenmemeli, açılmalı.
    @Test func openRequestOpensArchiveInsteadOfAdding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let first = try await fixture.makeArchive("ilk.7z", format: .sevenZip)
        let second = try await fixture.makeArchive("ikinci.zip", format: .zip)

        fixture.model.openArchive(first)
        await fixture.settle()
        fixture.model.handleOpenRequest([second])
        await fixture.settle()

        #expect(fixture.model.addRequest == nil)
        #expect(fixture.model.archiveURL == second)
    }

    /// Sürükle-bırak davranışı değişmemeli: açık düzenlenebilir arşive bırakılan dosyalar için ekleme sorulur.
    @Test func dropOntoEditableArchiveAsksToAdd() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("a.7z", format: .sevenZip)
        fixture.model.openArchive(archive)
        await fixture.settle()

        fixture.model.handleDrop([fixture.workspace.appendingPathComponent("kaynak/not.txt")])
        #expect(fixture.model.addRequest?.sources.count == 1)
    }

    @Test func passwordRetryFlowForEncryptedNames() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("gizli.7z", format: .sevenZip, password: "Doğru-1", encryptNames: true)

        fixture.model.openArchive(archive)
        await fixture.settle()
        let first = try #require(fixture.model.passwordRequest)
        #expect(!first.isRetry)

        fixture.model.submitPassword("yanlis")
        await fixture.settle()
        let second = try #require(fixture.model.passwordRequest)
        #expect(second.isRetry)
        #expect(fixture.model.listing == nil)

        fixture.model.submitPassword("Doğru-1")
        await fixture.settle()
        #expect(fixture.model.passwordRequest == nil)
        #expect(fixture.model.archiveURL == archive)
        #expect(fixture.model.listing?.entries.isEmpty == false)
    }

    /// Hata 14: "Buraya Çıkar" açık arşivin parolasını silmemeli.
    @Test func extractHereKeepsOpenArchivePassword() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let secret = try await fixture.makeArchive("gizli.7z", format: .sevenZip, password: "p4ss", encryptNames: true)
        let plain = try await fixture.makeArchive("acik.zip", format: .zip)

        fixture.model.openArchive(secret)
        await fixture.settle()
        fixture.model.submitPassword("p4ss")
        await fixture.settle()
        #expect(fixture.model.archiveURL == secret)

        fixture.model.extractHere([plain])
        await fixture.model.serviceQueueTask?.value
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("acik/kaynak/not.txt").path))

        // Parola hâlâ biliniyorsa test işlemi yeniden parola istemez.
        fixture.model.testArchive()
        await fixture.settle()
        #expect(fixture.model.passwordRequest == nil)
        #expect(fixture.model.alert == nil)
    }

    /// Hata 14: kuyruktaki şifreli arşiv parola beklerken sıradakine geçilmemeli ve parola o arşivde kullanılmalı.
    @Test func extractHereWaitsForPasswordThenContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let secret = try await fixture.makeArchive("sifreli.zip", format: .zip, password: "z1p")
        let plain = try await fixture.makeArchive("duz.7z", format: .sevenZip)

        fixture.model.extractHere([secret, plain])
        // Şifreli arşiv parola istemeli; ikinci arşiv henüz çıkarılmamış olmalı.
        while fixture.model.passwordRequest == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fixture.model.passwordRequest?.archive == secret)
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("duz").path))

        fixture.model.submitPassword("z1p")
        await fixture.model.serviceQueueTask?.value

        #expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("sifreli/kaynak/not.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("duz/kaynak/not.txt").path))
        // Açık arşiv yokken parola modelde saklanmamalı.
        #expect(fixture.model.archiveURL == nil)
    }

    /// Madde 15: internetten inmiş arşivden çıkan dosyalar karantina işaretini taşımalı.
    @Test func extractHerePropagatesQuarantine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("indirilen.zip", format: .zip)
        let value = "00c3;6ad350b0;Safari;3012A7DC-83D1-445D-AFFE-844654688EFB"
        #expect(setxattr(archive.path, "com.apple.quarantine", Array(value.utf8), value.utf8.count, 0, 0) == 0)

        fixture.model.extractHere([archive])
        await fixture.model.serviceQueueTask?.value

        let extracted = fixture.workspace.appendingPathComponent("indirilen/kaynak/alt/b.txt")
        #expect(Quarantine.value(of: extracted) == "0083;6ad350b0;Safari;3012A7DC-83D1-445D-AFFE-844654688EFB")
    }

    /// Madde 18: önizleme dosyaları arşiv oturumunun klasöründe tutulur ve arşiv kapanınca silinir.
    @Test func previewFilesAreRemovedOnClose() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("onizleme.7z", format: .sevenZip, password: "gizli")
        fixture.model.openArchive(archive)
        await fixture.settle()

        fixture.model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        fixture.model.submitPassword("gizli")
        await fixture.settle()
        let preview = try #require(fixture.model.quickLookURL)
        #expect(FileManager.default.fileExists(atPath: preview.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: preview.deletingLastPathComponent().deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(permissions?.uint16Value == 0o700)

        fixture.model.closeArchive()
        #expect(!FileManager.default.fileExists(atPath: preview.path))
    }

    /// Madde 19: çalıştırılabilir ya da adı yanıltıcı dosyalar sormadan açılmamalı.
    @Test func riskyFilesNeedConfirmation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let script = fixture.workspace.appendingPathComponent("kur.command")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        #expect(fixture.model.openRisk(for: script, path: "kur.command") != nil)
        let text = fixture.workspace.appendingPathComponent("kaynak/not.txt")
        #expect(fixture.model.openRisk(for: text, path: "kaynak/not.txt") == nil)
        #expect(fixture.model.openRisk(for: text, path: "fatura\u{202E}txt.command") != nil)
    }

    /// A7: ilk açılışta GitHub'a bağlanmadan önce izin sorulur; açılış denetimi varsayılan olarak kapalıdır.
    @Test func launchAsksForUpdateConsentWithoutNetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(!fixture.settings.checkUpdatesAtLaunch)
        #expect(!fixture.settings.updateConsentAsked)

        await fixture.model.launch()
        let alert = try #require(fixture.model.alert)
        #expect(alert.action != nil && alert.cancelAction != nil)
        // İzin verilmeden hiçbir denetim başlamamalı.
        #expect(fixture.model.updateState == .idle)
        #expect(fixture.model.appUpdateState == .idle)

        fixture.model.respondToUpdateConsent(false)
        #expect(fixture.settings.updateConsentAsked)
        #expect(!fixture.settings.checkUpdatesAtLaunch)
        #expect(fixture.defaults.bool(forKey: "updateConsentAsked"))
    }

    @Test func secondLaunchDoesNotAskAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.updateConsentAsked = true
        fixture.settings.checkUpdatesAtLaunch = false
        await fixture.model.launch()
        #expect(fixture.model.alert == nil)
        #expect(fixture.model.appUpdateState == .idle)
    }

    /// Madde 17: bozuk arşiv "üzerine yaz" ile çıkarılırken hata olursa mevcut dosya bozulmadan kalmalı.
    @Test func failedExtractionLeavesExistingFilesUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        fixture.settings.overwriteMode = .replace
        fixture.settings.extractIntoSubfolder = false

        // Saklama (sıkıştırmasız) zip: içerik düz metin olarak durur; değiştirince CRC hatası verir.
        let archive = fixture.workspace.appendingPathComponent("bozuk.zip")
        let options = CreateOptions(
            sources: [fixture.workspace.appendingPathComponent("kaynak")], destination: archive, format: .zip, level: .store
        )
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(options)))
        var bytes = try Data(contentsOf: archive)
        let range = try #require(bytes.range(of: Data("merhaba".utf8)))
        bytes.replaceSubrange(range, with: Data("MERHABA".utf8))
        try bytes.write(to: archive)

        // Hedef, kaynağın kendisi: kaynak/not.txt zaten var.
        fixture.model.extractHere([archive])
        await fixture.model.serviceQueueTask?.value

        let original = try String(contentsOf: fixture.workspace.appendingPathComponent("kaynak/not.txt"), encoding: .utf8)
        #expect(original == "merhaba\n")
        #expect(fixture.model.alert != nil)
        // Hazırlık klasörü kalmamalı.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).filter { $0.hasPrefix(".arhivar-staging") }
        #expect(leftovers.isEmpty)
    }

    @Test func folderNavigationAndEditing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("duzenle.7z", format: .sevenZip)
        let model = fixture.model
        model.browserMode = .folders
        model.openArchive(archive)
        await fixture.settle()

        #expect(model.displayNodes.map(\.id) == ["kaynak"])
        model.primaryAction(["kaynak"])
        #expect(model.currentFolder == "kaynak")
        #expect(Set(model.displayNodes.map(\.id)) == ["kaynak/alt", "kaynak/not.txt"])

        model.rename("kaynak/not.txt", to: "yeni.txt")
        await fixture.settle()
        #expect(model.currentFolder == "kaynak")
        #expect(model.node("kaynak/yeni.txt") != nil)

        model.requestDelete(["kaynak/alt"])
        model.confirmDelete()
        await fixture.settle()
        #expect(model.node("kaynak/alt") == nil)

        model.goUp()
        #expect(model.currentFolder == "")
        #expect(model.selection == ["kaynak"])
    }
}
