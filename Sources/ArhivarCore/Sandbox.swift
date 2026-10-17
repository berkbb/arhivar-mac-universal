import Foundation

/// 7zz'yi çekirdek kum havuzunda (sandbox-exec) çalıştırma kuralları.
///
/// Güvenilmeyen arşivleri ayrıştıran 7zz, kullanıcının tüm yetkileriyle çalışmamalı: ağ her zaman kapalıdır,
/// yalnızca işlemin hedef klasörüne yazabilir ve arşiv okunurken kişisel gizli veri klasörlerini okuyamaz.
/// Böylece ayrıştırıcı ya da sembolik bağlantı açıkları hedef dışına yazamaz, veri sızdıramaz.
public struct SandboxProfile: Sendable, Equatable {
    public var writableDirectories: [URL]
    public var deniedReadDirectories: [URL]

    public static let launcher = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: launcher.path)
    }

    public init(writableDirectories: [URL], deniedReadDirectories: [URL]) {
        self.writableDirectories = writableDirectories
        self.deniedReadDirectories = deniedReadDirectories
    }

    /// Arşiv okunurken erişilmemesi gereken kişisel veri klasörleri.
    public static func personalDataDirectories(home: URL) -> [URL] {
        [
            ".ssh", ".gnupg", ".aws", ".config/gh", ".netrc",
            "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages",
            "Library/Application Support/AddressBook", "Library/Safari", "Library/Accounts",
        ].map { home.appendingPathComponent($0) }
    }

    /// - Parameters:
    ///   - archive: İşlenen arşiv; kişisel klasörlerden birinin içindeyse o klasör yasaklanmaz.
    ///   - writable: 7zz'nin yazabileceği klasörler.
    ///   - protectPersonalData: Arşiv okunurken (liste, test, çıkarma) true; kullanıcı kaynak seçerken (oluşturma, ekleme) false.
    public static func forOperation(
        archive: URL, writable: [URL], protectPersonalData: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SandboxProfile {
        let writable = writable.map(resolved)
        let keep = [resolved(archive)] + writable
        let denied = protectPersonalData
            ? personalDataDirectories(home: home).map(resolved).filter { denied in
                // Kullanıcının açıkça çalıştığı bir yolu kapsayan yasak, işlemi bozardı.
                !keep.contains { $0.path == denied.path || $0.path.hasPrefix(denied.path + "/") }
            }
            : []
        return SandboxProfile(writableDirectories: writable, deniedReadDirectories: denied)
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
        let writes = ["(subpath \"/dev\")"] + writableDirectories.indices.map { "(subpath (param \"W\($0)\"))" }
        lines.append("(allow file-write* \(writes.joined(separator: " ")))")
        if !deniedReadDirectories.isEmpty {
            let reads = deniedReadDirectories.indices.map { "(subpath (param \"R\($0)\"))" }
            lines.append("(deny file-read* \(reads.joined(separator: " ")))")
        }
        return lines.joined(separator: "\n")
    }

    /// sandbox-exec'e verilecek argümanlar: profil, parametreler, ardından asıl program ve argümanları.
    public func launchArguments(executable: URL, arguments: [String]) -> [String] {
        var result = ["-p", profileText]
        for (index, url) in writableDirectories.enumerated() { result += ["-D", "W\(index)=\(url.path)"] }
        for (index, url) in deniedReadDirectories.enumerated() { result += ["-D", "R\(index)=\(url.path)"] }
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
