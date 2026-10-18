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

