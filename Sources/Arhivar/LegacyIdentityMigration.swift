import AppKit
import ArhivarCore
import UniformTypeIdentifiers

/// Paket kimliği net.babadogan.arhivar → com.babadogantech.arhivar geçişi. Tercihler `AppSettings` açılırken aktarılır;
/// bu adım Finder'daki "Birlikte Aç → Tümünü Değiştir" seçimlerini taşır (eski kimlikte kalınca macOS türleri Arşiv
/// İzlencesi'ne döndürür, Arhivar'ın belge simgeleri de kaybolur), ardından eski kimliğin Mac'te bıraktığı tercih ve önbellek
/// kayıtlarını arka planda siler. Tamamlanınca bir daha çalışmaz; yarıda kalırsa (ör. uygulama kapanırsa) sonraki açılışta sürer.
enum LegacyIdentityMigration {
    nonisolated static let legacyBundleID = "net.babadogan.arhivar"
    /// Geçişin bittiğini gösterir. Bir ayar değildir; "Tüm ayarları sıfırla" (`AppSettings.Key.all`) onu silmez.
    static let doneKey = "legacyIdentityMigrated"

    /// Eski kimliğin ~/Library altında bıraktığı, silinmesi güvenli kayıtlar. Eski Hızlı Bakış eklentisinin kapsayıcısı
    /// (Containers, Application Scripts) macOS'un uygulama verisi korumasında olduğundan dokunulmaz: silmek izin penceresi açar.
    nonisolated static let legacyLibraryItems = [
        "Caches/\(legacyBundleID)",
        "HTTPStorages/\(legacyBundleID)",
        "HTTPStorages/\(legacyBundleID).binarycookies",
        "Saved Application State/\(legacyBundleID).savedState",
        "WebKit/\(legacyBundleID)",
        "Application Support/\(legacyBundleID)",
    ]

    /// Kullanıcının varsayılan uygulama seçimleri (LSHandlers). Yalnızca okunur; değişiklik NSWorkspace ile yapılır.
    static var handlersFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
    }

    /// Herhangi bir rolde eski kimliğe bağlı içerik türleri, tekrarsız ve sıralı. Launch Services kimliği küçük harfle de yazabilir.
    static func legacyContentTypes(in plist: Data, legacyBundleID: String = legacyBundleID) -> [String] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let handlers = root["LSHandlers"] as? [[String: Any]] else { return [] }
        let roles = ["LSHandlerRoleAll", "LSHandlerRoleViewer", "LSHandlerRoleEditor"]
        var types = Set<String>()
        for handler in handlers {
            guard let type = handler["LSHandlerContentType"] as? String else { continue }
            if roles.contains(where: { (handler[$0] as? String)?.caseInsensitiveCompare(legacyBundleID) == .orderedSame }) {
                types.insert(type)
            }
        }
        return types.sorted()
    }

    static func run(bundle: Bundle = .main, defaults: UserDefaults = .standard, workspace: NSWorkspace = .shared) async {
        guard bundle.bundleIdentifier == AppLog.subsystem, !defaults.bool(forKey: doneKey) else { return }
        await moveDefaultHandlers(to: bundle.bundleURL, workspace: workspace)
        // Eski alan silinmeden önce, açılışta aktarılmamış bir tercih kalmasın.
        AppSettings.migrateLegacyDefaults(to: defaults)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let removed = await Task.detached(priority: .background) { removeLegacyRecords(home: home) }.value
        defaults.set(true, forKey: doneKey)
        AppLog.shared.info(.app, "Legacy \(legacyBundleID) records cleaned up (\(removed.count) removed)", detail: removed.joined(separator: "\n"))
    }

    /// Eski kimliğe bağlı türleri bu pakete bağlar. Bir tür taşınamazsa günlüğe yazılır; yeniden denemek sonucu değiştirmez.
    private static func moveDefaultHandlers(to app: URL, workspace: NSWorkspace) async {
        guard let data = try? Data(contentsOf: handlersFile) else { return }
        for identifier in legacyContentTypes(in: data) {
            guard let type = UTType(identifier) else { continue }
            do {
                try await workspace.setDefaultApplication(at: app, toOpen: type)
                AppLog.shared.info(.app, "Default app for \(identifier) moved from \(legacyBundleID) to \(AppLog.subsystem)")
            } catch {
                AppLog.shared.warning(.app, "Default app for \(identifier) could not be moved: \(AppLog.describe(error).kind)")
            }
        }
    }

    /// Eski tercih alanını ve `legacyLibraryItems` kayıtlarını siler; silinenlerin ~/Library'ye göre yollarını döndürür.
    nonisolated static func removeLegacyRecords(home: URL, legacyDomain: String = legacyBundleID) -> [String] {
        let preferences = "Preferences/\(legacyDomain).plist"
        var removed: [String] = []
        // Alan cfprefsd'de boşaltılmadan dosya silinirse önbellekten yeniden yazılabilir. Boşaltılan alanın dosyası
        // (boş bir plist) yerinde kaldığından ardından o da silinir.
        if let legacy = UserDefaults(suiteName: legacyDomain), legacy.persistentDomain(forName: legacyDomain)?.isEmpty == false {
            legacy.removePersistentDomain(forName: legacyDomain)
            removed.append(preferences)
        }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        for item in [preferences] + legacyLibraryItems {
            let url = library.appendingPathComponent(item)
            guard (try? url.checkResourceIsReachable()) == true else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil, !removed.contains(item) { removed.append(item) }
        }
        return removed
    }
}
