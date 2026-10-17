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
    #expect(Set(types.compactMap { $0["CFBundleTypeIconFile"] as? String }) == ["zip", "7z", "rar", "tar", "disk", "archive"])
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
    #expect(claimed.count == Set(claimed).count, "bir tür birden çok ailede")
    // Arhivar'ın tanımladığı tüm türler ve Servisler menüsündeki türler bir aileye bağlı olmalı.
    let imported = (plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
    let services = (plist["NSServices"] as? [[String: Any]] ?? [])
        .filter { $0["NSMessage"] as? String != "compress" }
        .flatMap { $0["NSSendFileTypes"] as? [String] ?? [] }
    #expect(Set(imported).isSubset(of: Set(claimed)))
    #expect(Set(services).isSubset(of: Set(claimed)))
    let family = { (uti: String) in types.first { ($0["LSItemContentTypes"] as? [String] ?? []).contains(uti) }?["CFBundleTypeIconFile"] as? String }
    #expect(family("public.zip-archive") == "zip")
    #expect(family("org.tukaani.tar-xz-archive") == "tar")
    #expect(family("com.apple.disk-image-udif") == "disk")
    #expect(family("public.iso-image") == "disk")
    #expect(family("public.archive") == "archive")
}
