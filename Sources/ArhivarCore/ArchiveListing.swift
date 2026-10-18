import Foundation

public struct ArchiveEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// Normalleştirilmiş yol ("./a//b/" → "a/b"); ağaç, gezinme ve görünüm bunu kullanır.
    public var path: String
    /// 7zz'nin listede yazdığı ham yol. 7zz öğeleri yalnızca bu yazımla eşleştirir; komutlara bu verilir.
    public var archivePath: String
    public var size: Int64?
    public var packedSize: Int64?
    public var modified: Date?
    public var isDirectory: Bool
    public var isEncrypted: Bool
    public var method: String?
    public var crc: String?
    /// Sembolik bağlantı girdisi. 7zz hedef dışını gösteren bağlantıyı yazmaz, yerine 0 baytlık bir dosya bırakır.
    public var isSymbolicLink: Bool

    public init(
        path: String, archivePath: String? = nil, size: Int64? = nil, packedSize: Int64? = nil, modified: Date? = nil,
        isDirectory: Bool = false, isEncrypted: Bool = false, method: String? = nil, crc: String? = nil,
        isSymbolicLink: Bool = false
    ) {
        self.path = path
        self.archivePath = archivePath ?? path
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
        self.method = method
        self.crc = crc
        self.isSymbolicLink = isSymbolicLink
    }
}

public struct ArchiveInfo: Sendable, Equatable {
    public var path: String?
    public var type: String?
    public var method: String?
    public var isSolid: Bool
    /// Arşivin diskteki boyutu; bölünmüş arşivlerde tüm parçaların toplamı.
    public var physicalSize: Int64?
    /// Arşiv yorumu (zip, rar, 7z), varsa.
    public var comment: String?
    /// Katı (solid) blok sayısı (7z).
    public var blocks: Int?
    /// Bölünmüş arşivin parça sayısı.
    public var volumes: Int?

    public init(
        path: String? = nil, type: String? = nil, method: String? = nil, isSolid: Bool = false, physicalSize: Int64? = nil,
        comment: String? = nil, blocks: Int? = nil, volumes: Int? = nil
    ) {
        self.path = path
        self.type = type
        self.method = method
        self.isSolid = isSolid
        self.physicalSize = physicalSize
        self.comment = comment
        self.blocks = blocks
        self.volumes = volumes
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
        // Satırlar bayt düzeyinde ve tembel okunur: 200 bin girdide milyonlarca öğelik ara dizi oluşmaz.
        // Girdi blokları okunurken işlenir; küçük başlık bölümü en sonda bir kez ayrıştırılır.
        //
        // Başlık ile girdileri ayıran, SON "----------" satırıdır. 7zz arşiv yorumunu "{ … }" arasında olduğu gibi
        // yazar; yorum sahte bir ayraç ve "Path = …" satırları içerebilir. Girdi alanlarında ise satır sonları "_"
        // olur, bu yüzden gerçek ayraçtan sonra bir daha ayraç gelemez (boş arşivde de ayraç yazılır). Sonradan gelen
        // her ayraç, o ana kadar girdi sanılanların da başlığa ait olduğunu gösterir.
        var headerEnd: String.Index?
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

        forEachLine(of: output[...]) { line in
            if isMarker(line, "----------") {
                headerEnd = line.startIndex
                entries.removeAll()
                block = Block()
            } else if headerEnd == nil {
                return
            } else if line.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                flush()
            } else if let (key, value) = keyValue(line) {
                block.set(key, value)
            }
        }
        var header: [Substring] = []
        forEachLine(of: output[..<(headerEnd ?? output.endIndex)]) { header.append($0) }
        // Girdi listesi yoksa yalnızca başlık okunur.
        guard headerEnd != nil else { return ArchiveListing(info: parseInfo(header[...]), entries: []) }
        flush()
        return ArchiveListing(info: parseInfo(header[...]), entries: entries)
    }

    /// Metnin satırlarını ara dizi oluşturmadan sırayla verir; "\r\n" sonundaki \r atılır.
    static func forEachLine(of text: Substring, _ body: (Substring) -> Void) {
        let utf8 = text.utf8
        var start = utf8.startIndex
        while start < utf8.endIndex {
            let end = utf8[start...].firstIndex(of: 0x0A) ?? utf8.endIndex
            var line = Substring(utf8[start..<end])
            if line.utf8.last == 0x0D { line = line.dropLast() }
            body(line)
            guard end < utf8.endIndex else { return }
            start = utf8.index(after: end)
        }
    }

    static func parseInfo(_ lines: ArraySlice<Substring>) -> ArchiveInfo {
        // Arşiv başlığı "--" satırından sonra gelir.
        guard let start = lines.firstIndex(where: { isMarker($0, "--") }) else {
            return ArchiveInfo()
        }
        let body = lines[(start + 1)...]
        // Çok satırlı değerler (arşiv yorumu) "Comment = " satırından sonra "{" ve "}" satırları arasında, olduğu gibi
        // yazılır. Yorum "Type = 7z" gibi alan satırları ya da kendi "}" satırını içerebilir; bunlar başlık alanlarını
        // değiştirmemeli. Gerçek kapanış başlıktaki son "}" satırıdır: ardından yalnızca 7zz'nin kendi alanları gelir.
        let lastClose = body.lastIndex { $0 == "}" }
        var values: [String: String] = [:]
        var lastKey: String?
        var index = body.startIndex
        while index < body.endIndex {
            defer { index += 1 }
            let line = body[index]
            guard let (key, value) = keyValue(line) else {
                if lastKey == "Comment", !isMarker(line, "--"), !isMarker(line, "----") {
                    // Süslü ayraçsız yazılmış çok satırlı yorumun devam satırları.
                    values["Comment", default: ""] += "\n" + line
                }
                continue
            }
            lastKey = String(key)
            let open = index + 1
            if value.isEmpty, open < body.endIndex, body[open] == "{", let close = lastClose, close > open {
                values[String(key)] = body[(open + 1)..<close].joined(separator: "\n")
                lastKey = nil
                index = close
            } else {
                values[String(key)] = String(value)
            }
        }
        let comment = values["Comment"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ArchiveInfo(
            path: values["Path"],
            type: values["Type"],
            method: values["Method"].flatMap { $0.isEmpty ? nil : $0 },
            isSolid: values["Solid"] == "+",
            // Bölünmüş arşivde "Physical Size" yalnızca ilk parçanın boyutudur.
            physicalSize: (values["Total Physical Size"] ?? values["Physical Size"]).flatMap { Int64($0) },
            comment: comment?.isEmpty == false ? comment : nil,
            blocks: values["Blocks"].flatMap { Int($0) },
            volumes: values["Volumes"].flatMap { Int($0) }
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
        var path, size, packedSize, modified, attributes, folder, encrypted, method, crc, mode, symbolicLink: Substring?
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
            case "Mode": mode = value
            case "Symbolic Link": symbolicLink = value
            default: break
            }
        }

        /// tar "Symbolic Link = hedef" ve "Mode = lrwxr-xr-x" yazar; zip ve 7z Unix kipini "Attributes" sonunda
        /// ("A lrwxr-xr-x") verir.
        var isSymbolicLink: Bool {
            if let symbolicLink, !symbolicLink.isEmpty { return true }
            if let mode, Block.isLinkMode(mode) { return true }
            return attributes?.split(separator: " ").last.map(Block.isLinkMode) ?? false
        }

        static func isLinkMode(_ text: Substring) -> Bool {
            text.utf8.count == 10 && text.utf8.first == UInt8(ascii: "l")
        }
    }

    /// Arşiv içi yolu ağaç için normalleştirir: baştaki "./", "." ve ".." bileşenleri, yinelenen ve sondaki "/" atılır.
    /// `tar -czf a.tgz .` ile oluşturulan arşivler "./src/main.swift" gibi yollar saklar. 7zz çıkarırken ".."
    /// bileşenlerini birleştirmeden atar ("a/../x.txt" → "a/x.txt"); ağaç ve hedef yollar da aynı yeri göstersin.
    public static func normalizedPath<S: StringProtocol>(_ raw: S) -> String {
        // Hızlı yol: neredeyse tüm yollar zaten normaldir; tek bayt taramasıyla anlaşılır, kopya yapılmaz.
        guard needsNormalization(raw) else { return String(raw) }
        return raw.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    /// Yolda boş ("//", baştaki ya da sondaki "/"), "." ya da ".." bileşeni var mı?
    static func needsNormalization<S: StringProtocol>(_ raw: S) -> Bool {
        // Bileşenin uzunluğu ve içindeki nokta sayısı; boş, "." ya da ".." bileşen normalleştirme ister.
        var length = 0
        var dots = 0
        for byte in raw.utf8 {
            if byte == 0x2F {
                if length == 0 || (dots == length && length <= 2) { return true }
                length = 0
                dots = 0
            } else {
                length += 1
                if byte == 0x2E { dots += 1 }
            }
        }
        return length == 0 || (dots == length && length <= 2)
    }

    /// 7zz boyutları işaretsiz yazar. Int64.max'ı aşan (uydurma) bir boyut `Int64(_:)` ile nil olur ve boş alan
    /// denetiminde 0 sayılırdı; sınırda durur. Negatif değer geçersizdir (nil).
    static func parseSize(_ text: Substring) -> Int64? {
        UInt64(text).map { Int64(clamping: $0) }
    }

    static func makeEntry(_ block: Block, timeZone: TimeZone) -> ArchiveEntry? {
        guard let raw = block.path, !raw.isEmpty else { return nil }
        let path = normalizedPath(raw)
        // "." (arşivin kendi kök klasörü) gibi boş kalan yollar ağaçta gösterilmez.
        guard !path.isEmpty else { return nil }
        let isDirectory = block.folder == "+" || (block.attributes?.hasPrefix("D") ?? false)
        var modified: Date?
        if let value = block.modified, value.utf8.count >= 19 {
            modified = parseTimestamp(value, timeZone: timeZone)
        }
        return ArchiveEntry(
            path: path,
            archivePath: String(raw),
            size: block.size.flatMap(parseSize),
            packedSize: block.packedSize.flatMap(parseSize),
            modified: modified,
            isDirectory: isDirectory,
            isEncrypted: block.encrypted == "+",
            method: block.method.flatMap { $0.isEmpty ? nil : String($0) },
            crc: block.crc.flatMap { $0.isEmpty ? nil : String($0) },
            isSymbolicLink: !isDirectory && block.isSymbolicLink
        )
    }
}

extension Int64 {
    /// Taşmada çökmek yerine sınırda durur. Kötü niyetli bir arşiv (zip bombası) toplamı Int64.max'ı aşan
    /// boyutlar bildirebilir; denetimsiz `+` uygulamayı anında çökertir.
    public func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other > 0 ? .max : .min
    }
}

extension Sequence where Element == Int64 {
    /// Taşmaya dayanıklı toplam.
    public func saturatingSum() -> Int64 {
        reduce(0) { $0.saturatingAdding($1) }
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
        var files = 0
        var total: Int64 = 0
        var packedSum: Int64 = 0
        var encrypted = false
        // Açık klasör girdileri ile dosya yollarından çıkan ara klasörler: birçok zip/tar klasör girdisi saklamaz.
        var folders = Set<Substring>()
        // tar'a sonradan eklenen (tar -r) aynı yollu girdiler: ağaçtaki gibi yalnızca en son girdi sayılır.
        var filePaths = Set<Substring>()
        for entry in listing.entries.reversed() {
            packedSum = packedSum.saturatingAdding(entry.packedSize ?? 0)
            if entry.isEncrypted { encrypted = true }
            let path = entry.path[...]
            if entry.isDirectory {
                guard folders.insert(path).inserted else { continue }
            } else {
                guard filePaths.insert(path).inserted else { continue }
                files += 1
                total = total.saturatingAdding(entry.size ?? 0)
            }
            // Üst klasörleri ekle; zaten bilinen bir üste gelince onun üstleri de bilinir.
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                guard folders.insert(parent).inserted else { break }
            }
        }
        fileCount = files
        folderCount = folders.count
        totalSize = total
        packedSize = listing.info.physicalSize ?? packedSum
        isEncrypted = encrypted
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
