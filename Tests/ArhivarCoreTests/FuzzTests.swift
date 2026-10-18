import Foundation
import Testing
@testable import ArhivarCore

// Belirli tohumlu (deterministik) bulanıklık (fuzz) testleri: saf ayrıştırıcılar ve yol mantığı hostil girdilerle
// beslenir. Amaç bir çökme (taşma tuzağı, dizin aşımı, zorla çözme) ya da sonsuz döngü / bellek patlaması bulmak;
// bir başarısızlık, tohum ve yineleme numarasıyla yeniden üretilebilir. Çökme = test sürecinin çökmesidir.

/// Tohumlanabilir, hızlı üreteç (SplitMix64); testin tekrarlanabilir olması için `Int.random`/`Date` kullanılmaz.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Ayrıştırıcıların derinlemesine kapsanması için "ilginç" belirteçler; saf rastgele metinden çok daha fazla dal gezer.
private let tokens: [String] = [
    " = ", "=", " =", "\n", "\r\n", "\r", "----------", "--", "{", "}", "  ", "\t",
    "Path", "Size", "Packed Size", "Modified", "Attributes", "Folder", "Encrypted", "Method", "CRC",
    "Comment", "Type", "Physical Size", "Total Physical Size", "Blocks", "Volumes", "Mode", "Symbolic Link",
    "zip", "7z", "tar", "Rar", "+", "-", "D", "A", "lrwxr-xr-x", "drwxr-xr-x",
    "a/b/c.txt", "./x", "../escape", "a//b", "klasor/", "._config", ".DS_Store", "__MACOSX",
    "0", "1", "-1", "999999999999999999999999", "18446744073709551615", "9223372036854775808",
    "2026-10-18 11:22:33", "not-a-date", "0000-99-99 99:99:99", "\u{0008}", "\u{202E}", "\u{0000}",
    " for data:", "SHA256", "CRC32", "BLAKE2sp", "Enter password", "Break signaled", "ERROR:",
    "Dangerous link path was ignored", "Everything is Ok", "Cannot open the file as archive", "%@", "%1$@",
]

private func randomScalar(_ g: inout SplitMix64) -> Unicode.Scalar {
    while true {
        let pick = UInt64.random(in: 0..<100, using: &g)
        let value: UInt32
        if pick < 40 {
            value = UInt32.random(in: 0...0x7F, using: &g) // ASCII, kontrol karakterleri dahil
        } else if pick < 70 {
            value = UInt32.random(in: 0x80...0xFFFF, using: &g) // BMP, birleştirmeler ve yön karakterleri
        } else {
            value = UInt32.random(in: 0x1_0000...0x10_FFFF, using: &g) // ek düzlemler (emoji vb.)
        }
        if (0xD800...0xDFFF).contains(value) { continue } // vekil (surrogate) kod noktaları geçersiz
        if let scalar = Unicode.Scalar(value) { return scalar }
    }
}

private func randomUnicode(_ g: inout SplitMix64, maxLen: Int = 40) -> String {
    let length = Int(UInt64.random(in: 0...UInt64(maxLen), using: &g))
    var scalars = String.UnicodeScalarView()
    for _ in 0..<length { scalars.append(randomScalar(&g)) }
    return String(scalars)
}

/// Belirteçleri ve rastgele unicode parçalarını birleştirerek dilbilgisine yakın girdi üretir.
private func spliced(_ g: inout SplitMix64, maxParts: Int) -> String {
    let parts = Int(UInt64.random(in: 0...UInt64(maxParts), using: &g))
    var out = ""
    for _ in 0..<parts {
        if UInt64.random(in: 0..<10, using: &g) < 7 {
            out += tokens[Int(UInt64.random(in: 0..<UInt64(tokens.count), using: &g))]
        } else {
            out += randomUnicode(&g, maxLen: 8)
        }
    }
    return out
}

private func assertNormalized(_ path: String, _ label: @autoclosure () -> String) {
    // normalizedPath çıktısı boş olabilir ama "//" içermemeli, "/" ile başlayıp bitmemeli, "." / ".." bileşeni olmamalı.
    #expect(!path.contains("//"), "\(label())")
    #expect(!path.hasPrefix("/"), "\(label())")
    #expect(!path.hasSuffix("/"), "\(label())")
    for component in path.split(separator: "/") {
        #expect(component != "." && component != "..", "\(label())")
    }
}

@Suite(.serialized)
struct FuzzTests {
    /// Tüm saf metin ayrıştırıcıları rastgele ve dilbilgisine yakın girdilerle; çökmemeli, takılmamalı.
    @Test func textParsersSurviveHostileInput() {
        var g = SplitMix64(seed: 0xA5A5_1234)
        for i in 0..<6000 {
            let input = UInt64.random(in: 0..<2, using: &g) == 0 ? randomUnicode(&g, maxLen: 120) : spliced(&g, maxParts: 60)

            let listing = ListingParser.parse(input)
            #expect(ListingParser.parse(input) == listing, "parse kararlı değil (tohum A, #\(i))") // deterministiklik
            let stats = ArchiveStatistics(listing: listing)
            #expect(stats.fileCount >= 0 && stats.folderCount >= 0, "#\(i)")
            #expect(stats.totalSize >= 0 && stats.packedSize >= 0, "negatif boyut toplamı (#\(i))")
            for entry in listing.entries { assertNormalized(entry.path, "entry.path #\(i)") }

            _ = ChecksumParser.parse(input)
            _ = ChecksumParser.text(ChecksumParser.parse(input))
            _ = ProgressParser.lastPercentage(in: input)
            if let percent = ProgressParser.lastPercentage(in: input) { #expect((0...100).contains(percent), "#\(i)") }
            _ = try? SevenZipError.check(ProcessResult(exitCode: Int32(truncatingIfNeeded: g.next()), stdout: input, stderr: spliced(&g, maxParts: 10)))
            _ = SevenZipError.needsPassword(ProcessResult(exitCode: 2, stdout: input, stderr: ""))
            _ = Quarantine.derivedValue(from: input)
        }
    }

    /// Yol normalleştirme ve arşiv adı yardımcıları: her girdide değişmezler korunmalı, çökme olmamalı.
    @Test func pathAndNamingSurviveHostileInput() throws {
        var g = SplitMix64(seed: 0x0BAD_F00D)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { StagedExtraction.removeTree(at: directory) }

        for i in 0..<6000 {
            let raw = UInt64.random(in: 0..<2, using: &g) == 0 ? randomUnicode(&g, maxLen: 60) : spliced(&g, maxParts: 20)
            assertNormalized(ListingParser.normalizedPath(raw), "normalizedPath(\(raw.debugDescription)) #\(i)")

            let url = directory.appendingPathComponent(raw.isEmpty ? "x" : raw)
            _ = ArchiveNaming.isArchive(url)
            _ = ArchiveNaming.firstVolume(of: url)
            _ = ArchiveNaming.baseName(of: url)
            _ = ArchiveNaming.streamItemName(for: url)
            _ = ArchiveNaming.isBrowsable(raw)
            _ = ArchiveTree.renamedPath(raw, to: "yeni")
            _ = ArchiveTree.breadcrumbs(for: ListingParser.normalizedPath(raw))
            _ = OpenSafety.hasDeceptiveCharacters(raw)
            let visible = OpenSafety.visibleName(raw)
            #expect(!OpenSafety.hasDeceptiveCharacters(visible), "visibleName hâlâ aldatıcı (#\(i))") // görünür ad temiz olmalı
        }
    }

    /// Rastgele girdilerden ağaç kurma ve gezinme: boyutlar saturasyonla toplanmalı, düğüm kimlikleri normalleştirilmiş olmalı.
    @Test func archiveTreeSurvivesHostileEntries() {
        var g = SplitMix64(seed: 0xDEAD_BEEF)
        for i in 0..<3000 {
            let count = Int(UInt64.random(in: 0...40, using: &g))
            var entries: [ArchiveEntry] = []
            for _ in 0..<count {
                let path = UInt64.random(in: 0..<2, using: &g) == 0 ? randomUnicode(&g, maxLen: 24) : spliced(&g, maxParts: 8)
                let size: Int64?
                switch UInt64.random(in: 0..<5, using: &g) {
                case 0: size = nil
                case 1: size = Int64.max
                case 2: size = -1
                case 3: size = Int64(bitPattern: g.next())
                default: size = Int64(UInt64.random(in: 0...1_000_000, using: &g))
                }
                entries.append(ArchiveEntry(
                    path: ListingParser.normalizedPath(path), archivePath: path, size: size, packedSize: size,
                    isDirectory: UInt64.random(in: 0..<2, using: &g) == 0, isSymbolicLink: UInt64.random(in: 0..<4, using: &g) == 0
                ))
            }
            let tree = ArchiveTree.build(from: entries)
            let index = ArchiveTree.index(tree)
            for (id, node) in index {
                assertNormalized(id, "node id #\(i)")
                #expect(node.id == id, "#\(i)")
            }
            // Görünüm katmanının yaptığı gibi her klasörün içeriğini iste; çökme olmamalı.
            for (id, node) in index where node.isDirectory {
                _ = ArchiveTree.contents(of: id, roots: tree, index: index)
            }
            _ = ArchiveTree.contents(of: "", roots: tree, index: index)
            _ = ArchiveStatistics(listing: ArchiveListing(info: ArchiveInfo(), entries: entries))
            let items = entries.prefix(3).map(\.path)
            #expect(DiskSpace.requiredBytes(for: Array(items), in: entries) >= 0, "negatif gereken bayt (#\(i))")
            #expect(DiskSpace.requiredBytes(for: [], in: entries) >= 0, "#\(i)")
        }
    }

    /// Büyük girdiler: parçalı okuma, taşma ya da dizin aşımı olmadan tamamlanmalı (bellek/süre patlaması olmamalı).
    @Test func largeInputsDoNotExplode() {
        var g = SplitMix64(seed: 0x1234_5678)
        // Çok sayıda girdi: 50.000 satırlık teknik liste.
        var huge = "--\nType = zip\n\n----------\n"
        for index in 0..<50_000 {
            huge += "Path = dosya\(index).bin\nSize = \(UInt64.random(in: 0...UInt64.max, using: &g))\n\n"
        }
        let listing = ListingParser.parse(huge)
        #expect(listing.entries.count == 50_000)
        let stats = ArchiveStatistics(listing: listing)
        #expect(stats.totalSize >= 0 && stats.packedSize >= 0)

        // Çok derin iç içe tek yol.
        let deep = (0..<20_000).map { "k\($0)" }.joined(separator: "/")
        assertNormalized(ListingParser.normalizedPath("./" + deep + "/"), "derin yol")
        let deepTree = ArchiveTree.build(from: [ArchiveEntry(path: ListingParser.normalizedPath(deep), archivePath: deep)])
        #expect(!deepTree.isEmpty)

        // Çok uzun tek bileşen ve çok sayıda "../".
        assertNormalized(ListingParser.normalizedPath(String(repeating: "a", count: 200_000)), "uzun bileşen")
        assertNormalized(ListingParser.normalizedPath(String(repeating: "../", count: 20_000) + "x"), "çok ../")
    }
}
