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
        // Bayt düzeyinde böl (karakter düzeyinde bölmekten çok daha hızlı); "\r\n" sonundaki \r atılır.
        let lines: [Substring] = output.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { bytes in
            let line = Substring(bytes)
            return line.utf8.last == 0x0D ? line.dropLast() : line
        }

        guard let separator = lines.firstIndex(where: { isMarker($0, "----------") }) else {
            // Girdi listesi yoksa (boş arşiv) yalnızca başlık okunur.
            return ArchiveListing(info: parseInfo(lines[...]), entries: [])
        }

        let info = parseInfo(lines[..<separator])
        var entries: [ArchiveEntry] = []
        // Alanlar satırın kendisini gösteren Substring'lerdir; yalnızca girdi oluşturulurken kopyalanır.
        var block = Block()

        func flush() {
            if block.hasFields, block.path?.isEmpty ?? true, entries.isEmpty, let fallbackName {
                block.path = Substring(fallbackName)
            }
            if let entry = makeEntry(block, timeZone: timeZone) { entries.append(entry) }
            block = Block()
        }

        for line in lines[(separator + 1)...] {
            if line.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                flush()
            } else if let (key, value) = keyValue(line) {
                block.set(key, value)
            }
        }
        flush()
        return ArchiveListing(info: info, entries: entries)
    }

    static func parseInfo(_ lines: ArraySlice<Substring>) -> ArchiveInfo {
        // Arşiv başlığı "--" satırından sonra gelir.
        guard let start = lines.firstIndex(where: { isMarker($0, "--") }) else {
            return ArchiveInfo()
        }
        var values: [String: String] = [:]
        for line in lines[(start + 1)...] {
            if let (key, value) = keyValue(line) { values[String(key)] = String(value) }
        }
        return ArchiveInfo(
            path: values["Path"],
            type: values["Type"],
            method: values["Method"].flatMap { $0.isEmpty ? nil : $0 },
            isSolid: values["Solid"] == "+",
            physicalSize: values["Physical Size"].flatMap { Int64($0) }
        )
    }

    static func isMarker(_ line: Substring, _ marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }

    static func keyValue(_ line: Substring) -> (Substring, Substring)? {
        if let range = line.range(of: " = ") {
            return (line[..<range.lowerBound], line[range.upperBound...])
        }
        if line.hasSuffix(" =") {
            return (line.dropLast(2), "")
        }
        return nil
    }

    /// Bir girdinin `-slt` alanları (yalnızca kullanılanlar).
    struct Block {
        var path, size, packedSize, modified, attributes, folder, encrypted, method, crc: Substring?
        var hasFields = false

        mutating func set(_ key: Substring, _ value: Substring) {
            hasFields = true
            switch key {
            case "Path": path = value
            case "Size": size = value
            case "Packed Size": packedSize = value
            case "Modified": modified = value
            case "Attributes": attributes = value
            case "Folder": folder = value
            case "Encrypted": encrypted = value
            case "Method": method = value
            case "CRC": crc = value
            default: break
            }
        }
    }

    static func makeEntry(_ block: Block, timeZone: TimeZone) -> ArchiveEntry? {
        guard let path = block.path, !path.isEmpty else { return nil }
        let isDirectory = block.folder == "+" || (block.attributes?.hasPrefix("D") ?? false)
        var modified: Date?
        if let raw = block.modified, raw.utf8.count >= 19 {
            modified = parseTimestamp(raw, timeZone: timeZone)
        }
        return ArchiveEntry(
            path: String(path),
            size: block.size.flatMap { Int64($0) },
            packedSize: block.packedSize.flatMap { Int64($0) },
            modified: modified,
            isDirectory: isDirectory,
            isEncrypted: block.encrypted == "+",
            method: block.method.flatMap { $0.isEmpty ? nil : String($0) },
            crc: block.crc.flatMap { $0.isEmpty ? nil : String($0) }
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

extension ListingParser {
    /// "yyyy-MM-dd HH:mm:ss[.fffffff]" (yerel saat) değerini okur.
    ///
    /// Büyük arşivlerde DateFormatter ayrıştırma süresinin çoğunu tüketiyordu (200 bin girdide ~12 sn);
    /// bu fonksiyon baytları doğrudan okur ve takvim hesabını kendisi yapar.
    static func parseTimestamp<S: StringProtocol>(_ raw: S, timeZone: TimeZone) -> Date? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(19)
        for byte in raw.utf8.prefix(19) { bytes.append(byte) }
        guard bytes.count == 19, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x20,
              bytes[13] == 0x3A, bytes[16] == 0x3A else { return nil }

        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }

        let local = Double(daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second)
        // Yerel saati UTC'ye çevir. Bir gün önce ve sonra fark aynıysa (neredeyse her zaman) geçiş yoktur.
        let before = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: local - 86_400))
        let after = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: local + 86_400))
        if before == after { return Date(timeIntervalSince1970: local - Double(before)) }
        // Yaz saati geçişi: her iki farkla aday üret, geçerli olanları seç. İki kez yaşanan saatte DateFormatter
        // gibi sonrakini (standart saat), var olmayan saatte geçişten sonraki farkı kullan.
        let valid = [before, after].compactMap { offset -> Date? in
            let candidate = Date(timeIntervalSince1970: local - Double(offset))
            return timeZone.secondsFromGMT(for: candidate) == offset ? candidate : nil
        }
        return valid.max() ?? Date(timeIntervalSince1970: local - Double(after))
    }

    /// 1970-01-01'den bu yana gün sayısı (Howard Hinnant'ın days_from_civil algoritması).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
