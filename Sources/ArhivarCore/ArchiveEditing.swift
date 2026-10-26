import Synchronization
import CoreTransferable
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Bir arşivin yerinde düzenlenip düzenlenemeyeceği.
public enum ArchiveCapabilities {
    /// 7zz'nin güncelleyebildiği (a / d / rn) türler.
    static let editableTypes: Set<String> = ["7z", "zip", "tar", "wim"]

    /// Biçim yerinde güncellenebilir ve arşiv yazılabilir bir yerde mi?
    public static func isEditable(type: String?, url: URL, volumes: Int? = nil, fileManager: FileManager = .default) -> Bool {
        supportsEditing(type: type, url: url, volumes: volumes) && isWritable(url, fileManager: fileManager)
    }

    /// Biçim 7zz ile yerinde güncellenebilir mi? Bölünmüş ve çok parçalı arşivler güncellenemez.
    public static func supportsEditing(type: String?, url: URL, volumes: Int? = nil) -> Bool {
        guard let type, editableTypes.contains(type.lowercased()) else { return false }
        if let volumes, volumes > 1 { return false }
        let ext = url.pathExtension
        if ext.count == 3 && ext.allSatisfy(\.isNumber) { return false }
        if ArchiveNaming.isSplitZipVolume(ext) || ArchiveNaming.isOldRarVolume(ext) { return false }
        return true
    }

    /// 7zz güncellenmiş kopyayı arşivin yanına yazıp eskisinin yerine koyar: arşiv ve klasörü yazılabilir olmalı.
    /// Salt okunur (0444) ya da kilitli arşiv, salt okunur disk görüntüsü veya paylaşım "errno=13 : Permission denied"
    /// verirdi. Diskte olmayan yol engellenmez.
    public static func isWritable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        return fileManager.isWritableFile(atPath: url.path) && fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
}

extension SevenZipCommand {
    /// Var olan arşive dosya ekler. `names`, `workingDirectory`'ye göre göreli yollardır.
    /// - Parameters:
    ///   - archiveType: 7zz'nin bildirdiği tür ("zip", "7z", …); yoksa uzantıdan anlaşılır.
    ///   - excluding: Eklenmeyecek özel dosyaların arşivdeki yolları (bkz. `SpecialFiles`).
    /// `workDirectory`: 7zz'nin güncellenmiş arşivin geçici kopyasını yazdığı klasör (`-w`). Verilmezse arşivin yanına
    /// yazar; o zaman kum havuzunda arşivin klasörünün tamamı yazılabilir olmak zorunda kalırdı ve zorla kapanışta
    /// "arşiv.tmp" dosyası orada kalırdı.
    public static func add(
        archive: URL, names: [String], password: String? = nil, encryptHeaders: Bool = false,
        archiveType: String? = nil, storeSymlinks: Bool = true, excludeMacMetadata: Bool = false, excluding: [String] = [],
        workDirectory: URL? = nil
    ) -> [String] {
        // Parola stdin'den verilir (bkz. passwordInput); burada yalnızca sorulması istenir.
        let hasPassword = password?.isEmpty == false
        var args = ["a", "-bsp1", "-bb0", "-y"] + common + (hasPassword ? ["-p"] : [])
        if encryptHeaders, hasPassword { args.append("-mhe=on") }
        // -mem verilmezse 7zz şifreli zip'e eklenen dosyaları zayıf ZipCrypto ile şifreler; oluşturmadaki gibi AES-256 kalsın.
        if hasPassword, (archiveType ?? archive.pathExtension).lowercased() == "zip" { args.append("-mem=AES256") }
        args += sourceSwitches(
            names: names + [archive.path], storeSymlinks: storeSymlinks, excludeMacMetadata: excludeMacMetadata, excluding: excluding
        )
        return args + workSwitch(workDirectory) + ["--", archive.path] + names
    }

    public static func delete(archive: URL, items: [String], workDirectory: URL? = nil) -> [String] {
        ["d", "-bsp1", "-bb0", "-y", "-spd"] + common + workSwitch(workDirectory) + ["--", archive.path] + items
    }

    public static func rename(archive: URL, from oldPath: String, to newPath: String, workDirectory: URL? = nil) -> [String] {
        ["rn", "-bb0", "-y", "-spd"] + common + workSwitch(workDirectory) + ["--", archive.path, oldPath, newPath]
    }

    static func workSwitch(_ workDirectory: URL?) -> [String] {
        workDirectory.map { ["-w" + $0.path] } ?? []
    }
}

/// Dosyaların arşiv içindeki belirli bir klasöre eklenmesi için hazırlık.
///
/// 7zz eklenen dosyaları çalışma klasörüne göre göreli yoluyla saklar. Hedef bir alt klasörse
/// dosyalar geçici bir klasörde aynı yol yapısına kopyalanır (APFS'de kopya anlıktır).
public struct AddPlan: Sendable, Equatable {
    public let workingDirectory: URL
    public let names: [String]
    /// İşlemden sonra silinmesi gereken geçici klasör.
    public let stagingDirectory: URL?
    /// Kopyalanırken atlanan, gizli bir dosyanın ikinci adı olan dosyalar (kaynaktaki yolları; bkz. `SecretLinks`).
    public var skippedSecretLinks: [String] = []

    public init(workingDirectory: URL, names: [String], stagingDirectory: URL?, skippedSecretLinks: [String] = []) {
        self.workingDirectory = workingDirectory
        self.names = names
        self.stagingDirectory = stagingDirectory
        self.skippedSecretLinks = skippedSecretLinks
    }

    /// Farklı klasörlerden aynı adlı öğeler aynı arşiv yoluna düşerdi.
    public struct DuplicateNameError: Error, Equatable, Sendable {
        public let names: [String]

        public init(names: [String]) {
            self.names = names
        }
    }

    /// Kaynakların hepsi atlanan özel dosyalarsa (FIFO, soket, aygıt) arşive eklenecek bir şey kalmaz. 7zz'ye boş
    /// ad listesi verilirse çalışma klasörünün tamamını ("*") eklerdi.
    public struct NothingToArchiveError: Error, Equatable, Sendable {
        public init() {}
    }

    /// Aynı son yol bileşenini (adı) paylaşan kaynakların adları (büyük/küçük harf duyarsız, APFS gibi).
    public static func duplicateNames(in sources: [URL]) -> [String] {
        var seen: [String: String] = [:]
        var duplicates: [String] = []
        for source in sources {
            let name = source.lastPathComponent
            let key = name.lowercased()
            if seen[key] != nil, !duplicates.contains(where: { $0.lowercased() == key }) {
                duplicates.append(name)
            }
            seen[key] = name
        }
        return duplicates
    }

    /// - Parameter followingSymlinks: Bağlantılar bağlantı olarak saklanmayacaksa true; 7zz o zaman bağlantının
    ///   gösterdiğini okur, FIFO'yu gösteren bağlantı da FIFO gibi atlanır.
    /// - Parameter secretLinks: Verilirse kişisel gizli klasördeki bir dosyanın ikinci adı olan dosyalar kopyalanmaz.
    public static func make(
        sources: [URL], into folder: String, stagingRoot: URL, followingSymlinks: Bool = false,
        secretLinks: SecretLinks? = nil, fileManager: FileManager = .default
    ) throws -> AddPlan {
        // FIFO ve soketler kopyalanamaz (ENOTSUP) ve 7zz'yi kilitler; kopyalanmadan atlanır.
        var skippedTopLevel: [String] = []
        let sources = sources.filter { source in
            if SpecialFiles.isSpecial(atPath: source.path, followingSymlinks: followingSymlinks) { return false }
            if let secretLinks, secretLinks.isSecretLink(atPath: source.path, followingSymlinks: followingSymlinks) {
                skippedTopLevel.append(source.path)
                return false
            }
            return true
        }
        guard !sources.isEmpty else { throw NothingToArchiveError() }
        let duplicates = duplicateNames(in: sources)
        guard duplicates.isEmpty else { throw DuplicateNameError(names: duplicates) }
        // "./belgeler" gibi ham yazımlar: ilk bileşen "." olursa 7zz'ye ad olarak "." verilirdi.
        let folder = ListingParser.normalizedPath(folder)
        if let parent = sources.first?.deletingLastPathComponent(), folder.isEmpty,
           sources.allSatisfy({ $0.deletingLastPathComponent() == parent }) {
            return AddPlan(
                workingDirectory: parent, names: sources.map(\.lastPathComponent), stagingDirectory: nil, skippedSecretLinks: skippedTopLevel
            )
        }
        // Kopyalar kullanıcının (belki gizli) dosyalarıdır: geçici klasör yalnızca kullanıcıya açık olsun.
        // Alt klasörler varsayılan izinlerle oluşturulur; arşive 0700 olarak girmesinler.
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = folder.isEmpty ? staging : staging.appendingPathComponent(folder, isDirectory: true)
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            // Klasörlerin içindeki özel dosyalar da kopyalanmaz.
            let skipping = SpecialFiles.SkippingCopier(followingSymlinks: followingSymlinks, secretLinks: secretLinks)
            let copier = FileManager()
            copier.delegate = skipping
            var names: [String] = []
            for source in sources {
                try copier.copyItem(at: source, to: target.appendingPathComponent(source.lastPathComponent))
                names.append(source.lastPathComponent)
            }
            withExtendedLifetime(skipping) {}
            let topLevel = folder.split(separator: "/").first.map(String.init)
            return AddPlan(
                workingDirectory: staging, names: topLevel.map { [$0] } ?? names, stagingDirectory: staging,
                skippedSecretLinks: skippedTopLevel + skipping.skippedSecretLinks
            )
        } catch {
            // Önce kopyalanan salt okunur (0555) bir klasör `removeItem` ile silinemezdi.
            StagedExtraction.removeTree(at: staging, fileManager: fileManager)
            throw error
        }
    }
}

/// FIFO (adlandırılmış boru), soket ve aygıt dosyaları: arşivlenecek veri değildir.
///
/// 7zz bir FIFO'yu O_NONBLOCK olmadan açar ve yazan biri gelene kadar çekirdekte sonsuza dek bekler (zip, tar, wim,
/// gz, …). `FileManager.copyItem` ise FIFO ve soketlerde ENOTSUP verip tüm kopyalamayı durdurur.
public enum SpecialFiles {
    /// Sıradan dosya, klasör ya da sembolik bağlantı değil mi? (lstat; bağlantı izlenmez)
    public static func isSpecial(atPath path: String, followingSymlinks: Bool = false) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        if info.st_mode & S_IFMT == S_IFLNK {
            // Bağlantılar izlenecekse (bağlantı olarak saklanmıyorsa) 7zz gösterdiği FIFO'yu açardı.
            guard followingSymlinks, stat(path, &info) == 0 else { return false }
        }
        let type = info.st_mode & S_IFMT
        return type != S_IFREG && type != S_IFDIR && type != S_IFLNK
    }

    /// Kaynakların hepsi atlanacak özel dosyalar mı? O zaman arşivlenecek bir şey kalmaz (bkz. `AddPlan.NothingToArchiveError`).
    public static func containsOnlySpecialFiles(_ sources: [URL], followingSymlinks: Bool = false) -> Bool {
        !sources.isEmpty && sources.allSatisfy { isSpecial(atPath: $0.path, followingSymlinks: followingSymlinks) }
    }

    /// Kaynakların içindeki özel dosyalar, arşivde alacakları yollarla ("klasör/alt/pipe").
    /// 7zz bir kaynağı son yol bileşeniyle saklar; `-x!` ile verilen bu yollar yalnızca o öğeyi dışlar.
    /// - Parameter followingSymlinks: Bağlantılar bağlantı olarak saklanmayacaksa true. 7zz o zaman klasörü gösteren
    ///   bağlantıların içine de iner; içlerindeki FIFO'lar da bağlantının yoluyla ("klasör/bag/pipe") bulunur.
    /// - Parameters:
    ///   - specials: Özel dosyalar (FIFO, soket, aygıt) listelensin mi?
    ///   - matchingRegularFile: Verilirse bu koşulu sağlayan sıradan dosyalar da listelenir (ör. `SecretLinks`).
    public static func archivePaths(
        in sources: [URL], followingSymlinks: Bool = false, specials: Bool = true,
        matchingRegularFile: ((String, stat) -> Bool)? = nil, fileManager: FileManager = .default
    ) -> [String] {
        var result: [String] = []
        // Döngüye giren bağlantılar ("a/geri → ..") için yalnızca o yoldaki üst klasörler tutulur: aynı klasöre iki
        // ayrı bağlantıdan inilirse 7zz ikisini de okur, ikisinin özel dosyaları da dışlanmalı.
        func visit(_ path: String, as archivePath: String, ancestors: Set<FileIdentity>) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard followingSymlinks, stat(path, &info) == 0 else { return }
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                if let matchingRegularFile, matchingRegularFile(path, info) { result.append(archivePath) }
                return
            case S_IFDIR:
                let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
                guard !ancestors.contains(identity) else { return }
                for child in (try? StagedExtraction.entries(ofDirectory: path)) ?? [] {
                    visit((path as NSString).appendingPathComponent(child), as: archivePath + "/" + child, ancestors: ancestors.union([identity]))
                }
            default:
                if specials { result.append(archivePath) }
            }
        }
        for source in sources { visit(source.path, as: source.lastPathComponent, ancestors: []) }
        return result
    }

    /// Kopyalarken özel dosyaları (bağlantılar izlenecekse FIFO'yu gösteren bağlantıları da) atlayan `FileManager` temsilcisi.
    final class SkippingCopier: NSObject, FileManagerDelegate {
        let followingSymlinks: Bool
        let secretLinks: SecretLinks?
        /// Gizli bir dosyanın ikinci adı olduğu için kopyalanmayan dosyalar (kaynaktaki yolları).
        private(set) var skippedSecretLinks: [String] = []

        init(followingSymlinks: Bool = false, secretLinks: SecretLinks? = nil) {
            self.followingSymlinks = followingSymlinks
            self.secretLinks = secretLinks
        }

        func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
            if SpecialFiles.isSpecial(atPath: srcURL.path, followingSymlinks: followingSymlinks) { return false }
            // Kopya yeni bir inode olur; gizli dosyanın içeriği o zaman ayırt edilemeden arşive girerdi.
            if let secretLinks, secretLinks.isSecretLink(atPath: srcURL.path, followingSymlinks: followingSymlinks) {
                skippedSecretLinks.append(srcURL.path)
                return false
            }
            return true
        }
    }
}

/// Arşivden tek bir öğeyi (dosya ya da klasör) geçici bir klasöre çıkarır.
public struct ItemExtractor: Sendable {
    public let runner: CommandRunner
    public let archive: URL
    public let password: String?
    /// Çıkarılan öğelerin konacağı klasör (arşiv oturumunun geçici klasörü).
    public let root: URL
    /// Arşivdeki sembolik bağlantı girdilerinin normalleştirilmiş yolları (bkz. `ArchiveEntry.isSymbolicLink`).
    public let symbolicLinks: Set<String>
    /// Sabit bağlantı girdileri: 7zz dışarıyı göstereni reddedip 0 baytlık yer tutucu bırakır; kabul edileni sıradan
    /// dosya olarak yazar (tek başına verilebilir).
    public let hardLinks: Set<String>

    /// Tek başına istenen sembolik bağlantı verilmez: taşındığı yerde (Finder, pano) hedef ağacın dışını gösterir ya da
    /// boşa düşer; 7zz reddettiyse yerinde 0 baytlık sahte bir dosya vardır.
    public struct SymbolicLinkError: Error, Equatable, Sendable {
        /// İstenen bağlantıların 7zz'nin tanıdığı (ham) yolları.
        public let paths: [String]

        public init(paths: [String]) {
            self.paths = paths
        }
    }

    public init(
        runner: CommandRunner, archive: URL, password: String?, root: URL = ItemExtractor.temporaryRoot,
        symbolicLinks: Set<String> = [], hardLinks: Set<String> = []
    ) {
        self.runner = runner
        self.archive = archive
        self.password = password
        self.root = root
        self.symbolicLinks = symbolicLinks
        self.hardLinks = hardLinks
    }

    public static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Arhivar", isDirectory: true)
    }

    /// Dosya uygulamanın geçici klasöründe mi (ör. listeden sürüklenip çıkarılmış bir öğe)? `/var` ile `/private/var`
    /// aynı yer sayılsın diye iki yol da gerçek yoluna çözülür.
    public static func isTemporaryItem(_ url: URL, root: URL = temporaryRoot) -> Bool {
        guard url.isFileURL else { return false }
        let base = StagedExtraction.resolvedPath(root.path)
        let path = StagedExtraction.resolvedPath(url.path)
        return path == base || path.hasPrefix(base + "/")
    }

    /// Önceki çalıştırmalardan kalan, `age` saniyeden eski geçici klasörleri siler.
    @discardableResult
    public static func sweepStale(olderThan age: TimeInterval, root: URL = temporaryRoot, now: Date = Date()) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return 0
        }
        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) > age else { continue }
            StagedExtraction.removeTree(at: entry, fileManager: fileManager)
            if StagedExtraction.itemType(entry, fileManager: fileManager) == nil { removed += 1 }
        }
        return removed
    }

    public func extract(
        _ path: String, into root: URL? = nil, expectedSize: Int64? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try await extract([path], into: root, expectedSize: expectedSize, onProgress: onProgress)[0]
    }

    /// Birden fazla öğeyi tek 7zz çalıştırmasıyla aynı geçici klasöre çıkarır (katı arşivler bir kez açılır).
    /// - Parameter paths: 7zz'nin tanıdığı (ham) iç yollar.
    /// - Returns: Her öğenin çıkarıldığı yer, `paths` sırasıyla.
    public func extract(
        _ paths: [String], into root: URL? = nil, expectedSize: Int64? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [URL] {
        let fileManager = FileManager.default
        let directory = (root ?? self.root).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = directory.standardizedFileURL.path + "/"
        // 7zz ".." bileşenlerini birleştirmeden atar ("a/../x.txt" → "a/x.txt"); hedef yollar da aynı kuralla bulunur.
        let normalized = paths.map(ListingParser.normalizedPath)
        let targets = normalized.map { directory.appendingPathComponent($0).standardizedFileURL }
        // Arşivdeki "../" gibi yollar geçici klasörün dışına çıkamasın.
        guard !paths.isEmpty else { throw SevenZipError.failed(code: 0, message: "") }
        // Listede bağlantı olduğu bilinen öğe için 7zz hiç çalıştırılmaz.
        let requestedLinks = zip(paths, normalized).filter { symbolicLinks.contains($0.1) }.map(\.0)
        guard requestedLinks.isEmpty else { throw SymbolicLinkError(paths: requestedLinks) }
        if let escaping = zip(paths, targets).first(where: { $0.1.path == directory.standardizedFileURL.path || !$0.1.path.hasPrefix(base) }) {
            throw SevenZipError.failed(code: 0, message: escaping.0)
        }
        // Geçici klasör sistem diskindedir; büyük bir öğe diski doldurmasın.
        if let expectedSize { try InsufficientSpaceError.check(required: expectedSize, at: root ?? self.root) }
        // Çözülmüş (belki şifreli arşivden gelen) içerik yalnızca kullanıcıya açık olsun.
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let options = ExtractOptions(archive: archive, destination: directory, items: paths, password: password, overwrite: .replace)
            let result = try await runner.run(SevenZipCommand.extract(options), workingDirectory: options.workingDirectory, input: options.input, onProgress: onProgress)
            try SevenZipError.check(result)
            // İptal 7zz bittikten sonra geldiyse bağlantı ayıklaması ve karantina atlanır; klasör aşağıda silinir.
            if Task.isCancelled { throw SevenZipError.cancelled }
            var links: [String] = []
            for (raw, (path, target)) in zip(paths, zip(normalized, targets)) {
                let type = StagedExtraction.itemType(target, fileManager: fileManager)
                if type == .typeSymbolicLink {
                    // Bağlantı listesi verilmemişse çıkarılan öğenin kendisine bakılır.
                    links.append(raw)
                    continue
                }
                guard type == .typeDirectory else { continue }
                // 7zz'nin reddettiği bağlantıların yer tutucuları önizlemede ya da sağlama değerinde içerik sanılmasın.
                let links = symbolicLinks.union(hardLinks).filter { $0.hasPrefix(path + "/") }.map { String($0.dropFirst(path.count + 1)) }
                StagedExtraction.removeLinkPlaceholders(in: target, links: links, fileManager: fileManager)
                // Bağlantılar yalnızca öğenin kendi içini gösterebilir: sürüklenen ya da kopyalanan öğe tek başına
                // taşınır, kardeş klasörleri ("../dış") ve mutlak hedefler yanında gitmez.
                StagedExtraction.secureSymlinks(in: target, extractionRoot: directory, fileManager: fileManager)
            }
            guard links.isEmpty else { throw SymbolicLinkError(paths: links) }
            if let missing = zip(paths, targets).first(where: { StagedExtraction.itemType($0.1, fileManager: fileManager) == nil }) {
                throw SevenZipError.failed(code: result.exitCode, message: missing.0)
            }
            // Klasör bu çıkarma için yeni oluşturuldu; içindeki her şey 7zz'nin yazdığıdır.
            Quarantine.propagate(from: archive, to: directory, since: .distantPast)
            return targets
        } catch {
            StagedExtraction.removeTree(at: directory, fileManager: fileManager)
            throw error
        }
    }
}

/// Birlikte sürüklenen öğeler (ör. ⌘A ile seçilip Finder'a bırakılanlar). Hepsi tek 7zz çalıştırmasıyla çıkarılır,
/// her istek aynı sonucu bekler. Katı bir arşiv öğe başına yeniden açılmaz, seçim büyüdükçe aynı anda onlarca 7zz
/// süreci de başlamaz.
///
/// Çıkarma sürükleme başlarken başlar (`prefetch()`). Bırakılan uygulama (Finder, Word…) dosyayı ister; SwiftUI bu
/// isteği uygulamanın ana iş parçacığını durdurarak yanıtlar. 7zz ancak o anda çalışsaydı uygulama sürükle-bırak
/// görüşmesinin ortasında yüzlerce milisaniye (büyük öğelerde saniyelerce) donardı; Word'e art arda birkaç bırakmadan
/// sonra sürükleme yeniden açılana kadar hiç başlamaz olabiliyordu. Dosyalar çoğunlukla bırakmadan önce hazırdır.
public final class DragBatch: Sendable {
    private struct State {
        var paths: [String] = []
        /// Yolun `paths` içindeki sırası: binlerce öğeli bir sürüklemede her istek sabit sürede yanıtlanır.
        var index: [String: Int] = [:]
        var task: Task<[URL], any Error>?
        /// İlk bırakma isteği günlüğe yazıldı mı?
        var requested = false
        /// Başarısızlık kullanıcıya bildirildi mi? (Bir kez.)
        var reported = false

        mutating func insert(_ path: String) {
            guard index[path] == nil else { return }
            index[path] = paths.count
            paths.append(path)
        }
    }

    /// Sürükleme başlarken çıkarılacak en büyük toplam boyut. Daha büyük seçimler ilk bırakma isteğinde çıkarılır:
    /// vazgeçilen bir sürükleme diski gigabaytlarca boşuna doldurmasın.
    public static let prefetchLimit: Int64 = 512 << 20
    /// Bırakma isteği bundan uzun beklerse (uygulama o sırada yanıt vermez) günlüğe uyarı yazılır.
    static let slowRequest: Duration = .milliseconds(500)
    /// Çıkarma sürdükçe bu aralıklarla günlüğe yazılır: takılan bir çıkarma Günlük penceresinde görünür.
    static let watchdogInterval: Duration = .seconds(10)
    private static let counter = Atomic<Int>(0)

    public let extractor: ItemExtractor
    /// Günlükte sürüklemeleri birbirinden ayıran sıra numarası.
    public let number: Int
    /// Çıkarılacak öğelerin (ham yollar) gerektirdiği alan; nil ise denetlenmez.
    private let requiredBytes: @Sendable ([String]) -> Int64?
    /// Bırakılan öğeler iptal dışında bir nedenle çıkarılamayınca bir kez çağrılır: bırakma sessizce boşa gitmesin.
    /// Önceden başlayan çıkarmanın hatası ancak bir bırakma isteği gelince bildirilir; vazgeçilen sürükleme uyarı göstermez.
    private let onFailure: @Sendable (any Error) -> Void
    private let log: AppLog
    private let state = Mutex(State())

    public init(
        extractor: ItemExtractor, requiredBytes: @escaping @Sendable ([String]) -> Int64? = { _ in nil },
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in }, log: AppLog = .shared
    ) {
        self.extractor = extractor
        self.requiredBytes = requiredBytes
        self.onFailure = onFailure
        self.log = log
        number = Self.counter.add(1, ordering: .relaxed).newValue
    }

    /// Öğeyi topluluğa ekler. Çıkarma başladıysa eklenmez (`false`): sonraki sürükleme yeni bir topluluk kurar.
    @discardableResult
    public func add(_ path: String) -> Bool {
        state.withLock { state in
            guard state.task == nil else { return false }
            state.insert(path)
            return true
        }
    }

    /// 7zz'nin tanıdığı (ham) yollar, eklenme sırasıyla.
    public var paths: [String] { state.withLock { $0.paths } }

    public var hasStarted: Bool { state.withLock { $0.task != nil } }

    /// Çıkarmayı hemen başlatır: sürükleme başlarken, sürüklenen satırların hepsi eklenince çağrılır. Seçim
    /// `prefetchLimit`'ten büyükse ya da çıkarma zaten başladıysa başlatmaz (`false`).
    @discardableResult
    public func prefetch() -> Bool {
        let paths = self.paths
        guard !paths.isEmpty, !hasStarted else { return false }
        if let size = requiredBytes(paths), size > Self.prefetchLimit {
            log.info(.drag, "Drag #\(number) started with \(paths.count) item(s) (\(size) bytes): extraction waits for the drop")
            return false
        }
        let started = state.withLock { state in
            guard state.task == nil else { return false }
            start(&state)
            return true
        }
        if started { log.info(.drag, "Drag #\(number) started with \(paths.count) item(s): extracting before the drop") }
        return started
    }

    /// Öğenin çıkarıldığı yer. Çıkarma başlamadıysa topluluğun tamamı şimdi çıkarılır; her istek aynı çıkarmayı bekler.
    public func url(for path: String) async throws -> URL {
        let clock = ContinuousClock.now
        let (task, index, first, count) = state.withLock { state in
            if state.task == nil {
                state.insert(path)
                start(&state)
            }
            defer { state.requested = true }
            return (state.task!, state.index[path], !state.requested, state.paths.count)
        }
        if first { log.info(.drag, "Drag #\(number): drop target requested the files (\(count) item(s))") }
        do {
            let urls = try await task.value
            let url: URL
            if let index {
                url = urls[index]
            } else {
                // Çıkarma başladıktan sonra eklenmek istenen yol topluluğa girmez; kendi başına çıkarılır.
                url = try await extract([path])[0]
            }
            if ContinuousClock.now - clock > Self.slowRequest {
                log.warning(.drag, "Drag #\(number): drop request waited \(AppLog.milliseconds(since: clock)) ms for the extraction")
            }
            return url
        } catch {
            report(error)
            throw error
        }
    }

    /// Topluluğun çıkarmasını başlatır (kilit altında çağrılır). Süre, sonuç ve uzun süren çıkarma günlüğe yazılır.
    private func start(_ state: inout State) {
        let paths = state.paths
        let number = number
        let log = log
        state.task = Task {
            let clock = ContinuousClock.now
            let watchdog = Task {
                var waited = Duration.zero
                while true {
                    try await Task.sleep(for: Self.watchdogInterval)
                    waited += Self.watchdogInterval
                    log.warning(.drag, "Drag #\(number): extraction of \(paths.count) item(s) still running after \(waited.components.seconds) s")
                }
            }
            defer { watchdog.cancel() }
            do {
                let urls = try await self.extract(paths)
                log.info(.drag, "Drag #\(number): extracted \(paths.count) item(s) in \(AppLog.milliseconds(since: clock)) ms")
                return urls
            } catch {
                let (kind, detail) = AppLog.describe(error)
                log.log(AppLog.isCancellation(error) ? .info : .error, .drag, "Drag #\(number): extraction \(kind)", detail: detail)
                throw error
            }
        }
    }

    /// Başarısızlığı bir kez bildirir; iptal bildirilmez.
    private func report(_ error: any Error) {
        guard !AppLog.isCancellation(error) else { return }
        let first = state.withLock { state in
            defer { state.reported = true }
            return !state.reported
        }
        if first { onFailure(error) }
    }

    private func extract(_ paths: [String]) async throws -> [URL] {
        // Arşiv bırakmadan önce kapandıysa oturum klasörü silinmiştir: yeniden oluşturulup sahipsiz kalmasın.
        guard FileManager.default.fileExists(atPath: extractor.root.path) else { throw SevenZipError.cancelled }
        return try await extractor.extract(paths, expectedSize: requiredBytes(paths))
    }
}

/// Listeden Finder'a sürüklenen öğe; dosya ancak bırakıldığında çıkarılır.
public struct ArchiveItemTransfer: Transferable, Sendable {
    /// nil: öğe çıkarılamaz (bkz. `unavailable(name:)`).
    public let batch: DragBatch?
    public let path: String
    public let name: String

    public init(batch: DragBatch, path: String, name: String) {
        batch.add(path)
        self.batch = batch
        self.path = path
        self.name = name
    }

    private init(unavailableNamed name: String) {
        batch = nil
        path = ""
        self.name = name
    }

    /// Satır sürüklenebilir görünürken arşiv kapanmış ya da motor kaybolmuşsa: bırakılınca hiçbir şey yazılmaz.
    public static func unavailable(name: String) -> ArchiveItemTransfer {
        ArchiveItemTransfer(unavailableNamed: name)
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { item in
            guard let batch = item.batch else { throw SevenZipError.cancelled }
            return SentTransferredFile(try await batch.url(for: item.path))
        }
        .suggestedFileName { $0.name }
    }
}

extension ArchiveTree {
    /// Klasör görünümü için bir klasörün doğrudan içeriği (alt düzeyler gizli).
    public static func contents(of folder: String, roots: [ArchiveNode], index: [String: ArchiveNode]) -> [ArchiveNode] {
        let nodes = folder.isEmpty ? roots : (index[folder]?.children ?? [])
        return nodes.map { node in
            var shallow = node
            shallow.children = nil
            return shallow
        }
    }

    /// "a/b/c" → [("a", "a"), ("b", "a/b"), ("c", "a/b/c")]
    public static func breadcrumbs(for folder: String) -> [(name: String, path: String)] {
        var result: [(String, String)] = []
        var current = ""
        for component in folder.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            result.append((String(component), current))
        }
        return result
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Bir öğenin yeniden adlandırıldıktan sonraki tam yolu. Ham yol sonda "/" taşıyabilir ("klasor/");
    /// üst klasör o "/" atılarak bulunur, yeni yol da aynı yazımı korur ("yeni/").
    public static func renamedPath(_ path: String, to newName: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let parent = parent(of: String(trimmed))
        let renamed = parent.isEmpty ? newName : parent + "/" + newName
        return trimmed.count < path.count ? renamed + "/" : renamed
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Denetim karakterleri (NUL, CR, LF…): NUL içeren bir ad süreç argümanı olarak verilemez ve uygulamayı çökertirdi.
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }
}

struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }
}

/// Kişisel gizli klasörlerdeki (ör. `~/.ssh`) dosyaların başka bir yerdeki ikinci adları (sabit bağlantı, hard link).
///
/// Kum havuzu bu klasörleri YOLLA yasaklar (bkz. `SandboxProfile`); aynı inode'a klasörün dışındaki bir sabit
/// bağlantıdan erişilirse içerik okunur ve arşive girer. Arşivlenecek bir klasöre böyle bir bağlantı bırakan yerel bir
/// süreç, gizli anahtarı kullanıcının arşivine taşıyabilirdi. Kaynaklardaki çok adlı (`st_nlink > 1`) sıradan dosyalar
/// korunan klasörlerdeki dosyalarla karşılaştırılır; eşleşenler arşive alınmaz. Korunan klasörün içindeki bir dosya
/// (kullanıcı `~/.ssh` klasörünü bilerek yedekliyorsa) etkilenmez.
public final class SecretLinks: Sendable {
    public let protectedRoots: [URL]
    /// Korunan klasörlerde taranacak en çok öğe (çok büyük bir klasör arşivlemeyi yavaşlatmasın).
    static let scanLimit = 20_000
    private let identities = Mutex<Set<FileIdentity>?>(nil)

    public init(protectedRoots: [URL] = SandboxProfile.secretDirectories(home: FileManager.default.homeDirectoryForCurrentUser)) {
        self.protectedRoots = protectedRoots.map { $0.resolvingSymlinksInPath() }
    }

    /// Dosya, korunan klasörlerin dışında duran ve korunan bir dosyanın ikinci adı olan sıradan bir dosya mı?
    public func isSecretLink(atPath path: String, followingSymlinks: Bool = false) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        if info.st_mode & S_IFMT == S_IFLNK {
            guard followingSymlinks, stat(path, &info) == 0 else { return false }
        }
        return isSecretLink(atPath: path, info: info)
    }

    func isSecretLink(atPath path: String, info: stat) -> Bool {
        // Tek adlı dosyalar (neredeyse tümü) taramaya hiç yol açmaz.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if protectedRoots.contains(where: { resolved == $0.path || resolved.hasPrefix($0.path + "/") }) { return false }
        return protectedIdentities().contains(FileIdentity(info))
    }

    /// Kaynaklardaki böyle dosyaların arşivdeki yolları (`-x!` ile dışlanmak üzere).
    public func archivePaths(in sources: [URL], followingSymlinks: Bool = false) -> [String] {
        SpecialFiles.archivePaths(in: sources, followingSymlinks: followingSymlinks, specials: false) { path, info in
            self.isSecretLink(atPath: path, info: info)
        }
    }

    /// Korunan klasörlerdeki çok adlı dosyaların kimlikleri; ilk gerektiğinde bir kez taranır.
    private func protectedIdentities() -> Set<FileIdentity> {
        identities.withLock { cached in
            if let cached { return cached }
            var found = Set<FileIdentity>()
            var visited = 0
            func visit(_ path: String, depth: Int) {
                guard visited < Self.scanLimit, depth < 12 else { return }
                visited += 1
                var info = stat()
                guard lstat(path, &info) == 0 else { return }
                switch info.st_mode & S_IFMT {
                case S_IFREG where info.st_nlink > 1: found.insert(FileIdentity(info))
                case S_IFDIR:
                    for child in (try? StagedExtraction.entries(ofDirectory: path)) ?? [] {
                        visit((path as NSString).appendingPathComponent(child), depth: depth + 1)
                    }
                default: break
                }
            }
            for root in protectedRoots { visit(root.path, depth: 0) }
            cached = found
            return found
        }
    }
}
