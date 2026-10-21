import Synchronization
import Foundation
import Testing
@testable import ArhivarCore

// Liste maddesi 17: hazırlık klasörüne çıkarıp taşıma ve disk alanı denetimi.

private struct Sandbox {
    let root: URL
    let staging: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        destination = root.appendingPathComponent("hedef", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("klasor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("klasor"), withIntermediateDirectories: true)
        try write("yeni", to: staging.appendingPathComponent("klasor/ortak.txt"))
        try write("yeni-ek", to: staging.appendingPathComponent("klasor/sadece-yeni.txt"))
        try write("yeni-kok", to: staging.appendingPathComponent("kok.txt"))
        try write("eski", to: destination.appendingPathComponent("klasor/ortak.txt"))
        try write("eski-ek", to: destination.appendingPathComponent("klasor/sadece-eski.txt"))
    }

    func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func mergeReplaceOverwritesAndKeepsOthers() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try StagedExtraction.merge(from: box.staging, into: box.destination, policy: .replace)
    #expect(box.read("klasor/ortak.txt") == "yeni")
    #expect(box.read("klasor/sadece-eski.txt") == "eski-ek")
    #expect(box.read("klasor/sadece-yeni.txt") == "yeni-ek")
    #expect(box.read("kok.txt") == "yeni-kok")
}

@Test func mergeSkipKeepsExistingFiles() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try StagedExtraction.merge(from: box.staging, into: box.destination, policy: .skip)
    #expect(box.read("klasor/ortak.txt") == "eski")
    #expect(box.read("klasor/sadece-yeni.txt") == "yeni-ek")
}

@Test func mergeRenameKeepsBoth() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try StagedExtraction.merge(from: box.staging, into: box.destination, policy: .rename)
    #expect(box.read("klasor/ortak.txt") == "eski")
    #expect(box.read("klasor/ortak_1.txt") == "yeni")
}

@Test func mergeNeverWritesThroughSymlinks() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // Hedefte "klasor" adında, başka bir yeri gösteren sembolik bağlantı olsun.
    let elsewhere = box.root.appendingPathComponent("baska-yer", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: box.destination.appendingPathComponent("klasor"))
    try FileManager.default.createSymbolicLink(at: box.destination.appendingPathComponent("klasor"), withDestinationURL: elsewhere)

    try StagedExtraction.merge(from: box.staging, into: box.destination, policy: .rename)
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    #expect(box.read("klasor_1/ortak.txt") == "yeni")
}

@Test func uniqueNamesFollowSevenZipStyle() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let target = box.destination.appendingPathComponent("klasor/ortak.txt")
    #expect(StagedExtraction.uniqueURL(for: target).lastPathComponent == "ortak_1.txt")
    try box.write("x", to: box.destination.appendingPathComponent("klasor/ortak_1.txt"))
    #expect(StagedExtraction.uniqueURL(for: target).lastPathComponent == "ortak_2.txt")
    #expect(StagedExtraction.uniqueURL(for: box.destination.appendingPathComponent("klasor")).lastPathComponent == "klasor_1")
}

@Test func stagingLivesOnDestinationVolume() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let staging = try StagedExtraction.makeStagingDirectory(for: box.destination.appendingPathComponent("henuz/yok"))
    defer { try? FileManager.default.removeItem(at: staging) }
    let volume = { (url: URL) in try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
    #expect(try volume(staging) == volume(box.root))
}

@Test func diskSpaceArithmetic() {
    let entries = [
        ArchiveEntry(path: "a", isDirectory: true),
        ArchiveEntry(path: "a/b.bin", size: 600),
        ArchiveEntry(path: "c.bin", size: 400),
        ArchiveEntry(path: "d.bin", size: nil),
    ]
    #expect(DiskSpace.requiredBytes(for: [], in: entries) == 1000)
    #expect(DiskSpace.requiredBytes(for: ["a"], in: entries) == 600)
    #expect(DiskSpace.hasRoom(required: 1000, available: 2000, reserve: 500))
    #expect(!DiskSpace.hasRoom(required: 1600, available: 2000, reserve: 500))
    #expect(DiskSpace.hasRoom(required: .max, available: nil))
    #expect(throws: InsufficientSpaceError.self) {
        try InsufficientSpaceError.check(required: Int64.max / 2, at: FileManager.default.temporaryDirectory)
    }
}

@Test func smartDestinationIgnoresMacMetadata() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let staging = box.root.appendingPathComponent("smart-meta", isDirectory: true)
    let base = box.root.appendingPathComponent("smart-base", isDirectory: true)
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("Proje"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: staging.appendingPathComponent(".DS_Store"))
    try Data("y".utf8).write(to: staging.appendingPathComponent("._Proje"))

    // Tek anlamlı kök öğe ("Proje") ve yanında macOS üst verileri varken akıllı kip doğrudan hedefe çıkarır (çift klasör yapmaz).
    #expect(StagedExtraction.destination(for: staging, base: base, archiveName: "Proje", mode: .smart) == base)

    // Birden fazla anlamlı kök öğe varken ise arşiv adıyla alt klasöre çıkarır.
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("Belgeler"), withIntermediateDirectories: true)
    #expect(StagedExtraction.destination(for: staging, base: base, archiveName: "Proje", mode: .smart).lastPathComponent == "Proje")
}


/// Akıllı kip içeriği doğrudan hedefe çıkarırken kökteki macOS üst verisi bırakılır; yalnızca üst veri olan arşivde,
/// alt klasöre çıkarken ya da başka kiplerde hiçbir şey bırakılmaz.
@Test func smartLeavesRootMetadataOutOnlyWhenExtractingIntoTheBase() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let base = box.root.appendingPathComponent("indirilenler", isDirectory: true)
    func staging(_ name: String, folders: [String], files: [String]) throws -> URL {
        let url = box.root.appendingPathComponent(name, isDirectory: true)
        for folder in folders { try FileManager.default.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try Data("x".utf8).write(to: url.appendingPathComponent(file)) }
        return url
    }
    func leaveOut(_ content: URL, mode: SubfolderMode) -> [String] {
        let destination = StagedExtraction.destination(for: content, base: base, archiveName: "Proje", mode: mode)
        return StagedExtraction.leaveOutRootMetadata(in: content, destination: destination, base: base, mode: mode)
    }

    // "._Proje" eşi ("Proje") yanında olduğu için AppleDouble üst verisidir.
    let finder = try staging("finder", folders: ["Proje", "__MACOSX/Proje"], files: [".DS_Store", "._Proje"])
    #expect(leaveOut(finder, mode: .smart) == [".DS_Store", "._Proje", "__MACOSX"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: finder.path) == ["Proje"])

    // Arşivde üst veriden başka bir şey yoksa çıkarılan tek şey odur; bırakılmaz.
    let onlyMetadata = try staging("yalniz", folders: [], files: [".DS_Store"])
    #expect(leaveOut(onlyMetadata, mode: .smart).isEmpty)
    // Birden çok anlamlı öğe: içerik arşiv adıyla bir alt klasöre gider, üst veri onunla birlikte kalır.
    let several = try staging("cok", folders: ["Proje", "Belgeler", "__MACOSX"], files: [])
    #expect(leaveOut(several, mode: .smart).isEmpty)
    // Kullanıcı "Her zaman" ya da "Hiçbir zaman" seçtiyse arşiv olduğu gibi çıkar.
    let always = try staging("her", folders: ["Proje", "__MACOSX"], files: [])
    #expect(leaveOut(always, mode: .always).isEmpty)
    #expect(leaveOut(always, mode: .never).isEmpty)
    #expect(StagedExtraction.isMacMetadata(".DS_Store", in: always) && !StagedExtraction.isMacMetadata("a.DS_Store", in: always))
}

/// Çıkarma sürerken boş alan tükenirse iş durdurulur (sıkıştırma bombası diski doldurmasın).
@Suite struct DiskSpaceGuardTests {
    private final class Flag: Sendable { let value = Mutex(false) }

    @Test func returnsTheResultWhenSpaceIsFine() async throws {
        let value = try await DiskSpaceGuard.run(watching: URL(fileURLWithPath: "/"), floor: 100, interval: .milliseconds(5), available: { 1_000 }) {
            try await Task.sleep(for: .milliseconds(30))
            return 42
        }
        #expect(value == 42)
    }

    @Test func stopsTheOperationWhenSpaceRunsOut() async throws {
        let cancelled = Flag()
        let remaining = Mutex<Int64>(10_000)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: InsufficientSpaceError(required: 500, available: 0, stoppedWhileWriting: true)) {
            try await DiskSpaceGuard.run(watching: URL(fileURLWithPath: "/"), floor: 500, interval: .milliseconds(5), available: {
                // Her yoklamada yer azalır; sonunda payın altına iner.
                remaining.withLock { $0 = max(0, $0 - 3_000); return $0 }
            }) {
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.value.withLock { $0 = true }; throw error }
                return 0
            }
        }
        #expect(cancelled.value.withLock { $0 })
        #expect(clock.now - start < .seconds(5))
    }

    @Test func unknownFreeSpaceNeverStopsTheOperation() async throws {
        let value = try await DiskSpaceGuard.run(watching: URL(fileURLWithPath: "/"), floor: .max, interval: .milliseconds(2), available: { nil }) {
            try await Task.sleep(for: .milliseconds(20))
            return "tamam"
        }
        #expect(value == "tamam")
    }

    /// Dış iş iptal edilince (Vazgeç) işin kendi hatası gelir; izleyicinin CancellationError'ı onun önüne geçmez.
    @Test func outerCancellationReportsTheOperationsOwnError() async {
        struct Stopped: Error, Equatable {}
        for _ in 0..<50 {
            let task = Task {
                try await DiskSpaceGuard.run(watching: URL(fileURLWithPath: "/"), interval: .milliseconds(1), available: { .max }) {
                    // 7zz'yi taklit eder: iptalde kendi "durduruldu" hatasını verir.
                    do { try await Task.sleep(for: .seconds(30)) } catch { throw Stopped() }
                    return 0
                }
            }
            try? await Task.sleep(for: .milliseconds(3))
            task.cancel()
            let result = await task.result
            guard case .failure(let error) = result else { Issue.record("iş tamamlandı sanıldı"); continue }
            #expect(error is Stopped, "\(error)")
        }
    }

    @Test func operationErrorsPropagate() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await DiskSpaceGuard.run(watching: URL(fileURLWithPath: "/"), interval: .milliseconds(5), available: { .max }) { throw Boom() }
        }
    }
}
