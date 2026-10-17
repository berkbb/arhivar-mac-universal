import Foundation
import Testing
@testable import ArhivarCore

// Liste maddeleri 15 (karantina), 18 (geçici klasörler), 19 (çalıştırılabilir / yanıltıcı ad), 22 (hızlı tarih okuma).

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tarih ayrıştırma

@Test(arguments: ["UTC", "Europe/Istanbul", "America/New_York", "Europe/Bucharest", "Australia/Lord_Howe"])
func timestampMatchesDateFormatter(zone: String) throws {
    let timeZone = try #require(TimeZone(identifier: zone))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let samples = [
        "1970-01-01 00:00:00", "1999-12-31 23:59:59", "2000-02-29 12:00:00", "2024-02-29 08:15:30",
        "2026-10-17 14:31:05", "2026-03-29 04:30:00", "2026-10-25 02:30:00", "2026-03-08 03:30:00",
        "2026-11-01 01:30:00", "1601-01-01 00:00:00", "2107-12-31 23:59:58",
    ]
    for sample in samples {
        let expected = formatter.date(from: sample)
        let actual = ListingParser.parseTimestamp(sample + ".1234567", timeZone: timeZone)
        // Yaz saati boşluğundaki (var olmayan) saatlerde iki yöntem bir saat farklı sonuç verebilir; yalnızca geçerli saatleri karşılaştır.
        if let expected {
            #expect(actual == expected, "\(zone) \(sample)")
        }
    }
}

@Test func rejectsMalformedTimestamps() {
    for bad in ["", "2026-10-17", "2026/10/17 10:00:00", "2026-13-01 00:00:00", "2026-10-17 25:00:00", "abcd-ef-gh ij:kl:mn"] {
        #expect(ListingParser.parseTimestamp(bad, timeZone: .gmt) == nil, "\(bad)")
    }
}

// MARK: - Karantina

@Test func derivedQuarantineClearsUserApprovalBit() {
    #expect(Quarantine.derivedValue(from: "00c3;6ad350b0;Safari;3012A7DC") == "0083;6ad350b0;Safari;3012A7DC")
    #expect(Quarantine.derivedValue(from: "0083;6ad350b0;Safari;") == "0083;6ad350b0;Safari;")
    #expect(Quarantine.derivedValue(from: "bozuk") == "bozuk")
}

@Test func propagationMarksOnlyNewItems() throws {
    let root = try temporaryDirectory("quarantine")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("indirilen.zip")
    try Data("x".utf8).write(to: archive)
    #expect(setxattr(archive.path, "com.apple.quarantine", Array("00c3;6ad350b0;Safari;".utf8), 21, 0, 0) == 0)

    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let old = destination.appendingPathComponent("eski.txt")
    try Data("eski".utf8).write(to: old)
    Thread.sleep(forTimeInterval: 1.2)

    let start = Date()
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("yeni/alt"), withIntermediateDirectories: true)
    try Data("yeni".utf8).write(to: destination.appendingPathComponent("yeni/alt/betik.command"))

    let count = Quarantine.propagate(from: archive, to: destination, since: start)
    #expect(count == 3)
    #expect(Quarantine.value(of: destination.appendingPathComponent("yeni/alt/betik.command")) == "0083;6ad350b0;Safari;")
    #expect(Quarantine.value(of: old) == nil)
}

@Test func noQuarantineOnArchiveMeansNothingToDo() throws {
    let root = try temporaryDirectory("quarantine")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("yerel.zip")
    try Data("x".utf8).write(to: archive)
    try Data("y".utf8).write(to: root.appendingPathComponent("a.txt"))
    #expect(Quarantine.propagate(from: archive, to: root, since: .distantPast) == 0)
}

// MARK: - Açma güvenliği

@Test func detectsHiddenCharactersInNames() {
    let spoofed = "fatura\u{202E}fdp.command"
    #expect(OpenSafety.hasDeceptiveCharacters(spoofed))
    #expect(OpenSafety.visibleName(spoofed) == "fatura⟦U+202E⟧fdp.command")
    #expect(OpenSafety.hasDeceptiveCharacters("a\u{200B}b.txt"))
    #expect(!OpenSafety.hasDeceptiveCharacters("Ağaç_şeker_İş.txt"))
    #expect(OpenSafety.visibleName("Ağaç.txt") == "Ağaç.txt")
}

@Test func detectsExecutableFiles() throws {
    let root = try temporaryDirectory("open-safety")
    defer { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String, executable: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }
    #expect(OpenSafety.executableKind(of: try file("calistir.command")) != nil)
    #expect(OpenSafety.executableKind(of: try file("kur.pkg")) != nil)
    #expect(OpenSafety.executableKind(of: try file("profil.mobileconfig")) != nil)
    #expect(OpenSafety.executableKind(of: try file("uzantisiz", executable: true)) != nil)
    #expect(OpenSafety.executableKind(of: try file("not.txt")) == nil)
    #expect(OpenSafety.executableKind(of: try file("resim.png")) == nil)
}

// MARK: - Geçici klasörler

@Test func sweepRemovesOnlyStaleFolders() throws {
    let root = try temporaryDirectory("sweep")
    defer { try? FileManager.default.removeItem(at: root) }
    let stale = root.appendingPathComponent("session-eski", isDirectory: true)
    let fresh = root.appendingPathComponent("session-yeni", isDirectory: true)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7 * 3600)], ofItemAtPath: stale.path)

    #expect(ItemExtractor.sweepStale(olderThan: 6 * 3600, root: root, now: now) == 1)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
}
