import Foundation

/// 7zz'ye çok sayıda öğe adını liste dosyasıyla (`-i@dosya`) verir.
///
/// macOS bir sürecin argümanlarını ve ortamını birlikte ARG_MAX (1 MiB) ile sınırlar. ⌘A ile on binlerce öğe
/// seçilince (sürükleme, kopyalama, seçilenleri çıkarma, silme; Finder'da binlerce dosyayı sıkıştırma) 7zz hiç
/// başlatılamıyor ("Argument list too long"), hata da "motor bulunamadı" diye görünüyordu. Öğe adları sınıra
/// yaklaşınca liste dosyasına yazılır; 7zz bunları doğrudan argümanlarla aynı kurallarla eşleştirir.
///
/// 7zz liste satırlarının başındaki ve sonundaki boşlukları kırpar ve tümüyle tırnak içindeki bir satırın
/// tırnaklarını atar; satır sonu içeren bir ad da tek satıra yazılamaz. Böyle adlar doğrudan argüman olarak kalır.
public enum ItemListFile {
    /// Doğrudan argüman olarak verilebilecek en çok öğe baytı; kum havuzu profili ve ortam için bol pay bırakır.
    public static let directByteLimit = 256 << 10
    /// Öğe adı alan komutlar. Öğeler "--" ayracından sonraki ilk argümanın (arşiv yolu) ardından gelir.
    static let commands: Set<String> = ["a", "d", "e", "t", "x"]

    public struct Fitted: Sendable, Equatable {
        public let arguments: [String]
        /// Yazılan liste dosyası; süreç bitince `remove()` ile silinir.
        public let listFile: URL?

        public func remove() {
            if let listFile { try? FileManager.default.removeItem(at: listFile) }
        }
    }

    /// Argümanlar sınıra sığıyorsa aynen döner; sığmıyorsa liste dosyasına yazılabilen öğe adları `-i@dosya` ile verilir.
    public static func fitting(
        _ arguments: [String], directory: URL = ItemExtractor.temporaryRoot, limit: Int = directByteLimit
    ) throws -> Fitted {
        guard let command = arguments.first, commands.contains(command),
              let separator = arguments.firstIndex(of: "--"), separator + 2 < arguments.count else {
            return Fitted(arguments: arguments, listFile: nil)
        }
        let items = arguments[(separator + 2)...]
        guard items.reduce(0, { $0 + $1.utf8.count + 1 }) > limit else { return Fitted(arguments: arguments, listFile: nil) }
        let listed = items.filter(isListable)
        // Boş bir liste dosyası 7zz'de komut satırı hatasıdır.
        guard !listed.isEmpty else { return Fitted(arguments: arguments, listFile: nil) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("items-\(UUID().uuidString).txt")
        // Arşivdeki adlar (şifreli bir arşivinkiler de) yalnızca kullanıcıya açık bir dosyada durur.
        let contents = Data((listed.joined(separator: "\n") + "\n").utf8)
        guard fileManager.createFile(atPath: file.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        let direct = items.filter { !isListable($0) }
        let fitted = Array(arguments[..<separator]) + ["-scsUTF-8", "-i@" + file.path, "--", arguments[separator + 1]] + direct
        return Fitted(arguments: fitted, listFile: file)
    }

    /// Ad, 7zz'nin liste dosyasından aynen okuyacağı biçimde mi?
    static func isListable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, let last = name.unicodeScalars.last else { return false }
        if first.properties.isWhitespace || last.properties.isWhitespace || first == "\u{FEFF}" { return false }
        if name.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) { return false }
        return !(name.unicodeScalars.count > 1 && first == "\"" && last == "\"")
    }
}
