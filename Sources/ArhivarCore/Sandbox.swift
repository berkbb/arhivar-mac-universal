import Foundation

/// 7zz'yi çekirdek kum havuzunda (sandbox-exec) çalıştırma kuralları.
///
/// Güvenilmeyen arşivleri ayrıştıran 7zz, kullanıcının tüm yetkileriyle çalışmamalı: ağ her zaman kapalıdır,
/// yalnızca işlemin hedef klasörüne yazabilir ve arşiv okunurken kişisel gizli veri klasörlerini okuyamaz.
/// Böylece ayrıştırıcı ya da sembolik bağlantı açıkları hedef dışına yazamaz, veri sızdıramaz.
public struct SandboxProfile: Sendable, Equatable {
    public var writableDirectories: [URL]
    public var deniedReadDirectories: [URL]
    /// Yazılabilir tek dosyalar: yerinde düzenlemede arşivin kendisi (7zz geçici dosyayı `-w` klasörüne yazar, sonra
    /// arşivi yerinde günceller; arşivin klasörünün tamamına yazma hakkı gerekmez).
    public var writableFiles: [URL]
    /// Yasaklı bir klasörün içinde olsa da okunabilir tek dosyalar: açılan arşivin kendisi (ör. Mail eki). Yasak
    /// klasörün tamamını açmak yerine yalnızca arşiv izinlidir; SBPL'de son eşleşen kural kazandığı için izin yasaktan
    /// sonra yazılır.
    public var readableFiles: [URL]
    /// Yasaklı bir klasörün içindeki (ya da kendisi olan), kullanıcının açıkça seçtiği kaynak klasörler: yasaklı klasör
    /// kapalı kalır, yalnızca bunlar (içerikleriyle) yasaktan sonra gelen izinle okunabilir.
    public var readableDirectories: [URL]

    public static let launcher = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: launcher.path)
    }

    public init(
        writableDirectories: [URL], deniedReadDirectories: [URL], writableFiles: [URL] = [], readableFiles: [URL] = [],
        readableDirectories: [URL] = []
    ) {
        self.writableDirectories = writableDirectories
        self.deniedReadDirectories = deniedReadDirectories
        self.writableFiles = writableFiles
        self.readableFiles = readableFiles
        self.readableDirectories = readableDirectories
    }

    /// Arşiv okunurken erişilmemesi gereken kişisel veri klasörleri.
    public static func personalDataDirectories(home: URL) -> [URL] {
        [
            // Kimlik bilgileri ve erişim belirteçleri
            ".ssh", ".gnupg", ".aws", ".config/gh", ".netrc", ".kube", ".docker", ".npmrc", ".pypirc", ".git-credentials",
            // Bulut ve geliştirici kimlik bilgileri (sabit liste eksiksiz olamaz; en yaygın gizli konumlar)
            ".config/gcloud", ".azure", ".oci", ".terraform.d", ".m2", ".gradle", ".cargo", ".gem", ".config/Code", "Library/Application Support/Code",
            // Kabuk geçmişi (komut satırına yazılmış parolalar, belirteçler)
            ".zsh_history", ".bash_history",
            // Sistem ve iletişim verileri
            "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages",
            "Library/Application Support/AddressBook", "Library/Safari", "Library/Accounts",
            // Uygulama kapları ve HTTP oturumları (sandbox'lı uygulamaların verileri, çerezleri)
            "Library/Containers", "Library/Group Containers", "Library/HTTPStorages",
            // Tarayıcı profilleri (çerezler, kayıtlı parolalar, oturumlar)
            "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox",
            "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge",
            "Library/Application Support/Arc", "Library/Application Support/Vivaldi",
            "Library/Application Support/com.operasoftware.Opera",
        ].map { home.appendingPathComponent($0) }
    }

    /// - Parameters:
    ///   - archive: İşlenen arşiv; kişisel klasörlerden birinin içindeyse o klasör yasaklanmaz.
    ///   - writable: 7zz'nin yazabileceği klasörler.
    ///   - readable: Kullanıcının açıkça seçtiği kaynaklar (oluşturma, ekleme). Kişisel bir klasörün içindeyse klasör
    ///     yasaklı KALIR, yalnızca o kaynak yasaktan sonra gelen bir izinle okunur; eskiden klasörün tamamı açılır ve
    ///     başka bir kaynaktaki bağlantı (proje/key → ~/.ssh/id_ed25519) izlendiğinde (gz/bz2/xz ya da "bağlantıları
    ///     sakla" kapalıyken) anahtar arşive girerdi. 7zz'nin çalışma klasörü yasaklı olsa da göreli adlar çözülür.
    ///   - protectPersonalData: false ise kişisel veri klasörleri yasaklanmaz.
    public static func forOperation(
        archive: URL, writable: [URL], writableFiles: [URL] = [], readable: [URL] = [], protectPersonalData: Bool = true,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SandboxProfile {
        let writable = writable.map(resolved)
        let archivePath = resolved(archive)
        // Bölünmüş arşivde 7zz kardeş parçaları da okur; o zaman arşivin klasörü açık kalır. Aksi hâlde arşiv yasaklı bir
        // klasördeyse (ör. Mail ya da Mesajlar eki) klasör yasaklı kalır, yalnızca arşivin kendisi okunabilir: eskiden
        // "Library/Containers"ın tamamı (tüm uygulama verileri) o işlem boyunca okunabilir olurdu.
        var readable = readable.map(resolved)
        if needsSiblingVolumes(archive) { readable.append(archivePath.deletingLastPathComponent()) }
        let denied = protectPersonalData
            ? personalDataDirectories(home: home).map(resolved).filter { denied in
                // Yazılan klasörü (hazırlık, hedef) kapsayan yasak, işlemi bozardı.
                !writable.contains { $0.path == denied.path || $0.path.hasPrefix(denied.path + "/") }
            }
            : []
        // Arşiv bir sembolik bağlantı üzerinden verildiyse bağlantının kendisi de (readlink için) okunabilmeli.
        var readableFiles = [archivePath]
        var info = stat()
        if lstat(archive.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { readableFiles.append(archive.standardizedFileURL) }
        // Yasaklı bir klasörün içindeki kaynak: klasör yasaklı kalır, yalnızca kaynak (klasörse içeriğiyle) izinlidir.
        var readableDirectories: [URL] = []
        for source in readable where denied.contains(where: { source.path == $0.path || source.path.hasPrefix($0.path + "/") }) {
            if stat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                readableDirectories.append(source)
            } else {
                readableFiles.append(source)
            }
        }
        return SandboxProfile(
            writableDirectories: writable, deniedReadDirectories: denied, writableFiles: writableFiles.map(resolved),
            readableFiles: readableFiles, readableDirectories: readableDirectories
        )
    }

    /// Çok parçalı bir arşiv mi (".001", ".z01", ".r00", ".part1.rar")? 7zz kardeş parçaları aynı klasörden okur.
    static func needsSiblingVolumes(_ url: URL) -> Bool {
        let ext = url.pathExtension
        if ext.count == 3, ext.allSatisfy(\.isNumber) { return true }
        if ArchiveNaming.isOldRarVolume(ext) || ArchiveNaming.isSplitZipVolume(ext) { return true }
        return ext.lowercased() == "rar" && ArchiveNaming.isPartVolumeSuffix((url.deletingPathExtension().lastPathComponent as NSString).pathExtension)
    }

    /// Sembolik bağlantıları çöz (/tmp → /private/tmp, /var → /private/var); çekirdek gerçek yolları denetler.
    /// `URL.resolvingSymlinksInPath()` baştaki "/private" kısmını sildiği için `realpath(3)` kullanılır.
    /// Henüz var olmayan yollar için var olan en yakın üst klasör çözülür.
    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing
        if let real = realpath(existing.path, nil) {
            result = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        for component in suffix { result.appendPathComponent(component) }
        return result
    }

    /// SBPL kuralları. Yollar `-D` parametreleriyle verilir; tırnak ya da kaçış sorunu olmaz.
    public var profileText: String {
        var lines = ["(version 1)", "(allow default)", "(deny network*)", "(deny file-write*)"]
        var writes = ["(subpath \"/dev\")"] + writableDirectories.indices.map { "(subpath (param \"W\($0)\"))" }
        writes += writableFiles.indices.map { "(literal (param \"A\($0)\"))" }
        lines.append("(allow file-write* \(writes.joined(separator: " ")))")
        if !deniedReadDirectories.isEmpty {
            let reads = deniedReadDirectories.indices.map { "(subpath (param \"R\($0)\"))" }
            lines.append("(deny file-read* \(reads.joined(separator: " ")))")
        }
        // Yasaklı klasördeki arşivin kendisi ve seçilen kaynaklar: izin yasaktan SONRA gelir (son eşleşen kural kazanır).
        if !readableFiles.isEmpty {
            let files = readableFiles.indices.map { "(literal (param \"F\($0)\"))" }
            lines.append("(allow file-read* \(files.joined(separator: " ")))")
        }
        if !readableDirectories.isEmpty {
            let directories = readableDirectories.indices.map { "(subpath (param \"S\($0)\"))" }
            lines.append("(allow file-read* \(directories.joined(separator: " ")))")
        }
        // Ele geçirilmiş bir 7zz (bozuk arşivle tetiklenen ayrıştırıcı hatası) başka program çalıştıramaz ve mach
        // servislerine (AppleEvents, launchd) ulaşamaz; yalnızca 7zz'nin kendisi çalıştırılabilir.
        lines.append("(deny mach-lookup)")
        lines.append("(deny process-exec)")
        lines.append("(allow process-exec (literal (param \"E\")))")
        return lines.joined(separator: "\n")
    }

    /// sandbox-exec'e verilecek argümanlar: profil, parametreler, ardından asıl program ve argümanları.
    public func launchArguments(executable: URL, arguments: [String]) -> [String] {
        var result = ["-p", profileText]
        for (index, url) in writableDirectories.enumerated() { result += ["-D", "W\(index)=\(url.path)"] }
        for (index, url) in writableFiles.enumerated() { result += ["-D", "A\(index)=\(url.path)"] }
        for (index, url) in deniedReadDirectories.enumerated() { result += ["-D", "R\(index)=\(url.path)"] }
        for (index, url) in readableFiles.enumerated() { result += ["-D", "F\(index)=\(url.path)"] }
        for (index, url) in readableDirectories.enumerated() { result += ["-D", "S\(index)=\(url.path)"] }
        // Çekirdek gerçek yolu denetler: bağlantı üzerinden verilen bir motor yolu da çözülür.
        result += ["-D", "E=\(Self.resolved(executable).path)"]
        return result + [executable.path] + arguments
    }
}

extension CommandRunner {
    /// Bu çalıştırıcının kum havuzunda çalışan kopyası (sandbox-exec yoksa olduğu gibi döner).
    public func sandboxed(_ profile: SandboxProfile?) -> CommandRunner {
        guard let profile, SandboxProfile.isAvailable else { return self }
        return CommandRunner(executableURL: executableURL, sandbox: profile)
    }
}
