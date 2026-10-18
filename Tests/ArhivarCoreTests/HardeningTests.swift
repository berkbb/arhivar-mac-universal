import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// .agents/context/roadmap.md, 13 açık madde (P0 1–6, P1 7–10, P2 11–13): birim testleri.

private let archive = URL(fileURLWithPath: "/tmp/ornek.7z")

private func temporaryFolder(_ name: String = "sert") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(of url: URL) -> UInt16? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt16(info.st_mode & 0o7777) : nil
}

// MARK: - P0-1 Çok satırlı yorum

/// 7zz'nin gerçek çıktısı: yorum "{ … }" arasında olduğu gibi yazılır; içindeki alanlar ve ayraç başlığı ya da
/// girdileri değiştiremez.
@Test func commentCannotSpoofHeaderOrInjectEntries() {
    let output = """
    Listing archive: c.zip

    --
    Path = c.zip
    Type = zip
    Physical Size = 194
    Comment =
    {
    satır bir
    Type = 7z
    ----------
    Path = sahte.txt
    Size = 999999

    }
    Total Physical Size = 1
    son satır
    }
    Total Physical Size = 300

    ----------
    Path = gercek.txt
    Size = 5
    Attributes =  -rw-r--r--

    """
    let listing = ListingParser.parse(output)
    #expect(listing.entries.map(\.path) == ["gercek.txt"])
    #expect(listing.info.type == "zip")
    #expect(listing.info.physicalSize == 300)
    #expect(listing.info.comment == "satır bir\nType = 7z\n----------\nPath = sahte.txt\nSize = 999999\n\n}\nTotal Physical Size = 1\nson satır")
    #expect(!ArchiveCapabilities.isEditable(type: ListingParser.parse(output.replacingOccurrences(of: "Type = zip", with: "Type = Rar")).info.type, url: archive))

    // Boş arşivde de 7zz ayracı yazar; yorumdaki sahte girdi listeye girmez.
    let empty = "--\nPath = e.zip\nType = zip\nComment = \n{\n----------\nPath = sahte\nSize = 5\n}\n\n----------\n"
    #expect(ListingParser.parse(empty).entries.isEmpty)
    #expect(ListingParser.parse(empty).info.comment == "----------\nPath = sahte\nSize = 5")
}

// MARK: - P0-5 Joker karakterler

@Test func archivePathsAreNeverWildcards() {
    let starred = URL(fileURLWithPath: "/tmp/yedek*1.7z")
    #expect(SevenZipCommand.list(archive: starred).contains("-spd"))
    #expect(SevenZipCommand.test(archive: starred).contains("-spd"))
    #expect(SevenZipCommand.extract(ExtractOptions(archive: starred, destination: URL(fileURLWithPath: "/tmp/c"), overwrite: .replace)).contains("-spd"))
    #expect(SevenZipCommand.hash(file: starred).contains("-spd"))
    #expect(SevenZipCommand.add(archive: starred, names: ["a"]).contains("-spd"))
    #expect(!SevenZipCommand.add(archive: archive, names: ["a"]).contains("-spd"))

    let plain = CreateOptions(sources: [URL(fileURLWithPath: "/x/a")], destination: URL(fileURLWithPath: "/tmp/y?.zip"), format: .zip, level: .fast)
    #expect(SevenZipCommand.create(plain).contains("-spd"))
    let tarGz = CreateOptions(sources: [URL(fileURLWithPath: "/x/a")], destination: URL(fileURLWithPath: "/tmp/y*.tar.gz"), format: .tarGzip, level: .fast)
    let stage = URL(fileURLWithPath: "/tmp/s/y.tar")
    #expect(SevenZipCommand.compressTarStage(tarGz, tarStage: stage)?.contains("-spd") == true)
}

