import CoreTransferable
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
    /// - Parameter archiveType: 7zz'nin bildirdiği tür ("zip", "7z", …); yoksa uzantıdan anlaşılır.
    public static func add(
        archive: URL, names: [String], password: String? = nil, encryptHeaders: Bool = false,
        archiveType: String? = nil, storeSymlinks: Bool = true, excludeMacMetadata: Bool = false
    ) -> [String] {
        // Parola stdin'den verilir (bkz. passwordInput); burada yalnızca sorulması istenir.
        let hasPassword = password?.isEmpty == false
        var args = ["a", "-bsp1", "-bb0", "-y"] + common + (hasPassword ? ["-p"] : [])
        if encryptHeaders, hasPassword { args.append("-mhe=on") }
        // -mem verilmezse 7zz şifreli zip'e eklenen dosyaları zayıf ZipCrypto ile şifreler; oluşturmadaki gibi AES-256 kalsın.
        if hasPassword, (archiveType ?? archive.pathExtension).lowercased() == "zip" { args.append("-mem=AES256") }
        args += sourceSwitches(names: names + [archive.path], storeSymlinks: storeSymlinks, excludeMacMetadata: excludeMacMetadata)
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

    public static func make(
        sources: [URL], into folder: String, stagingRoot: URL, fileManager: FileManager = .default
    ) throws -> AddPlan {
        let duplicates = duplicateNames(in: sources)
        guard duplicates.isEmpty else { throw DuplicateNameError(names: duplicates) }
        let folder = folder.split(separator: "/").joined(separator: "/")
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
            var names: [String] = []
            for source in sources {
                try fileManager.copyItem(at: source, to: target.appendingPathComponent(source.lastPathComponent))
                names.append(source.lastPathComponent)
            }
            let topLevel = folder.split(separator: "/").first.map(String.init)
            return AddPlan(workingDirectory: staging, names: topLevel.map { [$0] } ?? names, stagingDirectory: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
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

    public init(runner: CommandRunner, archive: URL, password: String?, root: URL = ItemExtractor.temporaryRoot) {
        self.runner = runner
        self.archive = archive
        self.password = password
        self.root = root
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
            if now.timeIntervalSince(modified) > age, (try? fileManager.removeItem(at: entry)) != nil {
                removed += 1
            }
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
        let targets = paths.map { directory.appendingPathComponent($0).standardizedFileURL }
        // Arşivdeki "../" gibi yollar geçici klasörün dışına çıkamasın.
        guard !paths.isEmpty else { throw SevenZipError.failed(code: 0, message: "") }
        if let escaping = zip(paths, targets).first(where: { !$0.1.path.hasPrefix(base) }) {
            throw SevenZipError.failed(code: 0, message: escaping.0)
        }
        // Geçici klasör sistem diskindedir; büyük bir öğe diski doldurmasın.
        if let expectedSize { try InsufficientSpaceError.check(required: expectedSize, at: root ?? self.root) }
        // Çözülmüş (belki şifreli arşivden gelen) içerik yalnızca kullanıcıya açık olsun.
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let start = Date()
            let options = ExtractOptions(archive: archive, destination: directory, items: paths, password: password, overwrite: .replace)
            let result = try await runner.run(SevenZipCommand.extract(options), workingDirectory: options.workingDirectory, input: options.input, onProgress: onProgress)
            try SevenZipError.check(result)
            // Hedef ağacın dışını gösteren bağlantılar sürüklenen ya da açılan öğeyle dışarı taşınmasın.
            StagedExtraction.secureSymlinks(in: directory)
            if let missing = zip(paths, targets).first(where: { StagedExtraction.itemType($0.1, fileManager: fileManager) == nil }) {
                throw SevenZipError.failed(code: result.exitCode, message: missing.0)
            }
            Quarantine.propagate(from: archive, to: directory, since: start)
            return targets
        } catch {
            try? fileManager.removeItem(at: directory)
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

    /// Bir öğenin yeniden adlandırıldıktan sonraki tam yolu.
    public static func renamedPath(_ path: String, to newName: String) -> String {
        let parent = parent(of: path)
        return parent.isEmpty ? newName : parent + "/" + newName
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }
}
