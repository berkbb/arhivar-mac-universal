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

// MARK: - R6-1 Çok parçalı RAR adları

/// Modern RAR parçalarında (.part01.rar) hem .rar hem .part01 atılır; çıkarılan klasör adı temiz kalır ("film").
@Test func multiPartRarBaseNameStripsPartSuffix() {
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/film.part01.rar")) == "film")
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/film.part1.rar")) == "film")
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/film.part002.rar")) == "film")
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/belge.part2.7z")) == "belge")
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/film.r01")) == "film")
    #expect(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/x/film.part01")) == "film")
}

// MARK: - R6-2 Bölünmüş ZIP parçaları

/// Bölünmüş ZIP parçaları (.z01 … .z99) arşiv sayılır ve ilk parça olan ".zip" dosyasına yönlendirilir.
@Test func splitZipVolumesOpenFromTheZipFile() throws {
    let folder = try temporaryFolder("bolunmus-zip")
    defer { StagedExtraction.removeTree(at: folder) }
    for name in ["yedek.zip", "yedek.z01", "yedek.z02", "tek.z01"] {
        try Data("zip".utf8).write(to: folder.appendingPathComponent(name))
    }
    #expect(ArchiveNaming.isArchive(folder.appendingPathComponent("yedek.z01")))
    #expect(ArchiveNaming.isArchive(folder.appendingPathComponent("yedek.Z12")))
    #expect(ArchiveNaming.isArchive(folder.appendingPathComponent("yedek.z100")))
    #expect(!ArchiveNaming.isArchive(folder.appendingPathComponent("a.doc")))
    #expect(!ArchiveNaming.isArchive(folder.appendingPathComponent("a.txt")))
    #expect(ArchiveNaming.firstVolume(of: folder.appendingPathComponent("yedek.z01")) == folder.appendingPathComponent("yedek.zip"))
    #expect(ArchiveNaming.firstVolume(of: folder.appendingPathComponent("yedek.z02")) == folder.appendingPathComponent("yedek.zip"))
    // Ana ".zip" dosyası yoksa olduğu gibi kalır.
    #expect(ArchiveNaming.firstVolume(of: folder.appendingPathComponent("tek.z01")) == folder.appendingPathComponent("tek.z01"))
    #expect(ArchiveNaming.baseName(of: folder.appendingPathComponent("yedek.z01")) == "yedek")
}

/// ".z64" (Nintendo 64 kalıbı), ".z80" (ZX Spectrum) gibi dosyalar yalnızca adlarına bakılarak bölünmüş ZIP parçası
/// sayılmaz: yanında aynı adlı ".zip" yoksa sıradan dosyadır (bırakılınca yeni arşiv önerilir, açılmaya çalışılmaz).
@Test func zipLikeExtensionsWithoutAZipAreNotArchives() throws {
    let folder = try temporaryFolder("z64")
    defer { StagedExtraction.removeTree(at: folder) }
    for name in ["oyun.z64", "spectrum.z80", "yedek.zip", "yedek.z64"] {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }
    #expect(!ArchiveNaming.isArchive(folder.appendingPathComponent("oyun.z64")))
    #expect(!ArchiveNaming.isArchive(folder.appendingPathComponent("spectrum.z80")))
    // Yanında ".zip" ana parçası olan 64. parça bölünmüş ZIP'in parçasıdır.
    #expect(ArchiveNaming.isArchive(folder.appendingPathComponent("yedek.z64")))
    #expect(ArchiveNaming.firstVolume(of: folder.appendingPathComponent("oyun.z64")) == folder.appendingPathComponent("oyun.z64"))
    // Bir arşivin içindeki tek bir parça (yanında ".zip" olmadan) iç içe gezilemez; varsayılan uygulamasıyla açılır.
    #expect(!ArchiveNaming.isBrowsable("oyun.z64"))
    #expect(!ArchiveNaming.isBrowsable("yedek.z01"))
}

// MARK: - R6-3 Çok parçalı arşivlerin düzenlenememesi

/// 7-Zip çok parçalı arşivleri yerinde güncellemeyi (ekleme, silme, yeniden adlandırma) desteklemez.
@Test func multiVolumeArchivesAreNotEditable() {
    let zipURL = URL(fileURLWithPath: "/x/a.zip")
    let z01URL = URL(fileURLWithPath: "/x/a.z01")
    let sevenZURL = URL(fileURLWithPath: "/x/a.7z")

    #expect(!ArchiveCapabilities.supportsEditing(type: "zip", url: zipURL, volumes: 2))
    #expect(!ArchiveCapabilities.supportsEditing(type: "7z", url: sevenZURL, volumes: 3))
    #expect(!ArchiveCapabilities.supportsEditing(type: "zip", url: z01URL))
    #expect(ArchiveCapabilities.supportsEditing(type: "zip", url: zipURL, volumes: 1))
    #expect(ArchiveCapabilities.supportsEditing(type: "zip", url: zipURL, volumes: nil))
    #expect(!ArchiveCapabilities.isEditable(type: "zip", url: zipURL, volumes: 2))
}
