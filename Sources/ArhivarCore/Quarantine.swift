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

    /// Öğenin karantina değeri (yoksa nil). Sembolik bağlantıda bağlantının kendisininki okunur.
    public static func value(of url: URL) -> String? {
        if let value = read(url.path) { return value }
        // Okuma izni olmayan (0111, 0000) dosyalarda getxattr EACCES verir; izin kısa süre açılır.
        guard errno == EACCES || errno == EPERM else { return nil }
        return OwnerAccess.granting(S_IRUSR, on: url.path) { read(url.path) }
    }

    private static func read(_ path: String) -> String? {
        let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &buffer, size, 0, XATTR_NOFOLLOW)
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

    /// Karantina değerini yazar. Sahibin yazma izni olmayan öğelerde (0555 .app ikilileri ve .command betikleri,
    /// 0444, 0111, 0000) setxattr EACCES verir; işaret yazılmazsa öğe Gatekeeper denetimi olmadan açılırdı.
    /// Bu yüzden izin kısa süre açılıp eski kip geri yüklenir.
    @discardableResult
    static func set(_ value: String, on url: URL) -> Bool {
        let bytes = Array(value.utf8)
        func write() -> Bool { setxattr(url.path, attributeName, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 }
        if write() { return true }
        guard errno == EACCES || errno == EPERM else { return false }
        return OwnerAccess.granting(S_IWUSR, on: url.path, write)
    }

    /// Öğe beklenen karantina değerini taşımıyorsa yeniden yazar (ör. dosya değiştirme eski üst veriyi geri getirdiyse).
    static func ensure(_ value: String?, on url: URL) {
        guard let value, self.value(of: url) != value else { return }
        set(value, on: url)
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

        func isFresh(_ url: URL) -> Bool {
            guard let changed = try? url.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate else {
                return false
            }
            return changed >= threshold
        }

        var topLevel = Set(roots.compactMap { $0.split(separator: "/").first.map(String.init) })
        // "._" ile başlayan sıradan dosyalar da (FileManager listelemez) işaretlenir; yoksa "._calis.command" Gatekeeper
        // denetimi olmadan açılırdı.
        for name in (try? StagedExtraction.entries(ofDirectory: destination.path)) ?? [] where isFresh(destination.appendingPathComponent(name)) {
            topLevel.insert(name)
        }

        var count = 0
        // Okuma ya da geçiş izni olmayan (0000, 0311) klasörlerin içi de işaretlenir: alt ağaç işlenirken klasöre
        // izin verilir, sonra eski kip geri yüklenir. Sembolik bağlantıların gösterdiği klasörlere inilmez.
        func visit(_ url: URL) {
            if isFresh(url), set(mark, on: url) { count += 1 }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
            OwnerAccess.granting(S_IRUSR | S_IXUSR, on: url.path) {
                for name in (try? StagedExtraction.entries(ofDirectory: url.path)) ?? [] {
                    visit(url.appendingPathComponent(name))
                }
            }
        }
        for name in topLevel.sorted() {
            var info = stat()
            let root = destination.appendingPathComponent(name)
            guard lstat(root.path, &info) == 0 else { continue }
            visit(root)
        }
        return count
    }
}
