// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ArhivarCore

/// Finder'ın Arhivar belge simgelerini güncel tutar.
///
/// Launch Services bir uygulamanın belge türlerini ve simgelerini paket kaydından okur; paket yenilenince (yeni sürüm
/// kurulunca) bu kayıt her zaman kendiliğinden tazelenmez ve Finder eski simgeyi ya da sistem simgesini gösterir.
/// Derleme numarası değişen ilk açılışta paket yeniden kaydedilir. Sistem geneli simge önbelleği
/// (`/Library/Caches/com.apple.iconservices.store`) ise yalnızca yönetici izniyle temizlenebilir; uygulama bunu yapmaz,
/// Ayarlar › Gelişmiş'te komutu gösterir.
enum FinderIconRefresh {
    /// Son kaydedilen derleme numarası. Bir ayar değildir; "Tüm ayarları sıfırla" (`AppSettings.Key.all`) onu silmez.
    static let registeredBuildKey = "registeredBuild"

    /// Simge önbelleğini temizleyen komut; Terminal'de yönetici parolasıyla çalıştırılır, ardından Finder ve Dock yeniden başlatılır.
    nonisolated static let cacheClearCommand = "sudo rm -rf /Library/Caches/com.apple.iconservices.store && killall Finder Dock"

    /// Derleme değiştiyse (ilk açılış, yükseltme ya da geri dönüş) paket yeniden kaydedilir.
    nonisolated static func needsRegistration(lastBuild: String?, currentBuild: String) -> Bool {
        lastBuild != currentBuild
    }

    /// Yalnızca gerçek Arhivar paketi (testlerde `Bundle.main` xctest'tir) ve yalnızca derleme değiştiğinde.
    static func registerIfBuildChanged(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard bundle.bundleIdentifier == AppLog.subsystem else { return }
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        guard needsRegistration(lastBuild: defaults.string(forKey: registeredBuildKey), currentBuild: build) else { return }
        if register(bundle: bundle) {
            defaults.set(build, forKey: registeredBuildKey)
            AppLog.shared.info(.app, "Re-registered with Launch Services for build \(build)")
        }
    }

    /// Paketi Launch Services'a yeniden kaydeder (`lsregister -f` ile aynı etki). Başarısızlık günlüğe yazılır.
    @discardableResult
    static func register(bundle: Bundle = .main) -> Bool {
        let status = LSRegisterURL(bundle.bundleURL as CFURL, true)
        if status != noErr {
            AppLog.shared.warning(.app, "Launch Services registration failed", detail: "LSRegisterURL status \(status)")
        }
        return status == noErr
    }

    /// Finder ve Dock'u kapatır; launchd ikisini de hemen yeniden başlatır. Açık Finder pencereleri kapanır.
    static func relaunchFinderAndDock() {
        for identifier in ["com.apple.finder", "com.apple.dock"] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) where !app.terminate() {
                app.forceTerminate()
            }
        }
        AppLog.shared.info(.app, "Finder and Dock relaunched to refresh document icons")
    }

    /// Ayarlar'daki düğme: yeniden kaydet, sonra Finder ve Dock'u yeniden başlat.
    static func refresh(bundle: Bundle = .main) {
        register(bundle: bundle)
        relaunchFinderAndDock()
    }
}
