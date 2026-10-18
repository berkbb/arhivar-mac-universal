import CoreTransferable
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Bir arşivin yerinde düzenlenip düzenlenemeyeceği.
public enum ArchiveCapabilities {
    /// 7zz'nin güncelleyebildiği (a / d / rn) türler.
    static let editableTypes: Set<String> = ["7z", "zip", "tar", "wim"]

    public static func isEditable(type: String?, url: URL) -> Bool {
        guard let type, editableTypes.contains(type.lowercased()) else { return false }
        // Bölünmüş arşivler (.001, .002, …) güncellenemez.
        let ext = url.pathExtension
        return !(ext.count == 3 && ext.allSatisfy(\.isNumber))
    }
}

extension SevenZipCommand {
    /// Var olan arşive dosya ekler. `names`, `workingDirectory`'ye göre göreli yollardır.
    /// - Parameters:
    ///   - archiveType: 7zz'nin bildirdiği tür ("zip", "7z", …); yoksa uzantıdan anlaşılır.
    ///   - excluding: Eklenmeyecek özel dosyaların arşivdeki yolları (bkz. `SpecialFiles`).
    public static func add(
        archive: URL, names: [String], password: String? = nil, encryptHeaders: Bool = false,
        archiveType: String? = nil, storeSymlinks: Bool = true, excludeMacMetadata: Bool = false, excluding: [String] = []
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
        return args + ["--", archive.path] + names
    }

    public static func delete(archive: URL, items: [String]) -> [String] {
        ["d", "-bsp1", "-bb0", "-y", "-spd"] + common + ["--", archive.path] + items
    }

    public static func rename(archive: URL, from oldPath: String, to newPath: String) -> [String] {
        ["rn", "-bb0", "-y", "-spd"] + common + ["--", archive.path, oldPath, newPath]
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
    public static func make(
        sources: [URL], into folder: String, stagingRoot: URL, followingSymlinks: Bool = false, fileManager: FileManager = .default
    ) throws -> AddPlan {
        // FIFO ve soketler kopyalanamaz (ENOTSUP) ve 7zz'yi kilitler; kopyalanmadan atlanır.
        let sources = sources.filter { !SpecialFiles.isSpecial(atPath: $0.path, followingSymlinks: followingSymlinks) }
        guard !sources.isEmpty else { throw NothingToArchiveError() }
        let duplicates = duplicateNames(in: sources)
        guard duplicates.isEmpty else { throw DuplicateNameError(names: duplicates) }
        // "./belgeler" gibi ham yazımlar: ilk bileşen "." olursa 7zz'ye ad olarak "." verilirdi.
        let folder = ListingParser.normalizedPath(folder)
        if let parent = sources.first?.deletingLastPathComponent(), folder.isEmpty,
           sources.allSatisfy({ $0.deletingLastPathComponent() == parent }) {
            return AddPlan(workingDirectory: parent, names: sources.map(\.lastPathComponent), stagingDirectory: nil)
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
            let skipping = SpecialFiles.SkippingCopier(followingSymlinks: followingSymlinks)
            let copier = FileManager()
            copier.delegate = skipping
            var names: [String] = []
            for source in sources {
                try copier.copyItem(at: source, to: target.appendingPathComponent(source.lastPathComponent))
                names.append(source.lastPathComponent)
            }
            withExtendedLifetime(skipping) {}
            let topLevel = folder.split(separator: "/").first.map(String.init)
            return AddPlan(workingDirectory: staging, names: topLevel.map { [$0] } ?? names, stagingDirectory: staging)
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

    /// Kaynakların içindeki özel dosyalar, arşivde alacakları yollarla ("klasör/alt/pipe").
    /// 7zz bir kaynağı son yol bileşeniyle saklar; `-x!` ile verilen bu yollar yalnızca o öğeyi dışlar.
    /// - Parameter followingSymlinks: Bağlantılar bağlantı olarak saklanmayacaksa true. 7zz o zaman klasörü gösteren
    ///   bağlantıların içine de iner; içlerindeki FIFO'lar da bağlantının yoluyla ("klasör/bag/pipe") bulunur.
    public static func archivePaths(in sources: [URL], followingSymlinks: Bool = false, fileManager: FileManager = .default) -> [String] {
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
                return
            case S_IFDIR:
                let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
                guard !ancestors.contains(identity) else { return }
                for child in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] {
                    visit((path as NSString).appendingPathComponent(child), as: archivePath + "/" + child, ancestors: ancestors.union([identity]))
                }
            default:
                result.append(archivePath)
            }
        }
        for source in sources { visit(source.path, as: source.lastPathComponent, ancestors: []) }
        return result
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// Kopyalarken özel dosyaları (bağlantılar izlenecekse FIFO'yu gösteren bağlantıları da) atlayan `FileManager` temsilcisi.
    final class SkippingCopier: NSObject, FileManagerDelegate {
        let followingSymlinks: Bool

        init(followingSymlinks: Bool = false) {
            self.followingSymlinks = followingSymlinks
        }

        func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
            !SpecialFiles.isSpecial(atPath: srcURL.path, followingSymlinks: followingSymlinks)
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
        symbolicLinks: Set<String> = []
    ) {
        self.runner = runner
        self.archive = archive
        self.password = password
        self.root = root
        self.symbolicLinks = symbolicLinks
    }

    public static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Arhivar", isDirectory: true)
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
                let links = symbolicLinks.filter { $0.hasPrefix(path + "/") }.map { String($0.dropFirst(path.count + 1)) }
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

/// Listeden Finder'a sürüklenen öğe; dosya ancak bırakıldığında çıkarılır.
public struct ArchiveItemTransfer: Transferable, Sendable {
    public let extractor: ItemExtractor
    public let path: String
    public let name: String
    public let size: Int64?

    public init(extractor: ItemExtractor, path: String, name: String, size: Int64? = nil) {
        self.extractor = extractor
        self.path = path
        self.name = name
        self.size = size
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { item in
            SentTransferredFile(try await item.extractor.extract(item.path, expectedSize: item.size))
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
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }
}
