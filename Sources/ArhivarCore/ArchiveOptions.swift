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
        }
    }

    /// 7zz -t anahtarının değeri.
    public var typeSwitch: String { "-t" + rawValue }

    public var supportsEncryption: Bool { self == .sevenZip || self == .zip }
    public var supportsHeaderEncryption: Bool { self == .sevenZip }
    public var supportsCompressionLevel: Bool { self != .tar && self != .wim }
    public var supportsMultithreading: Bool { [.sevenZip, .zip, .xz, .bzip2].contains(self) }
    /// gzip/bzip2/xz yalnızca tek bir dosyayı sıkıştırabilir.
    public var singleFileOnly: Bool { [.gzip, .bzip2, .xz].contains(self) }
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

/// Hazır bölüm (volume) boyutları, MB cinsinden.
public enum VolumeSize {
    public static let presetsMB = [10, 100, 700, 1024, 4092]
}

public struct CreateOptions: Sendable, Equatable {
    public var sources: [URL]
    public var destination: URL
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var password: String?
    public var encryptFileNames: Bool
    public var volumeSizeMB: Int?
    public var multithreaded: Bool

    public init(
        sources: [URL], destination: URL, format: ArchiveFormat, level: CompressionLevel,
        password: String? = nil, encryptFileNames: Bool = false, volumeSizeMB: Int? = nil, multithreaded: Bool = true
    ) {
        self.sources = sources
        self.destination = destination
        self.format = format
        self.level = level
        self.password = password
        self.encryptFileNames = encryptFileNames
        self.volumeSizeMB = volumeSizeMB
        self.multithreaded = multithreaded
    }
}

public struct ExtractOptions: Sendable, Equatable {
    public var archive: URL
    public var destination: URL
    /// Boşsa tüm arşiv çıkarılır.
    public var items: [String]
    public var password: String?
    public var overwrite: OverwriteMode

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

    static func passwordSwitch(_ password: String?) -> [String] {
        guard let password, !password.isEmpty else { return [] }
        return ["-p" + password]
    }

    public static func list(archive: URL, password: String? = nil) -> [String] {
        ["l", "-slt", "-bd"] + common + passwordSwitch(password) + ["--", archive.path]
    }

    public static func test(archive: URL, password: String? = nil) -> [String] {
        ["t", "-bsp1", "-bb0"] + common + passwordSwitch(password) + ["--", archive.path]
    }

    public static func extract(_ options: ExtractOptions) -> [String] {
        var args = ["x", "-o" + options.destination.path, options.overwrite.switchValue, "-bsp1", "-bb0", "-y"]
        args += common
        args += passwordSwitch(options.password)
        // Seçili öğelerin adları joker karakter olarak yorumlanmasın.
        if !options.items.isEmpty { args.append("-spd") }
        args += ["--", options.archive.path]
        args += options.items
        return args
    }

    public static func create(_ options: CreateOptions) -> [String] {
        let format = options.format
        var args = ["a", format.typeSwitch, "-bsp1", "-bb0", "-y"] + common
        if format.supportsCompressionLevel {
            args.append("-mx=\(options.level.rawValue)")
        }
        if format.supportsMultithreading {
            args.append(options.multithreaded ? "-mmt=on" : "-mmt=1")
        }
        if format.supportsEncryption, let password = options.password, !password.isEmpty {
            args += passwordSwitch(password)
            if format == .sevenZip && options.encryptFileNames { args.append("-mhe=on") }
            if format == .zip { args.append("-mem=AES256") }
        }
        if let volume = options.volumeSizeMB, volume > 0 {
            args.append("-v\(volume)m")
        }
        args += ["--", options.destination.path]
        args += options.sources.map(\.path)
        return args
    }
}
