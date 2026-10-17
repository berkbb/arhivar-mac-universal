import Foundation
import Testing
@testable import ArhivarCore

private let sampleListing = """
7-Zip (z) 26.04 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-10-05

Scanning the drive for archives:
1 file, 4096 bytes (4 KiB)

Listing archive: ornek.7z

--
Path = ornek.7z
Type = 7z
Physical Size = 4096
Headers Size = 210
Method = LZMA2:24 7zAES
Solid = +
Blocks = 1

----------
Path = belgeler
Size = 0
Packed Size = 0
Modified = 2026-10-05 19:42:01.1234567
Attributes = D drwxr-xr-x
CRC =
Encrypted = -
Method =
Block =

Path = belgeler/not.txt
Size = 1200
Packed Size = 3800
Modified = 2026-10-05 19:42:01.1234567
Attributes = A -rw-r--r--
CRC = ABCD1234
Encrypted = +
Method = LZMA2:24 7zAES
Block = 0

Path = resimler/tatil/foto.jpg
Size = 5000
Packed Size =
Modified = 2026-01-02 03:04:05
Attributes = A -rw-r--r--
Encrypted = -
Method = LZMA2:24

"""

@Test func parsesArchiveHeader() {
    let listing = ListingParser.parse(sampleListing, timeZone: TimeZone(identifier: "UTC")!)
    #expect(listing.info.type == "7z")
    #expect(listing.info.method == "LZMA2:24 7zAES")
    #expect(listing.info.isSolid)
    #expect(listing.info.physicalSize == 4096)
}

@Test func parsesEntries() throws {
    let listing = ListingParser.parse(sampleListing, timeZone: TimeZone(identifier: "UTC")!)
    #expect(listing.entries.count == 3)

    let folder = listing.entries[0]
    #expect(folder.path == "belgeler")
    #expect(folder.isDirectory)
    #expect(folder.method == nil)
    #expect(folder.crc == nil)

    let note = listing.entries[1]
    #expect(note.size == 1200)
    #expect(note.packedSize == 3800)
    #expect(note.isEncrypted)
    #expect(note.crc == "ABCD1234")
    let expected = try #require(ISO8601DateFormatter().date(from: "2026-10-05T19:42:01Z"))
    #expect(note.modified == expected)

    let photo = listing.entries[2]
    #expect(photo.packedSize == nil)
    #expect(!photo.isDirectory)
}

@Test func emptyArchiveHasNoEntries() {
    let output = """
    Listing archive: bos.zip

    --
    Path = bos.zip
    Type = zip
    Physical Size = 22

    """
    let listing = ListingParser.parse(output)
    #expect(listing.entries.isEmpty)
    #expect(listing.info.type == "zip")
}

@Test func statisticsUsePhysicalSize() {
    let listing = ListingParser.parse(sampleListing)
    let statistics = ArchiveStatistics(listing: listing)
    #expect(statistics.fileCount == 2)
    // "belgeler" açık girdi; "resimler" ve "resimler/tatil" yalnızca dosya yolundan çıkar (P2-18).
    #expect(statistics.folderCount == 3)
    #expect(statistics.totalSize == 6200)
    #expect(statistics.packedSize == 4096)
    #expect(statistics.isEncrypted)
    #expect(statistics.ratio != nil)
}

@Test func buildsTreeWithImplicitFolders() {
    let listing = ListingParser.parse(sampleListing)
    let tree = ArchiveTree.build(from: listing.entries)
    #expect(tree.map(\.name) == ["belgeler", "resimler"])

    let documents = tree[0]
    #expect(documents.isDirectory)
    #expect(documents.size == 1200)
    #expect(documents.children?.map(\.id) == ["belgeler/not.txt"])

    // "resimler" ve "resimler/tatil" arşivde açıkça yok; ağaç onları oluşturmalı.
    let pictures = tree[1]
    #expect(pictures.id == "resimler")
    #expect(pictures.children?.first?.id == "resimler/tatil")
    #expect(pictures.children?.first?.children?.first?.id == "resimler/tatil/foto.jpg")
    #expect(pictures.size == 5000)
}

@Test func sortsFoldersFirst() {
    let entries = [
        ArchiveEntry(path: "b.txt", size: 10),
        ArchiveEntry(path: "a.txt", size: 30),
        ArchiveEntry(path: "z", isDirectory: true),
    ]
    let tree = ArchiveTree.build(from: entries)
    let byName = ArchiveTree.sorted(tree, using: [KeyPathComparator(\.name)])
    #expect(byName.map(\.name) == ["z", "a.txt", "b.txt"])
    let bySizeDescending = ArchiveTree.sorted(tree, using: [KeyPathComparator(\.size, order: .reverse)])
    #expect(bySizeDescending.map(\.name) == ["z", "a.txt", "b.txt"])
    let bySize = ArchiveTree.sorted(tree, using: [KeyPathComparator(\.size)])
    #expect(bySize.map(\.name) == ["z", "b.txt", "a.txt"])
}

@Test func searchReturnsFullPaths() {
    let tree = ArchiveTree.build(from: ListingParser.parse(sampleListing).entries)
    let results = ArchiveTree.search(tree, query: "FOTO")
    #expect(results.map(\.name) == ["resimler/tatil/foto.jpg"])
    #expect(results.first?.children == nil)
}
