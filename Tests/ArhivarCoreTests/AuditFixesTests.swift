import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// 11 disiplinli denetim turunun doğrulanmış bulguları için düzeltme testleri (kum havuzu daraltma ve sertleştirme,
// yerinde düzenlemede -w, atomik birleştirme, kesik arşiv iletisi, ağaçta dosya/klasör çakışması).

private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ProcessInfo.processInfo.environment["ARHIVAR_7ZZ"],
        packageRoot.appendingPathComponent("Vendor/7-Zip/7zz").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

private func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(of url: URL) -> UInt16? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt16(info.st_mode & 0o7777) : nil
}

// MARK: - Kum havuzu: yalnızca motor çalıştırılabilir, mach servisleri kapalı, tek dosya izinleri

@Test func profileDeniesExecAndMachAndAllowsOnlyTheEngine() throws {
    let profile = SandboxProfile(
        writableDirectories: [URL(fileURLWithPath: "/tmp/w")], deniedReadDirectories: [URL(fileURLWithPath: "/Users/x/.ssh")],
        writableFiles: [URL(fileURLWithPath: "/tmp/a.7z")], readableFiles: [URL(fileURLWithPath: "/Users/x/.ssh/ek.zip")]
    )
    let text = profile.profileText
    for rule in ["(deny mach-lookup)", "(deny process-exec)", "(allow process-exec (literal (param \"E\")))", "(literal (param \"A0\"))", "(allow file-read* (literal (param \"F0\")))"] {
        #expect(text.contains(rule), "\(rule)")
    }
    // Tek dosya okuma izni yasaktan SONRA gelir (son eşleşen kural kazanır).
    #expect(try #require(text.range(of: "(deny file-read*")).lowerBound < (try #require(text.range(of: "(allow file-read* (literal"))).lowerBound)
    let args = profile.launchArguments(executable: URL(fileURLWithPath: "/bin/cat"), arguments: ["x"])
    #expect(args.contains("E=/bin/cat") && args.contains("A0=/tmp/a.7z") && args.contains("F0=/Users/x/.ssh/ek.zip"))
    #expect(Array(args.suffix(2)) == ["/bin/cat", "x"])
}

/// Mail / Mesajlar eki gibi yasaklı bir klasördeki arşiv: klasör yasaklı kalır, yalnızca arşivin kendisi okunabilir.
/// Bölünmüş arşivde kardeş parçalar gerektiğinden klasör eskisi gibi açılır.
@Test func archiveInsideProtectedFolderNoLongerUndeniesTheFolder() throws {
    let home = try tempDir("ev"); defer { StagedExtraction.removeTree(at: home) }
    let mail = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Mail Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
    let archive = mail.appendingPathComponent("ek.zip"); try Data("zip".utf8).write(to: archive)
    let containers = SandboxProfile.resolved(home.appendingPathComponent("Library/Containers")).path

    let profile = SandboxProfile.forOperation(archive: archive, writable: [], home: home)
    #expect(profile.deniedReadDirectories.map(\.path).contains(containers))
    #expect(profile.readableFiles.map(\.path) == [SandboxProfile.resolved(archive).path])

    let split = mail.appendingPathComponent("b.7z.001"); try Data("x".utf8).write(to: split)
    #expect(!SandboxProfile.forOperation(archive: split, writable: [], home: home).deniedReadDirectories.map(\.path).contains(containers))
    #expect(SandboxProfile.needsSiblingVolumes(URL(fileURLWithPath: "/x/film.part3.rar")))
    #expect(!SandboxProfile.needsSiblingVolumes(URL(fileURLWithPath: "/x/film.rar")))
}

/// Canlı: yasaklı klasördeki arşiv okunur, yanındaki dosya okunamaz; motor dışı program çalıştırılamaz.
@Test func liveSandboxReadsOnlyTheArchiveInsideAProtectedFolder() async throws {
    try #require(SandboxProfile.isAvailable)
    let home = try tempDir("ev"); defer { StagedExtraction.removeTree(at: home) }
    let mail = home.appendingPathComponent("Library/Mail/Attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
    let archive = mail.appendingPathComponent("ek.zip"); try Data("ZIPVERI".utf8).write(to: archive)
    let secret = mail.appendingPathComponent("gizli.txt"); try Data("GIZLI".utf8).write(to: secret)
    let profile = SandboxProfile.forOperation(archive: archive, writable: [], home: home)
    let cat = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat")).sandboxed(profile)

    let allowed = try await cat.run([archive.path])
    #expect(allowed.exitCode == 0 && allowed.stdout == "ZIPVERI")
    let denied = try await cat.run([secret.path])
    #expect(denied.exitCode != 0 && !denied.stdout.contains("GIZLI"))
    // process-exec yasağı: çalıştırılan program başka bir ikiliyi çalıştıramaz; yalnızca kendisi izinlidir.
    // (/bin/sh bile bash/zsh'e yeniden exec eden bir kabuk olduğu için kullanılamaz: env doğrudan exec eder.)
    let env = CommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/env")).sandboxed(SandboxProfile(writableDirectories: [], deniedReadDirectories: []))
    let itself = try await env.run([])                 // çocuk çalıştırmaz: ortamı yazar
    #expect(itself.exitCode == 0 && !itself.stdout.isEmpty)
    let child = try await env.run(["/bin/ls", "/"])    // /bin/ls'yi exec etmeye çalışır: yasak
    #expect(child.exitCode != 0 && child.stdout.isEmpty)
}

// MARK: - Yerinde düzenleme: -w çalışma klasörü, yalnızca arşiv dosyası yazılabilir

@Test func editCommandsCarryTheWorkDirectory() throws {
    let archive = URL(fileURLWithPath: "/tmp/a.7z"), work = URL(fileURLWithPath: "/tmp/is")
    #expect(SevenZipCommand.add(archive: archive, names: ["b"], workDirectory: work).contains("-w/tmp/is"))
    #expect(SevenZipCommand.delete(archive: archive, items: ["b"], workDirectory: work).contains("-w/tmp/is"))
    #expect(SevenZipCommand.rename(archive: archive, from: "a", to: "b", workDirectory: work).contains("-w/tmp/is"))
    #expect(!SevenZipCommand.add(archive: archive, names: ["b"]).contains { $0.hasPrefix("-w") })
    // "-w" "--" ayracından önce gelir.
    let args = SevenZipCommand.delete(archive: archive, items: ["b"], workDirectory: work)
    #expect(try #require(args.firstIndex(of: "-w/tmp/is")) < (try #require(args.firstIndex(of: "--"))))
}

/// Canlı 7zz: arşivin klasörü yazılamazken (yalnızca -w klasörü ve arşivin kendisi yazılabilir) ekleme, silme ve
/// yeniden adlandırma başarılı olur; arşivin yanında geçici dosya kalmaz.
@Test func liveInPlaceEditOnlyNeedsTheWorkDirectoryAndTheArchiveFile() async throws {
    try #require(SandboxProfile.isAvailable)
    let engine = try #require(engineURL)
    let root = try tempDir("yerinde"); defer { StagedExtraction.removeTree(at: root) }
    let folder = root.appendingPathComponent("arsivler", isDirectory: true)
    let work = root.appendingPathComponent("is", isDirectory: true)
    let sources = root.appendingPathComponent("kaynak", isDirectory: true)
    for dir in [folder, work, sources] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    try "a".write(to: sources.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "b".write(to: sources.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    let plain = CommandRunner(executableURL: engine)
    let archive = folder.appendingPathComponent("t.7z")
    try SevenZipError.check(try await plain.run(SevenZipCommand.create(CreateOptions(sources: [sources.appendingPathComponent("a.txt")], destination: archive, format: .sevenZip, level: .fast))))

    let profile = SandboxProfile.forOperation(archive: archive, writable: [work], writableFiles: [archive], readable: [sources], home: root)
    #expect(!profile.writableDirectories.map(\.path).contains(SandboxProfile.resolved(folder).path))
    let confined = plain.sandboxed(profile)
    try SevenZipError.check(try await confined.run(SevenZipCommand.add(archive: archive, names: ["b.txt"], workDirectory: work), workingDirectory: sources))
    try SevenZipError.check(try await confined.run(SevenZipCommand.rename(archive: archive, from: "b.txt", to: "c.txt", workDirectory: work)))
    try SevenZipError.check(try await confined.run(SevenZipCommand.delete(archive: archive, items: ["a.txt"], workDirectory: work)))
    let listed = try await plain.run(SevenZipCommand.list(archive: archive))
    #expect(ListingParser.parse(listed.stdout).entries.map(\.path) == ["c.txt"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["t.7z"]) // yanında .tmp yok
}

// MARK: - Atomik birleştirme

@Test func mergeIntoReadOnlyDestinationBaseRestoresItsMode() throws {
    let root = try tempDir("salt-hedef"); defer { StagedExtraction.removeTree(at: root) }
    let staging = root.appendingPathComponent("hazirlik", isDirectory: true)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("k"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try "x".write(to: staging.appendingPathComponent("k/x.txt"), atomically: true, encoding: .utf8)
    try "y".write(to: staging.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
    chmod(destination.path, 0o555)
    let changed = try StagedExtraction.merge(from: staging, into: destination, policy: .replace)
    #expect(changed.count == 2)
    #expect(mode(of: destination) == 0o555)
    chmod(destination.path, 0o755)
    #expect(try String(contentsOf: destination.appendingPathComponent("k/x.txt"), encoding: .utf8) == "x")
}

/// Klasörün yerine dosya konurken klasörün içinde kilitli (uchg) bir dosya olsa bile eski veri yok edilmez:
/// önce silip sonra taşıyamamak klasörü yarım silmiş bırakırdı. Yeni öğe yerine gelir, kilitli dosya yanda kalır.
@Test func crossTypeReplaceDoesNotDestroyTheOldItemWhenCleanupFails() throws {
    let root = try tempDir("tur-degis"); defer { StagedExtraction.removeTree(at: root) }
    let staging = root.appendingPathComponent("hazirlik", isDirectory: true)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("Belgeler"), withIntermediateDirectories: true)
    let locked = destination.appendingPathComponent("Belgeler/kilitli.txt")
    try "onemli".write(to: locked, atomically: true, encoding: .utf8)
    #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
    try "yeni".write(to: staging.appendingPathComponent("Belgeler"), atomically: true, encoding: .utf8)

    try StagedExtraction.merge(from: staging, into: destination, policy: .replace)
    #expect(try String(contentsOf: destination.appendingPathComponent("Belgeler"), encoding: .utf8) == "yeni")
    // Kilitli dosya silinemedi ama kaybolmadı: yana taşınmış klasörde durur.
    let aside = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".arhivar-replaced-") }
    #expect(aside.count == 1)
    let kept = destination.appendingPathComponent(aside[0]).appendingPathComponent("kilitli.txt")
    #expect(try String(contentsOf: kept, encoding: .utf8) == "onemli")
    _ = chflags(kept.path, 0)
}

@Test func staleFallbackStagingIsSwept() throws {
    let root = try tempDir("supur"); defer { StagedExtraction.removeTree(at: root) }
    let old = root.appendingPathComponent(StagedExtraction.stagingPrefix + "eski", isDirectory: true)
    let fresh = root.appendingPathComponent(StagedExtraction.stagingPrefix + "yeni", isDirectory: true)
    let user = root.appendingPathComponent(".arhivar-staging", isDirectory: true) // önek tam eşleşmez
    for dir in [old, fresh, user] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let twoHoursAgo = Date().addingTimeInterval(-7200)
    try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: old.path)
    StagedExtraction.sweepStaleStaging(in: root)
    #expect(StagedExtraction.itemType(old) == nil)
    #expect(StagedExtraction.itemType(fresh) == .typeDirectory)
    #expect(StagedExtraction.itemType(user) == .typeDirectory)
}

// MARK: - Sınıflandırma ve ağaç

@Test func truncatedArchiveReportsTheReasonInsteadOfNotAnArchive() throws {
    // Yarım inmiş 7z: 7zz hem "Cannot open the file as [7z] archive" hem "ERRORS:/Unexpected end of archive" yazar.
    let truncated = "ERROR: a.7z : a.7z\nERRORS:\nUnexpected end of archive\nOpen ERROR: Cannot open the file as [7z] archive\n"
    do {
        _ = try SevenZipError.check(ProcessResult(exitCode: 2, stdout: truncated, stderr: ""))
        Issue.record("hata atılmalıydı")
    } catch let SevenZipError.failed(_, message) {
        #expect(message.contains("Unexpected end of archive"))
    } catch {
        Issue.record("beklenmeyen: \(error)")
    }
    // Gerçekten arşiv olmayan dosya yine .notArchive.
    #expect(throws: SevenZipError.notArchive) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: "ERROR: x : x\nOpen ERROR: Cannot open the file as archive\n", stderr: ""))
    }
}

@Test func fileEntryWinsOverACollidingDeeperPath() {
    let tree = ArchiveTree.build(from: [
        ArchiveEntry(path: "a/b.txt", size: 42),
        ArchiveEntry(path: "a/b.txt/c.txt", size: 7),
    ])
    let index = ArchiveTree.index(tree)
    let file = index["a/b.txt"]
    #expect(file?.isDirectory == false && file?.size == 42 && file?.children == nil)
    #expect(index["a/b.txt/c.txt"] == nil)
}

// MARK: - Denetim turu 3 (06–10)

/// Tar sabit bağlantısı dışarıyı gösteriyorsa 7zz onu reddedip 0 baytlık yer tutucu bırakır; artık bu girdiler de
/// bağlantı olarak tanınır ve yer tutucu silinir ("üzerine yaz" hedefteki gerçek dosyayı sıfırlamaz).
@Test func hardLinkEntriesAreRecognizedAndTheirPlaceholdersRemoved() async throws {
    let engine = try #require(engineURL)
    let root = try tempDir("sabit"); defer { StagedExtraction.removeTree(at: root) }
    var tar = TarBuilder()
    tar.file("real.txt", "real")
    tar.hardLink("hl_out", to: "../outside.txt")
    tar.hardLink("hl_ok", to: "real.txt")
    let archive = root.appendingPathComponent("hl.tar"); try tar.archive.write(to: archive)
    let runner = CommandRunner(executableURL: engine)
    let listed = try await runner.run(SevenZipCommand.list(archive: archive))
    let entries = ListingParser.parse(listed.stdout).entries
    let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    #expect(byPath["hl_out"]?.isHardLink == true && byPath["hl_out"]?.isSymbolicLink == false && byPath["hl_out"]?.isDirectory == false)
    #expect(byPath["real.txt"]?.isHardLink == false)

    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    _ = try await runner.run(SevenZipCommand.extract(ExtractOptions(archive: archive, destination: out, overwrite: .replace)))
    #expect(StagedExtraction.itemType(out.appendingPathComponent("hl_out")) == .typeRegular) // 7zz'nin yer tutucusu
    let links = entries.filter { $0.isSymbolicLink || $0.isHardLink }.map(\.path)
    #expect(StagedExtraction.removeLinkPlaceholders(in: out, links: links) == ["hl_out"])
    #expect(StagedExtraction.itemType(out.appendingPathComponent("hl_out")) == nil)
    #expect(try String(contentsOf: out.appendingPathComponent("hl_ok"), encoding: .utf8) == "real") // kabul edilen bağlantı sıradan dosya
}
