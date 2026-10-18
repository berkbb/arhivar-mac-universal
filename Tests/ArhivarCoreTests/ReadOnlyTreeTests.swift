import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// .agents/context/roadmap.md, dördüncü tur (R4-1, R4-3): salt okunur ağaçlar ve yalnızca özel dosyalardan oluşan kaynaklar.

private func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(of url: URL) -> UInt16? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt16(info.st_mode & 0o7777) : nil
}

// MARK: - R4-1 Salt okunur klasör ağaçları

/// "Üzerine yaz" bir klasörün yerine dosya koyarken klasörün içindeki salt okunur alt klasörler silmeyi durdurmaz.
@Test func replacingAFolderWithReadOnlyContentsByAFile() throws {
    let root = try temporaryFolder("klasor-dosya")
    defer { StagedExtraction.removeTree(at: root) }
    let staging = root.appendingPathComponent("hazirlik", isDirectory: true)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("x/salt"), withIntermediateDirectories: true)
    try "eski".write(to: destination.appendingPathComponent("x/salt/f.txt"), atomically: true, encoding: .utf8)
    chmod(destination.appendingPathComponent("x/salt").path, 0o555)
    try "yeni".write(to: staging.appendingPathComponent("x"), atomically: true, encoding: .utf8)

    try StagedExtraction.merge(from: staging, into: destination, policy: .replace)
    #expect(try String(contentsOf: destination.appendingPathComponent("x"), encoding: .utf8) == "yeni")
}

/// İçine girilemeyen (0444, 0000) hedef klasörlere, okunamayan (0311) ve salt okunur (0555) hazırlık klasörlerinden birleştirilir;
/// hedefteki kipler korunur.
@Test func mergingThroughFoldersWithoutSearchPermission() throws {
    let root = try temporaryFolder("arama")
    defer { StagedExtraction.removeTree(at: root) }
    let staging = root.appendingPathComponent("hazirlik", isDirectory: true)
    let destination = root.appendingPathComponent("hedef", isDirectory: true)
    for name in ["okuma", "kapali"] {
        try FileManager.default.createDirectory(at: staging.appendingPathComponent(name), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent(name), withIntermediateDirectories: true)
        try "yeni".write(to: staging.appendingPathComponent("\(name)/yeni.txt"), atomically: true, encoding: .utf8)
        try "eski".write(to: destination.appendingPathComponent("\(name)/eski.txt"), atomically: true, encoding: .utf8)
    }
    // Hazırlıkta okunamayan (0311) ve salt okunur (0555) klasörler: listelenip boşaltılabilmeli.
    chmod(staging.appendingPathComponent("okuma").path, 0o311)
    chmod(staging.appendingPathComponent("kapali").path, 0o555)
    chmod(destination.appendingPathComponent("okuma").path, 0o444)
    chmod(destination.appendingPathComponent("kapali").path, 0o000)

    try StagedExtraction.merge(from: staging, into: destination, policy: .replace)
    #expect(mode(of: destination.appendingPathComponent("okuma")) == 0o444)
    #expect(mode(of: destination.appendingPathComponent("kapali")) == 0o000)
    for name in ["okuma", "kapali"] {
        chmod(destination.appendingPathComponent(name).path, 0o755)
        #expect(try String(contentsOf: destination.appendingPathComponent("\(name)/yeni.txt"), encoding: .utf8) == "yeni")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("\(name)/eski.txt").path))
    }
}

/// Salt okunur (0555) ya da okunamayan (0000) klasörlerdeki dışarıyı gösteren bağlantılar da silinir, içeriyi
/// gösteren mutlak bağlantılar göreli yapılır; klasörlerin kipleri korunur.
@Test func linksInsideReadOnlyFoldersAreStillSecured() throws {
    let root = try temporaryFolder("salt-bag")
    defer { StagedExtraction.removeTree(at: root) }
    let readOnly = root.appendingPathComponent("salt", isDirectory: true)
    let closed = root.appendingPathComponent("kapali", isDirectory: true)
    for folder in [readOnly, closed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try "f".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: readOnly.appendingPathComponent("dis").path, withDestinationPath: "/etc/hosts")
    try FileManager.default.createSymbolicLink(atPath: readOnly.appendingPathComponent("ic").path, withDestinationPath: root.path + "/f.txt")
    try FileManager.default.createSymbolicLink(atPath: closed.appendingPathComponent("dis").path, withDestinationPath: "/etc/hosts")
    chmod(readOnly.path, 0o555)
    chmod(closed.path, 0o000)

    let removed = StagedExtraction.secureSymlinks(in: root)
    #expect(removed == ["kapali/dis", "salt/dis"])
    #expect(mode(of: readOnly) == 0o555)
    #expect(mode(of: closed) == 0o000)
    chmod(closed.path, 0o755)
    #expect(StagedExtraction.itemType(readOnly.appendingPathComponent("dis"), fileManager: .default) == nil)
    #expect(StagedExtraction.itemType(closed.appendingPathComponent("dis"), fileManager: .default) == nil)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: readOnly.appendingPathComponent("ic").path) == "../f.txt")
}

