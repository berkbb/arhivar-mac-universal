import CLibArchive
import Foundation

/// Arşiv listesini macOS'un yerleşik libarchive kitaplığıyla süreç içinde okur.
///
/// Quick Look eklentileri "quicklook-preview" kum havuzu profilinde çalışır: bu profil alt süreç başlatmayı yasaklar,
/// bu yüzden eklenti 7zz'yi çalıştıramaz. Bu okuyucu, 7zz kullanılamadığında yalnızca listeleme için yedek yoldur;
/// arşiv içeriğini çıkarmaz ve diske hiçbir şey yazmaz.
public enum LibArchiveReader {
    public enum ReadError: Error, Equatable, LocalizedError {
        /// Dosya listesi (7z -mhe gibi) parola ile şifrelenmiş.
        case encryptedHeaders
        /// libarchive arşivi açamadı ya da okuyamadı.
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .encryptedHeaders: "encrypted headers"
            case .unreadable(let message): message
            }
        }
    }

    /// Listedeki girdi sayısı için üst sınır: bozuk ya da kötü niyetli arşiv belleği tüketmesin.
    public static let maxEntries = 200_000

    /// - Parameter maxEntries: Okunacak en çok girdi; sınıra ulaşılırsa liste orada kesilir.
    public static func list(archive url: URL, fallbackName: String? = nil, maxEntries: Int = maxEntries) throws -> ArchiveListing {
        do {
            return try read(url, raw: false, fallbackName: fallbackName, maxEntries: maxEntries)
        } catch ReadError.unreadable(let message) {
            // Tek akışlı sıkıştırılmış dosyalar (.gz, .xz, .bz2, .zst) bir arşiv biçimi taşımaz: ham akış olarak okunur.
            if let rawListing = try? read(url, raw: true, fallbackName: fallbackName, maxEntries: maxEntries) { return rawListing }
            throw ReadError.unreadable(message)
        }
    }

    private static func read(_ url: URL, raw: Bool, fallbackName: String?, maxEntries: Int) throws -> ArchiveListing {
        guard let handle = archive_read_new() else { throw ReadError.unreadable("archive_read_new") }
        defer { archive_read_free(handle) }
        archive_read_support_filter_all(handle)
        if raw {
            archive_read_support_format_raw(handle)
        } else {
            archive_read_support_format_all(handle)
        }

        func failure() -> ReadError {
            if archive_read_has_encrypted_entries(handle) > 0 { return .encryptedHeaders }
            let message = archive_error_string(handle).map { String(cString: $0) } ?? ""
            // libarchive 7z/rar başlık şifrelemesini desteklemez; yalnızca hata iletisiyle bildirir.
            if message.localizedCaseInsensitiveContains("encrypt") { return .encryptedHeaders }
            return .unreadable(message)
        }

        guard archive_read_open_filename(handle, url.path, 64 * 1024) == ARCHIVE_OK else { throw failure() }

        var entries: [ArchiveEntry] = []
        var entry: OpaquePointer?
        while entries.count < maxEntries {
            let status = archive_read_next_header(handle, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else { throw failure() }
            entries.append(makeEntry(entry, raw: raw, fallbackName: fallbackName ?? url.deletingPathExtension().lastPathComponent))
        }
        // Ham okuma her girdiyi ("data") kabul eder; bir sıkıştırma süzgeci yoksa dosya arşiv değildir.
        if raw && archive_filter_count(handle) <= 1 { throw ReadError.unreadable("") }

        let info = ArchiveInfo(
            path: url.path, type: typeName(handle, url: url),
            physicalSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        )
        return ArchiveListing(info: info, entries: entries)
    }

    private static func makeEntry(_ entry: OpaquePointer, raw: Bool, fallbackName: String) -> ArchiveEntry {
        let rawPath = (archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)).map { String(cString: $0) } ?? ""
        let archivePath = raw ? fallbackName : rawPath
        let fileType = UInt32(archive_entry_filetype(entry)) & UInt32(AE_IFMT)
        let isDirectory = fileType == UInt32(AE_IFDIR) || archivePath.hasSuffix("/")
        let size: Int64? = archive_entry_size_is_set(entry) != 0 && !isDirectory ? archive_entry_size(entry) : nil
        let modified: Date? = archive_entry_mtime_is_set(entry) != 0
            ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil
        return ArchiveEntry(
            path: ListingParser.normalizedPath(archivePath), archivePath: archivePath, size: size, modified: modified,
            isDirectory: isDirectory, isEncrypted: archive_entry_is_encrypted(entry) != 0,
            isSymbolicLink: fileType == UInt32(AE_IFLNK), isHardLink: archive_entry_hardlink(entry) != nil
        )
    }

    /// 7zz'nin "Type" alanıyla aynı kısa adlar ("7z", "zip", "rar", …); ham akışta süzgecin adı ("gzip", "xz").
    private static func typeName(_ handle: OpaquePointer, url: URL) -> String {
        switch archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK {
        case ARCHIVE_FORMAT_7ZIP: return "7z"
        case ARCHIVE_FORMAT_ZIP: return "zip"
        case ARCHIVE_FORMAT_RAR, ARCHIVE_FORMAT_RAR_V5: return "rar"
        case ARCHIVE_FORMAT_TAR: return "tar"
        case ARCHIVE_FORMAT_ISO9660: return "iso"
        case ARCHIVE_FORMAT_CAB: return "cab"
        case ARCHIVE_FORMAT_XAR: return "xar"
        case ARCHIVE_FORMAT_LHA: return "lzh"
        case ARCHIVE_FORMAT_CPIO: return "cpio"
        case ARCHIVE_FORMAT_AR: return "ar"
        case ARCHIVE_FORMAT_RAW:
            if archive_filter_count(handle) > 1, let name = archive_filter_name(handle, 0) { return String(cString: name) }
            return url.pathExtension.lowercased()
        default: return url.pathExtension.lowercased()
        }
    }
}
