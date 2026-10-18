import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// "._" ile başlayan dosyalar: FileManager klasör listelerinde bunları (yalnızca sıradan dosyaları) hiç göstermez.

private func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// AppleDouble üst veri dosyası: 0x00051607 imzası ve 2. sürüm başlığı.
private let appleDouble = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]) + Data(count: 24)

/// Klasör listesi "._" ile başlayan sıradan dosyaları da içerir (FileManager içermez).
@Test func directoryEntriesIncludeDotUnderscoreFiles() throws {
    let folder = try temporaryFolder("liste")
    defer { StagedExtraction.removeTree(at: folder) }
    try Data("veri".utf8).write(to: folder.appendingPathComponent("._config"))
    try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.txt"])
    #expect(try StagedExtraction.entries(ofDirectory: folder.path).sorted() == ["._config", "a.txt"])
    #expect(throws: (any Error).self) { try StagedExtraction.entries(ofDirectory: folder.appendingPathComponent("yok").path) }
}

/// Çıkarmada "._config" gibi dosyalar sessizce düşmez: kökte de, var olan bir klasörle birleştirilirken de taşınır.
@Test func mergeMovesDotUnderscoreFiles() throws {
    let root = try temporaryFolder("birlestir")
    defer { StagedExtraction.removeTree(at: root) }
    let staging = root.appendingPathComponent("hazirlik", isDirectory: true)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("k"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("k"), withIntermediateDirectories: true)
    try Data("kok".utf8).write(to: staging.appendingPathComponent("._config"))
    try Data("ic".utf8).write(to: staging.appendingPathComponent("k/._notlar"))

    try StagedExtraction.merge(from: staging, into: destination, policy: .replace)
    #expect(try String(contentsOf: destination.appendingPathComponent("._config"), encoding: .utf8) == "kok")
    #expect(try String(contentsOf: destination.appendingPathComponent("k/._notlar"), encoding: .utf8) == "ic")
}

/// Karantina işareti "._" ile başlayan dosyalara da yazılır (yoksa "._calis.command" Gatekeeper denetimsiz açılırdı).
@Test func quarantineReachesDotUnderscoreFiles() throws {
    let root = try temporaryFolder("karantina-ad")
    defer { StagedExtraction.removeTree(at: root) }
    let archive = root.appendingPathComponent("arsiv.zip")
    try Data("zip".utf8).write(to: archive)
    let mark = "0083;6ad350b0;Safari;"
    #expect(setxattr(archive.path, "com.apple.quarantine", Array(mark.utf8), mark.utf8.count, 0, 0) == 0)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("k"), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: destination.appendingPathComponent("._calis.command"))
    try Data("#!/bin/sh\n".utf8).write(to: destination.appendingPathComponent("k/._ic.command"))

    Quarantine.propagate(from: archive, to: destination, since: .distantPast)
    #expect(Quarantine.value(of: destination.appendingPathComponent("._calis.command")) == mark)
    #expect(Quarantine.value(of: destination.appendingPathComponent("k/._ic.command")) == mark)
}

/// Yalnızca gerçek AppleDouble dosyaları (imzasıyla) üst veri sayılır; "._config" veridir: akıllı kipte sayılır ve bırakılmaz.
@Test func onlyRealAppleDoubleFilesAreMetadata() throws {
    let root = try temporaryFolder("appledouble")
    defer { StagedExtraction.removeTree(at: root) }
    let base = root.appendingPathComponent("indirilenler", isDirectory: true)
    let content = root.appendingPathComponent("icerik", isDirectory: true)
    try FileManager.default.createDirectory(at: content.appendingPathComponent("Proje"), withIntermediateDirectories: true)
    try appleDouble.write(to: content.appendingPathComponent("._Proje"))
    #expect(StagedExtraction.isMacMetadata("._Proje", in: content))
    #expect(StagedExtraction.isMacMetadata(".DS_Store", in: content))
    #expect(!StagedExtraction.isMacMetadata("Proje", in: content))

    // Tek anlamlı öğe + gerçek AppleDouble: doğrudan hedefe, AppleDouble bırakılır.
    var destination = StagedExtraction.destination(for: content, base: base, archiveName: "Proje", mode: .smart)
    #expect(destination == base)
    #expect(StagedExtraction.leaveOutRootMetadata(in: content, destination: destination, base: base, mode: .smart) == ["._Proje"])

    // "._config" sıradan bir dosya: üst veri değildir, ikinci anlamlı öğe sayılır ve arşiv adıyla klasöre çıkılır.
    try Data("veri".utf8).write(to: content.appendingPathComponent("._config"))
    #expect(!StagedExtraction.isMacMetadata("._config", in: content))
    destination = StagedExtraction.destination(for: content, base: base, archiveName: "Proje", mode: .smart)
    #expect(destination.lastPathComponent == "Proje")
    #expect(StagedExtraction.leaveOutRootMetadata(in: content, destination: destination, base: base, mode: .smart).isEmpty)
}

/// Boş alan hesabı "._" ile başlayan dosyaların boyutunu da sayar.
@Test func totalSizeCountsDotUnderscoreFiles() throws {
    let root = try temporaryFolder("boyut")
    defer { StagedExtraction.removeTree(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("k"), withIntermediateDirectories: true)
    try Data(count: 100).write(to: root.appendingPathComponent("k/._buyuk"))
    try Data(count: 10).write(to: root.appendingPathComponent("k/kucuk"))
    #expect(DiskSpace.totalSize(of: [root.appendingPathComponent("k")]) == 110)
}
