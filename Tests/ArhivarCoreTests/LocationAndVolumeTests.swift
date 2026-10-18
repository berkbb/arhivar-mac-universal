import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// .agents/context/roadmap.md, beşinci tur (R5-2 … R5-4): salt okunur konumlar, eski RAR parçaları ve boyut toplamları.

private func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - R5-2 Salt okunur arşivler

/// 7zz arşivin güncellenmiş kopyasını yanına yazıp eskisinin yerine koyar: salt okunur (0444) ya da kilitli arşiv,
/// salt okunur klasördeki arşiv düzenlenemez ("errno=13 : Permission denied").
@Test func readOnlyArchivesAreNotEditable() throws {
    let folder = try temporaryFolder("salt-arsiv")
    defer {
        chmod(folder.path, 0o755)
        StagedExtraction.removeTree(at: folder)
    }
    let archive = folder.appendingPathComponent("a.7z")
    try Data("7z".utf8).write(to: archive)
    #expect(ArchiveCapabilities.isEditable(type: "7z", url: archive))

    chmod(archive.path, 0o444)
    #expect(!ArchiveCapabilities.isEditable(type: "7z", url: archive))
    chmod(archive.path, 0o644)

    #expect(chflags(archive.path, UInt32(UF_IMMUTABLE)) == 0)
    #expect(!ArchiveCapabilities.isEditable(type: "7z", url: archive))
    #expect(chflags(archive.path, 0) == 0)

    chmod(folder.path, 0o555)
    #expect(!ArchiveCapabilities.isEditable(type: "7z", url: archive))
    chmod(folder.path, 0o755)
    #expect(ArchiveCapabilities.isEditable(type: "7z", url: archive))
}

