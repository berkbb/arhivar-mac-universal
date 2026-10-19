import Darwin
import Foundation

/// Bir dosyanın kipi ve genişletilmiş öznitelikleri (karantina işareti, Finder etiketleri, "nereden indirildi").
///
/// 7zz yerinde düzenlemede (a/d/rn) arşivi `-w` klasöründeki kopyasıyla DEĞİŞTİRİR: yeni bir inode, umask kipi (0644)
/// ve hiç öznitelik olmadan. Karantina işareti kaybolunca sonraki çıkarmalarda hiçbir dosya işaretlenmez (Gatekeeper
/// atlanır); 0600 bir arşiv herkesçe okunur olur; Finder etiketleri silinir. Düzenlemeden önce alınır, sonra geri yazılır.
public struct PreservedAttributes: Sendable {
    /// İzin bitleri (st_mode & 07777).
    public let permissions: mode_t
    public let extendedAttributes: [String: [UInt8]]

    /// Sistemin kendisinin yönettiği, geri yazılamayan öznitelikler.
    static let unrestorable: Set<String> = ["com.apple.provenance"]

    /// Yalnızca sıradan dosyalar için; bağlantı izlenmez.
    public init?(of url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        permissions = info.st_mode & 0o7777
        var attributes: [String: [UInt8]] = [:]
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var names = [CChar](repeating: 0, count: size)
            let read = listxattr(url.path, &names, size, XATTR_NOFOLLOW)
            if read > 0 {
                for raw in names.prefix(read).split(separator: 0) {
                    let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    guard !Self.unrestorable.contains(name) else { continue }
                    let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    guard length >= 0 else { continue }
                    var value = [UInt8](repeating: 0, count: length)
                    let got = length == 0 ? 0 : getxattr(url.path, name, &value, length, 0, XATTR_NOFOLLOW)
                    guard got >= 0 else { continue }
                    attributes[name] = Array(value.prefix(got))
                }
            }
        }
        extendedAttributes = attributes
    }

    /// Öznitelikleri, sonra kipi geri yazar (salt okunur bir kipte öznitelik yazılamazdı). Yazılamayan tek tek atlanır.
    /// - Returns: Geri yazılamayan öznitelik adları.
    @discardableResult
    public func restore(to url: URL) -> [String] {
        var failed: [String] = []
        for (name, value) in extendedAttributes.sorted(by: { $0.key < $1.key }) {
            if setxattr(url.path, name, value, value.count, 0, XATTR_NOFOLLOW) != 0 { failed.append(name) }
        }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 != permissions {
            chmod(url.path, permissions)
        }
        return failed
    }
}
