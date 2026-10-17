import Foundation

/// Çıkarmayı önce hedefle aynı birimdeki bir hazırlık klasörüne yapar, başarıda hedefe taşır.
///
/// 7zz iptal ya da hata (CRC, dolu disk) durumunda yarım dosyaları son adlarıyla bırakır; "üzerine yaz"
/// seçiliyken kullanıcının mevcut dosyası kesik bir kopyayla değişebilir. Hazırlık klasörü sayesinde hedef
/// ya tamamen güncellenir ya da hiç değişmez.
public enum StagedExtraction {
    /// Hedefle aynı birimde, yalnızca kullanıcıya açık bir hazırlık klasörü.
    public static func makeStagingDirectory(for destination: URL, fileManager: FileManager = .default) throws -> URL {
        let anchor = existingAncestor(of: destination, fileManager: fileManager)
        if let replacement = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: anchor, create: true
        ) {
            return replacement
        }
        // Bazı birimlerde (ör. ağ paylaşımları) sistem klasörü verilemez; hedefin yanında gizli bir klasör kullanılır.
        let fallback = anchor.appendingPathComponent(".arhivar-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return fallback
    }

    /// Hazırlık klasöründeki öğeleri hedefe taşır ve üzerine yazma politikasını uygular.
    /// Klasörler birleştirilir. Hedefteki sembolik bağlantıların içine yazılmaz; bunlar çakışma sayılır.
    /// - Returns: Hedefte oluşan ya da değişen üst düzey öğeler.
    @discardableResult
    public static func merge(
        from staging: URL, into destination: URL, policy: OverwriteMode, fileManager: FileManager = .default
    ) throws -> [URL] {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var changed: [URL] = []
        for item in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            if let result = try mergeItem(item, into: destination.appendingPathComponent(item.lastPathComponent), policy: policy, fileManager: fileManager) {
                changed.append(result)
            }
        }
        return changed
    }

    private static func mergeItem(_ source: URL, into target: URL, policy: OverwriteMode, fileManager: FileManager) throws -> URL? {
        guard let targetType = itemType(target, fileManager: fileManager) else {
            try fileManager.moveItem(at: source, to: target)
            return target
        }
        if itemType(source, fileManager: fileManager) == .typeDirectory, targetType == .typeDirectory {
            var touched = false
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                if try mergeItem(child, into: target.appendingPathComponent(child.lastPathComponent), policy: policy, fileManager: fileManager) != nil {
                    touched = true
                }
            }
            return touched ? target : nil
        }
        switch policy {
        case .skip:
            return nil
        case .replace:
            if targetType == .typeRegular, itemType(source, fileManager: fileManager) == .typeRegular {
                // Dosyadan dosyaya: yerinde, tek adımda değiştir.
                _ = try fileManager.replaceItemAt(target, withItemAt: source)
            } else {
                try fileManager.removeItem(at: target)
                try fileManager.moveItem(at: source, to: target)
            }
            return target
        case .rename:
            let unique = uniqueURL(for: target, fileManager: fileManager)
            try fileManager.moveItem(at: source, to: unique)
            return unique
        }
    }

    /// 7-Zip'in "-aou" adlandırmasıyla aynı: "ad_1.uzanti", "ad_2.uzanti", …
    public static func uniqueURL(for url: URL, fileManager: FileManager = .default) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if itemType(candidate, fileManager: fileManager) == nil { return candidate }
            index += 1
        }
    }

    /// Son yol bileşenini izlemeden (lstat) öğe türü; yoksa nil.
    static func itemType(_ url: URL, fileManager: FileManager) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    static func existingAncestor(of url: URL, fileManager: FileManager) -> URL {
        var current = url
        while !fileManager.fileExists(atPath: current.path), current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}

/// Çıkarmadan önce boş alan denetimi.
public enum DiskSpace {
    /// Sistemin işlemesi için bırakılan pay.
    public static let reserve: Int64 = 1 << 30

    public static func availableCapacity(at url: URL, fileManager: FileManager = .default) -> Int64? {
        let anchor = StagedExtraction.existingAncestor(of: url, fileManager: fileManager)
        let values = try? anchor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Boyutu bilinmeyen birim (nil) engellenmez; çıkarma 7zz'nin kendi hatasıyla durur.
    public static func hasRoom(required: Int64, available: Int64?, reserve: Int64 = reserve) -> Bool {
        guard let available else { return true }
        return required <= max(0, available - reserve)
    }

    /// Seçili öğelerin (boşsa tüm arşivin) açılmış toplam boyutu.
    public static func requiredBytes(for items: [String], in entries: [ArchiveEntry]) -> Int64 {
        entries.reduce(0) { total, entry in
            guard !entry.isDirectory else { return total }
            let selected = items.isEmpty || items.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
            return selected ? total + (entry.size ?? 0) : total
        }
    }
}

/// Yetersiz disk alanı.
public struct InsufficientSpaceError: Error, Equatable, Sendable {
    public let required: Int64
    public let available: Int64

    public init(required: Int64, available: Int64) {
        self.required = required
        self.available = available
    }

    /// Gerekirse hata fırlatır.
    public static func check(required: Int64, at url: URL) throws {
        let available = DiskSpace.availableCapacity(at: url)
        guard DiskSpace.hasRoom(required: required, available: available) else {
            throw InsufficientSpaceError(required: required, available: available ?? 0)
        }
    }
}
