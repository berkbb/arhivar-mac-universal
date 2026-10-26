import Foundation
import Testing
@testable import ArhivarCore

/// Gerçek 7zz ile uçtan uca senaryolar. Vendor/7-Zip/7zz yoksa atlanır (ARHIVAR_7ZZ ile başka yol verilebilir).
private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ProcessInfo.processInfo.environment["ARHIVAR_7ZZ"],
        packageRoot.appendingPathComponent("Vendor/7-Zip/7zz").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

@Suite(.enabled(if: engineURL != nil, "7zz bulunamadı"), .serialized)
struct EngineIntegrationTests {
    let runner = CommandRunner(executableURL: engineURL ?? URL(fileURLWithPath: "/usr/bin/false"))
    let workspace: URL

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArhivarTests-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("kaynak/alt", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "merhaba dünya\n".write(to: workspace.appendingPathComponent("kaynak/not.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "veri ", count: 2000).write(to: source.appendingPathComponent("çok-büyük.txt"), atomically: true, encoding: .utf8)
    }

    @Test func encryptedSevenZipRoundTrip() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("test.7z")
        let create = CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: archive,
            format: .sevenZip, level: .maximum, password: "Gizli-123", encryptFileNames: true
        )
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(create), input: create.input))

        // Adlar şifreli olduğu için parolasız liste parola hatası vermeli.
        await #expect(throws: SevenZipError.wrongPassword) {
            try SevenZipError.check(try await runner.run(SevenZipCommand.list(archive: archive)))
        }
        await #expect(throws: SevenZipError.wrongPassword) {
            try SevenZipError.check(try await runner.run(SevenZipCommand.list(archive: archive), input: SevenZipCommand.passwordInput("yanlis")))
        }

        let result = try await runner.run(SevenZipCommand.list(archive: archive), input: SevenZipCommand.passwordInput("Gizli-123"))
        try SevenZipError.check(result)
        let listing = ListingParser.parse(result.stdout)
        #expect(listing.info.type == "7z")
        #expect(Set(listing.entries.map(\.path)) == ["kaynak", "kaynak/alt", "kaynak/not.txt", "kaynak/alt/çok-büyük.txt"])
        #expect(listing.entries.contains { $0.isEncrypted })

        try SevenZipError.check(try await runner.run(SevenZipCommand.test(archive: archive), input: SevenZipCommand.passwordInput("Gizli-123")))

        // Yalnızca seçili klasör çıkarılır.
        let output = workspace.appendingPathComponent("cikti", isDirectory: true)
        let progress = ProgressBox()
        let extract = ExtractOptions(archive: archive, destination: output, items: ["kaynak/alt"], password: "Gizli-123", overwrite: .replace)
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(extract), input: extract.input) { progress.last = $0 })
        let extracted = output.appendingPathComponent("kaynak/alt/çok-büyük.txt")
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("kaynak/not.txt").path))
    }

    @Test func zipCreateAndExtractAll() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("test.zip")
        let create = CreateOptions(sources: [workspace.appendingPathComponent("kaynak/not.txt")], destination: archive, format: .zip, level: .fast)
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(create)))

        let output = workspace.appendingPathComponent("zip-cikti", isDirectory: true)
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(
            ExtractOptions(archive: archive, destination: output, overwrite: .rename)
        )))
        let text = try String(contentsOf: output.appendingPathComponent("not.txt"), encoding: .utf8)
        #expect(text == "merhaba dünya\n")

        // İkinci çıkarma "ikisini de sakla" ile yeni adla yazmalı.
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(
            ExtractOptions(archive: archive, destination: output, overwrite: .rename)
        )))
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
        #expect(names.count == 2)
    }

    @Test func rejectsNonArchive() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let notArchive = workspace.appendingPathComponent("kaynak/not.txt")
        await #expect(throws: SevenZipError.notArchive) {
            try SevenZipError.check(try await runner.run(SevenZipCommand.list(archive: notArchive)))
        }
    }


    @Test func editsArchiveInPlace() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("duzenle.7z")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: archive, format: .sevenZip, level: .fast
        ))))

        // Alt klasöre ekleme.
        let extra = workspace.appendingPathComponent("ek.txt")
        try "ek".write(to: extra, atomically: true, encoding: .utf8)
        let plan = try AddPlan.make(sources: [extra], into: "kaynak/alt", stagingRoot: workspace.appendingPathComponent("staging"))
        try SevenZipError.check(try await runner.run(
            SevenZipCommand.add(archive: archive, names: plan.names), workingDirectory: plan.workingDirectory
        ))
        var paths = try await listPaths(archive)
        #expect(paths.contains("kaynak/alt/ek.txt"))

        // Klasörü yeniden adlandırma alt öğeleri de taşır.
        try SevenZipError.check(try await runner.run(SevenZipCommand.rename(archive: archive, from: "kaynak/alt", to: "kaynak/yeni")))
        paths = try await listPaths(archive)
        #expect(paths.contains("kaynak/yeni/ek.txt"))
        #expect(!paths.contains { $0.hasPrefix("kaynak/alt") })

        // Silme.
        try SevenZipError.check(try await runner.run(SevenZipCommand.delete(archive: archive, items: ["kaynak/yeni"])))
        paths = try await listPaths(archive)
        #expect(paths == ["kaynak", "kaynak/not.txt"])

        // Tek öğeyi geçici klasöre çıkarma (Hızlı Bakış / sürükleme).
        let extracted = try await ItemExtractor(runner: runner, archive: archive, password: nil)
            .extract("kaynak/not.txt", into: workspace.appendingPathComponent("gecici"))
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "merhaba dünya\n")
    }

    /// Birlikte sürüklenen öğeler (⌘A ile seçilip masaüstüne bırakılanlar) tek 7zz çalıştırmasıyla aynı klasöre
    /// çıkarılır; aynı anda gelen istekler aynı çıkarmayı bekler. Çıkarma başladıktan sonra topluluğa öğe eklenmez,
    /// sonradan istenen öğe kendi başına çıkarılır.
    @Test func dragBatchExtractsAllItemsInOneRun() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "ek\n".write(to: workspace.appendingPathComponent("kaynak/ek.txt"), atomically: true, encoding: .utf8)
        let archive = workspace.appendingPathComponent("surukle.7z")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: archive, format: .sevenZip, level: .fast
        ))))
        let session = workspace.appendingPathComponent("oturum", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let requested = PathsBox()
        let batch = DragBatch(extractor: ItemExtractor(runner: runner, archive: archive, password: nil, root: session)) { paths in
            requested.append(paths)
            return 1
        }
        #expect(batch.add("kaynak/not.txt"))
        #expect(batch.add("kaynak/ek.txt"))
        #expect(batch.add("kaynak/not.txt"))
        #expect(batch.paths == ["kaynak/not.txt", "kaynak/ek.txt"])
        #expect(!batch.hasStarted)

        async let first = batch.url(for: "kaynak/not.txt")
        async let second = batch.url(for: "kaynak/ek.txt")
        let (note, extra) = try await (first, second)
        #expect(try String(contentsOf: note, encoding: .utf8) == "merhaba dünya\n")
        #expect(try String(contentsOf: extra, encoding: .utf8) == "ek\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path).count == 1)
        #expect(requested.calls == [["kaynak/not.txt", "kaynak/ek.txt"]])
        #expect(batch.hasStarted)

        #expect(!batch.add("kaynak/alt"))
        let late = try await batch.url(for: "kaynak/alt")
        #expect(late.lastPathComponent == "alt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path).count == 2)
    }

    /// Bırakılan öğeler çıkarılamazsa (bozuk ya da bulunamayan öğe) hata bir kez bildirilir; aynı anda gelen istekler
    /// aynı hatayı alır. Arşiv bırakmadan önce kapandıysa (oturum klasörü silinmiş) hiçbir şey çıkarılmaz, klasör yeniden
    /// oluşturulup sahipsiz kalmaz ve bu bir hata olarak bildirilmez.
    @Test func dragBatchReportsFailureOnceAndSkipsClosedSessions() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("surukle.7z")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: archive, format: .sevenZip, level: .fast
        ))))
        let session = workspace.appendingPathComponent("oturum", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let failures = PathsBox()
        let extractor = ItemExtractor(runner: runner, archive: archive, password: nil, root: session)
        let broken = DragBatch(extractor: extractor, onFailure: { failures.append(["\($0)"]) })
        broken.add("kaynak/not.txt")
        broken.add("kaynak/yok.txt")
        async let first = Result { try await broken.url(for: "kaynak/not.txt") }
        async let second = Result { try await broken.url(for: "kaynak/yok.txt") }
        let results = await [first, second]
        #expect(results.allSatisfy { if case .failure = $0 { true } else { false } })
        #expect(failures.calls.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path).isEmpty)

        // Arşiv kapandı: oturum klasörü silindi.
        try FileManager.default.removeItem(at: session)
        let closed = DragBatch(extractor: extractor, onFailure: { failures.append(["\($0)"]) })
        closed.add("kaynak/not.txt")
        await #expect(throws: SevenZipError.cancelled) { try await closed.url(for: "kaynak/not.txt") }
        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect(failures.calls.count == 1)
    }

    /// Word'e art arda tek tek sürüklenen resimlerden birkaçından sonra sürükleme duruyordu: dosya bırakılınca
    /// isteniyor, SwiftUI isteği ana iş parçacığını durdurarak yanıtlıyor, 7zz o anda çalışıyordu. Çıkarma sürükleme
    /// başlarken başlamalı; bırakma isteği hazır dosyayı yeni bir 7zz çalıştırmadan, beklemeden almalı. Çok büyük
    /// seçimler önceden çıkarılmaz; önceden başlayan çıkarmanın hatası ancak bir bırakma isteğinde (bir kez) bildirilir.
    @Test func dragBatchExtractsBeforeTheDrop() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "ek\n".write(to: workspace.appendingPathComponent("kaynak/ek.txt"), atomically: true, encoding: .utf8)
        let archive = workspace.appendingPathComponent("surukle.7z")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak")], destination: archive, format: .sevenZip, level: .fast
        ))))
        let session = workspace.appendingPathComponent("oturum", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let extractor = ItemExtractor(runner: runner, archive: archive, password: nil, root: session)
        let log = AppLog(directory: nil)
        let requested = PathsBox()
        let failures = PathsBox()
        let batch = DragBatch(extractor: extractor, requiredBytes: { paths in
            requested.append(paths)
            return 16
        }, onFailure: { failures.append(["\($0)"]) }, log: log)
        batch.add("kaynak/not.txt")
        batch.add("kaynak/ek.txt")
        #expect(batch.prefetch())
        #expect(batch.hasStarted)
        #expect(!batch.prefetch())
        #expect(!batch.add("kaynak/alt"))

        // Bırakma isteği gelmeden dosyalar diske çıkar.
        let extracted = try await waitFor(log, "extracted 2 item(s)")
        #expect(extracted.category == .drag)
        let folders = try FileManager.default.contentsOfDirectory(atPath: session.path)
        #expect(folders.count == 1)
        #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent(folders[0]).appendingPathComponent("kaynak/ek.txt").path))

        let clock = ContinuousClock.now
        let note = try await batch.url(for: "kaynak/not.txt")
        let extra = try await batch.url(for: "kaynak/ek.txt")
        #expect(ContinuousClock.now - clock < .milliseconds(200))
        #expect(try String(contentsOf: note, encoding: .utf8) == "merhaba dünya\n")
        #expect(try String(contentsOf: extra, encoding: .utf8) == "ek\n")
        // Önceden başlayan çıkarma tek 7zz çalıştırmasıydı; istekler yenisini başlatmadı.
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path).count == 1)
        #expect(requested.calls.filter { $0 == ["kaynak/not.txt", "kaynak/ek.txt"] }.count == 2)
        #expect(log.entries.contains { $0.message.contains("extracting before the drop") })
        #expect(log.entries.filter { $0.message.contains("drop target requested") }.count == 1)
        #expect(!log.entries.contains { $0.level.isProblem })
        #expect(failures.calls.isEmpty)

        // Çok büyük seçim: bırakma isteği gelene kadar çıkarılmaz.
        let large = DragBatch(extractor: extractor, requiredBytes: { _ in DragBatch.prefetchLimit + 1 }, log: log)
        large.add("kaynak/not.txt")
        #expect(!large.prefetch())
        #expect(!large.hasStarted)
        #expect(log.entries.contains { $0.message.contains("extraction waits for the drop") })
        #expect(try String(contentsOf: try await large.url(for: "kaynak/not.txt"), encoding: .utf8) == "merhaba dünya\n")

        // Önceden başlayıp başarısız olan çıkarma: vazgeçilen bir sürükleme uyarı göstermez, bırakma isteği bir kez bildirir.
        let broken = DragBatch(extractor: extractor, onFailure: { failures.append(["\($0)"]) }, log: log)
        broken.add("kaynak/yok.txt")
        #expect(broken.prefetch())
        let failed = try await waitFor(log, "extraction 7zz failed")
        #expect(failed.level == .error)
        #expect(failures.calls.isEmpty)
        await #expect(throws: (any Error).self) { try await broken.url(for: "kaynak/yok.txt") }
        await #expect(throws: (any Error).self) { try await broken.url(for: "kaynak/yok.txt") }
        #expect(failures.calls.count == 1)
    }

    /// Günlükte iletisi `text` içeren kaydı bekler (en çok 20 sn).
    private func waitFor(_ log: AppLog, _ text: String) async throws -> AppLog.Entry {
        for _ in 0..<400 {
            if let entry = log.entries.first(where: { $0.message.contains(text) }) { return entry }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Günlükte bulunamadı: \(text)")
        throw CancellationError()
    }

    private func listPaths(_ archive: URL) async throws -> [String] {
        let result = try await runner.run(SevenZipCommand.list(archive: archive))
        try SevenZipError.check(result)
        return ListingParser.parse(result.stdout).entries.map(\.path).sorted()
    }


    @Test func tarXzListsAndExtractsInnerTar() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", workspace.appendingPathComponent("yedek.tar.xz").path, "-C", workspace.path, "kaynak"]
        try tar.run()
        tar.waitUntilExit()
        let archive = workspace.appendingPathComponent("yedek.tar.xz")

        let result = try await runner.run(SevenZipCommand.list(archive: archive))
        try SevenZipError.check(result)
        let listing = ListingParser.parse(result.stdout, fallbackName: ArchiveNaming.streamItemName(for: archive))
        #expect(listing.entries.map(\.path) == ["yedek.tar"])

        let extracted = try await ItemExtractor(runner: runner, archive: archive, password: nil)
            .extract("yedek.tar", into: workspace.appendingPathComponent("gecici"))
        #expect(FileManager.default.fileExists(atPath: extracted.path))
    }

    @Test func extractsIntoFolderWithStarInName() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("yildiz.zip")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [workspace.appendingPathComponent("kaynak/not.txt")], destination: archive, format: .zip, level: .fast
        ))))
        let destination = workspace.appendingPathComponent("İş*Yedek", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let options = ExtractOptions(archive: archive, destination: destination, overwrite: .replace)
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(options), workingDirectory: options.workingDirectory))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("not.txt").path))
    }

    @Test func readsEngineVersion() async throws {
        let result = try await runner.run([], timeout: 15)
        #expect(EngineLocator.parseVersion(result.stdout) != nil)
    }
}

private final class ProgressBox: @unchecked Sendable {
    var last: Double = 0
}

private final class PathsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var calls: [[String]] { lock.withLock { recorded } }

    func append(_ paths: [String]) {
        lock.withLock { recorded.append(paths) }
    }
}
