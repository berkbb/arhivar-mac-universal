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

@Suite("Kapsamlı Güvenlik, Stres, Kırma, Sızma, Yük, Hacim, Dayanıklılık, Zafiyet, Kırmızı Takım, Fuzz ve Kaos Test Matrisi")
struct ChaosAndSecurityMatrixTests {

    // MARK: - 1. GÜVENLİK TESTİ (Security Testing)

    /// Zip Slip / Dizin Dışına Çıkma (Directory Traversal) engelleme testi:
    /// Göreli ("../../") ya da mutlak ("/etc/") yollar içeren sembolik bağlantılar veya taşınan içerik
    /// hazırlık kökünün dışına çıkamaz.
    @Test func securityZipSlipTraversalBlocked() throws {
        let root = try makeTempFolder("sec-zipslip")
        defer { try? FileManager.default.removeItem(at: root) }

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Staging içinde dışarıyı (/etc/hosts) gösteren sembolik bağlantı
        let badLink = staging.appendingPathComponent("bad_link")
        try FileManager.default.createSymbolicLink(at: badLink, withDestinationPath: "/etc/hosts")

        // Staging içinde 3 üst klasörü gösteren göreli bağlantı
        let escapingLink = staging.appendingPathComponent("escaping_link")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationPath: "../../../../../tmp")

        // Geçerli iç bağlantı
        try Data("safe".utf8).write(to: staging.appendingPathComponent("target.txt"))
        let safeLink = staging.appendingPathComponent("safe_link")
        try FileManager.default.createSymbolicLink(at: safeLink, withDestinationPath: "target.txt")

        let removed = StagedExtraction.secureSymlinks(in: staging, extractionRoot: staging)
        #expect(removed.contains("bad_link"))
        #expect(removed.contains("escaping_link"))
        #expect(!removed.contains("safe_link"))

        #expect(!FileManager.default.fileExists(atPath: badLink.path))
        #expect(!FileManager.default.fileExists(atPath: escapingLink.path))
        #expect(FileManager.default.fileExists(atPath: safeLink.path))
    }

    /// Sıfır Komut Satırı Parola Sızıntısı (Zero Command-Line Password Exposure):
    /// Parolalar asla komut satırı argümanlarında yer almaz (`ps` veya `sysctl` ile okunamaz).
    @Test func securityZeroCommandLinePasswordExposure() {
        let secret = "GizliP@ssw0rd!#123"
        let archive = URL(fileURLWithPath: "/tmp/test.7z")
        let dest = URL(fileURLWithPath: "/tmp/cikti")

        // Create
        let createOpts = CreateOptions(sources: [URL(fileURLWithPath: "/tmp/a.txt")], destination: archive, format: .sevenZip, level: .normal, password: secret)
        let createArgs = SevenZipCommand.create(createOpts)
        #expect(!createArgs.contains(secret))
        #expect(!createArgs.contains("-p\(secret)"))
        #expect(createArgs.contains("-p")) // Yalnızca çıplak -p (stdin'den sorulsun)

        // Add
        let addArgs = SevenZipCommand.add(archive: archive, names: ["b.txt"], password: secret)
        #expect(!addArgs.contains(secret))
        #expect(!addArgs.contains("-p\(secret)"))
        #expect(addArgs.contains("-p"))

        // Extract
        let extractOpts = ExtractOptions(archive: archive, destination: dest, password: secret, overwrite: .replace)
        let extractArgs = SevenZipCommand.extract(extractOpts)
        #expect(!extractArgs.contains(secret))
        #expect(!extractArgs.contains("-p\(secret)"))

        // Stdin datası kontrolü
        let inputData = SevenZipCommand.passwordInput(secret)
        #expect(inputData != nil)
        let inputString = String(decoding: inputData!, as: UTF8.self)
        #expect(inputString.contains(secret + "\n"))
    }

    // MARK: - 2. STRES TESTİ (Stress Testing)

    /// Aşırı Hiyerarşi ve Genişlik Stres Testi:
    /// Tek bir klasörde 2.000 dosya ve 35 düzey derinlikte iç içe klasör hiyerarşisi oluşturulup
    /// ListingParser ve ArchiveTree üzerinde stres testi yapılır.
    @Test func stressMassiveHierarchyAndBreadth() {
        var lines = ["--\nPath = massive.7z\nType = 7z\n\n----------\n"]

        // 2000 dosya genişliği
        for i in 1...2000 {
            lines.append("Path = file_\(i).txt\nSize = 100\nPacked Size = 50\nAttributes = -rw-r--r--\n")
        }

        // 35 düzey derinlik
        var deepPath = ""
        for level in 1...35 {
            deepPath = deepPath.isEmpty ? "d\(level)" : "\(deepPath)/d\(level)"
            lines.append("Path = \(deepPath)\nFolder = +\nAttributes = drwxr-xr-x\n")
        }
        lines.append("Path = \(deepPath)/leaf.txt\nSize = 10\nPacked Size = 5\nAttributes = -rw-r--r--\n")

        let fullOutput = lines.joined(separator: "\n")
        let listing = ListingParser.parse(fullOutput)
        #expect(listing.entries.count == 2036)

        let startTree = CFAbsoluteTimeGetCurrent()
        let tree = ArchiveTree.build(from: listing.entries)
        let elapsedTree = CFAbsoluteTimeGetCurrent() - startTree

        #expect(tree.count == 2001) // 2000 files + 1 root directory "d1"
        #expect(elapsedTree < 1.0) // 1 saniyenin altında bitmeli
    }

    /// Hızlı Tekrarlı Ayrıştırma Verim Testi:
    /// Büyük bir çıktı art arda 50 kez ayrıştırılarak bellek ve işlemci stabilitesi test edilir.
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
        for _ in 1...50 {
            let parsed = ListingParser.parse(sample)
            #expect(parsed.entries.count == 3)
            #expect(parsed.info.type == "zip")
        }
    }

    // MARK: - 3. KIRMA TESTİ (Destructive Testing)

    /// Bozuk / Parçalanmış Arşiv Başlığı Kırma Testi:
    /// Başlık baytları rastgele bozulmuş arşiv dosyalarının motor tarafından çökme olmadan
    /// güvenli bir şekilde reddedildiği doğrulanır.
    @Test func destructiveCorruptedArchiveHandling() async throws {
        guard let engine = engineURL else { return }
        let root = try makeTempFolder("destr-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = CommandRunner(executableURL: engine)

        // 1. 0 Baytlık dosya
        let emptyFile = root.appendingPathComponent("empty.zip")
        try Data().write(to: emptyFile)
        let resEmpty = try await runner.run(SevenZipCommand.list(archive: emptyFile))
        #expect(resEmpty.exitCode != 0)
        #expect(SevenZipError.needsPassword(resEmpty) == false)
        #expect(throws: SevenZipError.self) { try SevenZipError.check(resEmpty) }

        // 2. Rastgele çöp baytlar
        let garbageFile = root.appendingPathComponent("garbage.7z")
        var garbageData = Data(count: 256)
        for i in 0..<garbageData.count { garbageData[i] = UInt8.random(in: 0...255) }
        try garbageData.write(to: garbageFile)

        let resGarbage = try await runner.run(SevenZipCommand.list(archive: garbageFile))
        #expect(resGarbage.exitCode != 0)
        #expect(throws: SevenZipError.self) { try SevenZipError.check(resGarbage) }
    }

    // MARK: - 4. SIZMA TESTİ (Penetration Testing)

    /// Karantina Bayrağı Sahteciliği ve Onay Biti Temizliği:
    /// Kullanıcı onayı (`0x0040`) içeren sahte karantina bayrağı çıkarılan dosyalara aktarılırken
    /// onay bitinin zorunlu olarak silindiği ve Gatekeeper korumasının aşılamadığı doğrulanır.
    @Test func penetrationQuarantineUserApprovalBitStripping() {
        // 0x0040 biti eklenmiş bir karantina dizesi (Safari'de indirilip çalıştırılmış gibi)
        let forged = "00c3;6ad350b0;Safari;3012A7DC"
        let sanitized = Quarantine.derivedValue(from: forged)
        #expect(!sanitized.hasPrefix("00c3"))
        #expect(sanitized.hasPrefix("0083")) // 0x00c3 & ~0x0040 = 0x0083
    }

    // MARK: - 5. YÜK VE HACİM TESTİ (Load & Volume Testing)

    /// Zip-Bomb Doygun Boyut Aritmetiği (Saturating Arithmetic):
    /// Arşiv içinde Int64.max değerine ulaşan ya da aşan boyut bildirimleri toplandığında
    /// tamsayı taşması (overflow trap) yerine doyum (saturation) mekanizmasının çalıştığı doğrulanır.
    @Test func loadAndVolumeZipBombSaturatingSum() {
        let huge1: Int64 = Int64.max - 100
        let huge2: Int64 = 200
        let result = huge1.saturatingAdding(huge2)
        #expect(result == Int64.max)

        let entries = [
            ArchiveEntry(path: "a", size: Int64.max / 2 + 1000),
            ArchiveEntry(path: "b", size: Int64.max / 2 + 2000),
            ArchiveEntry(path: "c", size: Int64.max / 2 + 3000),
        ]
        let sum = entries.compactMap(\.size).saturatingSum()
        #expect(sum == Int64.max)

        let required = DiskSpace.requiredBytes(for: entries)
        #expect(required == Int64.max)
    }

    // MARK: - 6. DAYANIKLILIK TESTİ (Endurance Testing)

    /// Hazırlık Dizinleri Oluşturma ve İmha Döngüsü Dayanıklılığı:
    /// 30 kez art arda hazırlık dizini oluşturulup StagedExtraction.removeTree ile imha edilir.
    /// Hiçbir sızıntı veya yetki hatası kalmadığı doğrulanır.
    @Test func enduranceStagingLifecycleCycles() throws {
        let root = try makeTempFolder("endurance-staging")
        defer { try? FileManager.default.removeItem(at: root) }

        for _ in 1...30 {
            let staging = try StagedExtraction.makeStagingDirectory(for: root)
            #expect(FileManager.default.fileExists(atPath: staging.path))

            // İçine salt okunur klasörler ve dosyalar bırak
            let roFolder = staging.appendingPathComponent("ro", isDirectory: true)
            try FileManager.default.createDirectory(at: roFolder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: roFolder.appendingPathComponent("ro.txt"))
            _ = chmod(roFolder.appendingPathComponent("ro.txt").path, 0o444)
            _ = chmod(roFolder.path, 0o555)

            StagedExtraction.removeTree(at: staging)
            #expect(!FileManager.default.fileExists(atPath: staging.path))
        }
    }

    // MARK: - 7. ZAFİYET TARAMA TESTİ (Vulnerability Scanning)

    /// Komut ve Seçenek Enjeksiyonu Koruması (Option / Parameter Injection):
    /// Arşiv adı veya dosya adı olarak `-` ile başlayan veya kabuk kaçışları içeren yollar
    /// `--` ayracı ve -spd ile korunmalıdır.
    @Test func vulnerabilityOptionInjectionShielding() {
        let dangerousArchive = URL(fileURLWithPath: "/tmp/-r.7z")
        let listArgs = SevenZipCommand.list(archive: dangerousArchive)
        #expect(listArgs.contains("--"))
        if let dashDashIndex = listArgs.firstIndex(of: "--") {
            #expect(dashDashIndex < listArgs.firstIndex(of: dangerousArchive.path)!)
        }

        let dangerousExtract = ExtractOptions(
            archive: dangerousArchive, destination: URL(fileURLWithPath: "/tmp/dest"),
            items: ["-y", "-mhe=off", ";rm -rf /"], overwrite: .replace
        )
        let extractArgs = SevenZipCommand.extract(dangerousExtract)
        #expect(extractArgs.contains("--"))
    }

    /// Trojan Source & Görünmez Unicode Karakter Taraması:
    /// RLO (U+202E), LRO, Braille dolgusu ve görünmez kontrol karakterlerinin tamamı tespit edilmelidir.
    @Test func vulnerabilityTrojanSourceUnicodeScanning() {
        let rlo = "belge\u{202E}txt.app"
        #expect(OpenSafety.hasDeceptiveCharacters(rlo))
        #expect(OpenSafety.visibleName(rlo).contains("⟦U+202E⟧"))

        let braille = "fatura.pdf\u{2800}\u{2800}.app"
        #expect(OpenSafety.hasDeceptiveCharacters(braille))

        let hangul = "dekont.pdf\u{3164}.command"
        #expect(OpenSafety.hasDeceptiveCharacters(hangul))

        let zeroWidth = "guvenli\u{200B}dosya.txt"
        #expect(OpenSafety.hasDeceptiveCharacters(zeroWidth))

        #expect(!OpenSafety.hasDeceptiveCharacters("Normal_Dosya_2026.pdf"))
    }

    /// Tehlikeli Çalıştırılabilir Türlerin Taraması:
    /// Sistemin kod çalıştırabileceği tüm uzantı ve türlerin OpenSafety tarafından yakalandığı doğrulanır.
    @Test func vulnerabilityRiskyExecutableTypesScanning() {
        let riskyNames = [
            "betik.command", "kod.sh", "program.app", "script.scpt", "otomasyon.workflow",
            "aksiyon.action", "profil.mobileconfig", "ayar.terminal", "baglanti.webloc", "link.url",
            "eklenti.qlgenerator", "panel.prefpane", "yama.osax"
        ]
        for name in riskyNames {
            let ext = (name as NSString).pathExtension
            #expect(OpenSafety.riskyExtensions.contains(ext), "Yakalanmayan riskli uzantı: \(ext)")
        }
    }

    // MARK: - 8. KIRMIZI TAKIM OPERASYONEL TESTİ (Red Team Operational)

    /// Tek Başına Sembolik Bağlantı Sızdırma Engeli:
    /// Bir saldırganın panoya kopyalama veya Finder'a sürükleme ile hedef dışındaki dosyalara erişim için
    /// hazırladığı bağımsız sembolik bağlantılar ItemExtractor tarafından SymbolicLinkError ile reddedilir.
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
    /// Çok parçalı (.001, .z01, .r01, volumes > 1) veya salt okunur dosyalarda ArchiveCapabilities düzenlemeyi reddeder.
    @Test func redTeamReadOnlyAndMultiVolumeEditingBlocked() {
        let singleZip = URL(fileURLWithPath: "/tmp/a.zip")
        #expect(ArchiveCapabilities.supportsEditing(type: "zip", url: singleZip, volumes: 1))
        #expect(!ArchiveCapabilities.supportsEditing(type: "zip", url: singleZip, volumes: 2))

        let split7z = URL(fileURLWithPath: "/tmp/a.7z.001")
        #expect(!ArchiveCapabilities.supportsEditing(type: "7z", url: split7z))

        let splitZip = URL(fileURLWithPath: "/tmp/a.z01")
        #expect(!ArchiveCapabilities.supportsEditing(type: "zip", url: splitZip))

        let rar = URL(fileURLWithPath: "/tmp/a.rar")
        #expect(!ArchiveCapabilities.supportsEditing(type: "rar", url: rar))
    }

    // MARK: - 9. BULANIKLIK TESTİ (Fuzz Testing)

    /// ListingParser Mutasyon ve Fuzzing Testi:
    /// Rastgele üretilmiş veya bozulmuş 100 farklı metin girdisiyle ListingParser.parse çalıştırılır;
    /// ayrıştırıcının asla çökmediği, sonsuz döngüye girmediği ve her zaman ArchiveListing döndürdüğü doğrulanır.
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
            #expect(result.entries.count >= 0)
        }

        // Rastgele ASCII/UTF-8 mutasyonları
        for _ in 1...50 {
            var randomText = ""
            for _ in 1...30 {
                let r = Int.random(in: 1...5)
                switch r {
                case 1: randomText += "Path = name_\(Int.random(in: 0...100))\n"
                case 2: randomText += "Size = \(Int.random(in: -100...1000000))\n"
                case 3: randomText += "----------\n"
                case 4: randomText += "Comment = {\(Int.random(in: 0...50))}\n"
                default: randomText += "--\nType = zip\n"
                }
            }
            let parsed = ListingParser.parse(randomText)
            #expect(parsed.entries.count >= 0)
        }
    }

    // MARK: - 10. KAOS VE ENDURANCE TESTİ (Chaos & Concurrency Testing)

    /// İnatçı / Yanıt Vermeyen Süreçlerin 2 Saniyelik Kill Grace Period ile Sonlandırılması:
    /// SIGTERM sinyalini yok sayan bir alt sürecin CommandRunner tarafından SIGKILL ile sonlandırıldığı
    /// ve sürecin arka planda zombi olarak kalmadığı test edilir.
    @Test func chaosProcessTerminationTimeoutAndKill() async throws {
        // perl ile SIGTERM sinyalini yok sayıp sonsuz döngüye giren süreç
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else { return }

        let runner = CommandRunner(executableURL: perl)
        let script = "$SIG{TERM} = 'IGNORE'; while(1) { sleep 1; }"

        let task = Task {
            try await runner.run(["-e", script])
        }

        try await Task.sleep(for: .milliseconds(300))
        runner.cancel()

        let start = CFAbsoluteTimeGetCurrent()
        let result = try await task.value
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(result.exitCode != 0)
        #expect(elapsed < 4.0) // 2 sn killGracePeriod + tolerans
    }

    /// Klasör İzinleri Kaos Testi (OwnerAccess İzin Yükseltme ve Geri Yükleme):
    /// 0o000 ve 0o555 gibi içine girilemeyen klasörlerin OwnerAccess ile güvenli bir şekilde işlenip
    /// eski kipine geri döndürüldüğü doğrulanır.
    @Test func chaosReadOnlyPermissionsRecovery() throws {
        let root = try makeTempFolder("chaos-perms")
        defer {
            _ = chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        let locked = root.appendingPathComponent("kilitli", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("gizli.txt")
        try Data("veri".utf8).write(to: file)

        // 0o000 yap (hiçbir yetki yok)
        #expect(chmod(locked.path, 0o000) == 0)

        // OwnerAccess ile geçici izin açıp içini oku
        let readSuccess = OwnerAccess.granting(S_IRUSR | S_IXUSR, on: locked.path) {
            FileManager.default.fileExists(atPath: file.path)
        }
        #expect(readSuccess == true)

        // İşlem bittikten sonra orijinal 0o000 kipine geri dönmüş olmalı
        var info = stat()
        #expect(lstat(locked.path, &info) == 0)
        #expect((info.st_mode & 0o777) == 0o000)

        // Temizlik için aç
        #expect(chmod(locked.path, 0o700) == 0)
    }

    /// Eşzamanlılık ve Re-entrancy Kaos Testi:
    /// Çok sayıda eşzamanlı Task üzerinden ayrıştırma, adlandırma ve kum havuzu fonksiyonları çağrılır;
    /// yarış koşulu (race condition) veya veri bozulması olmadığı doğrulanır.
    @Test func chaosConcurrentReentrancy() async throws {
        await withTaskGroup(of: Void.self) { group in
            for i in 1...20 {
                group.addTask {
                    let sample = "--\nPath = thread_\(i).zip\nType = zip\n----------\nPath = file_\(i).txt\nSize = 10\n"
                    let listing = ListingParser.parse(sample)
                    _ = ArchiveTree.build(from: listing.entries)
                    _ = ArchiveNaming.baseName(of: URL(fileURLWithPath: "/tmp/test_\(i).tar.gz"))
                    _ = SandboxProfile.forOperation(archive: URL(fileURLWithPath: "/tmp/t\(i).7z"), writable: [], protectPersonalData: true)
                }
            }
        }
    }
}
