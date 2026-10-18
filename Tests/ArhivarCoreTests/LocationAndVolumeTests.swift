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

// MARK: - R5-3 Eski RAR parçaları

/// Eski RAR bölümleri ".rar", ".r00", ".r01", … olarak adlanır; 7zz yalnızca ".rar" dosyasından açar.
@Test func oldStyleRarVolumesOpenFromTheRarFile() throws {
    let folder = try temporaryFolder("eski-rar")
    defer { StagedExtraction.removeTree(at: folder) }
    for name in ["film.rar", "film.r00", "film.r01", "yalniz.r00"] {
        try Data("rar".utf8).write(to: folder.appendingPathComponent(name))
    }
    #expect(ArchiveNaming.isArchive(folder.appendingPathComponent("film.r00")))
    #expect(ArchiveNaming.isArchive(folder.appendingPathComponent("film.R17")))
    #expect(!ArchiveNaming.isArchive(folder.appendingPathComponent("notlar.rtf")))
    #expect(!ArchiveNaming.isArchive(folder.appendingPathComponent("a.r1")))
    #expect(ArchiveNaming.firstVolume(of: folder.appendingPathComponent("film.r01")) == folder.appendingPathComponent("film.rar"))
    #expect(ArchiveNaming.firstVolume(of: folder.appendingPathComponent("film.r00")) == folder.appendingPathComponent("film.rar"))
    // ".rar" yoksa olduğu gibi kalır.
    #expect(ArchiveNaming.firstVolume(of: folder.appendingPathComponent("yalniz.r00")) == folder.appendingPathComponent("yalniz.r00"))
}

// MARK: - R5-4 Boyut toplamları

/// Negatif boyut gereken alanı azaltmaz; Int64.max'ı aşan (işaretsiz yazılmış) boyut yok sayılmaz, sınırda durur.
@Test func requiredBytesNeverShrinkAndHugeSizesSaturate() {
    let entries = [ArchiveEntry(path: "a", size: 10), ArchiveEntry(path: "b", size: -5)]
    #expect(DiskSpace.requiredBytes(for: [], in: entries) == 10)

    let output = """
    --
    Type = zip

    ----------
    Path = bomba.bin
    Size = 18446744073709551615
    Packed Size = 18446744073709551615

    Path = eksi.bin
    Size = -1

    """
    let listing = ListingParser.parse(output)
    #expect(listing.entries.first?.size == Int64.max)
    #expect(listing.entries.first?.packedSize == Int64.max)
    #expect(listing.entries.last?.size == nil)
    #expect(DiskSpace.requiredBytes(for: [], in: listing.entries) == Int64.max)
}
