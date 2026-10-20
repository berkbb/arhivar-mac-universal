import AppKit
import CryptoKit
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
        // Mevcut senaryolar arşiv adıyla klasör bekler; akıllı kural ayrıca sınanır.
        settings.subfolderMode = .always
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
        while model.operation != nil { await model.operationTask?.value }
        await model.searchTask?.value
    }

    /// Çıkarma hedefini sabitler (panel açılmasın) ve hedef klasörü döndürür.
    func useExtractFolder(_ name: String = "cikti") -> URL {
        let folder = workspace.appendingPathComponent(name, isDirectory: true)
        settings.extractLocation = .custom
        settings.customExtractFolder = folder.path
        return folder
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path)
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
        // Süre sınırı: bir hata parola isteğini engellerse test sonsuza dek beklemesin.
        for _ in 0..<200 where fixture.model.passwordRequest == nil { try await Task.sleep(for: .milliseconds(50)) }
        try #require(fixture.model.passwordRequest != nil)
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
        fixture.settings.subfolderMode = .never

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

    /// Uygulama Finder sağ tık menüsüyle kapalıyken açıldığında istek, motor denetlenmeden gelir.
    /// Önceden "7-Zip bulunamadı" uyarısı çıkıyordu; şimdi motor bulunana kadar beklenmeli.
    @Test func coldStartServiceRequestsWaitForEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try await fixture.makeArchive("soguk.zip", format: .zip)
        let other = try await fixture.makeArchive("acilacak.7z", format: .sevenZip)

        // refreshEngine() çağrılmadan:
        fixture.model.extractHere([archive])
        await fixture.model.serviceQueueTask?.value
        #expect(fixture.model.alert == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("soguk/kaynak/not.txt").path))

        let second = try Fixture()
        defer { second.cleanUp() }
        second.model.openArchive(other)
        while second.model.operation != nil { await second.model.operationTask?.value }
        #expect(second.model.alert == nil)
        #expect(second.model.archiveURL == other)
    }

    /// Finder servisleri ve "Birlikte Aç" uygulamayı penceresiz başlatabilir; istek geldiğinde ana pencere açılmalı.
    @Test func serviceRequestsOpenTheMainWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var opened = 0
        fixture.model.registerWindowOpener { opened += 1 }
        fixture.model.presentMainWindow()
        #expect(opened == 1)

        // Pencere açma eylemi henüz kayıtlı değilse (çok erken soğuk açılış) kayıt gelince yeniden denenir.
        let late = try Fixture()
        defer { late.cleanUp() }
        var lateOpened = 0
        late.model.presentMainWindow()
        late.model.registerWindowOpener { lateOpened += 1 }
        for _ in 0..<20 where lateOpened == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(lateOpened == 1)
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

    // MARK: - ROADMAP.md

    /// P0-1: adları açık, parolalı 7z'ye parolayla eklemek adları şifrelememeli (önceden -mhe=on veriliyordu).
    @Test func addingWithPasswordKeepsHeadersPlain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("parolali.7z", format: .sevenZip, password: "p", encryptNames: false)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        for name in ["ek1.txt", "ek2.txt"] {
            let extra = fixture.workspace.appendingPathComponent(name)
            try "ek".write(to: extra, atomically: true, encoding: .utf8)
            model.addFiles([extra])
            await fixture.settle()
            if model.passwordRequest != nil {
                model.submitPassword("p")
                await fixture.settle()
            }
        }
        #expect(model.node("ek2.txt") != nil)
        // Parolasız liste hâlâ çalışmalı: adlar şifrelenmedi.
        let plain = try await fixture.runner.run(SevenZipCommand.list(archive: archive))
        #expect(!SevenZipError.needsPassword(plain))
    }

    /// P1-11: bölünmüş arşiv oluşturulunca ilk parça son kullanılanlara girer; ikinci parça ilk parçadan açılır.
    @Test func splitArchivesOpenFromFirstVolume() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let big = fixture.workspace.appendingPathComponent("buyuk.bin")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<2_500_000).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: big)
        let destination = fixture.workspace.appendingPathComponent("parca.7z")
        fixture.model.createArchive(CreateOptions(sources: [big], destination: destination, format: .sevenZip, level: .store, volumeSizeMB: 1))
        await fixture.settle()

        #expect(fixture.model.alert == nil)
        #expect(fixture.model.recentArchives.first?.lastPathComponent == "parca.7z.001")
        #expect(fixture.exists("parca.7z.003"))
        fixture.model.openArchive(fixture.workspace.appendingPathComponent("parca.7z.002"))
        await fixture.settle()
        #expect(fixture.model.archiveURL?.lastPathComponent == "parca.7z.001")
        #expect(fixture.model.node("buyuk.bin") != nil)
        #expect((fixture.model.statistics?.packedSize ?? 0) > 2_000_000)
    }

    /// P1-13: iptal "Buraya Çıkar" kuyruğunun geri kalanını da durdurur.
    @Test func cancelStopsServiceQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let first = try await fixture.makeArchive("birinci.zip", format: .zip)
        let second = try await fixture.makeArchive("ikinci.zip", format: .zip)

        fixture.model.extractHere([first, second])
        for _ in 0..<500 where fixture.model.operation == nil { try await Task.sleep(for: .milliseconds(1)) }
        fixture.model.cancelOperation()
        await fixture.model.serviceQueueTask?.value
        #expect(!fixture.exists("ikinci"))
    }

    /// P1-15 ve özellik 1: alt klasördeyken seçilen öğe klasör yolu olmadan, tek öğe olduğu için doğrudan hedefe çıkar.
    @Test func extractingFromSubfolderStripsPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("alt.7z", format: .sevenZip)
        let output = fixture.useExtractFolder()
        fixture.settings.subfolderMode = .smart
        let model = fixture.model
        model.browserMode = .folders
        model.openArchive(archive)
        await fixture.settle()

        model.enterFolder("kaynak")
        model.enterFolder("kaynak/alt")
        model.extract(items: ["kaynak/alt/b.txt"])
        await fixture.settle()
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("kaynak").path))

        // Arama sonuçlarından çıkarma tam yolu korur.
        model.searchText = "not"
        model.extract(items: ["kaynak/not.txt"])
        await fixture.settle()
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("kaynak/not.txt").path))
    }

    /// Özellik 1: tek kök klasörlü arşiv "Ad/Ad" iç içeliği olmadan, çok öğeli arşiv kendi klasörüne çıkar.
    @Test func smartSubfolderAvoidsDoubleNesting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let single = try await fixture.makeArchive("tek.zip", format: .zip)
        let multiple = fixture.workspace.appendingPathComponent("cok.zip")
        let options = CreateOptions(
            sources: [fixture.workspace.appendingPathComponent("kaynak/not.txt"), fixture.workspace.appendingPathComponent("kaynak/alt")],
            destination: multiple, format: .zip, level: .fast
        )
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(options)))
        let output = fixture.useExtractFolder()
        fixture.settings.subfolderMode = .smart

        for archive in [single, multiple] {
            fixture.model.openArchive(archive)
            await fixture.settle()
            fixture.model.extract(selectedOnly: false)
            await fixture.settle()
        }
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("kaynak/alt/b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("tek").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("cok/alt/b.txt").path))
    }

    /// P1-16: yol çubuğuna bırakılan dosyalar onaylanana kadar açık klasör değişmez; hedef klasör istekte taşınır.
    @Test func addRequestCarriesTargetFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("hedef.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        let extra = fixture.workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)

        model.addRequest = AddRequest(sources: [extra], folder: "kaynak/alt")
        #expect(model.currentFolder == "")
        model.addRequest = nil
        #expect(model.currentFolder == "")

        model.addRequest = AddRequest(sources: [extra], folder: "kaynak/alt")
        model.confirmAdd()
        await fixture.settle()
        #expect(model.node("kaynak/alt/ek.txt") != nil)
        #expect(model.currentFolder == "")
    }

    /// P1-14: farklı klasörlerdeki aynı adlı dosyalar eklenmez; anlaşılır bir hata gösterilir.
    @Test func addingDuplicateNamesShowsError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("ayni.7z", format: .sevenZip)
        fixture.model.openArchive(archive)
        await fixture.settle()
        let other = fixture.workspace.appendingPathComponent("baska", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "x".write(to: other.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)

        fixture.model.addFiles([fixture.workspace.appendingPathComponent("kaynak/not.txt"), other.appendingPathComponent("not.txt")])
        await fixture.settle()
        #expect(fixture.model.alert?.message == fixture.settings.t(.duplicateNames, "not.txt"))
        #expect(fixture.model.node("not.txt") == nil)
    }

    /// P2-20: "Birlikte Aç" ile soğuk açılışta güncelleme izni, arşiv açılırken değil, iş bitince sorulur.
    @Test func consentWaitsForColdStartOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try await fixture.makeArchive("soguk.7z", format: .sevenZip)
        fixture.model.openArchive(archive)
        await fixture.model.launch()
        #expect(fixture.model.alert == nil)
        await fixture.settle()
        for _ in 0..<50 where fixture.model.alert == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.model.archiveURL == archive)
        #expect(fixture.model.alert?.title == fixture.settings.t(.consentTitle))
    }

    /// P2-21: Dock'a arşivle birlikte başka dosyalar bırakılırsa hepsi yeni arşive gider; yalnızca arşivlerse ilki açılır.
    @Test func openRequestWithMixedFilesCreatesArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let first = try await fixture.makeArchive("a.zip", format: .zip)
        let second = try await fixture.makeArchive("b.7z", format: .sevenZip)
        let text = fixture.workspace.appendingPathComponent("kaynak/not.txt")

        fixture.model.handleOpenRequest([first, text])
        #expect(fixture.model.createRequest?.sources == [first, text])
        #expect(fixture.model.archiveURL == nil)
        fixture.model.createRequest = nil

        fixture.model.handleOpenRequest([first, second])
        await fixture.settle()
        #expect(fixture.model.archiveURL == first)
    }

    /// P3-22: düzenlemeden sonra eski önizleme dosyaları silinir.
    @Test func editDiscardsStalePreviews() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("onizle.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        let preview = try #require(model.quickLookURL)
        model.quickLookURL = nil

        model.rename("kaynak/alt/b.txt", to: "c.txt")
        await fixture.settle()
        #expect(model.node("kaynak/alt/c.txt") != nil)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
    }

    /// P3-22: sıfırlama ilk kurulumdaki gibi hiçbir tercih bırakmaz; eski alt klasör tercihi yeni kurala çevrilir.
    @Test func resetRemovesAllPreferences() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // object(forKey:) genel alana (NSGlobalDomain) da bakar; yalnızca uygulamanın kendi alanı denetlenir.
        let stored = { fixture.defaults.persistentDomain(forName: fixture.suiteName) ?? [:] }
        fixture.settings.language = .en
        fixture.model.browserMode = .tree
        #expect(stored()["AppleLanguages"] != nil)

        fixture.model.browserMode = .folders
        fixture.settings.resetAll()
        #expect(stored()["AppleLanguages"] == nil)
        #expect(stored()["browserMode"] == nil)
        #expect(stored()["language"] == nil)
        #expect(stored()["quickLookShortcut"] == nil)
        #expect(fixture.settings.language == .tr)
        #expect(fixture.settings.subfolderMode == .smart)
        #expect(fixture.settings.quickLookShortcut == .spaceAndCmdY)
        #expect(fixture.settings.storeSymlinks)

        fixture.defaults.set(false, forKey: "extractIntoSubfolder")
        #expect(AppSettings(defaults: fixture.defaults, bundle: .main).subfolderMode == .never)
        fixture.defaults.set(true, forKey: "extractIntoSubfolder")
        #expect(AppSettings(defaults: fixture.defaults, bundle: .main).subfolderMode == .smart)
    }

    /// Hızlı Bakış kısayol ayarı (Boşluk ve ⌘Y, Yalnızca Boşluk, Yalnızca ⌘Y) tetikleyicileri doğru kısıtlar.
    @Test func quickLookShortcutPreferencesConfigureTriggers() {
        let fixture = try! Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings

        #expect(settings.quickLookShortcut == .spaceAndCmdY)
        #expect(settings.quickLookShortcut.allowsSpace)
        #expect(settings.quickLookShortcut.allowsCmdY)
        #expect(settings.quickLookShortcut.displayBadge == "Space / ⌘Y")

        settings.quickLookShortcut = .spaceOnly
        #expect(settings.quickLookShortcut.allowsSpace)
        #expect(!settings.quickLookShortcut.allowsCmdY)
        #expect(settings.quickLookShortcut.displayBadge == "Space")

        settings.quickLookShortcut = .cmdYOnly
        #expect(!settings.quickLookShortcut.allowsSpace)
        #expect(settings.quickLookShortcut.allowsCmdY)
        #expect(settings.quickLookShortcut.displayBadge == "⌘Y")
    }

    /// P1-8: "./" önekli tar'da "." klasörü görünmez; seçili öğe ham yoluyla çıkarılır.
    @Test func dotPrefixedTarBrowsesAndExtracts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = fixture.workspace.appendingPathComponent("nokta.tar")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--no-mac-metadata", "-cf", archive.path, "-C", fixture.workspace.appendingPathComponent("kaynak").path, "."]
        try tar.run()
        tar.waitUntilExit()
        let output = fixture.useExtractFolder()
        fixture.settings.subfolderMode = .smart
        let model = fixture.model
        model.browserMode = .folders
        model.openArchive(archive)
        await fixture.settle()

        #expect(Set(model.displayNodes.map(\.id)) == ["alt", "not.txt"])
        model.primaryAction(["alt"])
        #expect(model.breadcrumbs.map(\.path) == ["alt"])
        #expect(model.displayNodes.map(\.id) == ["alt/b.txt"])
        model.extract(items: ["alt/b.txt"])
        await fixture.settle()
        #expect(fixture.model.alert == nil)
        #expect(try String(contentsOf: output.appendingPathComponent("b.txt"), encoding: .utf8) == "alt\n")
    }

    /// Özellik 3: ⌘C öğeleri dosya olarak panoya koyar; ⌘V panodaki dosyaları eklemeyi önerir.
    @Test func copyAndPasteFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("pano.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ArhivarTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        model.copyItems(["kaynak/not.txt", "kaynak/alt"], to: pasteboard)
        await fixture.settle()
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        #expect(urls.map(\.lastPathComponent) == ["not.txt", "alt"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "merhaba\n")

        let extra = fixture.workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)
        pasteboard.clearContents()
        pasteboard.writeObjects([extra as NSURL])
        model.pasteFiles(from: pasteboard)
        #expect(model.addRequest?.sources == [extra])
    }

    /// Özellik 4: .tar.gz tek adımda oluşur; geçici tar kalmaz.
    @Test func createsTarGzInOneStep() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let destination = fixture.workspace.appendingPathComponent("yedek.tar.gz")
        fixture.model.createArchive(CreateOptions(sources: [fixture.workspace.appendingPathComponent("kaynak")], destination: destination, format: .tarGzip, level: .normal))
        await fixture.settle()
        #expect(fixture.model.alert == nil)
        #expect(fixture.model.recentArchives.first == destination)
        #expect(!fixture.exists("yedek.tar"))

        fixture.model.openArchive(destination)
        await fixture.settle()
        #expect(fixture.model.node("yedek.tar") != nil)
    }

    /// Özellik 5: arşivin içindeki arşive girilir, yol çubuğundan/⌘↑ ile geri dönülür; geçici dosyalar temizlenir.
    @Test func browsesNestedArchives() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let inner = try await fixture.makeArchive("ic.zip", format: .zip)
        let outer = fixture.workspace.appendingPathComponent("dis.7z")
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(CreateOptions(sources: [inner], destination: outer, format: .sevenZip, level: .fast))))
        let model = fixture.model
        model.browserMode = .folders
        model.openArchive(outer)
        await fixture.settle()
        #expect(model.isEditable)

        model.primaryAction(["ic.zip"])
        await fixture.settle()
        #expect(model.archiveURL?.lastPathComponent == "ic.zip")
        #expect(model.archiveStack.map(\.url) == [outer])
        #expect(model.rootArchiveURL == outer)
        #expect(!model.isEditable)
        #expect(model.displayNodes.map(\.id) == ["kaynak"])
        let nestedFile = try #require(model.archiveURL)

        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        let preview = try #require(model.quickLookURL)
        model.quickLookURL = nil

        #expect(model.canGoUp)
        model.goUp()
        #expect(model.archiveURL == outer)
        #expect(model.archiveStack.isEmpty)
        #expect(model.isEditable)
        #expect(model.node("ic.zip") != nil)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        #expect(FileManager.default.fileExists(atPath: nestedFile.path))

        model.closeArchive()
        #expect(!FileManager.default.fileExists(atPath: nestedFile.path))
    }

    /// Çıkışta (⌘Q) iç içe gezinmedeki tüm geçici klasörler silinir: iç arşivin kopyası ve üstteki arşivin önizlemeleri dahil.
    @Test func quittingInsideNestedArchiveRemovesAllSessions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let inner = try await fixture.makeArchive("ic.zip", format: .zip)
        let outer = fixture.workspace.appendingPathComponent("dis.7z")
        let options = CreateOptions(sources: [inner, fixture.workspace.appendingPathComponent("kaynak")], destination: outer, format: .sevenZip, level: .fast)
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(options)))
        let model = fixture.model
        model.browserMode = .folders
        model.openArchive(outer)
        await fixture.settle()

        // Üstteki arşivde bir önizleme, sonra iç arşive giriş ve orada bir önizleme.
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        let outerPreview = try #require(model.quickLookURL)
        model.quickLookURL = nil
        model.primaryAction(["ic.zip"])
        await fixture.settle()
        let nestedCopy = try #require(model.archiveURL)
        #expect(model.archiveStack.count == 1)
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        let innerPreview = try #require(model.quickLookURL)
        for file in [outerPreview, nestedCopy, innerPreview] {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }

        model.discardTemporaryFiles()
        for file in [outerPreview, nestedCopy, innerPreview] {
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
        }
        #expect(model.archiveStack.isEmpty)
    }

    /// Model doğrudan çağrıldığında da aynı adlı kaynaklar 7zz'ye verilmeden anlaşılır bir iletiyle reddedilir.
    @Test func createArchiveRejectsDuplicateNames() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let other = fixture.workspace.appendingPathComponent("baska", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "x".write(to: other.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)
        let destination = fixture.workspace.appendingPathComponent("ayni.zip")

        fixture.model.createArchive(CreateOptions(
            sources: [fixture.workspace.appendingPathComponent("kaynak/not.txt"), other.appendingPathComponent("not.txt")],
            destination: destination, format: .zip, level: .fast
        ))
        await fixture.settle()
        #expect(fixture.model.alert?.message == fixture.settings.t(.duplicateNames, "not.txt"))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(fixture.model.recentArchives.isEmpty)
    }

    /// Özellik 6: sağlama değerleri uyarıda gösterilir.
    @Test func showsChecksums() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("sagla.7z", format: .sevenZip)
        fixture.model.openArchive(archive)
        await fixture.settle()
        fixture.model.showChecksums("kaynak/not.txt")
        await fixture.settle()
        let expected = SHA256.hash(data: Data("merhaba\n".utf8)).map { String(format: "%02x", $0) }.joined()
        let message = try #require(fixture.model.alert?.message)
        #expect(message.lowercased().contains("sha256: " + expected))
        #expect(message.contains("CRC32: "))
    }

    // MARK: - .agents/context/roadmap.md: 13 açık madde

    /// P1-10 / P2-13: işlem sürerken ⇧⌘W arşivi kapatmaz (işlem bitince geri gelirdi); bırakılan dosyalar yok sayılır.
    @Test func closeAndDropWaitForTheRunningOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("islem.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        model.testArchive()
        #expect(model.operation != nil)
        model.closeArchive()
        model.handleDrop([fixture.workspace.appendingPathComponent("kaynak/not.txt")])
        #expect(model.addRequest == nil)
        #expect(model.createRequest == nil)
        await fixture.settle()
        #expect(model.archiveURL == archive)
        #expect(model.listing != nil)
        model.closeArchive()
        #expect(model.archiveURL == nil)
    }

    /// P1-10: motor denetlenirken iptal edilen işlem, denetim bitince başlamaz.
    @Test func cancellingWhileTheEngineIsCheckedStopsTheOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let archive = try await fixture.makeArchive("soguk.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        #expect(model.operation?.titleKey == .progressPreparing)
        model.cancelOperation()
        await fixture.settle()
        #expect(model.archiveURL == nil)
        #expect(model.alert == nil)
    }

    /// P1-9: ağaç görünümünde iç arşive girilince yol çubuğu ve ⌘↑ üstteki arşive döndürür; klasörde Return girer.
    @Test func treeViewKeepsTheWayBackFromNestedArchives() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let inner = try await fixture.makeArchive("ic.zip", format: .zip)
        let outer = fixture.workspace.appendingPathComponent("dis.7z")
        let options = CreateOptions(sources: [inner, fixture.workspace.appendingPathComponent("kaynak")], destination: outer, format: .sevenZip, level: .fast)
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(options)))
        let model = fixture.model
        model.browserMode = .tree
        model.openArchive(outer)
        await fixture.settle()
        #expect(!model.showsPathBar)
        #expect(!model.canGoUp)

        model.primaryAction(["ic.zip"])
        await fixture.settle()
        #expect(model.archiveStack.map(\.url) == [outer])
        #expect(model.browserMode == .tree)
        #expect(model.showsPathBar)
        #expect(model.canGoUp)
        model.searchText = "not"
        #expect(model.showsPathBar)
        model.goUp()
        #expect(model.archiveURL == outer)
        #expect(model.archiveStack.isEmpty)

        // Ağaç görünümünde klasörde Return / ⌘↓: klasör görünümüne geçip klasöre girer.
        model.primaryAction(["kaynak"])
        #expect(model.browserMode == .folders)
        #expect(model.currentFolder == "kaynak")
    }

    /// P2-12: iç arşivdeyken kenar çubuğunda kök arşive tıklamak onu diskten yeniden okumaz; parolası korunur.
    @Test func reopeningTheRootArchiveReturnsWithItsPassword() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let inner = try await fixture.makeArchive("ic.zip", format: .zip)
        let outer = fixture.workspace.appendingPathComponent("sifreli.7z")
        let options = CreateOptions(
            sources: [inner, fixture.workspace.appendingPathComponent("kaynak")], destination: outer, format: .sevenZip, level: .fast,
            password: "p", encryptFileNames: false
        )
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(options), input: options.input))
        let model = fixture.model
        model.openArchive(outer)
        await fixture.settle()
        model.primaryAction(["ic.zip"])
        await fixture.settle()
        model.submitPassword("p")
        await fixture.settle()
        #expect(model.rootArchiveURL == outer)
        #expect(model.archiveStack.count == 1)

        model.openArchive(outer)
        #expect(model.operation == nil)
        #expect(model.archiveURL == outer)
        #expect(model.archiveStack.isEmpty)
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        #expect(model.passwordRequest == nil)
        #expect(model.quickLookURL?.lastPathComponent == "not.txt")
    }

    /// P2-13: bağlam menüsünden başka bir öğe için Hızlı Bakış önizlemeyi o öğeye geçirir; aynı öğe kapatır.
    /// Liste yeniden okunurken tablo verisi bir kez hesaplanır.
    @Test func quickLookSwitchesItemsAndDisplayIsRebuiltOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("bakis.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        #expect(model.quickLookURL?.lastPathComponent == "not.txt")
        model.toggleQuickLook("kaynak/alt/b.txt")
        await fixture.settle()
        #expect(model.quickLookURL?.lastPathComponent == "b.txt")
        model.toggleQuickLook("kaynak/alt/b.txt")
        #expect(model.quickLookURL == nil)

        let before = model.displayRebuildCount
        model.openArchive(archive)
        await fixture.settle()
        #expect(model.displayRebuildCount - before == 1)
    }

    /// Arka arkaya hızlıca Cmd+Y / Boşluk yapıldığında (ör. 5 kez üst üste) çökmeden açılıp kapanmalıdır.
    @Test func quickLookRapidTogglesDoNotCrash() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("rapid.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        // 1. Aç (not.txt)
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        #expect(model.quickLookURL?.lastPathComponent == "not.txt")

        // 2. Kapat
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        #expect(model.quickLookURL == nil)

        // 3. Yeniden Aç (Cmd+Y 3. kez basılmış gibi)
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        #expect(model.quickLookURL?.lastPathComponent == "not.txt")

        // 4. Kapat
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        #expect(model.quickLookURL == nil)

        // 5. Yeniden Aç
        model.toggleQuickLook("kaynak/not.txt")
        await fixture.settle()
        #expect(model.quickLookURL?.lastPathComponent == "not.txt")

        // 6. Parametresiz kapat
        model.toggleQuickLook()
        #expect(model.quickLookURL == nil)
    }

    /// Hızlı Bakış açıkken ok tuşlarıyla başka bir dosyaya geçildiğinde önizleme yeni dosyaya geçer.
    @Test func quickLookSwitchesPreviewOnSelectionChange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("switch.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        model.selection = ["kaynak/not.txt"]
        model.toggleQuickLook()
        await fixture.settle()
        #expect(model.quickLookURL?.lastPathComponent == "not.txt")

        // Ok tuşuyla alt klasördeki b.txt dosyasına geçildiğinde
        model.selection = ["kaynak/alt/b.txt"]
        await fixture.settle()
        #expect(model.quickLookURL?.lastPathComponent == "b.txt")

        // Boşluk basıldığında kapanır
        model.toggleQuickLook()
        #expect(model.quickLookURL == nil)
    }

    /// P1-7: aynı klasördeki bir öğenin adına (büyük/küçük harf duyarsız) yeniden adlandırılmaz.
    @Test func renameRejectsSiblingNames() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("ad.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        #expect(model.renameConflicts("kaynak/not.txt", to: "alt"))
        #expect(model.renameConflicts("kaynak/not.txt", to: " ALT "))
        #expect(!model.renameConflicts("kaynak/not.txt", to: "NOT.txt"))
        #expect(!model.renameConflicts("kaynak/not.txt", to: "yeni.txt"))
        model.rename("kaynak/not.txt", to: "alt")
        #expect(model.operation == nil)
        #expect(model.alert?.message == fixture.settings.t(.renameExists, "alt"))
        #expect(model.node("kaynak/not.txt") != nil)
    }

    /// P0-3: var olan arşivin yerine yenisi konur (eklenmez); gz ve adları şifreli 7z'nin üzerine de yazılır.
    @Test func creatingReplacesAnExistingArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let model = fixture.model
        let extra = fixture.workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)

        for (name, format, password) in [("a.zip", ArchiveFormat.zip, nil), ("b.7z", .sevenZip, "p"), ("c.tar.gz", .tarGzip, nil)] as [(String, ArchiveFormat, String?)] {
            let archive = try await fixture.makeArchive(name, format: format, password: password, encryptNames: password != nil)
            model.createArchive(CreateOptions(sources: [extra], destination: archive, format: format, level: .fast))
            await fixture.settle()
            #expect(model.alert == nil, "\(name)")
            #expect(model.passwordRequest == nil, "\(name)")
            model.openArchive(archive)
            await fixture.settle()
            let expected = format == .tarGzip ? ["c.tar"] : ["ek.txt"]
            #expect(model.tree.map(\.id) == expected, "\(name)")
        }
        let gzip = fixture.workspace.appendingPathComponent("tek.txt.gz")
        for _ in 0..<2 {
            model.createArchive(CreateOptions(sources: [extra], destination: gzip, format: .gzip, level: .fast))
            await fixture.settle()
            #expect(model.alert == nil)
        }
    }

    /// P0-3: bölünmüş arşiv yeniden oluşturulunca eski parçaların fazlası kalmaz.
    @Test func creatingASplitArchiveRemovesStaleVolumes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let source = fixture.workspace.appendingPathComponent("rastgele.bin")
        var bytes = [UInt8](repeating: 0, count: 2_500_000)
        arc4random_buf(&bytes, bytes.count)
        try Data(bytes).write(to: source)
        let destination = fixture.workspace.appendingPathComponent("parca.7z")
        for index in 1...6 {
            try "eski".write(to: destination.appendingPathExtension(String(format: "%03d", index)), atomically: true, encoding: .utf8)
        }
        fixture.model.createArchive(CreateOptions(sources: [source], destination: destination, format: .sevenZip, level: .store, volumeSizeMB: 1))
        await fixture.settle()
        #expect(fixture.model.alert == nil)
        let volumes = try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).filter { $0.hasPrefix("parca.7z.") }.sorted()
        #expect(volumes == ["parca.7z.001", "parca.7z.002", "parca.7z.003"])
        #expect(fixture.model.recentArchives.first == destination.appendingPathExtension("001"))
    }

    /// P0-6: FIFO içeren klasörler oluşturma ve eklemede 7zz'yi kilitlemez; FIFO arşive girmez.
    @Test func fifosAreSkippedWhenCreatingAndAdding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        #expect(mkfifo(fixture.workspace.appendingPathComponent("kaynak/alt/boru").path, 0o644) == 0)
        let model = fixture.model
        let archive = fixture.workspace.appendingPathComponent("boru.zip")
        model.createArchive(CreateOptions(sources: [fixture.workspace.appendingPathComponent("kaynak")], destination: archive, format: .zip, level: .fast))
        await fixture.settle()
        #expect(model.alert == nil)
        model.openArchive(archive)
        await fixture.settle()
        #expect(model.node("kaynak/alt/b.txt") != nil)
        #expect(model.node("kaynak/alt/boru") == nil)

        let folder = fixture.workspace.appendingPathComponent("ekler", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "e".write(to: folder.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
        #expect(mkfifo(folder.appendingPathComponent("boru2").path, 0o644) == 0)
        model.addFiles([folder], into: "kaynak")
        await fixture.settle()
        #expect(model.alert == nil)
        model.addFiles([folder], into: "")
        await fixture.settle()
        #expect(model.alert == nil)
        #expect(model.node("kaynak/ekler/e.txt") != nil)
        #expect(model.node("ekler/e.txt") != nil)
        #expect(model.node("ekler/boru2") == nil)
    }

    /// P0-2: 7zz'nin reddettiği bağlantının 0 baytlık yer tutucusu hedefteki dosyayı ezmez; alt klasörden
    /// çıkarılan öğelerle mutlak bağlantılar hedefin dışını göstermez.
    @Test func extractionDropsLinkPlaceholdersAndEscapingLinks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let source = fixture.workspace.appendingPathComponent("kaynak")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("kotu").path, withDestinationPath: "../disari")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("alt/mutlak").path, withDestinationPath: "/etc/hosts")
        let archive = try await fixture.makeArchive("bag.zip", format: .zip)
        let model = fixture.model
        fixture.settings.subfolderMode = .never
        fixture.settings.overwriteMode = .replace
        let output = fixture.useExtractFolder()
        try FileManager.default.createDirectory(at: output.appendingPathComponent("kaynak"), withIntermediateDirectories: true)
        try "koru".write(to: output.appendingPathComponent("kaynak/kotu"), atomically: true, encoding: .utf8)
        model.openArchive(archive)
        await fixture.settle()

        model.extract(items: [])
        await fixture.settle()
        #expect(try String(contentsOf: output.appendingPathComponent("kaynak/kotu"), encoding: .utf8) == "koru")
        #expect(model.alert?.title == fixture.settings.t(.warningTitle))
        model.alert = nil

        let second = fixture.useExtractFolder("cikti2")
        model.browserMode = .folders
        model.enterFolder("kaynak/alt")
        model.extract(items: ["kaynak/alt/b.txt", "kaynak/alt/mutlak"])
        await fixture.settle()
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("b.txt").path))
        #expect(StagedExtraction.itemType(second.appendingPathComponent("mutlak"), fileManager: .default) == nil)
        // Ayıklanan bağlantı uyarıyla bildirilir (testte metinler yerelleştirilmez; yalnızca uyarının varlığı denetlenir).
        #expect(model.alert?.title == fixture.settings.t(.warningTitle))
    }

    /// P0-4: salt okunur ve yalnızca çalıştırılabilir dosyalar karantina işaretini taşır; "üzerine yaz" ile ikinci
    /// çıkarma salt okunur dosyalarda takılmaz.
    @Test func readOnlyFilesKeepQuarantineAndCanBeReplaced() async throws {
        let fixture = try Fixture()
        defer {
            StagedExtraction.removeTree(at: fixture.workspace)
            fixture.cleanUp()
        }
        await fixture.model.refreshEngine()
        let script = fixture.workspace.appendingPathComponent("kaynak/calis.command")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o555)
        let readOnly = fixture.workspace.appendingPathComponent("kaynak/salt.txt")
        try "salt".write(to: readOnly, atomically: true, encoding: .utf8)
        chmod(readOnly.path, 0o444)
        let archive = try await fixture.makeArchive("indirilen.7z", format: .sevenZip)
        let value = "0083;6ad350b0;Safari;"
        #expect(setxattr(archive.path, "com.apple.quarantine", Array(value.utf8), value.utf8.count, 0, 0) == 0)
        fixture.settings.subfolderMode = .never
        fixture.settings.overwriteMode = .replace
        let output = fixture.useExtractFolder()
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        for _ in 0..<2 {
            model.extract(items: [])
            await fixture.settle()
            #expect(model.alert == nil)
        }
        let extracted = output.appendingPathComponent("kaynak/calis.command")
        let permissions = (try FileManager.default.attributesOfItem(atPath: extracted.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(permissions == 0o555)
        #expect(Quarantine.value(of: extracted) == value)
        #expect(Quarantine.value(of: output.appendingPathComponent("kaynak/salt.txt")) == value)
    }

    // MARK: - .agents/context/roadmap.md: üçüncü tur

    /// R3-2: tek başına bağlantılar sürüklenmez; ⌘A + ⌘C kalanları kopyalar; açma, Hızlı Bakış ve sağlama değeri
    /// "kod 0" hatası yerine nedenini söyler.
    @Test func symbolicLinkRowsAreSkippedOrExplained() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        try FileManager.default.createSymbolicLink(
            atPath: fixture.workspace.appendingPathComponent("kaynak/iyi").path, withDestinationPath: "not.txt"
        )
        let archive = try await fixture.makeArchive("bag.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        let refusal = fixture.settings.t(.symbolicLinkItem, "iyi")

        #expect(model.isSymbolicLink("kaynak/iyi"))
        #expect(model.dragItem(for: try #require(model.node("kaynak/iyi"))) == nil)
        #expect(model.dragItem(for: try #require(model.node("kaynak/not.txt"))) != nil)
        model.selection = ["kaynak/iyi"]
        #expect(model.selectionIsSymbolicLink)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ArhivarTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        model.copyItems(["kaynak/alt", "kaynak/iyi", "kaynak/not.txt"], to: pasteboard)
        await fixture.settle()
        #expect(model.alert == nil)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        #expect(urls.map(\.lastPathComponent) == ["alt", "not.txt"])

        model.copyItems(["kaynak/iyi"], to: pasteboard)
        #expect(model.operation == nil)
        #expect(model.alert?.message == refusal)
        model.alert = nil
        model.openItem("kaynak/iyi")
        #expect(model.operation == nil)
        #expect(model.alert?.message == refusal)
        model.alert = nil
        model.toggleQuickLook("kaynak/iyi")
        #expect(model.operation == nil)
        #expect(model.quickLookURL == nil)
        #expect(model.alert?.message == refusal)
        model.alert = nil
        model.showChecksums("kaynak/iyi")
        #expect(model.operation == nil)
        #expect(model.alert?.message == refusal)
    }

    /// R3-3: yalnızca FIFO seçildiyse ekleme ve oluşturma 7zz'yi çalıştırmaz (boş ad listesi tüm klasörü eklerdi).
    @Test func onlySpecialFilesAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let pipe = fixture.workspace.appendingPathComponent("boru")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        let archive = try await fixture.makeArchive("ozel.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        let before = model.tree.map(\.id)

        model.addFiles([pipe])
        await fixture.settle()
        #expect(model.alert?.message == fixture.settings.t(.nothingToArchive))
        #expect(model.tree.map(\.id) == before)
        model.alert = nil

        let destination = fixture.workspace.appendingPathComponent("bos.zip")
        model.createArchive(CreateOptions(sources: [pipe], destination: destination, format: .zip, level: .fast))
        await fixture.settle()
        #expect(model.alert?.message == fixture.settings.t(.nothingToArchive))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// R3-4: işlem sürerken yeni arşiv sayfası açılmaz (içindeki "Oluştur" sessizce yok sayılırdı).
    @Test func newArchiveWaitsForTheRunningOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("bekle.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        model.testArchive()
        #expect(model.operation != nil)
        model.beginCreate()
        #expect(model.createRequest == nil)
        await fixture.settle()
        model.beginCreate()
        #expect(model.createRequest != nil)
    }

    // MARK: - .agents/context/roadmap.md: dördüncü tur

    /// R4-2: açık ve kilidi açılmış şifreli arşiv "Buraya Çıkar" ile çıkarılırken parolası yeniden sorulmaz, silinmez.
    @Test func extractHereReusesTheOpenArchivePassword() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let secret = try await fixture.makeArchive("gizli.7z", format: .sevenZip, password: "p4ss", encryptNames: true)
        let model = fixture.model
        model.openArchive(secret)
        await fixture.settle()
        model.submitPassword("p4ss")
        await fixture.settle()
        #expect(model.archiveURL == secret)

        model.extractHere([secret])
        // Süre sınırı: parola yeniden sorulursa kuyruk yanıt bekler; test sonsuza dek beklemesin.
        for _ in 0..<200 where model.serviceQueueTask != nil && model.passwordRequest == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let askedAgain = model.passwordRequest != nil
        if askedAgain { model.cancelPasswordRequest() }
        await model.serviceQueueTask?.value
        #expect(!askedAgain)
        #expect(model.alert == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("gizli/kaynak/not.txt").path))
        // Parola hâlâ biliniyor: test işlemi yeniden sormaz.
        model.testArchive()
        await fixture.settle()
        #expect(model.passwordRequest == nil)
        #expect(model.alert == nil)
    }

    // MARK: - .agents/context/roadmap.md: beşinci tur

    /// R5-1: hedefte arşivle aynı adlı bir klasör varsa 7zz çalıştırılmadan anlaşılır bir iletiyle reddedilir; klasöre dokunulmaz.
    @Test func creatingOverAFolderIsRefusedUpFront() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let folder = fixture.workspace.appendingPathComponent("proje.zip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "icerik".write(to: folder.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)

        fixture.model.createArchive(CreateOptions(sources: [fixture.workspace.appendingPathComponent("kaynak")], destination: folder, format: .zip, level: .fast))
        await fixture.settle()
        #expect(fixture.model.alert?.message == fixture.settings.t(.renameExists, "proje.zip"))
        #expect(try String(contentsOf: folder.appendingPathComponent("not.txt"), encoding: .utf8) == "icerik")
        #expect(fixture.model.recentArchives.isEmpty)
    }

    /// R5-2: salt okunur (0444) arşiv düzenlenemez: ekle, sil ve yeniden adlandır kapalıdır, nedeni söylenir,
    /// pencereye bırakılan dosyalar eklemeyi değil yeni arşivi önerir.
    @Test func readOnlyArchiveIsNotOfferedForEditing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("salt.7z", format: .sevenZip)
        chmod(archive.path, 0o444)
        defer { chmod(archive.path, 0o644) }
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        #expect(model.listing != nil)
        #expect(!model.isEditable)
        #expect(model.readOnlyReason == .readOnlyLocation)
        model.handleDrop([fixture.workspace.appendingPathComponent("kaynak/not.txt")])
        #expect(model.addRequest == nil)
        #expect(model.createRequest != nil)
    }

    /// Bölünmüş ZIP tespiti: ".z64" gibi bir dosya bırakılınca arşiv olarak açılmaya çalışılmaz, yeni arşiv önerilir.
    @Test func droppingAZipLikeRomOffersANewArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let rom = fixture.workspace.appendingPathComponent("oyun.z64")
        try Data("rom".utf8).write(to: rom)

        fixture.model.handleDrop([rom])
        #expect(fixture.model.operation == nil)
        #expect(fixture.model.createRequest?.sources == [rom])
    }

    /// Akıllı kip, Finder'ın "Sıkıştır" ile yaptığı tek klasörlü arşivi doğrudan hedefe çıkarırken yanındaki macOS üst
    /// verisini taşımaz: hedefe "__MACOSX" dağılmaz, hedef klasörün kendi ".DS_Store"u arşivinkiyle ezilmez.
    @Test func smartExtractionLeavesFinderMetadataOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let source = fixture.workspace.appendingPathComponent("finder", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Proje"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("__MACOSX/Proje"), withIntermediateDirectories: true)
        try "a".write(to: source.appendingPathComponent("Proje/a.txt"), atomically: true, encoding: .utf8)
        try "ad".write(to: source.appendingPathComponent("__MACOSX/Proje/._a.txt"), atomically: true, encoding: .utf8)
        try "arsiv".write(to: source.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let archive = fixture.workspace.appendingPathComponent("Proje.zip")
        let options = CreateOptions(
            sources: ["Proje", "__MACOSX", ".DS_Store"].map { source.appendingPathComponent($0) }, destination: archive, format: .zip, level: .fast
        )
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(options)))
        let output = fixture.useExtractFolder()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "kullanici".write(to: output.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        fixture.settings.subfolderMode = .smart
        fixture.settings.overwriteMode = .replace

        fixture.model.openArchive(archive)
        await fixture.settle()
        fixture.model.extract(items: [])
        await fixture.settle()
        #expect(fixture.model.alert == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == [".DS_Store", "Proje"])
        #expect(try String(contentsOf: output.appendingPathComponent(".DS_Store"), encoding: .utf8) == "kullanici")
        #expect(try String(contentsOf: output.appendingPathComponent("Proje/a.txt"), encoding: .utf8) == "a")
        #expect(fixture.model.toast?.revealURL?.lastPathComponent == "Proje")
        #expect(fixture.model.toast?.message == fixture.settings.t(.toastExtracted, "Proje"))
    }

    /// "._" ile başlayan sıradan dosyalar (ör. "._config") arşivden çıkarılırken sessizce düşmez ve karantina işaretini alır.
    @Test func dotUnderscoreFilesAreExtractedAndQuarantined() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let source = fixture.workspace.appendingPathComponent("ad", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Proje"), withIntermediateDirectories: true)
        try "kok".write(to: source.appendingPathComponent("._config"), atomically: false, encoding: .utf8)
        try "ic".write(to: source.appendingPathComponent("Proje/._notlar"), atomically: false, encoding: .utf8)
        let archive = fixture.workspace.appendingPathComponent("Ayarlar.zip")
        let options = CreateOptions(
            sources: ["._config", "Proje"].map { source.appendingPathComponent($0) }, destination: archive, format: .zip, level: .fast
        )
        try SevenZipError.check(try await fixture.runner.run(SevenZipCommand.create(options)))
        let mark = "0083;6ad350b0;Safari;"
        #expect(setxattr(archive.path, "com.apple.quarantine", Array(mark.utf8), mark.utf8.count, 0, 0) == 0)
        let output = fixture.useExtractFolder()

        fixture.model.openArchive(archive)
        await fixture.settle()
        #expect(fixture.model.node("._config") != nil)
        fixture.model.extract(items: [])
        await fixture.settle()
        #expect(fixture.model.alert == nil)
        let extracted = output.appendingPathComponent("Ayarlar")
        #expect(try String(contentsOf: extracted.appendingPathComponent("._config"), encoding: .utf8) == "kok")
        #expect(try String(contentsOf: extracted.appendingPathComponent("Proje/._notlar"), encoding: .utf8) == "ic")
        #expect(Quarantine.value(of: extracted.appendingPathComponent("._config")) == mark)
    }

    /// Seçilen öğe 7zz tarafından eşleştirilemezse (listede yok, ya da adında satır sonu var) 7zz 0 ile biter ama hiçbir
    /// şey çıkmaz; "çıkarıldı" denmez, hata gösterilir.
    @Test func extractingAMissingItemIsAnErrorNotASuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("eksik.7z", format: .sevenZip)
        let output = fixture.useExtractFolder()
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()

        model.extract(items: ["yok.txt"])
        await fixture.settle()
        #expect(model.alert != nil)
        #expect(model.toast == nil)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("yok.txt").path))
    }

    /// Sembolik bağlantı üzerinden açılan arşiv gerçek dosyasıyla açılır; ekleme gerçek arşive gider, bağlantı bozulmaz.
    @Test func editingASymlinkedArchiveUpdatesTheRealFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let real = try await fixture.makeArchive("gercek.7z", format: .sevenZip)
        let linkDir = fixture.workspace.appendingPathComponent("baglar", isDirectory: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appendingPathComponent("kisayol.7z")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let extra = fixture.workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)
        let model = fixture.model

        model.openArchive(link)
        await fixture.settle()
        #expect(model.archiveURL?.lastPathComponent == "gercek.7z")
        model.addFiles([extra])
        await fixture.settle()
        #expect(model.alert == nil)
        #expect(model.node("ek.txt") != nil)
        #expect(StagedExtraction.itemType(link) == .typeSymbolicLink)
        #expect(try FileManager.default.contentsOfDirectory(atPath: linkDir.path) == ["kisayol.7z"]) // yanında .tmp yok
    }

    /// Bir arşiv için açılan parola isteği, bu arada başka bir arşiv açılırsa ona uygulanmaz.
    @Test func passwordRequestForAnotherArchiveIsNotAppliedToTheOpenOne() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let secret = try await fixture.makeArchive("gizli.7z", format: .sevenZip, password: "p", encryptNames: false)
        let plain = try await fixture.makeArchive("acik.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(secret)
        await fixture.settle()
        model.toggleQuickLook("kaynak/not.txt")
        #expect(model.passwordRequest?.archive == secret)

        model.openArchive(plain)
        await fixture.settle()
        #expect(model.archiveURL == plain)
        #expect(model.passwordRequest == nil) // eski istek düştü
        model.submitPassword("p")
        await fixture.settle()
        #expect(model.quickLookURL == nil && model.operation == nil)
    }

    /// "Buraya Çıkar" kuyruğunun baş öğesi beklerken iptal edilirse o da çıkarılmaz.
    @Test func serviceQueueHeadIsDroppedByCancel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let open = try await fixture.makeArchive("acik.7z", format: .sevenZip)
        let queued = try await fixture.makeArchive("sirada.zip", format: .zip)
        let model = fixture.model
        model.openArchive(open)
        await fixture.settle()

        model.testArchive()
        #expect(model.operation != nil)
        model.extractHere([queued])
        model.cancelOperation()
        await model.serviceQueueTask?.value
        await fixture.settle()
        #expect(!fixture.exists("sirada"))
    }

    /// Yerinde düzenleme (7zz arşivi yeni bir inode olarak yazar) karantina işaretini, Finder etiketlerini ve kipi korur.
    @Test func inPlaceEditKeepsQuarantineTagsAndMode() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("indirilen.zip", format: .zip)
        let quarantine = Array("0083;68f1a2b3;Safari;0A1B2C3D-0000-4000-8000-000000000000".utf8)
        #expect(setxattr(archive.path, "com.apple.quarantine", quarantine, quarantine.count, 0, XATTR_NOFOLLOW) == 0)
        let tags = Array("bplist00-etiketler".utf8)
        #expect(setxattr(archive.path, "com.apple.metadata:_kMDItemUserTags", tags, tags.count, 0, XATTR_NOFOLLOW) == 0)
        #expect(chmod(archive.path, 0o600) == 0)
        var before = stat()
        #expect(stat(archive.path, &before) == 0)
        let extra = fixture.workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        model.addFiles([extra])
        await fixture.settle()
        #expect(model.alert == nil && model.node("ek.txt") != nil)

        var after = stat()
        #expect(stat(archive.path, &after) == 0)
        #expect(after.st_ino != before.st_ino) // 7zz 26.04 arşivi değiştirir; korunma bu yüzden gerekir
        #expect(Quarantine.value(of: archive) == String(decoding: quarantine, as: UTF8.self))
        #expect(after.st_mode & 0o7777 == 0o600)
        var buffer = [UInt8](repeating: 0, count: 64)
        let read = getxattr(archive.path, "com.apple.metadata:_kMDItemUserTags", &buffer, 64, 0, XATTR_NOFOLLOW)
        #expect(read == tags.count && Array(buffer.prefix(max(0, read))) == tags)
    }

    /// Düzenlemeden sonraki yeniden listeleme iptal edilemez: iptal edilmiş bir görevde bile liste yenilenir.
    @Test func relistAfterAnEditIsNotCancellable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("yeniden.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        let engine = try #require(model.engineURL)
        let task = Task { @MainActor in
            try await model.relistAfterEdit(of: archive, runner: CommandRunner(executableURL: engine), password: nil)
        }
        task.cancel()
        try await task.value
        #expect(model.archiveURL == archive && model.listing != nil)
    }

    /// Yazma diske işlendi ama liste okunamıyorsa eski liste gösterilmez; arşiv kapanır ve hata fırlatılır.
    @Test func relistFailureAfterAnEditClosesTheArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let archive = try await fixture.makeArchive("bozuk-liste.7z", format: .sevenZip)
        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        // 7zz'de çıkış kodu 1 yalnızca uyarıdır; listeleme gerçekten başarısız olmalı (motor yok).
        let failing = CommandRunner(executableURL: URL(fileURLWithPath: "/nonexistent/7zz-yok"))
        await #expect(throws: (any Error).self) {
            try await model.relistAfterEdit(of: archive, runner: failing, password: nil)
        }
        #expect(model.archiveURL == nil && model.listing == nil && model.tree.isEmpty)
    }

    /// Kapatılan arşive bağlı parola isteği (Hızlı Bakış için açılmış) arşivsiz bir sayfa olarak kalmaz.
    @Test func closingTheArchiveDropsItsPasswordRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()
        let secret = try await fixture.makeArchive("gizli.7z", format: .sevenZip, password: "p", encryptNames: false)
        let model = fixture.model
        model.openArchive(secret)
        await fixture.settle()
        model.toggleQuickLook("kaynak/not.txt")
        #expect(model.passwordRequest != nil)
        model.closeArchive()
        #expect(model.passwordRequest == nil && model.archiveURL == nil)
    }

    /// sandboxEngine ayarı açıkken AppModel.confined kum havuzunu bağlar; kapalıyken yalın runner döndürür.
    @Test func confinedWiresSandboxProfileWhenSettingIsOn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat"))
        let archive = fixture.workspace.appendingPathComponent("test.7z")

        fixture.model.settings.sandboxEngine = true
        let sandboxed = fixture.model.confined(runner, archive: archive)
        #expect(sandboxed.sandbox != nil)

        fixture.model.settings.sandboxEngine = false
        let plain = fixture.model.confined(runner, archive: archive)
        #expect(plain.sandbox == nil)
    }

    /// 1.000+ öğeli büyük arşivlerde arama ana thread'i dondurmaz; arka planda asenkron çalışır ve displayNodes'u günceller.
    @Test func asyncSearchForLargeArchiveRunsInBackgroundAndUpdatesDisplay() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.model.refreshEngine()

        let folder = fixture.workspace.appendingPathComponent("large_src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<1050 {
            try "veri".write(to: folder.appendingPathComponent(String(format: "file_%04d.txt", i)), atomically: true, encoding: .utf8)
        }
        let archive = fixture.workspace.appendingPathComponent("large.7z")
        let runner = CommandRunner(executableURL: try #require(fixture.model.engineURL))
        let options = CreateOptions(sources: [folder], destination: archive, format: .sevenZip, level: .fast)
        _ = try await runner.run(SevenZipCommand.create(options))

        let model = fixture.model
        model.openArchive(archive)
        await fixture.settle()
        #expect(model.tree.count > 0)

        // 1.000+ öğe varken arama başlat:
        model.searchText = "file_0500"
        #expect(model.isSearching)

        await fixture.settle()
        #expect(!model.isSearching)
        #expect(model.displayNodes.contains { $0.id.contains("file_0500.txt") })

        // Arama temizlenince anında senkron olarak döner:
        model.searchText = ""
        #expect(!model.isSearching)
        #expect(model.displayNodes.count > 0)
    }
}
