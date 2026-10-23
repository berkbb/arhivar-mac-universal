import Foundation
import Testing
@testable import ArhivarCore

private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ProcessInfo.processInfo.environment["ARHIVAR_7ZZ"],
        packageRoot.appendingPathComponent("Vendor/7-Zip/7zz").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArhivarListTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Az sayıda öğe komut satırında kalır; liste dosyası yazılmaz.
@Test func smallItemListsStayOnTheCommandLine() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let arguments = ["x", "-o/tmp/a", "-y", "-spd", "--", "/tmp/a.zip", "bir.txt", "iki.txt"]
    let fitted = try ItemListFile.fitting(arguments, directory: folder)
    #expect(fitted == ItemListFile.Fitted(arguments: arguments, listFile: nil))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}

/// Sınırı aşan öğeler liste dosyasına (yalnızca kullanıcıya açık) yazılır; 7zz'nin kırpacağı ya da bozacağı adlar
/// (baş/son boşluk, tümüyle tırnaklı, satır sonu, BOM) komut satırında kalır. Arşiv yolu "--" korumasında kalır.
@Test func largeItemListsMoveToAListFile() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let safe = ["a.txt", "klasör/şçğ İ.txt", "-tire", "@et", "yıldız*.txt", "a\"b\".txt", "iç  boşluk.txt", "#diyez", ";noktalı"]
    let unsafe = [" baş.txt", "son.txt ", "\"tırnak\"", "satır\nsonu", "\u{FEFF}bom", "\tsekme"]
    let head = ["x", "-o/tmp/a", "-y", "-spd"]
    let fitted = try ItemListFile.fitting(head + ["--", "/tmp/a.zip"] + safe + unsafe, directory: folder, limit: 8)
    let file = try #require(fitted.listFile)
    #expect(fitted.arguments == head + ["-scsUTF-8", "-i@" + file.path, "--", "/tmp/a.zip"] + unsafe)
    #expect(try String(contentsOf: file, encoding: .utf8) == safe.joined(separator: "\n") + "\n")
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    fitted.remove()
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

/// Öğe listesi almayan komutlar (yeniden adlandırma, listeleme, sağlama) ve yalnızca liste dosyasına yazılamayan
/// adlar olduğunda argümanlara dokunulmaz.
@Test func itemListFileLeavesOtherCommandsAlone() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let long = String(repeating: "a", count: 300)
    for arguments in [
        ["rn", "-spd", "--", "/tmp/a.zip", long, long + "b"],
        ["l", "-slt", "--", "/tmp/a.zip"],
        ["h", "-scrcSHA256", "--", long],
        ["x", "-y", "--", "/tmp/a.zip", " " + long, long + " "],
        ["x", "-y", "/tmp/a.zip", long, long],
    ] {
        #expect(try ItemListFile.fitting(arguments, directory: folder, limit: 8).arguments == arguments)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}

/// Liste dosyası yasaklı bir kişisel klasörün içinde yazılsa da kum havuzundaki 7zz onu okuyabilmeli (çalıştırıcı
/// dosyayı profile okunabilir olarak ekler); ekli değilse 7zz liste dosyasını açamaz.
@Test(.enabled(if: engineURL != nil && SandboxProfile.isAvailable)) func sandboxedEngineReadsListFileInDeniedFolder() async throws {
    let home = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: home) }
    let source = home.appendingPathComponent("kaynak", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for index in 0..<4 { try Data("\(index)".utf8).write(to: source.appendingPathComponent("\(index).txt")) }
    let engine = CommandRunner(executableURL: try #require(engineURL))
    let archive = home.appendingPathComponent("a.7z")
    try SevenZipError.check(try await engine.run(SevenZipCommand.create(CreateOptions(sources: [source], destination: archive, format: .sevenZip, level: .fast))))
    // Liste dosyasının yazılacağı yer kişisel bir klasör (Library/Containers) gibi okumaya kapalı.
    let denied = home.appendingPathComponent("Library/Containers", isDirectory: true)
    let output = home.appendingPathComponent("cikti", isDirectory: true)
    let profile = SandboxProfile.forOperation(archive: archive, writable: [output], home: home)
    #expect(profile.deniedReadDirectories.contains(SandboxProfile.resolved(denied)))
    let items = (0..<4).map { "kaynak/\($0).txt" }
    let arguments = SevenZipCommand.extract(ExtractOptions(archive: archive, destination: output, items: items, overwrite: .replace))
    let fitted = try ItemListFile.fitting(arguments, directory: denied, limit: 8)
    defer { fitted.remove() }
    #expect(fitted.listFile != nil)
    // Çalıştırıcının yaptığı gibi liste dosyası profile eklenir.
    var allowed = profile
    allowed.readableFiles.append(SandboxProfile.resolved(try #require(fitted.listFile)))
    let result = try await CommandRunner(executableURL: engine.executableURL, sandbox: allowed).run(fitted.arguments)
    try SevenZipError.check(result)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("kaynak").path).count == 4)
    // Eklenmeseydi 7zz listeyi okuyamazdı.
    try? FileManager.default.removeItem(at: output)
    let blocked = try await CommandRunner(executableURL: engine.executableURL, sandbox: profile).run(fitted.arguments)
    #expect(blocked.exitCode != 0 || !FileManager.default.fileExists(atPath: output.appendingPathComponent("kaynak/0.txt").path))
}

/// ⌘A ile binlerce öğe: argümanlar ARG_MAX'ı (1 MiB) aşıyordu ve 7zz hiç başlatılamıyordu ("motor bulunamadı").
/// Çıkarma (sürükleme, kopyalama), silme ve oluşturma kum havuzunda gerçek 7zz ile çalışmalı; liste
/// dosyasına yazılamayan adlar da doğru öğeyi bulmalı, adındaki "*" başka dosyayı seçmemeli.
@Suite(.enabled(if: engineURL != nil, "7zz bulunamadı"), .serialized)
struct ItemListFileIntegrationTests {
    let workspace: URL
    let source: URL
    let names: [String]

    init() throws {
        workspace = try temporaryFolder()
        source = workspace.appendingPathComponent("kaynak", isDirectory: true)
        let folder = "Çok_Uzun_Adlı_Bir_Fotoğraf_Klasörü_" + String(repeating: "x", count: 40)
        try FileManager.default.createDirectory(at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
        // Az sayıda ama uzun (dosya adı başına ~254 bayt) ad: argümanlar yine 1 MiB'ı aşar, 7zz'nin eşleştirmesi kısa sürer.
        let padding = String(repeating: "ö", count: 120)
        var names = (0..<3200).map { "\(folder)/IMG_\(String(format: "%05d", $0))_\(padding).jpg" }
        names += [" baş.txt", "son.txt ", "\"tırnak\"", "yıldız*.txt", "yıldızX.txt", "-tire.txt", "@et.txt"]
        for name in names {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }
        self.names = names
    }

    private var runner: CommandRunner { CommandRunner(executableURL: engineURL ?? URL(fileURLWithPath: "/usr/bin/false")) }

    /// Arşivdeki dosya yolları, 7zz'nin yazdığı biçimde (Foundation diske ayrışık Unicode yazar: "ö" → "o" + "¨").
    /// Uygulama da öğe adlarını 7zz'ye listeden aldığı biçimde verir.
    private func listedPaths(_ archive: URL) async throws -> [String] {
        let result = try await runner.run(SevenZipCommand.list(archive: archive))
        try SevenZipError.check(result)
        return ListingParser.parse(result.stdout).entries.filter { !$0.isDirectory }.map(\.archivePath)
    }

    private func listed(_ archive: URL) async throws -> Set<String> {
        Set(try await listedPaths(archive))
    }

    private func listFiles() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: ItemExtractor.temporaryRoot.path)) ?? []).filter { $0.hasPrefix("items-") })
    }

    @Test func thousandsOfItemsRunThroughTheEngine() async throws {
        defer { try? FileManager.default.removeItem(at: workspace) }
        let listFilesBefore = listFiles()

        // Oluşturma: Finder'da binlerce dosya seçilip sıkıştırılır gibi, her biri ayrı (mutlak yollu) kaynak.
        let sources = names.map { source.appendingPathComponent($0) }
        #expect(sources.reduce(0) { $0 + $1.path.utf8.count + 1 } > 1 << 20)
        let flat = workspace.appendingPathComponent("duz.zip")
        try SevenZipError.check(try await runner.sandboxed(.forOperation(archive: flat, writable: [workspace], readable: [source]))
            .run(SevenZipCommand.create(CreateOptions(sources: sources, destination: flat, format: .zip, level: .store))))
        #expect(try await listed(flat) == Set(names.map { ($0 as NSString).lastPathComponent }))

        // Klasörden bir arşiv: girdi yolları uzun, ⌘A ile hepsi seçilince argümanlar 1 MiB'ı aşar.
        let archive = workspace.appendingPathComponent("buyuk.7z")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(sources: [source], destination: archive, format: .sevenZip, level: .fast))))
        let all = try await listedPaths(archive)
        #expect(all.count == names.count)
        #expect(all.reduce(0) { $0 + $1.utf8.count + 1 } > 1 << 20)

        // Çıkarma (sürükleme, ⌘C): "yıldızX.txt" istenmedi; "yıldız*.txt" onu seçmemeli.
        let wanted = all.filter { !$0.hasSuffix("yıldızX.txt") }
        let session = workspace.appendingPathComponent("oturum", isDirectory: true)
        let extractor = ItemExtractor(
            runner: runner.sandboxed(.forOperation(archive: archive, writable: [session])), archive: archive, password: nil, root: session
        )
        let urls = try await extractor.extract(wanted)
        #expect(urls.count == wanted.count)
        for (name, url) in zip(wanted, urls) {
            #expect(try String(contentsOf: url, encoding: .utf8) == String(name.dropFirst("kaynak/".count)))
        }
        let photo = try #require(urls.first { $0.lastPathComponent.hasPrefix("IMG_") })
        let root = photo.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("kaynak/yıldızX.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: photo.deletingLastPathComponent().path).count == 3200)

        // Silme (⌘A + Sil): biri dışında hepsi silinir.
        try SevenZipError.check(try await runner.sandboxed(.forOperation(archive: archive, writable: [workspace], writableFiles: [archive]))
            .run(SevenZipCommand.delete(archive: archive, items: wanted)))
        #expect(try await listedPaths(archive) == ["kaynak/yıldızX.txt"])

        // Liste dosyaları süreç bitince silinir.
        #expect(listFiles().subtracting(listFilesBefore).isEmpty)
    }
}

