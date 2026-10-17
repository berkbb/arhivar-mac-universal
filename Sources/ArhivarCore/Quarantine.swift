import Darwin
import Foundation

/// İnternetten inmiş bir arşivin karantina işaretini (com.apple.quarantine) çıkarılan dosyalara aktarır.
///
/// 7zz bunu yapmaz; aktarılmazsa arşivden çıkan .app, .command ve betikler Gatekeeper denetimi olmadan açılır.
/// Archive Utility ve ditto aynı işareti aktarır.
public enum Quarantine {
    static let attributeName = "com.apple.quarantine"
    /// "Kullanıcı açmayı onayladı" biti; arşivin onayı içindeki dosyalara geçmemeli.
    static let userApprovedFlag: UInt32 = 0x0040

    /// Dosyanın karantina değeri (yoksa nil).
    public static func value(of url: URL) -> String? {
        let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, attributeName, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    /// Arşivin değerinden çıkarılan dosyalara yazılacak değer: biçim "bayraklar;zaman;ajan;uuid", onay biti temizlenir.
    public static func derivedValue(from archiveValue: String) -> String {
        var fields = archiveValue.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, let flags = UInt32(first, radix: 16) else { return archiveValue }
        fields[0] = String(format: "%04x", flags & ~userApprovedFlag)
        return fields.joined(separator: ";")
    }

    static func set(_ value: String, on url: URL) {
        let bytes = Array(value.utf8)
        _ = setxattr(url.path, attributeName, bytes, bytes.count, 0, XATTR_NOFOLLOW)
    }

    /// Hedefteki, `since` anından sonra yazılmış öğeleri işaretler.
    ///
    /// - Parameters:
    ///   - roots: İncelenecek üst düzey adlar (ör. arşivin kök öğeleri). Hedefte yeni oluşan üst düzey öğeler de eklenir.
    ///   - since: Çıkarmanın başladığı an; değişim zamanı (ctime) bundan yeni olanlar 7zz tarafından yazılmıştır.
    /// - Returns: İşaretlenen öğe sayısı.
    @discardableResult
    public static func propagate(
        from archive: URL, to destination: URL, roots: [String] = [], since start: Date,
        fileManager: FileManager = .default
    ) -> Int {
        guard let archiveValue = value(of: archive) else { return 0 }
        let mark = derivedValue(from: archiveValue)
        // Dosya sistemi zaman çözünürlüğü için küçük pay.
        let threshold = start.addingTimeInterval(-1)
        let keys: [URLResourceKey] = [.attributeModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]

        func isFresh(_ url: URL) -> Bool {
            guard let changed = try? url.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate else {
                return false
            }
            return changed >= threshold
        }

        var topLevel = Set(roots.compactMap { $0.split(separator: "/").first.map(String.init) })
        if let entries = try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: keys) {
            for entry in entries where isFresh(entry) { topLevel.insert(entry.lastPathComponent) }
        }

        var count = 0
        for name in topLevel.sorted() {
            let root = destination.appendingPathComponent(name)
            guard (try? root.checkResourceIsReachable()) == true || isSymlink(root) else { continue }
            if isFresh(root) {
                set(mark, on: root)
                count += 1
            }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { continue }
            for case let item as URL in enumerator where isFresh(item) {
                set(mark, on: item)
                count += 1
            }
        }
        return count
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
