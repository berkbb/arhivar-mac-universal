import Darwin
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
        // Sistem klasörünü OS temizler; bu yedek klasörler çökme ya da zorla kapanışta kalır: eskileri burada süpürülür.
        sweepStaleStaging(in: anchor, fileManager: fileManager)
        let fallback = anchor.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return fallback
    }

    static let stagingPrefix = ".arhivar-staging-"

    /// Bir çökmeden kalan, `age` saniyeden eski yedek hazırlık klasörlerini siler.
    static func sweepStaleStaging(in directory: URL, olderThan age: TimeInterval = 3600, now: Date = Date(), fileManager: FileManager = .default) {
        for name in (try? entries(ofDirectory: directory.path)) ?? [] where name.hasPrefix(stagingPrefix) {
            let url = directory.appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if now.timeIntervalSince(modified) > age { removeTree(at: url, fileManager: fileManager) }
        }
    }

    /// Hazırlık klasöründe taşınacak içeriğin kökü. Klasör görünümünde bir alt klasördeyken seçilen öğeler
    /// 7zz tarafından tam iç yollarıyla ("a/b/c/dosya.txt") yazılır; hedefe o klasörün yolu olmadan gitmeleri için
    /// içerik "a/b/c" altından alınır.
    public static func contentRoot(in staging: URL, stripping folder: String, fileManager: FileManager = .default) -> URL {
        let components = folder.split(separator: "/").filter { $0 != "." && $0 != ".." }
        guard !components.isEmpty else { return staging }
        let candidate = components.reduce(staging) { $0.appendingPathComponent(String($1), isDirectory: true) }
        guard itemType(candidate, fileManager: fileManager) == .typeDirectory else { return staging }
        // Yoldaki bir üst klasör sembolik bağlantıysa içerik hazırlık klasörünün dışından alınırdı.
        let expected = ([resolvedPath(staging.path)] + components.map(String.init)).joined(separator: "/")
        return resolvedPath(candidate.path) == expected ? candidate : staging
    }

    /// İçeriğin taşınacağı klasör: alt klasör kuralına göre hedefin kendisi ya da arşiv adıyla bir alt klasörü.
    /// "Akıllı" kural, tek kök öğeli arşivlerde "Ad/Ad/…" iç içe klasörünü önler; çok öğeli arşivlerin
    /// ("tarbomb") içeriği hedefe dağılmaz, arşiv adıyla bir klasörde toplanır.
    public static func destination(
        for content: URL, base: URL, archiveName: String, mode: SubfolderMode, fileManager: FileManager = .default
    ) -> URL {
        let subfolder = base.appendingPathComponent(archiveName, isDirectory: true)
        switch mode {
        case .always: return subfolder
        case .never: return base
        case .smart:
            let roots = (try? entries(ofDirectory: content.path)) ?? []
            // .DS_Store, __MACOSX ve AppleDouble (._*) üst verileri sayılmaz: Finder'ın "Sıkıştır" ile yaptığı
            // tek klasörlü arşivlerin kökündeki __MACOSX, "akıllı" kipin "Ad/Ad/…" iç içe klasörü oluşturmasına yol açmasın.
            let meaningful = roots.filter { !isMacMetadata($0, in: content) }
            let count = meaningful.isEmpty ? roots.count : meaningful.count
            return count > 1 ? subfolder : base
        }
    }

    /// `directory` içindeki `name` bir macOS üst veri öğesi mi: Finder görünüm ayarları (.DS_Store), Arşiv İzlencesi'nin
    /// kaynak çatalı klasörü (__MACOSX) ya da bir AppleDouble dosyası ("._ad")?
    ///
    /// "._" ile başlayan her dosya üst veri değildir ("._config" gibi veri dosyaları olabilir): yalnızca AppleDouble
    /// imzasını (0x00051607) taşıyan ya da yanında eşi ("ad") bulunan dosyalar sayılır.
    public static func isMacMetadata(_ name: String, in directory: URL) -> Bool {
        if name == ".DS_Store" || name == "__MACOSX" { return true }
        guard name.hasPrefix("._"), name.count > 2 else { return false }
        let url = directory.appendingPathComponent(name)
        guard itemType(url) == .typeRegular else { return false }
        if itemType(directory.appendingPathComponent(String(name.dropFirst(2)))) != nil { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x00, 0x05, 0x16, 0x07])
    }

    /// Klasörün tüm öğelerinin adları (`readdir`). `FileManager.contentsOfDirectory` ve numaralandırıcıları "._" ile
    /// başlayan sıradan dosyaları hiç listelemez: bunlar çıkarmada hedefe taşınmaz, karantina işareti almaz, boş alan
    /// hesabına girmezdi. Klasör, bağlantı ve FIFO'lar her iki yolla da listelenir.
    public static func entries(ofDirectory path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Akıllı kural, kökteki tek anlamlı öğenin yanında yalnızca macOS üst verisi olduğu için içeriği doğrudan hedefe
    /// çıkarıyorsa o üst veri hedefe taşınmaz: kullanıcının klasörüne "__MACOSX" dağılmaz, klasörün kendi ".DS_Store"u
    /// (Finder görünüm ayarları) arşivinkiyle ezilmez. Arşivde üst veriden başka bir şey yoksa ya da içerik bir alt
    /// klasöre çıkıyorsa hiçbir şey bırakılmaz.
    /// - Returns: Hazırlıkta bırakılan (taşınmayacak) kök öğelerin adları.
    @discardableResult
    public static func leaveOutRootMetadata(
        in content: URL, destination: URL, base: URL, mode: SubfolderMode, fileManager: FileManager = .default
    ) -> [String] {
        guard mode == .smart, destination == base else { return [] }
        let roots = (try? entries(ofDirectory: content.path)) ?? []
        let metadata = roots.filter { isMacMetadata($0, in: content) }
        guard !metadata.isEmpty, metadata.count < roots.count else { return [] }
        for name in metadata { removeTree(at: content.appendingPathComponent(name), fileManager: fileManager) }
        return metadata.sorted()
    }

    /// Hazırlık klasöründeki öğeleri hedefe taşır ve üzerine yazma politikasını uygular.
    /// Klasörler birleştirilir. Hedefteki sembolik bağlantıların içine yazılmaz; bunlar çakışma sayılır.
    /// - Returns: Hedefte oluşan ya da değişen üst düzey öğeler.
    @discardableResult
    public static func merge(
        from staging: URL, into destination: URL, policy: OverwriteMode, fileManager: FileManager = .default
    ) throws -> [URL] {
        // Hedef yolun kendisi bir sembolik bağlantı ya da dosyaysa (ör. hedefte arşivle aynı adlı bir bağlantı varken
        // "arşiv adıyla klasör") içine, yani bağlantının gösterdiği yere yazılmaz; alt öğelerdeki çakışma kuralı uygulanır.
        var destination = destination
        if let type = itemType(destination, fileManager: fileManager), type != .typeDirectory {
            switch policy {
            case .skip: return []
            case .replace: try fileManager.removeItem(at: destination) // bağlantının kendisi silinir, gösterdiği yer değil
            case .rename: destination = uniqueURL(for: destination, fileManager: fileManager)
            }
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        // Önceki bir çıkarmadan kalan salt okunur (0555) hedef klasöre de taşınabilsin; kip sonra geri yüklenir
        // (yoksa ilk öğede durulur ve hedef yarım güncellenmiş kalırdı).
        return try OwnerAccess.granting(S_IWUSR | S_IXUSR, on: destination.path) {
            var changed: [URL] = []
            for name in try entries(ofDirectory: staging.path) {
                let item = staging.appendingPathComponent(name)
                if let result = try mergeItem(item, into: destination.appendingPathComponent(name), policy: policy, fileManager: fileManager) {
                    changed.append(result)
                }
            }
            return changed
        }
    }

    private static func mergeItem(_ source: URL, into target: URL, policy: OverwriteMode, fileManager: FileManager) throws -> URL? {
        guard let targetType = itemType(target, fileManager: fileManager) else {
            try fileManager.moveItem(at: source, to: target)
            return target
        }
        if itemType(source, fileManager: fileManager) == .typeDirectory, targetType == .typeDirectory {
            // Önceki bir çıkarmadan kalan salt okunur (0555) ya da içine girilemeyen (0444, 0000) hedef klasöre yazılabilmesi,
            // hazırlıktaki okunamayan (0311) ya da salt okunur (0555) klasörün listelenip boşaltılabilmesi için izinler
            // geçici olarak açılır.
            return try OwnerAccess.granting(S_IWUSR | S_IXUSR, on: target.path) {
                try OwnerAccess.granting(S_IRWXU, on: source.path) {
                    var touched = false
                    for name in try entries(ofDirectory: source.path) {
                        let child = source.appendingPathComponent(name)
                        if try mergeItem(child, into: target.appendingPathComponent(name), policy: policy, fileManager: fileManager) != nil {
                            touched = true
                        }
                    }
                    return touched ? target : nil
                }
            }
        }
        switch policy {
        case .skip:
            return nil
        case .replace:
            if targetType == .typeRegular, itemType(source, fileManager: fileManager) == .typeRegular {
                // Dosyadan dosyaya: yerinde, tek adımda değiştir. Eski dosyanın üst verisi (karantina dahil)
                // yeni içeriğe taşınmasın; yeni dosyanın karantina işareti ayrıca yeniden denetlenir.
                // Salt okunur (0444, 0555) bir dosya yazma izni olmadan değiştirilemez (Cocoa 513).
                let mark = Quarantine.value(of: source)
                let result = try OwnerAccess.granting(S_IWUSR, on: target.path, restoring: false) {
                    try fileManager.replaceItemAt(target, withItemAt: source, options: .usingNewMetadataOnly) ?? target
                }
                Quarantine.ensure(mark, on: result)
                return result
            }
            // Türü farklı öğe (ör. dosyanın yerine klasör): eski öğe önce yanına taşınır, yenisi yerine konur, sonra eski
            // silinir. Önce silip sonra taşıyamamak (ör. içinde kilitli bir dosya varken) eski öğeyi yok ederdi.
            let aside = target.deletingLastPathComponent().appendingPathComponent(".arhivar-replaced-" + UUID().uuidString)
            try fileManager.moveItem(at: target, to: aside)
            do {
                try fileManager.moveItem(at: source, to: target)
            } catch {
                try? fileManager.moveItem(at: aside, to: target)
                throw error
            }
            removeTree(at: aside, fileManager: fileManager)
            return target
        case .rename:
            let unique = uniqueURL(for: target, fileManager: fileManager)
            try fileManager.moveItem(at: source, to: unique)
            return unique
        }
    }

    // MARK: - Sembolik bağlantılar

    /// Klasördeki sembolik bağlantıları denetler: hedef ağacın dışını gösterenleri siler, 7zz'nin mutlak yollu
    /// bağlantıları güvenli kılmak için çıkarma klasörüne göre yazdığı hedefleri göreli yapar.
    ///
    /// 7zz mutlak bir bağlantıyı (ör. "/etc/hosts") çıkarma klasörünün içine yönlendirir ("<hazırlık>/etc/hosts");
    /// hazırlık klasörü taşınıp silinince bu bağlantı ağacın dışını gösterirdi. Göreli yapılınca hedefte de
    /// aynı yeri (hedef/etc/hosts) gösterir.
    /// - Parameters:
    ///   - root: Hedefe taşınacak içeriğin kökü; hiçbir bağlantı bunun dışını göstermemeli.
    ///   - extractionRoot: 7zz'nin çıkardığı klasör (mutlak bağlantıları buna göre yazar); yoksa `root`.
    ///     Alt klasörden çıkarmada içerik ("<hazırlık>/a/b") 7zz'nin klasöründen ("<hazırlık>") daha derindedir:
    ///     "<hazırlık>/etc/hosts" hazırlık klasörünün içinde ama taşınan içeriğin dışındadır.
    /// - Returns: Silinen bağlantıların `root`'a göre yolları.
    @discardableResult
    public static func secureSymlinks(in root: URL, extractionRoot: URL? = nil, fileManager: FileManager = .default) -> [String] {
        // Okunamayan ya da içine girilemeyen (0000, 0311, 0444) klasörlerdeki bağlantılar taramada görünmez, salt okunur
        // (0555) klasördeki bağlantı silinemez ya da yeniden yazılamazdı: tarama sırasında klasörlere sahibi için geçici
        // olarak tam izin verilir, sonunda eski kipler (önce alt klasörler) geri yüklenir.
        var links: [String] = []
        var changed: [(path: String, mode: mode_t)] = []
        func walk(_ path: String, relative: String) {
            if let original = OwnerAccess.add(S_IRWXU, on: path) { changed.append((path, original)) }
            for child in (try? entries(ofDirectory: path)) ?? [] {
                let childPath = (path as NSString).appendingPathComponent(child)
                let childRelative = relative.isEmpty ? child : relative + "/" + child
                var info = stat()
                guard lstat(childPath, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: links.append(childRelative)
                case S_IFDIR: walk(childPath, relative: childRelative)
                default: break
                }
            }
        }
        walk(root.path, relative: "")
        defer { OwnerAccess.restore(changed.reversed()) }
        guard !links.isEmpty else { return [] }

        let rootPath = root.standardizedFileURL.path
        let realRoot = resolvedPath(rootPath)
        let extractionPath = (extractionRoot ?? root).standardizedFileURL.path
        let realExtraction = resolvedPath(extractionPath)
        // 7zz hedefi bizim verdiğimiz yazımla ("/var/…") ya da gerçek yolla ("/private/var/…") yazabilir.
        let bases = Array(Set([
            extractionPath, realExtraction, (extractionPath as NSString).standardizingPath, (realExtraction as NSString).standardizingPath,
        ])).sorted { $0.count > $1.count }
        func inside(_ path: String, of base: String) -> Bool { path == base || path.hasPrefix(base + "/") }
        // İçerik kökünün 7zz klasörüne göre yolu ("a/b"); mutlak bağlantının hedefi bunun altında kalmalı.
        let rootComponents = inside(realRoot, of: realExtraction)
            ? String(realRoot.dropFirst(realExtraction.count)).split(separator: "/").map(String.init)
            : []

        // Önce tüm kararlar özgün ağaç üzerinde verilir, sonra uygulanır: bir bağlantının kararı,
        // daha önce silinen başka bir bağlantıya bağlı olmasın.
        var removals: [String] = []
        var rewrites: [(String, String)] = []
        for relative in links {
            let link = (rootPath as NSString).appendingPathComponent(relative)
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link) else { continue }
            if target.hasPrefix("/") {
                let normalized = lexicallyNormalized(target)
                if let base = bases.first(where: { inside(normalized, of: $0) }) {
                    let fromExtraction = String(normalized.dropFirst(base.count)).split(separator: "/").map(String.init)
                    if fromExtraction.starts(with: rootComponents) {
                        rewrites.append((relative, relativePath(from: relative, to: Array(fromExtraction.dropFirst(rootComponents.count)))))
                        continue
                    }
                }
                removals.append(relative)
                continue
            }
            let resolved = resolvedPath(((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target))
            if !inside(resolved, of: realRoot) { removals.append(relative) }
        }
        for relative in removals {
            try? fileManager.removeItem(atPath: (rootPath as NSString).appendingPathComponent(relative))
        }
        for (relative, target) in rewrites {
            let link = (rootPath as NSString).appendingPathComponent(relative)
            try? fileManager.removeItem(atPath: link)
            try? fileManager.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
        return removals.sorted()
    }

    /// 7zz hedef dışını gösteren bir bağlantıyı ("Dangerous link path was ignored") yazmaz ama yerine 0 baytlık
    /// sıradan bir dosya bırakır. Bu dosya "üzerine yaz" ile hedefteki gerçek dosyayı ezer, önizlemede ve sağlama
    /// değerinde sahte içerik olarak görünür. Arşivde bağlantı olan yollardaki 0 baytlık dosyalar silinir.
    /// - Parameter links: Bağlantı girdilerinin `root`'a göre (normalleştirilmiş) yolları.
    /// - Returns: Silinen yer tutucuların yolları.
    @discardableResult
    public static func removeLinkPlaceholders(in root: URL, links: [String], fileManager: FileManager = .default) -> [String] {
        var removed: [String] = []
        for link in links where !link.isEmpty {
            let url = root.appendingPathComponent(link)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == 0 else { continue }
            // Yer tutucu salt okunur (0555) bir klasörde olabilir; silmek için üst klasöre geçici yazma/geçiş izni verilir.
            let deleted = OwnerAccess.granting(S_IWUSR | S_IXUSR, on: url.deletingLastPathComponent().path) {
                (try? fileManager.removeItem(at: url)) != nil
            }
            if deleted { removed.append(link) }
        }
        return removed.sorted()
    }

    /// Klasörü içindekilerle siler. Arşivden çıkan salt okunur (0555) klasörlerin içi `removeItem` ile silinemez;
    /// hazırlık ve geçici klasörler diskte kalmasın diye önce sahibine yazma izni verilir.
    public static func removeTree(at url: URL, fileManager: FileManager = .default) {
        if (try? fileManager.removeItem(at: url)) != nil || itemType(url, fileManager: fileManager) == nil { return }
        _ = OwnerAccess.addTree(S_IRWXU, below: url.path, fileManager: fileManager)
        try? fileManager.removeItem(at: url)
    }

    /// Hazırlık klasöründe oluşturulmuş arşivi hedef klasöre taşır; aynı adlı eski arşivin yerini tek adımda alır.
    ///
    /// 7zz var olan bir arşive yazarsa onu değiştirmez, içine ekler (eski girdiler kalır); gzip/xz ve bölünmüş
    /// arşivlerde ise hata verir. İptal ya da hata, yarım bir arşivi hedefte bırakmasın diye arşiv önce hazırlık
    /// klasöründe oluşturulur, yalnızca başarıda buraya taşınır.
    /// - Parameters:
    ///   - name: Arşivin adı ("yedek.7z"); bölünmüşse parçalar "yedek.7z.001", "yedek.7z.002", …
    ///   - split: Bölünmüş arşiv mi? Öyleyse hedefteki eski parçalar ("yedek.7z.00N") önce silinir.
    /// - Returns: Hedefte açılabilecek ilk dosya.
    @discardableResult
    public static func installArchive(
        named name: String, from staging: URL, into directory: URL, split: Bool, fileManager: FileManager = .default
    ) throws -> URL {
        let sources = split ? try volumes(of: name, in: staging, fileManager: fileManager) : [staging.appendingPathComponent(name)]
        guard let firstSource = sources.first, itemType(firstSource, fileManager: fileManager) == .typeRegular else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: staging.appendingPathComponent(name).path])
        }
        let stale = split ? try volumes(of: name, in: directory, fileManager: fileManager) : []
        let targets = sources.map { directory.appendingPathComponent($0.lastPathComponent) }
        // Aynı adlı bir klasör arşivle değiştirilmez (kullanıcının klasörü silinmesin).
        if let folder = (stale + targets).first(where: { itemType($0, fileManager: fileManager) == .typeDirectory }) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path])
        }
        for volume in stale { try fileManager.removeItem(at: volume) }
        for (source, target) in zip(sources, targets) {
            switch itemType(target, fileManager: fileManager) {
            case nil:
                try fileManager.moveItem(at: source, to: target)
            case .typeRegular?:
                _ = try OwnerAccess.granting(S_IWUSR, on: target.path, restoring: false) {
                    try fileManager.replaceItemAt(target, withItemAt: source, options: .usingNewMetadataOnly)
                }
            default:
                // Aynı adlı sembolik bağlantı: bağlantının gösterdiği dosyaya değil, bağlantının yerine yazılır.
                try fileManager.removeItem(at: target)
                try fileManager.moveItem(at: source, to: target)
            }
        }
        return targets[0]
    }

    /// Klasördeki "ad.001", "ad.002", … parçaları (sırayla).
    static func volumes(of name: String, in directory: URL, fileManager: FileManager) throws -> [URL] {
        let prefix = name + "."
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { item in
                guard item.hasPrefix(prefix) else { return false }
                let suffix = item.dropFirst(prefix.count)
                return suffix.count >= 3 && suffix.allSatisfy(\.isASCII) && suffix.allSatisfy(\.isNumber)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { directory.appendingPathComponent($0) }
    }

    /// `link` (köke göre göreli bağlantı yolu) konumundan, köke göre `target` bileşenlerine giden göreli yol.
    static func relativePath(from link: String, to target: [String]) -> String {
        let directory = link.split(separator: "/").dropLast().map(String.init)
        var common = 0
        while common < directory.count, common < target.count, directory[common] == target[common] { common += 1 }
        let parts = Array(repeating: "..", count: directory.count - common) + target[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// "." ve ".." bileşenlerini metin üzerinde çözer (`standardizingPath`'in aksine "/private" önekini silmez).
    static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Yolu sembolik bağlantıları izleyerek çözer (realpath). Var olmayan son bileşenler, var olan en yakın
    /// üst klasör çözüldükten sonra sırayla eklenir ("..", bir üst klasöre çıkar).
    static func resolvedPath(_ path: String) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        let base = resolvedPath(parent)
        switch (path as NSString).lastPathComponent {
        case "..": return (base as NSString).deletingLastPathComponent
        case ".", "": return base
        case let name: return (base as NSString).appendingPathComponent(name)
        }
    }

    // MARK: - Yardımcılar

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
    public static func itemType(_ url: URL, fileManager: FileManager = .default) -> FileAttributeType? {
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

/// Sahibin izin bitleri eksik olan öğelerde (0555 klasör, 0444/0111/0000 dosya) geçici izin.
///
/// Arşivden çıkan öğeler salt okunur ya da yalnızca çalıştırılabilir olabilir. macOS bu öğelere karantina
/// işareti yazmayı (setxattr) ve değiştirmeyi reddeder; öğeler sahibine aittir, izin kısa süre açılıp geri alınır.
/// Sembolik bağlantılara dokunulmaz (chmod bağlantının gösterdiğini değiştirirdi).
enum OwnerAccess {
    /// Eksikse `bits` izinlerini ekler. - Returns: Değiştirildiyse eski kip; değişmediyse nil.
    static func add(_ bits: mode_t, on path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK, info.st_mode & bits != bits else { return nil }
        let original = info.st_mode & 0o7777
        return chmod(path, original | bits) == 0 ? original : nil
    }

    /// Ağaçtaki klasörlere (kök dahil) eksikse `bits` izinlerini verir; bir klasör ancak bundan sonra listelenebilir (0000).
    /// - Returns: Değişen klasörler ve eski kipleri; alt klasörler üstlerinden önce gelir (`restore` bu sırayla geri yükler).
    static func addTree(_ bits: mode_t, below path: String, fileManager: FileManager = .default) -> [(path: String, mode: mode_t)] {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
        let own = add(bits, on: path).map { [(path: path, mode: $0)] } ?? []
        var inner: [(path: String, mode: mode_t)] = []
        for child in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] {
            inner += addTree(bits, below: (path as NSString).appendingPathComponent(child), fileManager: fileManager)
        }
        return inner + own
    }

    /// Eski kipleri verilen sırayla geri yükler (alt klasörler önce: üst klasörün geçiş izni o sırada hâlâ açıktır).
    static func restore<S: Sequence>(_ changes: S) where S.Element == (path: String, mode: mode_t) {
        for change in changes { chmod(change.path, change.mode) }
    }

    /// `body` süresince sahibine `bits` izinlerini verir, sonra eski kipi geri yükler.
    /// - Parameter restoring: false ise eski kip yalnızca `body` hata verirse geri yüklenir (öğe değiştiriliyorsa).
    static func granting<T>(_ bits: mode_t, on path: String, restoring: Bool = true, _ body: () throws -> T) rethrows -> T {
        guard let original = add(bits, on: path) else { return try body() }
        do {
            let result = try body()
            if restoring { chmod(path, original) }
            return result
        } catch {
            chmod(path, original)
            throw error
        }
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

    /// Seçili öğelerin (boşsa tüm arşivin) açılmış toplam boyutu. Uydurma boyutlar (zip bombası) taşma yerine Int64.max'ta durur.
    public static func requiredBytes(for items: [String], in entries: [ArchiveEntry]) -> Int64 {
        entries.reduce(0) { total, entry in
            guard !entry.isDirectory else { return total }
            let selected = items.isEmpty || items.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
            // Bozuk ya da uydurma negatif bir boyut gereken alanı azaltmasın.
            return selected ? total.saturatingAdding(max(0, entry.size ?? 0)) : total
        }
    }

    /// Dosya ve klasörlerin (alt öğeleri dahil) diskteki toplam mantıksal boyutu. Sembolik bağlantılar izlenmez.
    public static func totalSize(of urls: [URL], fileManager: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            guard let type = StagedExtraction.itemType(url, fileManager: fileManager) else { continue }
            if type == .typeRegular {
                total = total.saturatingAdding(size(of: url, fileManager: fileManager))
            } else if type == .typeDirectory {
                total = total.saturatingAdding(regularFileBytes(below: url.path))
            }
        }
        return total
    }

    /// Klasör ağacındaki sıradan dosyaların boyutu ("._" ile başlayanlar dahil; bağlantılar izlenmez).
    static func regularFileBytes(below path: String) -> Int64 {
        var total: Int64 = 0
        for name in (try? StagedExtraction.entries(ofDirectory: path)) ?? [] {
            let child = (path as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(child, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG: total = total.saturatingAdding(Int64(info.st_size))
            case S_IFDIR: total = total.saturatingAdding(regularFileBytes(below: child))
            default: break
            }
        }
        return total
    }

    static func size(of url: URL, fileManager: FileManager) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Arşiv oluşturma ya da yerinde düzenleme için gereken en az alan.
    ///
    /// Sıkıştırılan biçimlerde sonuç boyutu önceden bilinemez; yanlışlıkla engellememek için kaynaklar sayılmaz.
    /// Sıkıştırmasız biçimler (tar, wim, "saklama") kaynakların tamamını yazar. Yerinde düzenlemede 7zz
    /// arşivin geçici bir kopyasını yazıp eskisiyle değiştirir; bu yüzden mevcut arşiv boyutu da gerekir.
    public static func requiredForWriting(sourceBytes: Int64, compresses: Bool, existingArchiveBytes: Int64 = 0) -> Int64 {
        existingArchiveBytes.saturatingAdding(compresses ? 0 : sourceBytes)
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
