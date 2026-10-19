import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// .agents/context/roadmap.md, 13 açık madde (P0 1–6, P1 7–10, P2 11–13): birim testleri.

private let archive = URL(fileURLWithPath: "/tmp/ornek.7z")

private func temporaryFolder(_ name: String = "sert") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(of url: URL) -> UInt16? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt16(info.st_mode & 0o7777) : nil
}

// MARK: - P0-1 Çok satırlı yorum

/// 7zz'nin gerçek çıktısı: yorum "{ … }" arasında olduğu gibi yazılır; içindeki alanlar ve ayraç başlığı ya da
/// girdileri değiştiremez.
@Test func commentCannotSpoofHeaderOrInjectEntries() {
    let output = """
    Listing archive: c.zip

    --
    Path = c.zip
    Type = zip
    Physical Size = 194
    Comment =
    {
    satır bir
    Type = 7z
    ----------
    Path = sahte.txt
    Size = 999999

    }
    Total Physical Size = 1
    son satır
    }
    Total Physical Size = 300

    ----------
    Path = gercek.txt
    Size = 5
    Attributes =  -rw-r--r--

    """
    let listing = ListingParser.parse(output)
    #expect(listing.entries.map(\.path) == ["gercek.txt"])
    #expect(listing.info.type == "zip")
    #expect(listing.info.physicalSize == 300)
    #expect(listing.info.comment == "satır bir\nType = 7z\n----------\nPath = sahte.txt\nSize = 999999\n\n}\nTotal Physical Size = 1\nson satır")
    #expect(!ArchiveCapabilities.isEditable(type: ListingParser.parse(output.replacingOccurrences(of: "Type = zip", with: "Type = Rar")).info.type, url: archive))

    // Boş arşivde de 7zz ayracı yazar; yorumdaki sahte girdi listeye girmez.
    let empty = "--\nPath = e.zip\nType = zip\nComment = \n{\n----------\nPath = sahte\nSize = 5\n}\n\n----------\n"
    #expect(ListingParser.parse(empty).entries.isEmpty)
    #expect(ListingParser.parse(empty).info.comment == "----------\nPath = sahte\nSize = 5")
}

/// zip/7z Unix kipini "Attributes" sonunda, tar "Mode" ve "Symbolic Link" alanlarında verir.
@Test func detectsSymbolicLinkEntries() {
    let output = """
    --
    Type = tar

    ----------
    Path = zip-bag
    Attributes =  lrwxr-xr-x

    Path = 7z-bag
    Attributes = A lrwxr-xr-x

    Path = tar-bag
    Mode = lrwxr-xr-x
    Symbolic Link = ../dis

    Path = dosya
    Attributes = A -rw-r--r--

    Path = klasor
    Attributes = D drwxr-xr-x

    """
    let links = ListingParser.parse(output).entries.filter(\.isSymbolicLink).map(\.path)
    #expect(links == ["zip-bag", "7z-bag", "tar-bag"])
}

// MARK: - P0-5 Joker karakterler

@Test func archivePathsAreNeverWildcards() {
    let starred = URL(fileURLWithPath: "/tmp/yedek*1.7z")
    #expect(SevenZipCommand.list(archive: starred).contains("-spd"))
    #expect(SevenZipCommand.test(archive: starred).contains("-spd"))
    #expect(SevenZipCommand.extract(ExtractOptions(archive: starred, destination: URL(fileURLWithPath: "/tmp/c"), overwrite: .replace)).contains("-spd"))
    #expect(SevenZipCommand.hash(file: starred).contains("-spd"))
    #expect(SevenZipCommand.add(archive: starred, names: ["a"]).contains("-spd"))
    #expect(!SevenZipCommand.add(archive: archive, names: ["a"]).contains("-spd"))

    let plain = CreateOptions(sources: [URL(fileURLWithPath: "/x/a")], destination: URL(fileURLWithPath: "/tmp/y?.zip"), format: .zip, level: .fast)
    #expect(SevenZipCommand.create(plain).contains("-spd"))
    let tarGz = CreateOptions(sources: [URL(fileURLWithPath: "/x/a")], destination: URL(fileURLWithPath: "/tmp/y*.tar.gz"), format: .tarGzip, level: .fast)
    let stage = URL(fileURLWithPath: "/tmp/s/y.tar")
    #expect(SevenZipCommand.compressTarStage(tarGz, tarStage: stage)?.contains("-spd") == true)
}

// MARK: - P0-6 Özel dosyalar

@Test func specialFilesAreExcludedByArchivePath() {
    var options = CreateOptions(sources: [URL(fileURLWithPath: "/x/kaynak")], destination: archive, format: .zip, level: .fast)
    options.excludedPaths = ["kaynak/alt/boru"]
    let args = SevenZipCommand.create(options)
    #expect(args.contains("-x!kaynak/alt/boru"))
    #expect(!args.contains("-spd"))
    // Joker karakterli yol "-spd" olmadan başka dosyaları da dışlardı.
    options.excludedPaths = ["kaynak/b?ru"]
    #expect(SevenZipCommand.create(options).contains("-spd"))
    #expect(SevenZipCommand.add(archive: archive, names: ["a"], excluding: ["a/boru"]).contains("-x!a/boru"))
}

@Test func addPlanSkipsFifosAndSockets() throws {
    let root = try temporaryFolder("ozel")
    defer { StagedExtraction.removeTree(at: root) }
    let source = root.appendingPathComponent("k", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("alt"), withIntermediateDirectories: true)
    try "x".write(to: source.appendingPathComponent("alt/dosya.txt"), atomically: true, encoding: .utf8)
    #expect(mkfifo(source.appendingPathComponent("alt/boru").path, 0o644) == 0)
    // Unix soketi (sun_path en çok 104 bayt; geçici klasör yolu buna sığar).
    let socketPath = source.appendingPathComponent("s").path
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        socketPath.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(bound == 0)

    #expect(SpecialFiles.archivePaths(in: [source]).sorted() == ["k/alt/boru", "k/s"])
    #expect(SpecialFiles.isSpecial(atPath: source.appendingPathComponent("alt/boru").path))
    #expect(!SpecialFiles.isSpecial(atPath: source.appendingPathComponent("alt/dosya.txt").path))
    // Bağlantı izlenecekse (bağlantı olarak saklanmıyorsa) FIFO'yu gösteren bağlantı da dışlanır.
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("bag").path, withDestinationPath: "alt/boru")
    #expect(!SpecialFiles.archivePaths(in: [source]).contains("k/bag"))
    #expect(SpecialFiles.archivePaths(in: [source], followingSymlinks: true).contains("k/bag"))

    // Kopyalama FIFO ve soketlerde durmaz; onlar atlanır.
    let plan = try AddPlan.make(sources: [source], into: "hedef", stagingRoot: root.appendingPathComponent("hazirlik"))
    let staged = try #require(plan.stagingDirectory).appendingPathComponent("hedef/k")
    #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("alt/dosya.txt").path))
    #expect(StagedExtraction.itemType(staged.appendingPathComponent("alt/boru"), fileManager: .default) == nil)
    #expect(StagedExtraction.itemType(staged.appendingPathComponent("s"), fileManager: .default) == nil)
}

// MARK: - P0-6 Kum havuzu

@Test func creatingKeepsPersonalDataProtected() {
    let home = URL(fileURLWithPath: "/Users/ornek")
    let denied = Set(SandboxProfile.personalDataDirectories(home: home).map(\.path))
    for path in [".zsh_history", ".bash_history", "Library/Containers", "Library/Group Containers", "Library/HTTPStorages"] {
        #expect(denied.contains("/Users/ornek/" + path), "\(path)")
    }
    // Kaynak kişisel bir klasördeyse klasör yasaklı kalır; yalnızca kaynağın kendisi yasaktan sonra izinlidir.
    let profile = SandboxProfile.forOperation(
        archive: URL(fileURLWithPath: "/Users/ornek/Desktop/yedek.zip"), writable: [URL(fileURLWithPath: "/Users/ornek/Desktop")],
        readable: [URL(fileURLWithPath: "/Users/ornek/.ssh/config")], home: home
    )
    let paths = profile.deniedReadDirectories.map(\.path)
    #expect(paths.contains("/Users/ornek/.ssh"))
    #expect(profile.readableFiles.map(\.path).contains("/Users/ornek/.ssh/config"))
    #expect(paths.contains("/Users/ornek/.aws"))
    #expect(paths.contains("/Users/ornek/Library/Keychains"))
}

// MARK: - P1-7 Yeniden adlandırma

@Test func renamedPathKeepsTrailingSlashSpelling() {
    #expect(ArchiveTree.renamedPath("klasor/", to: "yeni") == "yeni/")
    #expect(ArchiveTree.renamedPath("a/b/", to: "c") == "a/c/")
    #expect(ArchiveTree.renamedPath("a/b", to: "c") == "a/c")
    #expect(ArchiveTree.renamedPath("./a/b.txt", to: "c.txt") == "./a/c.txt")
}

// MARK: - P1-8 Yollar ve istatistik

@Test func addPlanNormalizesDotPrefixedFolder() throws {
    let root = try temporaryFolder("nokta")
    defer { StagedExtraction.removeTree(at: root) }
    let file = root.appendingPathComponent("yeni.txt")
    try "y".write(to: file, atomically: true, encoding: .utf8)
    let plan = try AddPlan.make(sources: [file], into: "./belgeler/", stagingRoot: root.appendingPathComponent("hazirlik"))
    #expect(plan.names == ["belgeler"])
    #expect(FileManager.default.fileExists(atPath: try #require(plan.stagingDirectory).appendingPathComponent("belgeler/yeni.txt").path))
}

@Test func statisticsCountAppendedDuplicatesOnce() {
    let listing = ArchiveListing(info: ArchiveInfo(), entries: [
        ArchiveEntry(path: "a.txt", size: 10), ArchiveEntry(path: "b/c.txt", size: 5), ArchiveEntry(path: "a.txt", size: 20),
    ])
    let statistics = ArchiveStatistics(listing: listing)
    #expect(statistics.fileCount == 2)
    #expect(statistics.totalSize == 25)
    #expect(statistics.folderCount == 1)
    // Ağaç da en son girdiyi gösterir.
    #expect(ArchiveTree.build(from: listing.entries).first { $0.id == "a.txt" }?.size == 20)
}

// MARK: - P0-2 Bağlantılar ve yer tutucular

@Test func symlinksAreCheckedAgainstTheMovedContent() throws {
    let staging = try temporaryFolder("baglanti")
    defer { StagedExtraction.removeTree(at: staging) }
    let content = staging.appendingPathComponent("a/b", isDirectory: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("a/dis_b"), withIntermediateDirectories: true)
    try "f".write(to: content.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    let link = { (name: String, target: String) in
        try FileManager.default.createSymbolicLink(atPath: content.appendingPathComponent(name).path, withDestinationPath: target)
    }
    // 7zz mutlak bağlantıları çıkarma klasörüne yönlendirir: "/etc/hosts" → "<hazırlık>/etc/hosts".
    try link("mutlak", staging.path + "/etc/hosts")
    try link("ic_mutlak", staging.path + "/a/b/f.txt")
    try link("kardes", "../dis_b")
    try link("iyi", "f.txt")

    let removed = StagedExtraction.secureSymlinks(in: content, extractionRoot: staging)
    #expect(removed == ["kardes", "mutlak"])
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: content.appendingPathComponent("ic_mutlak").path) == "f.txt")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: content.appendingPathComponent("iyi").path) == "f.txt")
}

@Test func linkPlaceholdersAreRemoved() throws {
    let root = try temporaryFolder("yer")
    defer { StagedExtraction.removeTree(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("a/kotu"))
    try Data().write(to: root.appendingPathComponent("bos.txt"))
    try Data("dolu".utf8).write(to: root.appendingPathComponent("dolu"))
    let removed = StagedExtraction.removeLinkPlaceholders(in: root, links: ["a/kotu", "dolu", "yok"])
    #expect(removed == ["a/kotu"])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("bos.txt").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("dolu").path))
}

@Test func contentRootRejectsSymlinkedFolders() throws {
    let staging = try temporaryFolder("kok")
    let elsewhere = try temporaryFolder("baska")
    defer {
        StagedExtraction.removeTree(at: staging)
        StagedExtraction.removeTree(at: elsewhere)
    }
    try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("b"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("a"), withDestinationURL: elsewhere)
    #expect(StagedExtraction.contentRoot(in: staging, stripping: "a/b") == staging)
}

// MARK: - P0-4 Salt okunur öğeler

@Test func quarantineReachesReadOnlyItems() throws {
    let root = try temporaryFolder("karantina")
    defer { StagedExtraction.removeTree(at: root) }
    let mark = "0081;6ad350b0;Safari;"
    var files: [(URL, UInt16)] = []
    for (name, permissions) in [("rx", 0o555), ("r", 0o444), ("x", 0o111), ("hic", 0o000)] as [(String, UInt16)] {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        chmod(url.path, mode_t(permissions))
        files.append((url, permissions))
    }
    for (url, permissions) in files {
        #expect(Quarantine.set(mark, on: url), "\(url.lastPathComponent)")
        #expect(Quarantine.value(of: url) == mark, "\(url.lastPathComponent)")
        #expect(mode(of: url) == permissions, "\(url.lastPathComponent)")
    }

    // Erişilemeyen (0000) ve salt okunur (0555) klasörlerin içi de işaretlenir; kipler korunur.
    let archive = root.appendingPathComponent("arsiv.zip")
    try Data("zip".utf8).write(to: archive)
    #expect(Quarantine.set(mark, on: archive))
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    let closed = destination.appendingPathComponent("App.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
    let binary = closed.appendingPathComponent("App")
    try Data("bin".utf8).write(to: binary)
    chmod(binary.path, 0o555)
    chmod(closed.path, 0o000)
    chmod(destination.appendingPathComponent("App.app").path, 0o555)
    Quarantine.propagate(from: archive, to: destination, since: .distantPast)
    chmod(closed.path, 0o755)
    #expect(Quarantine.value(of: binary) == Quarantine.derivedValue(from: mark))
    #expect(mode(of: binary) == 0o555)
    #expect(mode(of: destination.appendingPathComponent("App.app")) == 0o555)
}

@Test func replaceWorksOnReadOnlyTargets() throws {
    let root = try temporaryFolder("salt")
    defer { StagedExtraction.removeTree(at: root) }
    let staging = root.appendingPathComponent("hazirlik/klasor", isDirectory: true)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("klasor"), withIntermediateDirectories: true)
    try "yeni".write(to: staging.appendingPathComponent("dosya"), atomically: true, encoding: .utf8)
    try "yeni2".write(to: staging.appendingPathComponent("ek"), atomically: true, encoding: .utf8)
    let old = destination.appendingPathComponent("klasor/dosya")
    try "eski".write(to: old, atomically: true, encoding: .utf8)
    chmod(old.path, 0o444)
    // Önceki bir çıkarmadan kalan salt okunur klasör.
    chmod(destination.appendingPathComponent("klasor").path, 0o555)

    try StagedExtraction.merge(from: root.appendingPathComponent("hazirlik"), into: destination, policy: .replace)
    #expect(try String(contentsOf: old, encoding: .utf8) == "yeni")
    #expect(try String(contentsOf: destination.appendingPathComponent("klasor/ek"), encoding: .utf8) == "yeni2")
    #expect(mode(of: destination.appendingPathComponent("klasor")) == 0o555)
}

@Test func removeTreeDeletesReadOnlyFolders() throws {
    let root = try temporaryFolder("sil")
    let inner = root.appendingPathComponent("a/b", isDirectory: true)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try "x".write(to: inner.appendingPathComponent("f"), atomically: true, encoding: .utf8)
    chmod(inner.path, 0o555)
    chmod(root.appendingPathComponent("a").path, 0o000)
    StagedExtraction.removeTree(at: root)
    #expect(StagedExtraction.itemType(root, fileManager: .default) == nil)
}

// MARK: - P0-3 Arşivin yerine konması

@Test func installedArchiveReplacesOldOneAndStaleVolumes() throws {
    let root = try temporaryFolder("kur")
    defer { StagedExtraction.removeTree(at: root) }
    let staging = root.appendingPathComponent("hazirlik", isDirectory: true)
    let directory = root.appendingPathComponent("hedef", isDirectory: true)
    for folder in [staging, directory] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    try "yeni".write(to: staging.appendingPathComponent("a.zip"), atomically: true, encoding: .utf8)
    let old = directory.appendingPathComponent("a.zip")
    try "eski".write(to: old, atomically: true, encoding: .utf8)
    chmod(old.path, 0o444)
    #expect(try StagedExtraction.installArchive(named: "a.zip", from: staging, into: directory, split: false) == old)
    #expect(try String(contentsOf: old, encoding: .utf8) == "yeni")

    // Bölünmüş: yeni iki parça gelir, eski üç parçanın fazlası kalmaz; benzer adlı dosyalara dokunulmaz.
    for index in 1...2 { try "y\(index)".write(to: staging.appendingPathComponent("b.7z.00\(index)"), atomically: true, encoding: .utf8) }
    for name in ["b.7z.001", "b.7z.002", "b.7z.003", "b.7z.notlar", "b.7z"] {
        try "eski".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let first = try StagedExtraction.installArchive(named: "b.7z", from: staging, into: directory, split: true)
    #expect(first.lastPathComponent == "b.7z.001")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("b.7z") }.sorted()
    #expect(names == ["b.7z", "b.7z.001", "b.7z.002", "b.7z.notlar"])
    #expect(try String(contentsOf: directory.appendingPathComponent("b.7z.002"), encoding: .utf8) == "y2")

    // Aynı adlı bir klasör silinmez.
    try "c".write(to: staging.appendingPathComponent("c.zip"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("c.zip"), withIntermediateDirectories: true)
    #expect(throws: CocoaError.self) { try StagedExtraction.installArchive(named: "c.zip", from: staging, into: directory, split: false) }
    #expect(StagedExtraction.itemType(directory.appendingPathComponent("c.zip"), fileManager: .default) == .typeDirectory)
}

// MARK: - P2-11 Açma güvenliği

@Test func moreRiskyExtensionsAndInvisibleCharacters() throws {
    let root = try temporaryFolder("risk")
    defer { StagedExtraction.removeTree(at: root) }
    for name in ["Akis.workflow", "Eylem.action", "Ek.osax", "Kisayol.url", "Konum.webloc"] {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        #expect(OpenSafety.executableKind(of: url) != nil, "\(name)")
    }
    // U+034F ve U+17B4 "format" kategorisinde değildir ama görünmez.
    #expect(OpenSafety.hasDeceptiveCharacters("fatura\u{034F}.pdf"))
    #expect(OpenSafety.hasDeceptiveCharacters("a\u{17B4}.command"))
    #expect(OpenSafety.visibleName("a\u{034F}b") == "a⟦U+034F⟧b")
    // Emojinin biçim seçicisi görünür karakterin parçasıdır; tek başına ise gizlidir.
    #expect(!OpenSafety.hasDeceptiveCharacters("Kalp ❤\u{FE0F}.txt"))
    #expect(OpenSafety.hasDeceptiveCharacters("fatura\u{FE0F}.pdf"))
}
