import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// .agents/context/roadmap.md güvenlik denetimi turu: onaylanan ve düzeltilen açıklar.

private func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Denetim #8: ".term" (com.apple.terminal.session) açıldığında Terminal'de komut çalıştırır; uyarı gerektirir.
@Test func terminalSessionFilesAreRisky() throws {
    let dir = try tempDir("term"); defer { StagedExtraction.removeTree(at: dir) }
    for name in ["oturum.term", "ayar.terminal"] {
        let url = dir.appendingPathComponent(name)
        try Data("<plist/>".utf8).write(to: url)
        #expect(OpenSafety.executableKind(of: url) != nil, "\(name) riskli sayılmalı")
    }
    // Zararsız bir veri dosyası riskli sayılmaz.
    let plain = dir.appendingPathComponent("notlar.txt"); try Data("x".utf8).write(to: plain)
    #expect(OpenSafety.executableKind(of: plain) == nil)
}

/// Denetim #3: kişisel veri kara listesi yaygın bulut/geliştirici kimlik bilgisi konumlarını da kapsar.
@Test func denylistCoversCloudAndDevCredentials() {
    let home = URL(fileURLWithPath: "/Users/ornek")
    let denied = Set(SandboxProfile.personalDataDirectories(home: home).map(\.path))
    for path in [".config/gcloud", ".azure", ".oci", ".terraform.d", ".m2", ".gradle", ".cargo", ".gem", "Library/Application Support/Code"] {
        #expect(denied.contains("/Users/ornek/" + path), "\(path) korunmalı")
    }
}

/// Denetim #1: 7zz'nin dış ağacı gösteren bağlantı yerine bıraktığı 0 baytlık yer tutucu, salt okunur (0555) bir
/// klasörün içinde olsa bile silinir (yoksa "üzerine yaz" ile hedefteki gerçek dosyayı sıfırlardı).
@Test func linkPlaceholderRemovedInsideReadOnlyDirectory() throws {
    let root = try tempDir("yer"); defer { StagedExtraction.removeTree(at: root) }
    let ro = root.appendingPathComponent("ro", isDirectory: true)
    try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
    try Data().write(to: ro.appendingPathComponent("x")) // 0 baytlık yer tutucu
    chmod(ro.path, 0o555)

    #expect(StagedExtraction.removeLinkPlaceholders(in: root, links: ["ro/x"]) == ["ro/x"])
    #expect(StagedExtraction.itemType(ro.appendingPathComponent("x"), fileManager: .default) == nil)
    var info = stat(); _ = lstat(ro.path, &info)
    #expect(info.st_mode & 0o777 == 0o555, "klasör kipi geri yüklenmeli")
}

/// Denetim #4/#5: devasa çıktı üreten bir süreç belleği tüketmeden sınırda durdurulur ve işlem hatayla biter.
@Test func commandRunnerCapsHugeOutput() async {
    let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat"))
    // /dev/zero sonsuz NUL üretir; 1 MiB sınırla süreç durdurulmalı ve çağrı takılmadan hata atmalı.
    await #expect(throws: (any Error).self) {
        _ = try await runner.run(["/dev/zero"], maxOutputBytes: 1 << 20)
    }
}

// MARK: - Denetim turu 2 (11 disiplin)

/// Bir sembolik bağlantı üzerinden açılan arşivin karantina işareti gerçek dosyadan okunur; aksi hâlde çıkarılan
/// çalıştırılabilirler işaretsiz kalır (Gatekeeper atlatması). Hedefteki öğeler için NOFOLLOW davranışı değişmez.
@Test func quarantineFollowsSymlinkedArchive() throws {
    let root = try tempDir("bag-arsiv"); defer { StagedExtraction.removeTree(at: root) }
    let real = root.appendingPathComponent("indirilen.zip"); try Data("zip".utf8).write(to: real)
    let mark = "0083;6ad350b0;Safari;"
    #expect(setxattr(real.path, "com.apple.quarantine", Array(mark.utf8), mark.utf8.count, 0, 0) == 0)
    let link = root.appendingPathComponent("kisayol.zip")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(Quarantine.value(of: link) == nil)            // bağlantının kendi özniteliği yok (NOFOLLOW)
    #expect(Quarantine.sourceValue(of: link) == mark)     // kaynak arşiv: gerçek dosya
    let dest = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let script = dest.appendingPathComponent("calis.command"); try Data("#!/bin/sh".utf8).write(to: script)
    #expect(Quarantine.propagate(from: link, to: dest, since: .distantPast) == 1)
    #expect(Quarantine.value(of: script) == Quarantine.derivedValue(from: mark))
}

/// Parola stdin verisi boru tamponunu (64 KiB) asla aşmaz: aşırı uzun bir parola süreç başlamadan yapılan yazmayı
/// sonsuza dek bloklardı (iptal de ulaşamazdı). Normal parola yine 4 kez tekrarlanır.
@Test func passwordInputNeverExceedsThePipeBuffer() async throws {
    let normal = try #require(SevenZipCommand.passwordInput("gizli"))
    #expect(String(decoding: normal, as: UTF8.self) == String(repeating: "gizli\n", count: 4))
    let long = String(repeating: "a", count: 20_000)
    let data = try #require(SevenZipCommand.passwordInput(long))
    #expect(data.count <= SevenZipCommand.maxPasswordInputBytes)
    // Parola kesilmez; tekrar sayısı sığacak kadar azaltılır (20 KiB satır için 3).
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.hasPrefix(long + "\n") && data.count % (long.utf8.count + 1) == 0 && data.count < 4 * (long.utf8.count + 1))
    let absurd = try #require(SevenZipCommand.passwordInput(String(repeating: "ğ", count: 70_000)))
    #expect(absurd.count <= SevenZipCommand.maxPasswordInputBytes && absurd.last == 0x0A)
    // Canlı: veri bloklanmadan sürece ulaşır (cat geri yazar).
    let echoed = try await CommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat")).run([], input: data)
    #expect(echoed.stdout.utf8.count == data.count)
}

/// Arşivin fiziksel boyutu girdi boyutları gibi okunur: negatif değer kabul edilmez, taşan değer sınırda durur.
@Test func physicalSizeIsParsedLikeEntrySizes() {
    let negative = ListingParser.parse("--\nType = zip\nPhysical Size = -5\n\n----------\nPath = a\nSize = 1\nPacked Size = 1\n")
    #expect(negative.info.physicalSize == nil)
    #expect(ArchiveStatistics(listing: negative).packedSize == 1)   // toplam paketli boyuta düşer
    let huge = ListingParser.parse("--\nType = zip\nTotal Physical Size = 18446744073709551615\n\n----------\n")
    #expect(huge.info.physicalSize == Int64.max)
}

/// Kesik bir arşiv (ERRORS: / Unexpected end of archive) içinde tehlikeli bir bağlantı da varsa işlem uyarıya
/// indirgenmez; yalnızca bağlantı hatası olan çıkarma ise eskisi gibi uyarıyla tamamlanır. Açıklama satırı korunur.
@Test func truncatedArchiveWithDangerousLinkIsNotDowngradedToWarning() throws {
    let linkOnly = "ERROR: Dangerous link path was ignored : badlink : ../outside\n\nSub items Errors: 1\n\nArchives with Errors: 1\n"
    #expect(try SevenZipError.check(ProcessResult(exitCode: 2, stdout: linkOnly, stderr: "")) != nil)
    let truncated = linkOnly + "\nERRORS:\nUnexpected end of archive\n\nOpen Errors: 1\n"
    do {
        _ = try SevenZipError.check(ProcessResult(exitCode: 2, stdout: truncated, stderr: ""))
        Issue.record("kesik arşiv uyarıya indirgendi")
    } catch let SevenZipError.failed(code, message) {
        #expect(code == 2 && message.contains("Unexpected end of archive"))
    } catch {
        Issue.record("beklenmeyen hata: \(error)")
    }
    #expect(SevenZipError.diagnostic(from: "ERRORS:\nUnexpected end of archive\n\nErrors: 1\n").contains("Unexpected end of archive"))
}
