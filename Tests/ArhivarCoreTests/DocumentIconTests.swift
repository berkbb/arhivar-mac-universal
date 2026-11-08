// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing

/// Info.plist'teki belge türleri ile Resources/DocumentIcons altındaki simgeler tutarlı olmalı.
private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func infoPlist() throws -> [String: Any] {
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Support/Info.plist"))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Test func everyDocumentTypeHasItsIcon() throws {
    let types = try #require(try infoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
    // Biçim başına bir simge; adlar Scripts/make_document_icons.swift içindeki ailelerle aynı.
    let expected: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "z", "zst", "lz4", "lz", "lzma", "iso", "dmg", "vmdk", "vhd", "vhdx", "qcow2", "squashfs", "udf", "wim", "cab", "cpio", "xar", "deb", "rpm", "split", "arj", "lzh", "archive"]
    #expect(Set(types.compactMap { $0["CFBundleTypeIconFile"] as? String }) == expected)
    #expect(types.count == expected.count, "her simge tek bir belge türüne ait")
    for type in types {
        let icon = try #require(type["CFBundleTypeIconFile"] as? String)
        let url = packageRoot.appendingPathComponent("Resources/DocumentIcons/\(icon).icns")
        #expect(FileManager.default.fileExists(atPath: url.path), "\(icon).icns")
        // Arhivar kendini varsayılan yapmaz; simgeler kullanıcı "Tümünü Değiştir" dediğinde görünür.
        #expect(type["LSHandlerRank"] as? String == "Alternate")
    }
}

@Test func documentTypesCoverEveryArchiveTypeOnce() throws {
    let plist = try infoPlist()
    let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let claimed = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
    #expect(claimed.count == Set(claimed).count, "bir tür birden çok belge türünde")
    // Arhivar'ın tanımladığı tüm türler ve Servisler menüsündeki türler bir aileye bağlı olmalı.
    let imported = (plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
    let services = (plist["NSServices"] as? [[String: Any]] ?? [])
        .filter { $0["NSMessage"] as? String != "compress" }
        .flatMap { $0["NSSendFileTypes"] as? [String] ?? [] }
    #expect(Set(imported).isSubset(of: Set(claimed)))
    #expect(Set(services).isSubset(of: Set(claimed)))
    let family = { (uti: String) in types.first { ($0["LSItemContentTypes"] as? [String] ?? []).contains(uti) }?["CFBundleTypeIconFile"] as? String }
    #expect(family("public.zip-archive") == "zip")
    #expect(family("public.tar-archive") == "tar")
    #expect(family("org.gnu.gnu-zip-archive") == "gz")
    #expect(family("org.gnu.gnu-zip-tar-archive") == "tgz")
    #expect(family("org.tukaani.xz-archive") == "xz")
    #expect(family("org.tukaani.tar-xz-archive") == "txz")
    #expect(family("com.facebook.zstandard-archive") == "zst")
    #expect(family("com.apple.disk-image-udif") == "dmg")
    #expect(family("public.iso-image") == "iso")
    #expect(family("com.microsoft.windows-imaging-format") == "wim")
    #expect(family("org.7-zip.split-archive") == "split")
    #expect(family("public.archive") == "archive")
}
