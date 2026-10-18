import Foundation

/// Arhivar'ın oluşturabildiği arşiv biçimleri.
public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case sevenZip = "7z"
    case zip
    case tar
    case wim
    case gzip
    case bzip2
    case xz
    /// Klasörler ve birden çok dosya için tek adımda .tar.gz / .tar.xz / .tar.bz2: önce geçici bir tar yazılır,
    /// ardından sıkıştırılır. (Resmî 7zz zstd sıkıştıramaz; .zst / .tar.zst yalnızca açılabilir.)
    case tarGzip = "tar.gz"
    case tarXz = "tar.xz"
    case tarBzip2 = "tar.bz2"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sevenZip: "7z"
        case .zip: "ZIP"
        case .tar: "TAR"
        case .wim: "WIM"
        case .gzip: "GZIP"
        case .bzip2: "BZIP2"
        case .xz: "XZ"
        case .tarGzip: "TAR.GZ"
        case .tarXz: "TAR.XZ"
        case .tarBzip2: "TAR.BZ2"
        }
    }

    public var fileExtension: String {
        switch self {
        case .sevenZip: "7z"
        case .zip: "zip"
        case .tar: "tar"
        case .wim: "wim"
        case .gzip: "gz"
        case .bzip2: "bz2"
        case .xz: "xz"
        case .tarGzip: "tar.gz"
        case .tarXz: "tar.xz"
        case .tarBzip2: "tar.bz2"
        }
    }

    /// tar.* biçimlerinde ikinci adımın (tar'ı sıkıştırma) biçimi.
    public var tarCompression: ArchiveFormat? {
        switch self {
        case .tarGzip: .gzip
        case .tarXz: .xz
        case .tarBzip2: .bzip2
        default: nil
        }
    }

    /// 7zz -t anahtarının değeri (tar.* için ilk adım: tar).
    public var typeSwitch: String { "-t" + (tarCompression == nil ? rawValue : ArchiveFormat.tar.rawValue) }

    public var supportsEncryption: Bool { self == .sevenZip || self == .zip }
    public var supportsHeaderEncryption: Bool { self == .sevenZip }
    public var supportsCompressionLevel: Bool { self != .tar && self != .wim }
    public var supportsMultithreading: Bool { [.sevenZip, .zip, .xz, .bzip2, .tarXz, .tarBzip2].contains(self) }
    /// gzip/bzip2/xz yalnızca tek bir dosyayı sıkıştırabilir.
    public var singleFileOnly: Bool { [.gzip, .bzip2, .xz].contains(self) }
    /// Bölünmüş (çok parçalı) arşiv yazılabilir mi? tar.* iki adımda üretildiği için bölünemez.
    public var supportsVolumes: Bool { !singleFileOnly && tarCompression == nil }
    /// Sembolik bağlantıları bağlantı olarak saklayabilen biçimler (-snl).
    public var supportsSymlinks: Bool { [.sevenZip, .zip, .tar, .wim, .tarGzip, .tarXz, .tarBzip2].contains(self) }
}

/// 7zz -mx düzeyleri.
public enum CompressionLevel: Int, CaseIterable, Identifiable, Sendable, Codable {
    case store = 0
    case fastest = 1
    case fast = 3
    case normal = 5
    case maximum = 7
    case ultra = 9

    public var id: Int { rawValue }

    public var titleKey: LKey {
        switch self {
        case .store: .levelStore
        case .fastest: .levelFastest
        case .fast: .levelFast
        case .normal: .levelNormal
        case .maximum: .levelMaximum
        case .ultra: .levelUltra
        }
    }
}

/// Çıkarırken var olan dosyalara ne yapılacağı.
public enum OverwriteMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case replace
    case skip
    case rename

    public var id: String { rawValue }

    public var switchValue: String {
        switch self {
        case .replace: "-aoa"
        case .skip: "-aos"
        case .rename: "-aou"
        }
    }

    public var titleKey: LKey {
        switch self {
        case .replace: .overwriteReplace
        case .skip: .overwriteSkip
        case .rename: .overwriteRename
        }
    }
}

/// Çıkarırken arşiv adıyla bir klasör oluşturma kuralı.
public enum SubfolderMode: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Arşivin kökünde birden fazla öğe varsa klasör oluştur; tek öğe doğrudan hedefe çıkar.
    case smart
    case always
    case never

    public var id: String { rawValue }

    public var titleKey: LKey {
        switch self {
        case .smart: .subfolderSmart
        case .always: .subfolderAlways
        case .never: .subfolderNever
        }
    }
}

/// Hazır bölüm (volume) boyutları, MB cinsinden.
public enum VolumeSize {
    public static let presetsMB = [10, 100, 700, 1024, 4092]
}

public struct CreateOptions: Sendable, Equatable {
    /// 7zz'nin stdin'ine yazılacak parola (biçim şifrelemeyi destekliyorsa).
    public var input: Data? { format.supportsEncryption ? SevenZipCommand.passwordInput(password) : nil }

    public var sources: [URL]
    public var destination: URL
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var password: String?
    public var encryptFileNames: Bool
    public var volumeSizeMB: Int?
    public var multithreaded: Bool
    /// Sembolik bağlantıları bağlantı olarak sakla (.app ve .framework paketleri için gerekli).
    public var storeSymlinks: Bool
    /// .DS_Store, ._* ve __MACOSX dosyalarını arşive alma.
    public var excludeMacMetadata: Bool
    /// Arşive alınmayacak öğelerin arşivdeki yolları ("klasör/alt/pipe"): FIFO, soket ve aygıt dosyaları
    /// (bkz. `SpecialFiles`). 7zz bir FIFO'yu okumaya çalışırken çekirdekte sonsuza dek bekler.
    public var excludedPaths: [String]

    public init(
        sources: [URL], destination: URL, format: ArchiveFormat, level: CompressionLevel,
        password: String? = nil, encryptFileNames: Bool = false, volumeSizeMB: Int? = nil, multithreaded: Bool = true,
        storeSymlinks: Bool = true, excludeMacMetadata: Bool = false, excludedPaths: [String] = []
    ) {
        self.sources = sources
        self.destination = destination
        self.format = format
        self.level = level
        self.password = password
        self.encryptFileNames = encryptFileNames
        self.volumeSizeMB = volumeSizeMB
        self.multithreaded = multithreaded
        self.storeSymlinks = storeSymlinks
        self.excludeMacMetadata = excludeMacMetadata
        self.excludedPaths = excludedPaths
    }

    /// Bölünmüş arşivde 7zz "ad.7z" yerine "ad.7z.001", "ad.7z.002", … yazar.
    public var isSplit: Bool { (volumeSizeMB ?? 0) > 0 && format.supportsVolumes }

    /// Diskte oluşan (açılabilir) ilk dosya.
    public var firstOutput: URL { isSplit ? destination.appendingPathExtension("001") : destination }

    /// Sonuç boyutu kaynaklardan küçük olabilir mi? (Boş alan tahmini için.)
    public var compresses: Bool { format.supportsCompressionLevel && level != .store }
}

public struct ExtractOptions: Sendable, Equatable {
    public var archive: URL
    public var destination: URL
    /// Boşsa tüm arşiv çıkarılır.
    public var items: [String]
    public var password: String?
    public var overwrite: OverwriteMode

    /// 7zz'nin çalışması gereken klasör; yalnızca hedef yolunda "*" varsa doludur.
    /// 7zz'nin stdin'ine yazılacak parola (yoksa nil).
    public var input: Data? { SevenZipCommand.passwordInput(password) }

    public var workingDirectory: URL? {
        destination.path.contains("*") ? destination : nil
    }

    public init(archive: URL, destination: URL, items: [String] = [], password: String? = nil, overwrite: OverwriteMode) {
        self.archive = archive
        self.destination = destination
        self.items = items
        self.password = password
        self.overwrite = overwrite
    }
}

/// 7zz komut satırı argümanlarını üretir.
public enum SevenZipCommand {
    static let common = ["-sccUTF-8"]

    /// Parola hiçbir zaman komut satırına yazılmaz (`ps` ile okunabilirdi); 7zz'nin stdin'ine verilir.
    /// l/t/x/d/rn şifreli girdide parolayı kendisi sorar; `a` için çıplak `-p` sorulmasını sağlar.
    /// Ad şifreli (-mhe) arşive eklemede birden fazla istem gelebildiği için satır birkaç kez yazılır.
    public static func passwordInput(_ password: String?) -> Data? {
        guard let password, !password.isEmpty else { return nil }
        let line = password.split(whereSeparator: \.isNewline).first.map(String.init) ?? password
        return Data(String(repeating: line + "\n", count: 4).utf8)
    }

    // Arşiv yolunun kendisi de joker karakter sayılır: "yedek*1.7z" açılırken "-spd" olmadan aynı klasördeki
    // "yedekX1.7z" de listelenir, test edilir, çıkarılır. Filtre kullanmayan komutlar her zaman "-spd" verir.

    public static func list(archive: URL) -> [String] {
        ["l", "-slt", "-bd", "-spd"] + common + ["--", archive.path]
    }

    public static func test(archive: URL) -> [String] {
        ["t", "-bsp1", "-bb0", "-spd"] + common + ["--", archive.path]
    }

    public static func extract(_ options: ExtractOptions) -> [String] {
        // 7zz -o yolundaki "*" karakterini arşiv adıyla değiştirir; böyle bir yolda hedef klasörde çalışılıp "-o." verilir.
        let output = options.workingDirectory == nil ? options.destination.path : "."
        // Arşiv yolu ve seçili öğelerin adları joker karakter olarak yorumlanmasın.
        var args = ["x", "-o" + output, options.overwrite.switchValue, "-bsp1", "-bb0", "-y", "-spd"]
        args += common
        args += ["--", options.archive.path]
        args += options.items
        return args
    }

    /// macOS üst veri dosyaları: Finder görünüm ayarları, AppleDouble kopyaları ve Arşiv İzlencesi klasörü.
    public static let macMetadataExclusions = ["-xr!.DS_Store", "-xr!._*", "-xr!__MACOSX"]

    /// Adlarında "*" ya da "?" geçen yollar (kaynaklar, arşivin kendisi, dışlanan öğeler) joker karakter
    /// sanılmasın diye `-spd` verilir. `-spd` hariç tutma kalıplarındaki jokerleri de kapattığı için yalnızca
    /// gerektiğinde eklenir; o zaman "._*" kalıbı uygulanamaz (".DS_Store" ve "__MACOSX" tam adla yine çalışır).
    static func wildcardSafety(for names: [String]) -> [String] {
        names.contains { $0.contains("*") || $0.contains("?") } ? ["-spd"] : []
    }

    /// Ekleme ve oluşturmada ortak seçenekler: joker güvenliği, bağlantılar, üst veri ve özel dosya dışlama.
    /// - Parameters:
    ///   - names: Kaynak yolları ve arşivin yolu.
    ///   - excluding: Arşive alınmayacak öğelerin arşivdeki yolları (`-x!` yalnızca o yolu dışlar).
    static func sourceSwitches(names: [String], storeSymlinks: Bool, excludeMacMetadata: Bool, excluding: [String] = []) -> [String] {
        var args = wildcardSafety(for: names + excluding)
        if storeSymlinks { args.append("-snl") }
        if excludeMacMetadata { args += macMetadataExclusions }
        args += excluding.map { "-x!" + $0 }
        return args
    }

    /// - Parameter tarStage: tar.* biçimlerinde ilk adımın yazacağı geçici tar dosyası (bkz. `tarStage(for:in:)`).
    public static func create(_ options: CreateOptions, tarStage: URL? = nil) -> [String] {
        let format = options.format
        let isTarStage = format.tarCompression != nil
        var args = ["a", format.typeSwitch, "-bsp1", "-bb0", "-y"] + common
        // tar.* biçimlerinde bu komut ilk adımdır (sıkıştırmasız tar); düzey ve iş parçacığı ikinci adımda kullanılır.
        if format.supportsCompressionLevel, !isTarStage {
            args.append("-mx=\(options.level.rawValue)")
        }
        if format.supportsMultithreading, !isTarStage {
            args.append(options.multithreaded ? "-mmt=on" : "-mmt=1")
        }
        if format.supportsEncryption, let password = options.password, !password.isEmpty {
            args.append("-p")
            if format == .sevenZip && options.encryptFileNames { args.append("-mhe=on") }
            if format == .zip { args.append("-mem=AES256") }
        }
        if options.isSplit, let volume = options.volumeSizeMB {
            args.append("-v\(volume)m")
        }
        let output = isTarStage ? (tarStage ?? Self.tarStage(for: options.destination, in: options.destination.deletingLastPathComponent())) : options.destination
        args += sourceSwitches(
            names: options.sources.map(\.path) + [output.path],
            storeSymlinks: options.storeSymlinks && format.supportsSymlinks,
            excludeMacMetadata: options.excludeMacMetadata,
            excluding: options.excludedPaths
        )
        args += ["--", output.path]
        args += options.sources.map(\.path)
        return args
    }

    /// tar.* için ilk adımın geçici tar dosyası: "yedek.tar.gz" → "<klasör>/yedek.tar".
    /// gzip içteki dosyanın adını saklar; açıldığında doğru adla ("yedek.tar") çıkması için ad hedeften türetilir,
    /// klasör ise çağıranın oluşturduğu geçici bir klasördür (var olan bir "yedek.tar" ezilmesin).
    public static func tarStage(for destination: URL, in directory: URL) -> URL {
        let name = destination.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(name.lowercased().hasSuffix(".tar") ? name : name + ".tar")
    }

    /// tar.* için ikinci adım: geçici tar'ı gzip/xz/bzip2 ile hedefe sıkıştırır.
    public static func compressTarStage(_ options: CreateOptions, tarStage: URL) -> [String]? {
        guard let compression = options.format.tarCompression else { return nil }
        var args = ["a", compression.typeSwitch, "-bsp1", "-bb0", "-y"] + common
        args.append("-mx=\(options.level.rawValue)")
        if compression.supportsMultithreading {
            args.append(options.multithreaded ? "-mmt=on" : "-mmt=1")
        }
        return args + wildcardSafety(for: [tarStage.path, options.destination.path]) + ["--", options.destination.path, tarStage.path]
    }
}
