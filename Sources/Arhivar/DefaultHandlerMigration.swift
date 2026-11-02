import AppKit
import ArhivarCore
import UniformTypeIdentifiers

/// Paket kimliği net.babadogan.arhivar → com.babadogantech.arhivar olunca Finder'daki "Birlikte Aç → Tümünü Değiştir"
/// seçimleri Launch Services'te eski kimlikte kalır. macOS bu türleri yeniden Arşiv İzlencesi'ne bağlar; belge simgeleri
/// varsayılan uygulamadan geldiği için Arhivar'ın zip/7z/rar simgeleri de kaybolur. Eski kimliğe bağlı türler açılışta
/// yeni pakete aktarılır. Aktarılan kayıt yeni kimliği taşıdığından işlem kendiliğinden bir kez yapılır; kullanıcının
/// sonradan başka bir uygulamaya verdiği türlere dokunulmaz.
enum DefaultHandlerMigration {
    static let legacyBundleID = "net.babadogan.arhivar"

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

    static func run(bundle: Bundle = .main, workspace: NSWorkspace = .shared) async {
        guard bundle.bundleIdentifier == AppLog.subsystem,
              let data = try? Data(contentsOf: handlersFile) else { return }
        for identifier in legacyContentTypes(in: data) {
            guard let type = UTType(identifier) else { continue }
            do {
                try await workspace.setDefaultApplication(at: bundle.bundleURL, toOpen: type)
                AppLog.shared.info(.app, "Default app for \(identifier) moved from \(legacyBundleID) to \(AppLog.subsystem)")
            } catch {
                AppLog.shared.warning(.app, "Default app for \(identifier) could not be moved: \(AppLog.describe(error).kind)")
            }
        }
    }
}
