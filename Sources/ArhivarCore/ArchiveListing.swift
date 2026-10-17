import Foundation

public struct ArchiveEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var size: Int64?
    public var packedSize: Int64?
    public var modified: Date?
    public var isDirectory: Bool
    public var isEncrypted: Bool
    public var method: String?
    public var crc: String?

    public init(
        path: String, size: Int64? = nil, packedSize: Int64? = nil, modified: Date? = nil,
        isDirectory: Bool = false, isEncrypted: Bool = false, method: String? = nil, crc: String? = nil
    ) {
        self.path = path
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
        self.method = method
        self.crc = crc
    }
}

public struct ArchiveInfo: Sendable, Equatable {
    public var path: String?
    public var type: String?
    public var method: String?
    public var isSolid: Bool
    public var physicalSize: Int64?

    public init(path: String? = nil, type: String? = nil, method: String? = nil, isSolid: Bool = false, physicalSize: Int64? = nil) {
        self.path = path
        self.type = type
        self.method = method
        self.isSolid = isSolid
        self.physicalSize = physicalSize
    }
}

public struct ArchiveListing: Sendable, Equatable {
    public var info: ArchiveInfo
    public var entries: [ArchiveEntry]

    public init(info: ArchiveInfo, entries: [ArchiveEntry]) {
        self.info = info
        self.entries = entries
    }
}

/// `7zz l -slt` (teknik liste) çıktısını ayrıştırır.
public enum ListingParser {
    /// - Parameter fallbackName: Tek akışlı biçimlerde (xz, bzip2) 7zz öğe adı yazmaz; bu ad kullanılır.
    public static func parse(_ output: String, timeZone: TimeZone = .current, fallbackName: String? = nil) -> ArchiveListing {
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        guard let separator = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "----------" }) else {
            // Girdi listesi yoksa (boş arşiv) yalnızca başlık okunur.
            return ArchiveListing(info: parseInfo(lines[...]), entries: [])
        }

        let info = parseInfo(lines[..<separator])
        var entries: [ArchiveEntry] = []
        var block: [String: String] = [:]

        func flush() {
            if !block.isEmpty, block["Path"]?.isEmpty ?? true, entries.isEmpty, let fallbackName {
                block["Path"] = fallbackName
            }
            if let entry = makeEntry(block, formatter: formatter) { entries.append(entry) }
            block = [:]
        }

        for line in lines[(separator + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if let (key, value) = keyValue(line) {
                block[key] = value
            }
        }
        flush()
        return ArchiveListing(info: info, entries: entries)
    }

    static func parseInfo(_ lines: ArraySlice<String>) -> ArchiveInfo {
        // Arşiv başlığı "--" satırından sonra gelir.
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "--" }) else {
            return ArchiveInfo()
        }
        var values: [String: String] = [:]
        for line in lines[(start + 1)...] {
            if let (key, value) = keyValue(line) { values[key] = value }
        }
        return ArchiveInfo(
            path: values["Path"],
            type: values["Type"],
            method: values["Method"].flatMap { $0.isEmpty ? nil : $0 },
            isSolid: values["Solid"] == "+",
            physicalSize: values["Physical Size"].flatMap { Int64($0) }
        )
    }

    static func keyValue(_ line: String) -> (String, String)? {
        if let range = line.range(of: " = ") {
            return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
        }
        if line.hasSuffix(" =") {
            return (String(line.dropLast(2)), "")
        }
        return nil
    }

    static func makeEntry(_ block: [String: String], formatter: DateFormatter) -> ArchiveEntry? {
        guard let path = block["Path"], !path.isEmpty else { return nil }
        let isDirectory = block["Folder"] == "+" || (block["Attributes"]?.hasPrefix("D") ?? false)
        var modified: Date?
        if let raw = block["Modified"], raw.count >= 19 {
            modified = formatter.date(from: String(raw.prefix(19)))
        }
        return ArchiveEntry(
            path: path,
            size: block["Size"].flatMap { Int64($0) },
            packedSize: block["Packed Size"].flatMap { Int64($0) },
            modified: modified,
            isDirectory: isDirectory,
            isEncrypted: block["Encrypted"] == "+",
            method: block["Method"].flatMap { $0.isEmpty ? nil : $0 },
            crc: block["CRC"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// Durum çubuğu ve bilgi paneli için özet değerler.
public struct ArchiveStatistics: Sendable, Equatable {
    public let fileCount: Int
    public let folderCount: Int
    public let totalSize: Int64
    public let packedSize: Int64
    public let isEncrypted: Bool

    public var ratio: Double? {
        totalSize > 0 ? Double(packedSize) / Double(totalSize) : nil
    }

    public init(listing: ArchiveListing) {
        let files = listing.entries.filter { !$0.isDirectory }
        fileCount = files.count
        folderCount = listing.entries.count - files.count
        totalSize = files.reduce(0) { $0 + ($1.size ?? 0) }
        let packedSum = listing.entries.reduce(0) { $0 + ($1.packedSize ?? 0) }
        packedSize = listing.info.physicalSize ?? packedSum
        isEncrypted = listing.entries.contains(where: \.isEncrypted)
    }
}
