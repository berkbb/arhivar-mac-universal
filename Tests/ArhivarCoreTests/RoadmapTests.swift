import Foundation
import Testing
@testable import ArhivarCore

// ROADMAP.md maddeleri için çekirdek testleri (P0–P3 ve planlanan özellikler).

private let archive = URL(fileURLWithPath: "/tmp/ornek.zip")

// MARK: - P0

/// P0-1: başarılı (çıkış 0) sonuç parola gerektirmez; `try?` düzleştirmesi bunu "parola gerekli" sanıyordu.
@Test func successfulListingDoesNotNeedPassword() {
    #expect(!SevenZipError.needsPassword(ProcessResult(exitCode: 0, stdout: "Everything is Ok", stderr: "")))
    #expect(SevenZipError.needsPassword(ProcessResult(exitCode: 255, stdout: "Enter password:", stderr: "Break signaled")))
    #expect(SevenZipError.needsPassword(ProcessResult(exitCode: 2, stdout: "Cannot open encrypted archive. Wrong password?", stderr: "")))
    #expect(!SevenZipError.needsPassword(ProcessResult(exitCode: 2, stdout: "", stderr: "ERROR: CRC Failed")))
}

/// P0-2: toplamı Int64.max'ı aşan uydurma boyutlar (zip bombası) uygulamayı çökertmemeli.
@Test func hugeDeclaredSizesSaturate() {
    let half = Int64.max / 2 + 1
    let entries = [
        ArchiveEntry(path: "a/bomba1", size: half, packedSize: half),
        ArchiveEntry(path: "a/bomba2", size: half, packedSize: half),
        ArchiveEntry(path: "b", size: .max),
    ]
    let statistics = ArchiveStatistics(listing: ArchiveListing(info: ArchiveInfo(), entries: entries))
    #expect(statistics.totalSize == .max)
    #expect(statistics.packedSize == .max)
    #expect(DiskSpace.requiredBytes(for: [], in: entries) == .max)
    #expect(DiskSpace.requiredBytes(for: ["a"], in: entries) == .max)
    let tree = ArchiveTree.build(from: entries)
    #expect(tree.first { $0.id == "a" }?.size == .max)
    #expect(Int64(5).saturatingAdding(-7) == -2)
    #expect(Int64.min.saturatingAdding(-1) == .min)
}

/// P0-3: şifreli zip'e eklemede de AES-256 kullanılmalı (ZipCrypto değil).
@Test func addingToEncryptedZipKeepsAES() {
    #expect(SevenZipCommand.add(archive: archive, names: ["a"], password: "p").contains("-mem=AES256"))
    #expect(SevenZipCommand.add(archive: URL(fileURLWithPath: "/x/a.dat"), names: ["a"], password: "p", archiveType: "zip").contains("-mem=AES256"))
    #expect(!SevenZipCommand.add(archive: archive, names: ["a"]).contains("-mem=AES256"))
    #expect(!SevenZipCommand.add(archive: URL(fileURLWithPath: "/x/a.7z"), names: ["a"], password: "p").contains("-mem=AES256"))
}

/// P0-4: hedef dışını gösteren bağlantılar silinir, hazırlık klasörüne mutlak yazılanlar göreli olur.
@Test func symlinksPointingOutsideAreRemoved() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try fileManager.createDirectory(at: staging.appendingPathComponent("F.framework/Versions/A"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: staging.appendingPathComponent("etc"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: staging.appendingPathComponent("F.framework/Versions/A/F"))
    try Data("h".utf8).write(to: staging.appendingPathComponent("etc/hosts"))
    func link(_ path: String, _ target: String) throws {
        try fileManager.createSymbolicLink(atPath: staging.appendingPathComponent(path).path, withDestinationPath: target)
    }
    try link("F.framework/Versions/Current", "A")
    try link("F.framework/F", "Versions/Current/F")
    try link("kacak", "../../disarida")
    try link("mutlak-dis", "/etc/hosts")
    // 7zz mutlak bağlantıları çıkarma klasörünün içine yazar.
    try link("F.framework/mutlak-ic", staging.appendingPathComponent("etc/hosts").path)
    // İç bağlantı üzerinden dışarı kaçış.
    try link("ust", "..")
    try link("dolayli", "ust/../disarida")

    let removed = StagedExtraction.secureSymlinks(in: staging)
    #expect(removed == ["dolayli", "kacak", "mutlak-dis", "ust"])
    #expect(try fileManager.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("F.framework/Versions/Current").path) == "A")
    #expect(try fileManager.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("F.framework/F").path) == "Versions/Current/F")
    #expect(try fileManager.destinationOfSymbolicLink(atPath: staging.appendingPathComponent("F.framework/mutlak-ic").path) == "../etc/hosts")

    // Hedefe taşındıktan sonra da hedefin içini gösterir.
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try StagedExtraction.merge(from: staging, into: destination, policy: .replace)
    let moved = destination.appendingPathComponent("F.framework/mutlak-ic")
    #expect(try String(contentsOf: moved, encoding: .utf8) == "h")
}

@Test func relativeLinkPaths() {
    #expect(StagedExtraction.relativePath(from: "a/b/link", to: ["a", "c", "d"]) == "../c/d")
    #expect(StagedExtraction.relativePath(from: "link", to: ["x"]) == "x")
    #expect(StagedExtraction.relativePath(from: "a/link", to: ["a"]) == ".")
    #expect(StagedExtraction.lexicallyNormalized("/private/var/./x/../y") == "/private/var/y")
}

/// P0-4: "üzerine yaz" eski dosyanın üst verisini (karantina) yeni içeriğe taşımamalı.
@Test func replaceKeepsNewQuarantine() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let fresh = staging.appendingPathComponent("a.txt")
    let old = destination.appendingPathComponent("a.txt")
    try Data("yeni".utf8).write(to: fresh)
    try Data("eski".utf8).write(to: old)
    let mark = "0083;6ad350b0;Safari;3012A7DC-83D1-445D-AFFE-844654688EFB"
    Quarantine.set(mark, on: fresh)

    try StagedExtraction.merge(from: staging, into: destination, policy: .replace)
    #expect(try String(contentsOf: old, encoding: .utf8) == "yeni")
    #expect(Quarantine.value(of: old) == mark)
}

/// P0-4: AddPlan'in geçici kopyaları yalnızca kullanıcıya açık olmalı.
@Test func addPlanStagingIsPrivate() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("kaynak/not.txt")
    try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: source)
    let plan = try AddPlan.make(sources: [source], into: "belgeler", stagingRoot: root.appendingPathComponent("staging"))
    let staging = try #require(plan.stagingDirectory)
    let permissions = { (url: URL) in (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value }
    #expect(try permissions(staging) == 0o700)
    // Arşive girecek alt klasör varsayılan izinlerle kalır.
    #expect(try permissions(staging.appendingPathComponent("belgeler")) != 0o700)
}

/// P0-5 / P0-6: bağlantılar saklanır; joker güvenliği yalnızca adda "*" ya da "?" varken eklenir.
@Test func createAndAddSourceSwitches() {
    let plain = CreateOptions(sources: [URL(fileURLWithPath: "/x/Uygulama.app")], destination: archive, format: .zip, level: .normal)
    let args = SevenZipCommand.create(plain)
    #expect(args.contains("-snl"))
    #expect(!args.contains("-spd"))
    let starred = CreateOptions(sources: [URL(fileURLWithPath: "/x/İş*Yedek")], destination: archive, format: .sevenZip, level: .normal)
    #expect(SevenZipCommand.create(starred).contains("-spd"))
    #expect(SevenZipCommand.add(archive: archive, names: ["a?b"]).contains("-spd"))
    var noLinks = plain
    noLinks.storeSymlinks = false
    #expect(!SevenZipCommand.create(noLinks).contains("-snl"))
    // gzip tek dosya sıkıştırır; bağlantı saklayamaz.
    let gzip = CreateOptions(sources: [URL(fileURLWithPath: "/x/a")], destination: archive, format: .gzip, level: .normal)
    #expect(!SevenZipCommand.create(gzip).contains("-snl"))
}

/// P0-7: istem olmadan gelen "Break signaled" dışarıdan gelen bir sinyaldir, parola hatası değil.
@Test func breakSignalWithoutPromptIsNotPassword() {
    #expect(throws: SevenZipError.cancelled) {
        try SevenZipError.check(ProcessResult(exitCode: 255, stdout: "", stderr: "\n\nBreak signaled"))
    }
    #expect(throws: SevenZipError.wrongPassword) {
        try SevenZipError.check(ProcessResult(exitCode: 255, stdout: "Enter password:", stderr: "Break signaled"))
    }
}

/// P0-7: SIGTERM'i yok sayan süreç iptalde SIGKILL ile durdurulmalı; iptal takılı kalmamalı.
@Test func cancellationKillsProcessIgnoringSigterm() async {
    let shell = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
    let started = ContinuousClock.now
    let task = Task { try await shell.run(["-c", "trap '' TERM; exec sleep 20"]) }
    try? await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await #expect(throws: SevenZipError.cancelled) { _ = try await task.value }
    #expect(ContinuousClock.now - started < .seconds(10))
}

/// Yalnızca "tehlikeli bağlantı atlandı" hatası, çıkarmayı başarısız saymaz; uyarı olarak döner.
@Test func dangerousLinkOnlyErrorIsWarning() throws {
    let output = "ERROR: Dangerous link path was ignored : ln/esc : ../../outside\nSub items Errors: 1\nArchives with Errors: 1"
    let warning = try SevenZipError.check(ProcessResult(exitCode: 2, stdout: output, stderr: ""))
    #expect(warning?.contains("Dangerous link") == true)
    #expect(throws: SevenZipError.self) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: output + "\nERROR: CRC Failed : a.txt", stderr: ""))
    }
}

// MARK: - P1

/// P1-8: "./" önekli, yinelenen ve sondaki "/" ayıklanır; 7zz'ye ham yol verilir.
@Test func normalizesEntryPaths() throws {
    #expect(ListingParser.normalizedPath("./src/main.swift") == "src/main.swift")
    #expect(ListingParser.normalizedPath("a//b/") == "a/b")
    #expect(ListingParser.normalizedPath("a/./b/.") == "a/b")
    #expect(ListingParser.normalizedPath(".") == "")
    #expect(ListingParser.normalizedPath(".gizli/a") == ".gizli/a")
    #expect(ListingParser.normalizedPath("../kacak") == "../kacak")
    #expect(ListingParser.normalizedPath("._.") == "._.")

    let output = """
    --
    Type = tar

    ----------
    Path = .
    Folder = +

    Path = ./src
    Folder = +

    Path = ./src/main.swift
    Size = 2

    Path = ./lib//util/x.c
    Size = 3

    """
    let listing = ListingParser.parse(output)
    #expect(listing.entries.map(\.path) == ["src", "src/main.swift", "lib/util/x.c"])
    #expect(listing.entries.map(\.archivePath) == ["./src", "./src/main.swift", "./lib//util/x.c"])

    let tree = ArchiveTree.build(from: listing.entries)
    #expect(tree.map(\.id) == ["src", "lib"])
    let index = ArchiveTree.index(tree)
    #expect(index["src"]?.archivePath == "./src")
    // Arşivde girdisi olmayan ara klasörün ham yolu alt girdiden türetilir.
    #expect(index["lib"]?.archivePath == "./lib")
    #expect(index["lib/util"]?.archivePath == "./lib//util")
    #expect(index["lib/util/x.c"]?.archivePath == "./lib//util/x.c")
    // Yol çubuğu gezinmesi normalleştirilmiş kimliklerle çalışır.
    #expect(ArchiveTree.contents(of: "lib/util", roots: tree, index: index).map(\.id) == ["lib/util/x.c"])
    #expect(ArchiveTree.rawPrefix("./a//b/c.txt", components: 2) == "./a//b")
}

/// P1-9: kullanılan 7zz sürümü güncelleme betiğine verilir.
@Test func updaterPassesCurrentVersion() {
    let script = URL(fileURLWithPath: "/x/update-7zip.sh")
    #expect(EngineUpdater(scriptURL: script, currentVersion: "26.04").arguments(command: "check")
        == ["/x/update-7zip.sh", "check", "--current", "26.04"])
}

/// P1-10: ad sıralaması Finder'daki gibi: büyük/küçük harf duyarsız, sayılar sayı olarak.
@Test func namesSortLikeFinder() {
    let tree = ArchiveTree.build(from: ["Zebra", "apple", "file10.txt", "file2.txt", "Çanta"].map { ArchiveEntry(path: $0) })
    let sorted = ArchiveTree.sorted(tree, using: [ArchiveTree.nameComparator])
    #expect(sorted.map(\.name) == ["apple", "Çanta", "file2.txt", "file10.txt", "Zebra"])
}

/// P1-11: bölünmüş arşivin herhangi bir parçası ilk parçaya çevrilir; boyut tüm parçaların toplamıdır.
@Test func splitArchiveVolumes() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("vol-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["veri.7z.001", "veri.7z.002", "film.part01.rar", "film.part02.rar", "tek.part3.rar"] {
        try Data().write(to: root.appendingPathComponent(name))
    }
    #expect(ArchiveNaming.firstVolume(of: root.appendingPathComponent("veri.7z.002")).lastPathComponent == "veri.7z.001")
    #expect(ArchiveNaming.firstVolume(of: root.appendingPathComponent("veri.7z.001")).lastPathComponent == "veri.7z.001")
    #expect(ArchiveNaming.firstVolume(of: root.appendingPathComponent("film.part02.rar")).lastPathComponent == "film.part01.rar")
    // İlk parça yoksa dokunulmaz.
    #expect(ArchiveNaming.firstVolume(of: root.appendingPathComponent("tek.part3.rar")).lastPathComponent == "tek.part3.rar")
    #expect(ArchiveNaming.firstVolume(of: root.appendingPathComponent("a.zip")).lastPathComponent == "a.zip")

    let info = ListingParser.parse("""
    --
    Path = sp.7z.001
    Type = Split
    Physical Size = 102400
    Volumes = 3
    Total Physical Size = 300122
    ----
    Path = sp.7z
    Size = 300122
    --
    Path = sp.7z
    Type = 7z
    Blocks = 1

    ----------
    """).info
    #expect(info.physicalSize == 300122)
    #expect(info.volumes == 3)
    #expect(info.blocks == 1)

    let options = CreateOptions(sources: [], destination: root.appendingPathComponent("b.7z"), format: .sevenZip, level: .normal, volumeSizeMB: 10)
    #expect(options.firstOutput.lastPathComponent == "b.7z.001")
}

/// P1-14: farklı klasörlerdeki aynı adlı kaynaklar yakalanır.
@Test func duplicateSourceNames() throws {
    let sources = [URL(fileURLWithPath: "/A/rapor.pdf"), URL(fileURLWithPath: "/B/Rapor.pdf"), URL(fileURLWithPath: "/B/x.txt")]
    #expect(AddPlan.duplicateNames(in: sources) == ["Rapor.pdf"])
    #expect(AddPlan.duplicateNames(in: [URL(fileURLWithPath: "/A/a"), URL(fileURLWithPath: "/A/b")]).isEmpty)
    #expect(throws: AddPlan.DuplicateNameError.self) {
        try AddPlan.make(sources: sources, into: "", stagingRoot: FileManager.default.temporaryDirectory)
    }
}

/// P1-15 ve akıllı alt klasör: içerik kökü ve hedef klasörü.
@Test func contentRootAndSmartDestination() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("smart-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try fileManager.createDirectory(at: staging.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    try Data().write(to: staging.appendingPathComponent("a/b/x.txt"))
    try Data().write(to: staging.appendingPathComponent("a/b/y.txt"))
    let base = root.appendingPathComponent("hedef", isDirectory: true)

    #expect(StagedExtraction.contentRoot(in: staging, stripping: "a/b").lastPathComponent == "b")
    #expect(StagedExtraction.contentRoot(in: staging, stripping: "") == staging)
    #expect(StagedExtraction.contentRoot(in: staging, stripping: "yok") == staging)

    // Tek kök öğe ("a") → doğrudan hedefe; iki öğe ("x.txt", "y.txt") → arşiv adıyla klasöre.
    #expect(StagedExtraction.destination(for: staging, base: base, archiveName: "Arşiv", mode: .smart) == base)
    let inner = StagedExtraction.contentRoot(in: staging, stripping: "a/b")
    #expect(StagedExtraction.destination(for: inner, base: base, archiveName: "Arşiv", mode: .smart).lastPathComponent == "Arşiv")
    #expect(StagedExtraction.destination(for: staging, base: base, archiveName: "Arşiv", mode: .always).lastPathComponent == "Arşiv")
    #expect(StagedExtraction.destination(for: inner, base: base, archiveName: "Arşiv", mode: .never) == base)
}

// MARK: - P2

/// P2-17: yeni kişisel veri klasörleri ve riskli türler, görünmez doldurma karakterleri.
@Test func strongerPersonalDataAndOpenSafety() throws {
    let home = URL(fileURLWithPath: "/Users/deneme")
    let denied = SandboxProfile.personalDataDirectories(home: home).map(\.path)
    for path in [".kube", ".docker", ".npmrc", ".pypirc", ".git-credentials", "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox"] {
        #expect(denied.contains("/Users/deneme/" + path))
    }
    #expect(OpenSafety.hasDeceptiveCharacters("fatura.pdf\u{2800}\u{2800}.app"))
    #expect(OpenSafety.hasDeceptiveCharacters("a\u{3164}b"))
    #expect(OpenSafety.hasDeceptiveCharacters("a\u{115F}"))
    #expect(!OpenSafety.hasDeceptiveCharacters("Çalışma Planı.pdf"))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("risk-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["betik.scpt", "kestirme.shortcut", "metin.applescript", "Panel.prefPane", "Onizleme.qlgenerator"] {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        #expect(OpenSafety.executableKind(of: url) != nil, "\(name)")
    }
    let text = root.appendingPathComponent("not.txt")
    try Data("x".utf8).write(to: text)
    #expect(OpenSafety.executableKind(of: text) == nil)
}

/// P2-19: yazmadan önce gereken alan; sıkıştırılan biçimlerde kaynaklar sayılmaz.
@Test func spaceNeededForWriting() throws {
    #expect(DiskSpace.requiredForWriting(sourceBytes: 1000, compresses: false) == 1000)
    #expect(DiskSpace.requiredForWriting(sourceBytes: 1000, compresses: true) == 0)
    #expect(DiskSpace.requiredForWriting(sourceBytes: 1000, compresses: true, existingArchiveBytes: 500) == 500)
    #expect(DiskSpace.requiredForWriting(sourceBytes: .max, compresses: false, existingArchiveBytes: 1) == .max)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("alt"), withIntermediateDirectories: true)
    try Data(count: 100).write(to: root.appendingPathComponent("a.bin"))
    try Data(count: 50).write(to: root.appendingPathComponent("alt/b.bin"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bag"), withDestinationURL: root.appendingPathComponent("a.bin"))
    #expect(DiskSpace.totalSize(of: [root]) == 150)
    #expect(DiskSpace.totalSize(of: [root.appendingPathComponent("a.bin")]) == 100)
    #expect(DiskSpace.totalSize(of: [root.appendingPathComponent("yok")]) == 0)
}

// MARK: - Planlanan özellikler

/// Özellik 2: macOS üst veri dosyaları dışlanır.
@Test func excludesMacMetadataSwitches() {
    var options = CreateOptions(sources: [URL(fileURLWithPath: "/x/a")], destination: archive, format: .zip, level: .normal)
    #expect(!SevenZipCommand.create(options).contains("-xr!.DS_Store"))
    options.excludeMacMetadata = true
    let args = SevenZipCommand.create(options)
    #expect(SevenZipCommand.macMetadataExclusions.allSatisfy(args.contains))
    #expect(SevenZipCommand.add(archive: archive, names: ["a"], excludeMacMetadata: true).contains("-xr!__MACOSX"))
}

/// Özellik 4: tar.* iki adımda üretilir; içteki tar hedefin adını taşır.
@Test func tarCompressionCommands() throws {
    let destination = URL(fileURLWithPath: "/x/yedek.tar.gz")
    let stageDirectory = URL(fileURLWithPath: "/tmp/stage", isDirectory: true)
    let options = CreateOptions(sources: [URL(fileURLWithPath: "/x/klasor")], destination: destination, format: .tarGzip, level: .maximum)
    let stage = SevenZipCommand.tarStage(for: destination, in: stageDirectory)
    #expect(stage.path == "/tmp/stage/yedek.tar")
    let first = SevenZipCommand.create(options, tarStage: stage)
    #expect(first.starts(with: ["a", "-ttar"]))
    #expect(!first.contains { $0.hasPrefix("-mx") })
    #expect(first.suffix(3) == ["--", "/tmp/stage/yedek.tar", "/x/klasor"])
    let second = try #require(SevenZipCommand.compressTarStage(options, tarStage: stage))
    #expect(second.starts(with: ["a", "-tgzip"]))
    #expect(second.contains("-mx=7"))
    #expect(second.suffix(3) == ["--", "/x/yedek.tar.gz", "/tmp/stage/yedek.tar"])
    #expect(SevenZipCommand.compressTarStage(CreateOptions(sources: [], destination: destination, format: .zip, level: .normal), tarStage: stage) == nil)
    #expect(SevenZipCommand.tarStage(for: URL(fileURLWithPath: "/x/a.tgz"), in: stageDirectory).lastPathComponent == "a.tar")
    #expect(!ArchiveFormat.tarXz.supportsVolumes)
    #expect(ArchiveFormat.tarXz.fileExtension == "tar.xz")
}

/// Özellik 5: arşivin içinde çift tıklayınca açılacak türler.
@Test func browsableNames() {
    #expect(ArchiveNaming.isBrowsable("ic.zip"))
    #expect(ArchiveNaming.isBrowsable("yedek.tar"))
    #expect(ArchiveNaming.isBrowsable("Kurulum.pkg"))
    #expect(!ArchiveNaming.isBrowsable("rapor.docx"))
    #expect(!ArchiveNaming.isBrowsable("not.txt"))
}

/// Özellik 6: `7zz h` çıktısı ve yorum / blok bilgisi.
@Test func parsesChecksumsAndComments() {
    let output = """
    Size: 3

    CRC32  for data:              ED6F7A7A

    SHA256 for data:              98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4

    BLAKE2sp for data:              49228db2a2fa8d25e8b3b2aca5a70234c71490516eaca9cba007b27d59c532b8

    Everything is Ok
    """
    let sums = ChecksumParser.parse(output)
    #expect(sums.map(\.algorithm) == ["CRC32", "SHA256", "BLAKE2sp"])
    #expect(sums[0].value == "ED6F7A7A")
    #expect(ChecksumParser.text(sums).hasPrefix("CRC32: ED6F7A7A\nSHA256: 98ea"))
    #expect(SevenZipCommand.hash(file: URL(fileURLWithPath: "/x/a")) == ["h", "-bd", "-spd", "-scrcCRC32", "-scrcSHA256", "-scrcBLAKE2sp", "-sccUTF-8", "--", "/x/a"])

    let info = ListingParser.parse("--\nPath = c.zip\nType = zip\nComment = Merhaba yorum\nikinci satır\n\n----------\n").info
    #expect(info.comment == "Merhaba yorum\nikinci satır")
    #expect(ListingParser.parse("--\nType = zip\n\n----------\n").info.comment == nil)
}
