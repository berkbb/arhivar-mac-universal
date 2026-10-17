import Foundation

/// 7zz programını bulur ve sürümünü okur.
public enum EngineLocator {
    public static let homebrewPaths = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"]

    /// Uygulama paketi yazılamadığında güncelleyicinin 7zz.yi kurduğu yedek klasör.
    public static var managedEngineDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arhivar/engine", isDirectory: true)
    }

    /// Sıra: kullanıcının seçtiği → uygulamayla gelen → yedek klasör → Homebrew.
    public static func candidates(customPath: String?, managedDirectory: URL = managedEngineDirectory, bundle: Bundle = .main) -> [URL] {
        var result: [URL] = []
        if let customPath, !customPath.isEmpty { result.append(URL(fileURLWithPath: customPath)) }
        if let bundled = bundle.url(forAuxiliaryExecutable: "7zz") { result.append(bundled) }
        result.append(managedDirectory.appendingPathComponent("7zz"))
        result += homebrewPaths.map { URL(fileURLWithPath: $0) }
        return result
    }

    public static func locate(
        customPath: String?, managedDirectory: URL = managedEngineDirectory,
        bundle: Bundle = .main, fileManager: FileManager = .default
    ) -> URL? {
        candidates(customPath: customPath, managedDirectory: managedDirectory, bundle: bundle)
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Sürümü bilinen adaylar arasından en yenisini seçer; eşitlikte sıradaki ilk aday kazanır.
    public static func newest(_ candidates: [(url: URL, version: String?)]) -> URL? {
        func parts(_ value: String?) -> [Int] { value?.split(separator: ".").map { Int($0) ?? 0 } ?? [] }
        var best: (url: URL, version: [Int])?
        for candidate in candidates where candidate.version != nil {
            let version = parts(candidate.version)
            if best == nil || best!.version.lexicographicallyPrecedes(version) { best = (candidate.url, version) }
        }
        return best?.url
    }

    /// "7-Zip (z) 26.04 (arm64) : ..." satırından "26.04" değerini çıkarır.
    public static func parseVersion(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("7-Zip") {
            for token in line.split(separator: " ") where isVersionToken(token) {
                return String(token)
            }
        }
        return nil
    }

    static func isVersionToken(_ token: Substring) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

/// update-7zip.sh betiğinin KEY=value çıktısı.
public struct EngineUpdateResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case upToDate = "up-to-date"
        case updateAvailable = "update-available"
        case installed
        case error
    }

    public var status: Status
    public var latestVersion: String?
    public var currentVersion: String?
    public var installedPath: String?
    public var sourceURL: URL?
    public var errorMessage: String?

    public static func parse(_ output: String) -> EngineUpdateResult? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard let rawStatus = values["STATUS"], let status = Status(rawValue: rawStatus) else { return nil }
        let current = values["CURRENT"].flatMap { $0 == "none" || $0.isEmpty ? nil : $0 }
        return EngineUpdateResult(
            status: status,
            latestVersion: values["LATEST"],
            currentVersion: current,
            installedPath: values["INSTALLED"],
            sourceURL: values["SOURCE"].flatMap(URL.init(string:)),
            errorMessage: values["ERROR"]
        )
    }
}

/// Güncelleme betiğini çalıştırır; arayüz ile komut satırı aynı mantığı kullanır.
public struct EngineUpdater: Sendable {
    public let scriptURL: URL
    /// Boşsa betik hedefi kendisi seçer: uygulamanın içindeyse o uygulamanın 7zz'si güncellenir.
    public let targets: [String]

    public init(scriptURL: URL, targets: [String] = []) {
        self.scriptURL = scriptURL
        self.targets = targets
    }

    public func arguments(command: String) -> [String] {
        [scriptURL.path, command] + targets
    }

    public func check() async throws -> EngineUpdateResult {
        try await run(command: "check", timeout: 60)
    }

    public func install() async throws -> EngineUpdateResult {
        try await run(command: "install", timeout: 900)
    }

    private func run(command: String, timeout: TimeInterval) async throws -> EngineUpdateResult {
        let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/bash"))
        let result = try await runner.run(arguments(command: command), timeout: timeout)
        guard let parsed = EngineUpdateResult.parse(result.stdout) else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SevenZipError.failed(code: result.exitCode, message: message)
        }
        if parsed.status == .error {
            throw SevenZipError.failed(code: result.exitCode, message: parsed.errorMessage ?? "")
        }
        return parsed
    }

    /// "26.04" ile "26.10" gibi sürümleri sayısal olarak karşılaştırır.
    public static func isNewer(_ candidate: String, than current: String?) -> Bool {
        guard let current else { return true }
        func parts(_ value: String) -> [Int] { value.split(separator: ".").map { Int($0) ?? 0 } }
        return parts(current).lexicographicallyPrecedes(parts(candidate))
    }
}

/// Arşiv adları ve uzantılarıyla ilgili yardımcılar.
public enum ArchiveNaming {
    static let archiveExtensions: Set<String> = [
        "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma", "tlz", "z", "taz",
        "zst", "tzst", "lz", "lz4", "cab", "iso", "dmg", "wim", "swm", "esd", "arj", "cpio", "rpm", "deb",
        "lzh", "lha", "xar", "vhd", "vhdx", "vmdk", "qcow2", "squashfs", "udf", "apfs", "hfs",
    ]

    static func isArchiveExtension(_ ext: String) -> Bool {
        let ext = ext.lowercased()
        if archiveExtensions.contains(ext) { return true }
        // Bölünmüş arşiv parçaları: .001, .002, …
        return ext.count == 3 && ext.allSatisfy(\.isNumber)
    }

    public static func isArchive(_ url: URL) -> Bool {
        isArchiveExtension(url.pathExtension)
    }

    /// "fotograflar.tar.gz" → "fotograflar", "veri.7z.001" → "veri".
    public static func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        for _ in 0..<3 {
            let ext = (name as NSString).pathExtension
            guard !ext.isEmpty, isArchiveExtension(ext) else { break }
            name = (name as NSString).deletingPathExtension
        }
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// Yeni arşiv için önerilen ad (uzantısız).
    public static func suggestedName(for sources: [URL], isDirectory: (URL) -> Bool = defaultIsDirectory) -> String {
        guard let first = sources.first else { return "Archive" }
        if sources.count == 1 {
            if isDirectory(first) { return first.lastPathComponent }
            let stripped = first.deletingPathExtension().lastPathComponent
            return stripped.isEmpty ? first.lastPathComponent : stripped
        }
        let parent = first.deletingLastPathComponent()
        let sameParent = sources.allSatisfy { $0.deletingLastPathComponent() == parent }
        let parentName = parent.lastPathComponent
        return sameParent && !parentName.isEmpty && parentName != "/" ? parentName : "Archive"
    }

    public static func defaultIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
