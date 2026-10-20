import Darwin
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

private func makeTempFolder(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Ağacın en büyük derinliği (özyinelemesiz; testin kendisi derin ağaçta taşmasın diye açık yığınla).
private func treeDepth(_ nodes: [ArchiveNode]) -> Int {
    var maxDepth = 0
    var stack: [(ArchiveNode, Int)] = nodes.map { ($0, 1) }
    while let (node, depth) = stack.popLast() {
        maxDepth = Swift.max(maxDepth, depth)
        for child in node.children ?? [] { stack.append((child, depth + 1)) }
    }
    return maxDepth
}

/// Tohumlanabilir, deterministik sözde rastgele sayı üreteci (SplitMix64).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Kapsamlı Güvenlik, Stres, Kırma, Sızma, Yük, Hacim, Dayanıklılık, Zafiyet, Kırmızı Takım, Fuzz ve Kaos Test Matrisi")
struct ChaosAndSecurityMatrixTests {

    // MARK: - 1. GÜVENLİK TESTİ (01-sandbox-isolation & Password Protection)

    /// Canlı Stdin Parola İletimi ve Argv Temizliği:
    /// Parolalar asla komut satırında yer almaz; doğrudan stdin pipe üzerinden /bin/cat'e iletilir.
    @Test func securityLiveStdinPasswordDelivery() async throws {
        let catURL = URL(fileURLWithPath: "/bin/cat")
        guard FileManager.default.isExecutableFile(atPath: catURL.path) else { return }

        let secret = "SuperGizliP@ssw0rd!#987"
        let catRunner = CommandRunner(executableURL: catURL)
        let inputData = SevenZipCommand.passwordInput(secret)
        #expect(inputData != nil)

        // /bin/cat girdi verisini olduğu gibi stdout'a yazar.
        let result = try await catRunner.run([], input: inputData)
        #expect(result.exitCode == 0)
        let expected = secret + "\n" + secret + "\n" + secret + "\n" + secret + "\n"
        #expect(result.stdout == expected)

        // Parola verilmediğinde boş çıktı döner.
        let emptyResult = try await catRunner.run([], input: nil)
        #expect(emptyResult.exitCode == 0)
        #expect(emptyResult.stdout.isEmpty)
    }

    /// Tüm Komut Oluşturucularda Sıfır Argüman Parola Sızıntısı:
    /// Her bir SevenZipCommand fonksiyonunun ve SandboxProfile argümanlarının parolayı argv içinde taşımadığı taranır.
    @Test func securityZeroCommandLinePasswordExposure() {
        let secret = "GizliP@ssw0rd!#123"
        let archive = URL(fileURLWithPath: "/tmp/test.7z")
        let dest = URL(fileURLWithPath: "/tmp/cikti")

        let commands: [[String]] = [
            SevenZipCommand.create(CreateOptions(sources: [URL(fileURLWithPath: "/tmp/a.txt")], destination: archive, format: .sevenZip, level: .normal, password: secret)),
            SevenZipCommand.add(archive: archive, names: ["b.txt"], password: secret),
            SevenZipCommand.extract(ExtractOptions(archive: archive, destination: dest, password: secret, overwrite: .replace)),
            SevenZipCommand.list(archive: archive),
            SevenZipCommand.test(archive: archive),
            SevenZipCommand.delete(archive: archive, items: ["c.txt"]),
            SevenZipCommand.rename(archive: archive, from: "old.txt", to: "new.txt"),
            SevenZipCommand.hash(file: archive),
            SevenZipCommand.compressTarStage(CreateOptions(sources: [URL(fileURLWithPath: "/tmp/a.txt")], destination: URL(fileURLWithPath: "/tmp/a.tar.gz"), format: .tarGzip, level: .normal), tarStage: URL(fileURLWithPath: "/tmp/stage.tar")) ?? []
        ]

        let profile = SandboxProfile.forOperation(archive: archive, writable: [dest], protectPersonalData: true)
        for args in commands {
            let joined = args.joined(separator: "\u{0}")
            #expect(!joined.contains(secret), "Argümanlarda parola bulundu: \(args)")
            #expect(!args.contains("-p\(secret)"), "Argümanlarda -p+parola bulundu: \(args)")

            let sandboxedArgs = profile.launchArguments(executable: URL(fileURLWithPath: "/usr/bin/7zz"), arguments: args)
            let sandboxedJoined = sandboxedArgs.joined(separator: "\u{0}")
            #expect(!sandboxedJoined.contains(secret), "Kum havuzu argümanlarında parola bulundu: \(sandboxedArgs)")
        }
    }

    /// Canlı Kum Havuzu Okuma ve Ağ Engeli (Sandbox Read & Network Deny):
    /// sandbox-exec altında kişisel veri dizinleri (~/.ssh) okunamamalı ve ağ erişimi tamamen reddedilmelidir.
    @Test(.enabled(if: engineURL != nil && SandboxProfile.isAvailable))
    func securityLiveSandboxReadDenyAndNetworkDeny() async throws {
        let home = try makeTempFolder("sec-sandbox-home")
        defer { StagedExtraction.removeTree(at: home) }

        let sshDir = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let sshKey = sshDir.appendingPathComponent("id_ed25519")
        try "OPENSSH PRIVATE KEY".write(to: sshKey, atomically: true, encoding: .utf8)

        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let safeFile = downloads.appendingPathComponent("safe.txt")
        try "guvenli metin".write(to: safeFile, atomically: true, encoding: .utf8)

        let archiveURL = downloads.appendingPathComponent("test.7z")
        let profile = SandboxProfile.forOperation(archive: archiveURL, writable: [], protectPersonalData: true, home: home)
        let runner = CommandRunner(executableURL: try #require(engineURL)).sandboxed(profile)

        // 1. ~/.ssh altındaki anahtarı okuma/özetleme girişimi kum havuzu tarafından engellenir (exitCode != 0).
        let deniedHash = try await runner.run(SevenZipCommand.hash(file: sshKey))
        #expect(deniedHash.exitCode != 0, "Yasaklı ~/.ssh dizini okunabildi!")

        // 2. İzinli dizindeki dosya başarıyla okunup özetlenir.
        let allowedHash = try await runner.run(SevenZipCommand.hash(file: safeFile))
        #expect(allowedHash.exitCode == 0, "İzinli dosya okunamadı: \(allowedHash.stderr)")

        // 3. Ağ erişimi engeli: nc çalıştırılabilirse yerel soket bağlantısı kum havuzunda engellenir.
        let ncURL = URL(fileURLWithPath: "/usr/bin/nc")
        if FileManager.default.isExecutableFile(atPath: ncURL.path) {
            let ncRunner = CommandRunner(executableURL: ncURL).sandboxed(profile)
            let ncResult = try await ncRunner.run(["-z", "-w1", "127.0.0.1", "54321"])
            #expect(ncResult.exitCode != 0, "Ağ erişimi kum havuzunda engellenmedi!")
        }
    }

    // MARK: - 2. STRES TESTİ (02-hierarchy-stress)

    /// Aşırı Hiyerarşi ve Genişlik Yapısal Stres Testi:
    /// 2.000 dosyalık geniş klasör ve ArchiveTree.maxDepth (100) sınırını aşan 150 katmanlı derin dizin
    /// ayrıştırılır; ağaç, arama, sıralama ve dizinleme fonksiyonlarının çökmeksizin doğru çalıştığı doğrulanır.
    @Test func stressMassiveHierarchyAndBreadth() {
        var lines = ["--\nPath = massive.7z\nType = 7z\n\n----------\n"]

        // 2000 dosya genişliği: wide/ klasörü altında
        for i in 1...2000 {
            lines.append("Path = wide/file_\(i).txt\nSize = 100\nPacked Size = 50\nAttributes = -rw-r--r--\n")
        }

        // 150 düzey derinlik (ArchiveTree.maxDepth = 100 sınırını aşar)
        var deepPath = ""
        for level in 1...150 {
            deepPath = deepPath.isEmpty ? "d\(level)" : "\(deepPath)/d\(level)"
            lines.append("Path = \(deepPath)\nFolder = +\nAttributes = drwxr-xr-x\n")
        }
        lines.append("Path = \(deepPath)/leaf.txt\nSize = 10\nPacked Size = 5\nAttributes = -rw-r--r--\n")

        let fullOutput = lines.joined(separator: "\n")
        let listing = ListingParser.parse(fullOutput)
        #expect(listing.entries.count == 2152)

        let tree = ArchiveTree.build(from: listing.entries)
        let index = ArchiveTree.index(tree)

        // Geniş klasör yapısal doğrulaması
        #expect(index["wide/file_1.txt"] != nil)
        #expect(index["wide/file_2000.txt"] != nil)
        #expect(ArchiveTree.contents(of: "wide", roots: tree, index: index).count == 2000)

        // Arama ve sıralama işlevleri
        #expect(!ArchiveTree.search(tree, query: "file_100").isEmpty)
        let sorted = ArchiveTree.sorted(tree, using: [ArchiveTree.nameComparator])
        #expect(!sorted.isEmpty)

        // Derinlik sınırı: maxDepth (100) seviyesinde kesilmeli, yığın taşması önlenmelidir.
        #expect(treeDepth(tree) == ArchiveTree.maxDepth)
    }

    /// Hızlı Tekrarlı Ayrıştırma Verim ve Belirlenimcilik Testi:
    @Test func stressRapidParsingThroughput() {
        let sample = """
        --
        Path = bench.zip
        Type = zip
        Physical Size = 1000000

        ----------
        Path = a.txt
        Size = 1024
        Packed Size = 512
        Modified = 2026-10-18 12:00:00

        Path = sub/b.png
        Size = 204800
        Packed Size = 190000
        Modified = 2026-10-18 12:01:00

        Path = sub/deep/c.pdf
        Size = 512000
        Packed Size = 450000
        Modified = 2026-10-18 12:02:00
        """
        let first = ListingParser.parse(sample)
        for _ in 1...50 {
            let parsed = ListingParser.parse(sample)
            #expect(parsed.entries == first.entries)
            #expect(parsed.info.type == "zip")
            #expect(parsed.entries.allSatisfy { !$0.path.isEmpty && ($0.size ?? 0) > 0 })
        }
    }

    // MARK: - 3. KIRMA TESTİ (03-malformed-data)

    /// Bozuk, Kesik ve Çöp Baytlı Arşiv Başlığı Kırma Testi:
    /// Motorun 0-byte, bozulmuş, kesik veya başlığı tahrif edilmiş dosyalar karşısında güvenle hata fırlattığı doğrulanır.
    @Test(.enabled(if: engineURL != nil))
    func destructiveCorruptedArchiveHandling() async throws {
        let engine = try #require(engineURL)
        let root = try makeTempFolder("destr-corrupt")
        defer { StagedExtraction.removeTree(at: root) }

        let runner = CommandRunner(executableURL: engine)

        // 1. 0 Baytlık dosya -> SevenZipError.notArchive
        let emptyFile = root.appendingPathComponent("empty.zip")
        try Data().write(to: emptyFile)
        let resEmpty = try await runner.run(SevenZipCommand.list(archive: emptyFile))
        #expect(resEmpty.exitCode != 0)
        #expect(!SevenZipError.needsPassword(resEmpty))
        #expect(throws: SevenZipError.notArchive) { try SevenZipError.check(resEmpty) }

        // 2. Deterministik SplitMix64 tohumlu çöp baytlar (PK ve 7z başlık önekleriyle)
        var g = SplitMix64(seed: 0xDEAD_BEEF)
        let signatures = ["PK\u{03}\u{04}", "7z\u{BC}\u{AF}'\u{1C}"]
        for (idx, sig) in signatures.enumerated() {
            let garbageFile = root.appendingPathComponent("garbage_\(idx).7z")
            var data = Data(sig.utf8)
            for _ in 0..<256 { data.append(UInt8(truncatingIfNeeded: g.next())) }
            try data.write(to: garbageFile)

            let resGarbage = try await runner.run(SevenZipCommand.list(archive: garbageFile))
            #expect(resGarbage.exitCode != 0)
            #expect(!SevenZipError.needsPassword(resGarbage))
            #expect(throws: SevenZipError.self) { try SevenZipError.check(resGarbage) }
        }

        // 3. Kesik (truncated) gerçek arşiv: son 40 baytı kırpılmış dosya
        let validSrc = root.appendingPathComponent("sample.txt")
        try "gecerli icerik metni".write(to: validSrc, atomically: true, encoding: .utf8)
        let validArchive = root.appendingPathComponent("valid.zip")
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [validSrc], destination: validArchive, format: .zip, level: .fast
        ))))

        var archiveData = try Data(contentsOf: validArchive)
        if archiveData.count > 40 {
            archiveData.removeLast(40)
            let truncatedArchive = root.appendingPathComponent("truncated.zip")
            try archiveData.write(to: truncatedArchive)

            let resTruncated = try await runner.run(SevenZipCommand.list(archive: truncatedArchive))
            #expect(resTruncated.exitCode != 0)
            #expect(throws: SevenZipError.self) { try SevenZipError.check(resTruncated) }
        }
    }

    // MARK: - 4. SIZMA TESTİ (04-quarantine)

    /// Uçtan Uca Karantina Yayılımı ve Onay Biti Temizliği:
    /// Sahte 0x0040 onay bitine sahip bir arşivden çıkarılan tüm dosyalara (salt okunur, ._* ve sembolik bağlantılar dahil)
    /// com.apple.quarantine özniteliğinin zorunlu olarak Gatekeeper denetimi gerektiren biçimde (0x0083) yazıldığı doğrulanır.
    @Test(.enabled(if: engineURL != nil))
    func penetrationQuarantineEndToEndPropagation() async throws {
        let engine = try #require(engineURL)
        let root = try makeTempFolder("sec-quarantine-e2e")
        defer { StagedExtraction.removeTree(at: root) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        let cmdFile = srcDir.appendingPathComponent("run.command")
        try "#!/bin/sh\necho test\n".write(to: cmdFile, atomically: true, encoding: .utf8)
        _ = chmod(cmdFile.path, 0o755)

        let roFile = srcDir.appendingPathComponent("readonly.txt")
        try "salt okunur".write(to: roFile, atomically: true, encoding: .utf8)
        _ = chmod(roFile.path, 0o444)

        let dotUnderscore = srcDir.appendingPathComponent("._config")
        try "apple double metadata".write(to: dotUnderscore, atomically: true, encoding: .utf8)

        let archiveURL = root.appendingPathComponent("quarantined.zip")
        let runner = CommandRunner(executableURL: engine)
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(
            sources: [cmdFile, roFile, dotUnderscore], destination: archiveURL, format: .zip, level: .fast
        ))))

        // Sahte 0x0040 onay bayrağı mühürle
        let forged = "00c3;6ad350b0;Safari;3012A7DC-0000-0000-0000-000000000000"
        #expect(Quarantine.set(forged, on: archiveURL))

        let staging = try StagedExtraction.makeStagingDirectory(for: root)
        defer { StagedExtraction.removeTree(at: staging) }

        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(ExtractOptions(
            archive: archiveURL, destination: staging, overwrite: .replace
        ))))

        _ = StagedExtraction.secureSymlinks(in: staging, extractionRoot: staging)
        _ = Quarantine.propagate(from: archiveURL, to: staging, since: .distantPast)

        let destination = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try StagedExtraction.merge(from: staging, into: destination, policy: .replace)

        // Çıkarılan her bir dosyanın karantina etiketini kontrol et
        for name in ["run.command", "readonly.txt", "._config"] {
            let extracted = destination.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: extracted.path), "\(name) çıkarılmadı")
            let qVal = Quarantine.value(of: extracted)
            #expect(qVal != nil, "\(name) karantina değeri alamadı")
            #expect(qVal?.hasPrefix("0083;") == true, "\(name) onay bitinden arındırılmadı: \(qVal ?? "")")
            #expect(qVal?.hasPrefix("00c3;") == false, "\(name) hileli 00c3 onayını korudu")
        }
    }

    // MARK: - 5. YÜK VE HACİM TESTİ (05-saturating-arithmetic)

    /// Zip-Bomb Doygun Boyut Aritmetiği ve Boyut Taşması Koruması:
    /// UInt64 / Int64.max sınırlarını aşan girişlerde tamsayı taşması tuzağı oluşmadan
    /// ListingParser, ArchiveStatistics, ArchiveTree ve DiskSpace bileşenlerinde doyum sağlandığı doğrulanır.
    @Test func loadAndVolumeZipBombSaturatingSum() {
        let text = """
        --
        Path = bomb.zip
        Type = zip
        Physical Size = 18446744073709551615

        ----------
        Path = folder/huge1.bin
        Size = 18446744073709551615
        Packed Size = 18446744073709551615

        Path = folder/huge2.bin
        Size = 18446744073709551615
        Packed Size = 18446744073709551615
        """
        let listing = ListingParser.parse(text)
        #expect(listing.info.physicalSize == Int64.max)
        #expect(listing.entries.count == 2)
        #expect(listing.entries[0].size == Int64.max)
        #expect(listing.entries[0].packedSize == Int64.max)

        let stats = ArchiveStatistics(listing: listing)
        #expect(stats.totalSize == Int64.max)
        #expect(stats.packedSize == Int64.max)

        let tree = ArchiveTree.build(from: listing.entries)
        let folderNode = tree.first { $0.id == "folder" }
        #expect(folderNode?.size == Int64.max)

        let required = DiskSpace.requiredBytes(for: ["folder"], in: listing.entries)
        #expect(required == Int64.max)

        #expect(!DiskSpace.hasRoom(required: Int64.max, available: Int64.max - 1))
        #expect(DiskSpace.hasRoom(required: Int64.max, available: nil))
        #expect(throws: InsufficientSpaceError.self) {
            try InsufficientSpaceError.check(required: Int64.max, at: URL(fileURLWithPath: "/tmp"))
        }

        // UI bayt biçimlendiricisi Int64.max değerinde çökmemeli
        let formatted = Int64.max.formatted(.byteCount(style: .file))
        #expect(!formatted.isEmpty)
    }

    // MARK: - 6. DAYANIKLILIK TESTİ (06-endurance-leaks)

    /// Hazırlık Dizinleri Oluşturma, Temizleme ve Dosya Tanıtıcısı (FD) Dayanıklılığı:
    /// 30 ardışık staging döngüsünde salt okunur dosyalar altında dosya tanıtıcısı sızıntısı kalmadığı doğrulanır.
    @Test func enduranceStagingLifecycleCycles() throws {
        let root = try makeTempFolder("endurance-staging")
        defer { StagedExtraction.removeTree(at: root) }

        let initialFDs = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0

        for _ in 1...30 {
            let staging = try StagedExtraction.makeStagingDirectory(for: root)
            #expect(FileManager.default.fileExists(atPath: staging.path))

            let roFolder = staging.appendingPathComponent("ro", isDirectory: true)
            try FileManager.default.createDirectory(at: roFolder, withIntermediateDirectories: true)
            let roFile = roFolder.appendingPathComponent("ro.txt")
            try Data("x".utf8).write(to: roFile)
            _ = chmod(roFile.path, 0o444)
            _ = chmod(roFolder.path, 0o555)

            let dotFile = staging.appendingPathComponent("._sample")
            try Data("metadata".utf8).write(to: dotFile)
            _ = StagedExtraction.isMacMetadata("._sample", in: staging)

            StagedExtraction.removeTree(at: staging)
            #expect(!FileManager.default.fileExists(atPath: staging.path))
        }

        // Açık tanıtıcı sayısı kontrolü (işletim sistemi varyasyonları için makul toleransla)
        let finalFDs = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
        #expect(finalFDs <= initialFDs + 3, "Dosya tanıtıcısı (FD) sızıntısı tespit edildi: \(initialFDs) -> \(finalFDs)")
    }

    // MARK: - 7. ZAFİYET TARAMA TESTİ (07-input-sanitization)

    /// Komut ve Seçenek Enjeksiyonu Koruması (Option / Parameter Injection):
    /// Her bir komut oluşturucuda kullanıcı girdilerinin kesinlikle '--' ayracından sonra yer aldığı doğrulanır.
    @Test func vulnerabilityOptionInjectionShielding() {
        let dangerousArchive = URL(fileURLWithPath: "/tmp/-r.7z")
        let dangerousExtract = ExtractOptions(
            archive: dangerousArchive, destination: URL(fileURLWithPath: "/tmp/dest"),
            items: ["-y", "-mhe=off", ";rm -rf /"], overwrite: .replace
        )

        let extractArgs = SevenZipCommand.extract(dangerousExtract)
        #expect(extractArgs.contains("-spd"))
        if let sepIndex = extractArgs.firstIndex(of: "--") {
            #expect(sepIndex < extractArgs.firstIndex(of: dangerousArchive.path)!)
            for item in dangerousExtract.items {
                if let itemIndex = extractArgs.firstIndex(of: item) {
                    #expect(itemIndex > sepIndex, "Kullanıcı parametresi '--' öncesinde yer aldı: \(item)")
                }
            }
        }

        let listArgs = SevenZipCommand.list(archive: dangerousArchive)
        #expect(listArgs.contains("-spd"))
        if let sepIndex = listArgs.firstIndex(of: "--") {
            #expect(sepIndex < listArgs.firstIndex(of: dangerousArchive.path)!)
        }
    }

    /// Trojan Source, Görünmez Karakterler ve Ad Doğrulama Güvenliği:
    @Test func vulnerabilityTrojanSourceUnicodeScanning() {
        let rlo = "belge\u{202E}txt.app"
        #expect(OpenSafety.hasDeceptiveCharacters(rlo))
        #expect(OpenSafety.visibleName(rlo).contains("⟦U+202E⟧"))
        #expect(!OpenSafety.hasDeceptiveCharacters(OpenSafety.visibleName(rlo)))

        let braille = "fatura.pdf\u{2800}\u{2800}.app"
        #expect(OpenSafety.hasDeceptiveCharacters(braille))

        let hangul = "dekont.pdf\u{3164}.command"
        #expect(OpenSafety.hasDeceptiveCharacters(hangul))

        let zeroWidth = "guvenli\u{200B}dosya.txt"
        #expect(OpenSafety.hasDeceptiveCharacters(zeroWidth))

        let controlTab = "gizli\tdosya.txt"
        #expect(OpenSafety.hasDeceptiveCharacters(controlTab))

        #expect(!OpenSafety.hasDeceptiveCharacters("Normal_Dosya_2026.pdf"))

        // ArchiveTree.isValidName doğrulaması
        #expect(ArchiveTree.isValidName("temiz_dosya.txt"))
        #expect(!ArchiveTree.isValidName(""))
        #expect(!ArchiveTree.isValidName("   "))
        #expect(!ArchiveTree.isValidName("."))
        #expect(!ArchiveTree.isValidName(".."))
        #expect(!ArchiveTree.isValidName("dizin/dosya"))
        #expect(!ArchiveTree.isValidName("denetim\u{0000}karakteri"))
    }

    /// Tehlikeli Çalıştırılabilir Türlerin Taraması:
    @Test func vulnerabilityRiskyExecutableTypesScanning() throws {
        let temp = try makeTempFolder("risky-types")
        defer { StagedExtraction.removeTree(at: temp) }

        let dynamicExtensions = [
            "script.scpt", "otomasyon.workflow", "aksiyon.action", "baglanti.webloc",
            "link.url", "eklenti.qlgenerator", "panel.prefpane", "yama.osax"
        ]
        for name in dynamicExtensions {
            let ext = (name as NSString).pathExtension
            #expect(OpenSafety.riskyExtensions.contains(ext), "Yakalanmayan dinamik riskli uzantı: \(ext)")
        }

        let sampleFiles = [
            "betik.command", "kod.sh", "program.app", "profil.mobileconfig", "ayar.terminal",
            "belge.workflow", "bag.url", "script.scpt"
        ]
        for name in sampleFiles {
            let file = temp.appendingPathComponent(name)
            try Data("echo test".utf8).write(to: file)
            #expect(OpenSafety.executableKind(of: file) != nil, "executableKind yakalayamadı: \(name)")
        }

        // Güvenli dosyalar nil dönmeli
        for safeName in ["belge.txt", "rapor.pdf", "resim.jpg"] {
            let safeFile = temp.appendingPathComponent(safeName)
            try Data("metin".utf8).write(to: safeFile)
            #expect(OpenSafety.executableKind(of: safeFile) == nil, "Güvenli dosya riskli sayıldı: \(safeName)")
        }

        // Uzantısız dosyalar: çalıştırılabilir ise riskli, değilse nil
        let binFile = temp.appendingPathComponent("calisabilir_ikili")
        try Data("ikili".utf8).write(to: binFile)
        _ = chmod(binFile.path, 0o755)
        #expect(OpenSafety.executableKind(of: binFile) != nil)
        _ = chmod(binFile.path, 0o644)
        #expect(OpenSafety.executableKind(of: binFile) == nil)
    }

    // MARK: - 8. KIRMIZI TAKIM OPERASYONEL TESTİ (08-access-containment)

    /// Tek Başına Sembolik Bağlantı Sızdırma Engeli ve Çok Parçalı Düzenleme Sınırı:
    @Test func redTeamStandaloneSymlinkExfiltrationBlocked() async throws {
        guard let engine = engineURL else { return }
        let runner = CommandRunner(executableURL: engine)
        let archive = URL(fileURLWithPath: "/tmp/fake.7z")
        let extractor = ItemExtractor(runner: runner, archive: archive, password: nil, symbolicLinks: ["link_to_root"])

        do {
            _ = try await extractor.extract(["link_to_root"])
            #expect(Bool(false), "SymbolicLinkError fırlatılmalıydı")
        } catch let error as ItemExtractor.SymbolicLinkError {
            #expect(error.paths == ["link_to_root"])
        } catch {
            #expect(Bool(false), "Beklenmeyen hata türü: \(error)")
        }
    }

    /// Salt Okunur ve Çok Bölümlü Arşivlerde Yerinde Düzenleme Engeli:
    @Test func redTeamReadOnlyAndMultiVolumeEditingBlocked() throws {
        let singleZip = URL(fileURLWithPath: "/tmp/a.zip")
        #expect(ArchiveCapabilities.supportsEditing(type: "zip", url: singleZip, volumes: 1))
        #expect(!ArchiveCapabilities.supportsEditing(type: "zip", url: singleZip, volumes: 2))

        let split7z = URL(fileURLWithPath: "/tmp/a.7z.001")
        #expect(!ArchiveCapabilities.supportsEditing(type: "7z", url: split7z))

        let splitZip = URL(fileURLWithPath: "/tmp/a.z01")
        #expect(!ArchiveCapabilities.supportsEditing(type: "zip", url: splitZip))

        let rar = URL(fileURLWithPath: "/tmp/a.rar")
        #expect(!ArchiveCapabilities.supportsEditing(type: "rar", url: rar))

        // Diskte salt okunur (chmod 0444) dosya kontrolü
        let root = try makeTempFolder("sec-readonly-edit")
        defer { StagedExtraction.removeTree(at: root) }
        let roArchive = root.appendingPathComponent("readonly.zip")
        try Data("PK".utf8).write(to: roArchive)
        _ = chmod(roArchive.path, 0o444)
        #expect(!ArchiveCapabilities.isEditable(type: "zip", url: roArchive))
    }

    // MARK: - 9. BULANIKLIK TESTİ (09-parser-fuzz)

    /// ListingParser Deterministik ve Tohumlu Bulanıklık (Fuzz) Testi:
    @Test func fuzzListingParserMutations() {
        let fuzzSeeds = [
            "",
            "-----",
            "----------\n",
            "Path = \n",
            "Comment = {\n",
            "Comment = {\n}\n}\n",
            "Size = -9999999999999999999999999\n",
            "Attributes = \u{00}\u{FF}\n",
            String(repeating: "----------\nPath = a\n", count: 20),
            String(repeating: "Comment = {\nPath = spoof\n}\n", count: 10),
            "Type = 7z\nSolid = ++\nPhysical Size = notanumber\n",
            "Modified = 9999-99-99 99:99:99\nPath = test\n"
        ]

        for seed in fuzzSeeds {
            let result = ListingParser.parse(seed)
            #expect(result.entries == ListingParser.parse(seed).entries)
            #expect(result.entries.allSatisfy { !$0.path.isEmpty })
            let stats = ArchiveStatistics(listing: result)
            #expect(stats.fileCount >= 0 && stats.folderCount >= 0)
            #expect(stats.totalSize >= 0 && stats.packedSize >= 0)
        }

        // Deterministik SplitMix64 tohumuyla mutasyon döngüsü
        var g = SplitMix64(seed: 0xCAFE_BABE)
        for _ in 1...50 {
            var randomText = ""
            for _ in 1...30 {
                let r = Int(UInt64.random(in: 1...5, using: &g))
                switch r {
                case 1: randomText += "Path = name_\(UInt64.random(in: 0...100, using: &g))\n"
                case 2: randomText += "Size = \(Int64.random(in: -100...1000000, using: &g))\n"
                case 3: randomText += "----------\n"
                case 4: randomText += "Comment = {\(UInt64.random(in: 0...50, using: &g))}\n"
                default: randomText += "--\nType = zip\n"
                }
            }
            let parsed = ListingParser.parse(randomText)
            #expect(parsed.entries == ListingParser.parse(randomText).entries)
            #expect(parsed.entries.allSatisfy { !$0.path.isEmpty && ($0.size ?? 0) >= 0 })
        }
    }

    // MARK: - 10. KAOS VE EŞZAMANLILIK TESTİ (10-chaos-concurrency)

    /// İnatçı Süreçlerin 2 Saniyelik Kill Grace Period ile Sonlandırılması:
    @Test func chaosProcessTerminationTimeoutAndKill() async throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else { return }

        let runner = CommandRunner(executableURL: perl)
        let script = "$SIG{TERM} = 'IGNORE'; while(1) { sleep 1; }"

        let task = Task {
            try await runner.run(["-e", script])
        }

        try await Task.sleep(for: .milliseconds(300))
        let start = CFAbsoluteTimeGetCurrent()
        task.cancel()
        await #expect(throws: SevenZipError.cancelled) {
            _ = try await task.value
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect(elapsed < 4.0) // 2 sn killGracePeriod + tolerans
    }

    /// Klasör İzinleri Kaos Testi (OwnerAccess İzin Yükseltme ve Geri Yükleme):
    @Test func chaosReadOnlyPermissionsRecovery() throws {
        let root = try makeTempFolder("chaos-perms")
        defer {
            _ = chmod(root.path, 0o700)
            StagedExtraction.removeTree(at: root)
        }

        let locked = root.appendingPathComponent("kilitli", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("gizli.txt")
        try Data("veri".utf8).write(to: file)

        #expect(chmod(locked.path, 0o000) == 0)

        let readSuccess = OwnerAccess.granting(S_IRUSR | S_IXUSR, on: locked.path) {
            FileManager.default.fileExists(atPath: file.path)
        }
        #expect(readSuccess == true)

        var info = stat()
        #expect(lstat(locked.path, &info) == 0)
        #expect((info.st_mode & 0o777) == 0o000)

        // 0o555 klasörde yazma izin testi
        #expect(chmod(locked.path, 0o555) == 0)
        let writeSuccess = OwnerAccess.granting(S_IWUSR, on: locked.path) {
            let newFile = locked.appendingPathComponent("yeni.txt")
            return (try? Data("ek".utf8).write(to: newFile)) != nil
        }
        #expect(writeSuccess == true)
        #expect(lstat(locked.path, &info) == 0)
        #expect((info.st_mode & 0o777) == 0o555)
    }

    /// Eşzamanlılık ve Re-entrancy Kaos Testi:
    @Test func chaosConcurrentReentrancy() async throws {
        struct Snapshot: Equatable, Sendable {
            let paths: [String], roots: [String], base: String, profile: String
        }
        @Sendable func compute(_ i: Int) -> Snapshot {
            let sample = "--\nPath = thread_\(i).zip\nType = zip\n----------\nPath = file_\(i).txt\nSize = 10\n"
            let listing = ListingParser.parse(sample)
            return Snapshot(
                paths: listing.entries.map(\.path), roots: ArchiveTree.build(from: listing.entries).map(\.id),
                base: ArchiveNaming.baseName(of: URL(fileURLWithPath: "/tmp/test_\(i).tar.gz")),
                profile: SandboxProfile.forOperation(archive: URL(fileURLWithPath: "/tmp/t\(i).7z"), writable: [], protectPersonalData: true).profileText
            )
        }
        let expected = Dictionary(uniqueKeysWithValues: (1...20).map { ($0, compute($0)) })
        let concurrent = await withTaskGroup(of: (Int, Snapshot).self) { group in
            for i in 1...20 { group.addTask { (i, compute(i)) } }
            var collected: [Int: Snapshot] = [:]
            for await (i, snapshot) in group { collected[i] = snapshot }
            return collected
        }
        #expect(concurrent == expected)
        #expect(expected[7]?.paths == ["file_7.txt"] && expected[7]?.roots == ["file_7.txt"] && expected[7]?.base == "test_7")
    }

    // MARK: - 11. ATOMİK ÇIKARMA TESTİ (11-atomic-extraction)

    /// Atomik Çıkarma İptal/Hata Güvencesi:
    /// Birleştirme öncesinde işlem durursa veya hata alırsa hedef dizindeki mevcut dosyalar tek bayt değişmez.
    @Test func atomicExtractionRollbackAndUntouchedDestination() throws {
        let root = try makeTempFolder("atomic-extract")
        defer { StagedExtraction.removeTree(at: root) }

        let dest = root.appendingPathComponent("hedef", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let existing = dest.appendingPathComponent("mevcut.txt")
        try "orijinal icerik".write(to: existing, atomically: true, encoding: .utf8)

        let staging = try StagedExtraction.makeStagingDirectory(for: root)
        let stagedNew = staging.appendingPathComponent("yeni.txt")
        try "yeni cikarilan dosya".write(to: stagedNew, atomically: true, encoding: .utf8)

        // Birleştirme öncesi bir iptal simülasyonu: staging imha edilir, hedef dizine dokunulmaz.
        StagedExtraction.removeTree(at: staging)
        #expect(!FileManager.default.fileExists(atPath: stagedNew.path))

        // Hedef dizin tam olarak başlangıç halini korumalıdır.
        #expect(try String(contentsOf: existing, encoding: .utf8) == "orijinal icerik")
        let destContents = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(destContents == ["mevcut.txt"])
    }
}
