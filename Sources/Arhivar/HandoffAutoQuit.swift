// SPDX-License-Identifier: GPL-3.0-only
import ArhivarCore
import Foundation

/// Yalnızca penceresiz bir Buraya Çıkar isteği (`ExtractHandoff`) için başlatılan Arhivar'ın, istekler bitince kendiliğinden
/// kapanması (Descarcator madde 506).
///
/// Arhivar'ı başlatan ilk olay böyle bir istekse ve kullanıcı o zamandan beri uygulamayı kullanmadıysa, son isteğin sonucu
/// bildirildikten sonra kısa bir bekleme (`gracePeriod`) boyunca boşta kalırsa kapanır. Bekleme sırasında gelen yeni istek
/// aynı süreci kullanır. Kullanıcı uygulamayı etkinleştirir, Dock'tan yeniden açar, bir arşiv açar ya da Finder servisini
/// kullanırsa karar kalıcı olarak "açık kal" olur; Arhivar zaten çalışıyorken gelen istek de onu kapatmaz.
final class HandoffAutoQuit {
    /// Uygulamanın neden çalıştığı.
    enum Launch: Equatable {
        /// Açılıştan beri ne istek ne de kullanıcı etkileşimi oldu.
        case undetermined
        /// İlk olay penceresiz bir istekti ve kullanıcı o zamandan beri uygulamayı kullanmadı.
        case handoffOnly
        /// Kalıcı: kullanıcı uygulamayı açtı ya da kullandı (Arhivar zaten çalışıyordu).
        case user
    }

    /// Penceresiz açılışı bitiren kullanıcı etkileşimi (günlük için).
    enum Engagement: String {
        /// Arhivar belge ya da istek olmadan, olağan biçimde başlatıldı.
        case defaultLaunch = "normal launch"
        /// İşaretsiz açma: Finder, "Birlikte Aç", tarayıcı.
        case open
        /// Dock simgesine tıklama ya da yeniden açma olayı.
        case reopen
        /// Uygulama öne geldi (Dock, ⌘⇥, menü, pencere).
        case activated
        /// Finder servisi (Buraya Çıkar, Sıkıştır, Aç).
        case service
    }

    /// Kapanmayı engelleyen anlık durum; hepsi false ise uygulama boştadır.
    struct Activity: Equatable {
        /// Sonucu henüz bildirilmemiş penceresiz istek var.
        var handoffPending = false
        /// Buraya Çıkar kuyruğunda arşiv var ya da bir işlem (çıkarma, motor denetimi, bekleyen açma) sürüyor.
        var queueBusy = false
        /// Parola sorusu, uyarı ya da başka bir soru ekranda.
        var questionOnScreen = false
        /// Görünen bir pencere var.
        var windowVisible = false
    }

    /// Son istekten sonra kapanmadan önce beklenen süre: Descarcator'ın art arda gönderdiği istekler aynı süreci kullanır.
    static let defaultGracePeriod: Duration = .seconds(4)

    /// Kapanma kararı: yalnızca penceresiz bir istekle başlatılmış, kullanıcının dokunmadığı ve tamamen boşta olan uygulama.
    static func shouldQuit(launch: Launch, activity: Activity) -> Bool {
        launch == .handoffOnly
            && !activity.handoffPending
            && !activity.queueBusy
            && !activity.questionOnScreen
            && !activity.windowVisible
    }

    private(set) var launch: Launch = .undetermined
    let gracePeriod: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activity: () -> Activity
    private let terminate: () -> Void
    /// Bekleme süresi dolunca kararı yeniden veren görev; yeni istek ya da kullanıcı etkileşimi iptal eder.
    private(set) var pendingQuit: Task<Void, Never>?

    /// - Parameters:
    ///   - sleep: Bekleme (gerçekte `Task.sleep`; testler elle ilerletir).
    ///   - activity: O anki model ve pencere durumu.
    ///   - terminate: Uygulamayı kapatır (gerçekte `NSApp.terminate`; testler kaydeder).
    init(
        gracePeriod: Duration = HandoffAutoQuit.defaultGracePeriod,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        activity: @escaping () -> Activity,
        terminate: @escaping () -> Void
    ) {
        self.gracePeriod = gracePeriod
        self.sleep = sleep
        self.activity = activity
        self.terminate = terminate
    }

    /// Açılış bitti. Belgesiz, olağan bir açılış kullanıcınındır; belgeli açılışta karar ilk olaya kalır.
    func launchFinished(isDefaultLaunch: Bool) {
        if isDefaultLaunch { userEngaged(.defaultLaunch) }
    }

    /// Penceresiz bir istek geldi: açılıştan beri ilk olaysa uygulama bu istek için açılmıştır. Bekleyen kapanma iptal edilir.
    func handoffRequested() {
        cancelPendingQuit()
        if launch == .undetermined {
            launch = .handoffOnly
            AppLog.shared.info(.app, "Launched for a background extract request; Arhivar quits when the requests are done")
        }
    }

    /// Kullanıcı uygulamayı kullandı: kalıcı olarak açık kalır.
    func userEngaged(_ engagement: Engagement) {
        cancelPendingQuit()
        guard launch != .user else { return }
        if launch == .handoffOnly {
            AppLog.shared.info(.app, "Background-only launch taken over by the user (\(engagement.rawValue)); Arhivar stays open")
        }
        launch = .user
    }

    /// İstekler bitti ve sonuçları bildirildi: uygulama bu istekler için açıldıysa bekleme sonunda hâlâ boştaysa kapanır.
    func handoffsSettled() {
        cancelPendingQuit()
        guard launch == .handoffOnly else { return }
        pendingQuit = Task { [gracePeriod, sleep] in
            do { try await sleep(gracePeriod) } catch { return }
            guard !Task.isCancelled else { return }
            pendingQuit = nil
            // Bekleme sırasında durum değişmiş olabilir (yeni istek, parola sorusu, açılan pencere): karar yeniden verilir.
            guard Self.shouldQuit(launch: launch, activity: activity()) else { return }
            AppLog.shared.info(.app, "Background extract requests are done; quitting the background-only launch")
            terminate()
        }
    }

    private func cancelPendingQuit() {
        pendingQuit?.cancel()
        pendingQuit = nil
    }
}
