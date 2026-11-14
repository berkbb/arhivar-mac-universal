// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Testing
@testable import Arhivar

/// Elle ilerletilen bekleme: istenen süreleri kaydeder, `advance()` gelene kadar bekletir (gerçek süre geçmez).
@MainActor
private final class ManualSleep {
    private(set) var requested: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !waiting.isEmpty }

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    func advance() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}

/// Kapanma denetleyicisi; uygulamayı kapatmak yerine çağrıları sayar, durum testte değiştirilir.
@MainActor
private final class Harness {
    let clock = ManualSleep()
    var activity = HandoffAutoQuit.Activity()
    private(set) var terminated = 0
    /// Ana pencere işlemleri: açma ve kapatma sayılır, "istekle öne getirildi" testte değiştirilir.
    private(set) var opened = 0
    private(set) var closed = 0
    var windowRequested = false
    lazy var autoQuit = HandoffAutoQuit(
        sleep: { [clock] in await clock.sleep($0) },
        activity: { [unowned self] in self.activity },
        terminate: { [unowned self] in self.terminated += 1 }
    )

    /// Uygulama temsilcisi; ana pencere işlemleri sayılır, hiçbir pencere açılmaz.
    func makeDelegate() -> AppDelegate {
        AppDelegate(autoQuit: autoQuit, mainWindow: AppDelegate.MainWindowActions(
            open: { [unowned self] in self.opened += 1 },
            wasRequested: { [unowned self] in self.windowRequested },
            close: { [unowned self] in self.closed += 1 }
        ))
    }

    /// Bekleme görevi `sleep`'e ulaşana kadar bekler.
    func waitForSleep() async {
        for _ in 0..<1_000 where !clock.isWaiting { await Task.yield() }
    }

    /// Bekleme süresini doldurur ve kararın verilmesini bekler.
    func elapse() async {
        let task = autoQuit.pendingQuit
        clock.advance()
        await task?.value
    }

    /// Arhivar penceresiz bir istekle açılmış ve istek bitmiş gibi.
    func backgroundLaunchSettled() async {
        autoQuit.handoffRequested()
        autoQuit.launchFinished(isDefaultLaunch: false)
        autoQuit.handoffsSettled()
        await waitForSleep()
    }
}

/// Descarcator madde 506: yalnızca penceresiz istek için açılan Arhivar istekler bitince kendiliğinden kapanır.
@Suite(.serialized)
@MainActor
struct HandoffAutoQuitTests {
    /// Karar: yalnızca istekle açılmış ve tamamen boştaki uygulama kapanır; engellerden biri yeterlidir.
    @Test func quitsOnlyWhenLaunchedForAHandoffAndIdle() {
        let idle = HandoffAutoQuit.Activity()
        #expect(HandoffAutoQuit.shouldQuit(launch: .handoffOnly, activity: idle))
        #expect(!HandoffAutoQuit.shouldQuit(launch: .user, activity: idle), "Arhivar zaten çalışıyordu ya da kullanıldı")
        #expect(!HandoffAutoQuit.shouldQuit(launch: .undetermined, activity: idle))
        let blockers: [(String, WritableKeyPath<HandoffAutoQuit.Activity, Bool>)] = [
            ("sonucu bildirilmemiş istek", \.handoffPending),
            ("kuyrukta ya da süren çıkarma", \.queueBusy),
            ("parola ya da başka bir soru", \.questionOnScreen),
            ("görünen pencere", \.windowVisible),
        ]
        for (name, keyPath) in blockers {
            var activity = idle
            activity[keyPath: keyPath] = true
            #expect(!HandoffAutoQuit.shouldQuit(launch: .handoffOnly, activity: activity), "\(name)")
        }
    }

    /// İstekle açılan uygulama, son istekten sonra bekleme süresi dolmadan kapanmaz; süre dolunca boştaysa kapanır.
    @Test func quitsAfterTheGracePeriod() async {
        let harness = Harness()
        #expect(HandoffAutoQuit.defaultGracePeriod >= .seconds(3) && HandoffAutoQuit.defaultGracePeriod <= .seconds(5))
        await harness.backgroundLaunchSettled()
        #expect(harness.autoQuit.launch == .handoffOnly)
        #expect(harness.clock.requested == [HandoffAutoQuit.defaultGracePeriod])
        #expect(harness.terminated == 0, "bekleme süresi dolmadan kapanmaz")
        await harness.elapse()
        #expect(harness.terminated == 1)
    }

    /// Bekleme sırasında gelen istek aynı süreci kullanır: kapanma iptal edilir, istek bitince yeniden beklenir.
    @Test func aRequestDuringTheGracePeriodReusesTheProcess() async throws {
        let harness = Harness()
        await harness.backgroundLaunchSettled()
        let first = try #require(harness.autoQuit.pendingQuit)
        harness.autoQuit.handoffRequested()
        #expect(harness.autoQuit.pendingQuit == nil)
        harness.clock.advance()
        await first.value
        #expect(harness.terminated == 0)
        #expect(harness.autoQuit.launch == .handoffOnly)

        harness.autoQuit.handoffsSettled()
        await harness.waitForSleep()
        await harness.elapse()
        #expect(harness.terminated == 1)
    }

    /// Bekleme süresi dolduğunda karar yeniden verilir: bu arada bir parola sorusu, yeni bir çıkarma ya da bir pencere
    /// belirdiyse kapanmaz.
    @Test func blockersThatAppearDuringTheGracePeriodKeepArhivarOpen() async {
        let blockers: [WritableKeyPath<HandoffAutoQuit.Activity, Bool>] = [\.handoffPending, \.queueBusy, \.questionOnScreen, \.windowVisible]
        for keyPath in blockers {
            let harness = Harness()
            await harness.backgroundLaunchSettled()
            harness.activity[keyPath: keyPath] = true
            await harness.elapse()
            #expect(harness.terminated == 0)
        }
    }

    /// Kullanıcı uygulamayı kullandıysa (açma, Dock'tan yeniden açma, etkinleştirme, Finder servisi) kalıcı olarak açık kalır;
    /// sonraki istekler de onu kapatmaz.
    @Test func userActivityKeepsArhivarOpen() async {
        for engagement in [HandoffAutoQuit.Engagement.open, .reopen, .activated, .service] {
            // Bekleme sırasında.
            let during = Harness()
            await during.backgroundLaunchSettled()
            let task = during.autoQuit.pendingQuit
            during.autoQuit.userEngaged(engagement)
            during.clock.advance()
            await task?.value
            #expect(during.terminated == 0)
            #expect(during.autoQuit.launch == .user)

            // İstek sürerken; sonraki istek de kararı değiştirmez.
            let before = Harness()
            before.autoQuit.handoffRequested()
            before.autoQuit.userEngaged(engagement)
            before.autoQuit.handoffRequested()
            before.autoQuit.handoffsSettled()
            #expect(before.autoQuit.pendingQuit == nil && before.autoQuit.launch == .user)
        }
    }

    /// Arhivar istek gelmeden önce (olağan açılışla ya da bir açmayla) çalışıyorsa istek bitince kapanmaz.
    @Test func anAlreadyRunningArhivarNeverQuits() {
        let launched = Harness()
        launched.autoQuit.launchFinished(isDefaultLaunch: true)
        launched.autoQuit.handoffRequested()
        launched.autoQuit.handoffsSettled()
        #expect(launched.autoQuit.pendingQuit == nil && launched.autoQuit.launch == .user)

        let opened = Harness()
        opened.autoQuit.userEngaged(.open)
        opened.autoQuit.launchFinished(isDefaultLaunch: false)
        opened.autoQuit.handoffRequested()
        opened.autoQuit.handoffsSettled()
        #expect(opened.autoQuit.pendingQuit == nil && opened.terminated == 0)
    }

    /// Uygulama temsilcisi Dock tıklamasını (yeniden açma) ve etkinleştirmeyi kullanıcı etkileşimi sayar; yeniden açmada
    /// olağan davranış (pencere açma) korunur.
    @Test func appDelegateTreatsReopenAndActivationAsUserActivity() async {
        let reopened = Harness()
        let delegate = reopened.makeDelegate()
        await reopened.backgroundLaunchSettled()
        let task = reopened.autoQuit.pendingQuit
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        reopened.clock.advance()
        await task?.value
        #expect(reopened.terminated == 0 && reopened.autoQuit.launch == .user)
        // SwiftUI ana pencereyi açılışta açmadığından Dock tıklaması onu açar.
        #expect(reopened.opened == 1)

        let activated = Harness()
        let other = activated.makeDelegate()
        activated.autoQuit.handoffRequested()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        #expect(activated.autoQuit.launch == .user)
        withExtendedLifetime(other) {}
    }

    /// Gerçek deneme (Arhivar 1.6.0, yapı 21): istek için başlatılan Arhivar'da ana pencere belirdi ve "görünen pencere"
    /// kapanmayı engelledi. SwiftUI ana pencereyi açılışta artık kendisi açmaz (`defaultLaunchBehavior(.suppressed)`);
    /// temsilci de penceresiz açılışta açmaz, macOS'un geri yüklediği ya da sonradan kendiliğinden beliren pencereyi kapatır.
    /// Bekleme süresi dolunca uygulama kapanır.
    @Test func aBackgroundOnlyLaunchOpensNoMainWindowAndQuits() async {
        let harness = Harness()
        let delegate = harness.makeDelegate()
        // Açılıştaki `odoc`, `applicationDidFinishLaunching`'den önce gelir.
        harness.autoQuit.handoffRequested()
        delegate.launchFinished(isDefaultLaunch: false)
        #expect(harness.opened == 0, "penceresiz açılışta ana pencere açılmaz")
        #expect(harness.closed == 1, "macOS'un geri yüklediği pencere kapatılır")
        delegate.mainWindowAppeared()
        #expect(harness.closed == 2, "sonradan kendiliğinden beliren pencere de kapatılır")

        harness.autoQuit.handoffsSettled()
        await harness.waitForSleep()
        #expect(harness.terminated == 0, "bekleme süresi dolmadan kapanmaz")
        await harness.elapse()
        #expect(harness.terminated == 1)
        #expect(harness.opened == 0)
    }

    /// Penceresiz açılışta parola sorusu için öne getirilen ana pencere kapatılmaz; kapanmayı pencerenin kendisi engeller.
    @Test func aWindowPresentedForAPasswordStaysOpen() async {
        let harness = Harness()
        let delegate = harness.makeDelegate()
        harness.autoQuit.handoffRequested()
        delegate.launchFinished(isDefaultLaunch: false)
        harness.windowRequested = true
        harness.activity.windowVisible = true
        delegate.mainWindowAppeared()
        #expect(harness.closed == 1, "yalnızca açılıştaki denetim; istenen pencereye dokunulmaz")
        harness.autoQuit.handoffsSettled()
        await harness.waitForSleep()
        await harness.elapse()
        #expect(harness.terminated == 0)
    }

    /// Penceresiz açılışta kapanan son pencere (kendiliğinden belirip kapatılan) uygulamayı hemen kapatmaz: süren istek
    /// yarıda kalırdı. Karar bekleme sonunda verilir. Diğer açılışlarda olağan kural: son pencere kapanınca kapanır.
    @Test func theLastWindowClosingQuitsOnlyOutsideABackgroundLaunch() async {
        let background = Harness()
        let delegate = background.makeDelegate()
        background.autoQuit.handoffRequested()
        background.activity.handoffPending = true
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        await background.waitForSleep()
        await background.elapse()
        #expect(background.terminated == 0, "istek sürüyor")
        background.activity.handoffPending = false
        background.autoQuit.handoffsSettled()
        await background.waitForSleep()
        await background.elapse()
        #expect(background.terminated == 1)

        for launch in [true, false] {
            let normal = Harness()
            let other = normal.makeDelegate()
            other.launchFinished(isDefaultLaunch: launch)
            #expect(other.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
            #expect(normal.autoQuit.pendingQuit == nil)
        }
    }

    /// Penceresiz istek için başlatılmayan her açılış ana pencereyi açar: olağan açılış, açma ya da Finder servisiyle açılış
    /// ve geri yüklenen oturum (olağan sayılmaz). Kendiliğinden kapatma yalnızca penceresiz açılışta yapılır.
    @Test func aNormalLaunchStillOpensTheMainWindow() {
        let normal = Harness()
        let delegate = normal.makeDelegate()
        delegate.launchFinished(isDefaultLaunch: true)
        #expect(normal.opened == 1 && normal.closed == 0 && normal.autoQuit.launch == .user)
        delegate.mainWindowAppeared()
        #expect(normal.closed == 0)

        let opened = Harness()
        let openDelegate = opened.makeDelegate()
        opened.autoQuit.userEngaged(.open)
        openDelegate.launchFinished(isDefaultLaunch: false)
        #expect(opened.opened == 1 && opened.closed == 0)

        let restored = Harness()
        let restoredDelegate = restored.makeDelegate()
        restoredDelegate.launchFinished(isDefaultLaunch: false)
        restoredDelegate.mainWindowAppeared()
        #expect(restored.opened == 1 && restored.closed == 0)
        // Dock: görünen pencere varsa olağan davranış, yeni pencere açılmaz.
        #expect(restoredDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        #expect(restored.opened == 1)
        #expect(restoredDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(restored.opened == 2)
    }

    /// Kapanmayı yalnızca kullanıcının pencereleri engeller: ana olabilen pencere, sayfa ve kipli uyarı. Sistemin ve
    /// AppKit'in iç pencereleri (ana olamayan panel) ya da ekranda olmayan pencere engellemez.
    @Test func onlyUserWindowsKeepArhivarOpen() {
        typealias Traits = HandoffAutoQuit.WindowTraits
        #expect(HandoffAutoQuit.isUserWindow(Traits(isVisible: true, canBecomeMain: true)), "Arhivar penceresi")
        #expect(HandoffAutoQuit.isUserWindow(Traits(isVisible: true, isSheet: true)), "parola sayfası")
        #expect(HandoffAutoQuit.isUserWindow(Traits(isVisible: true, isModal: true)), "kipli uyarı")
        #expect(!HandoffAutoQuit.isUserWindow(Traits(isVisible: true)), "iç pencere")
        #expect(!HandoffAutoQuit.isUserWindow(Traits(canBecomeMain: true, isSheet: true, isModal: true)), "ekranda değil")

        // Gerçek pencerelerle.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        for item in [window, panel] { item.isReleasedWhenClosed = false }
        defer { [window, panel].forEach { $0.close() } }
        #expect(!HandoffAutoQuit.showsUserWindow([window, panel], modalWindow: nil), "henüz gösterilmedi")
        panel.orderFrontRegardless()
        #expect(panel.isVisible && !panel.canBecomeMain)
        #expect(!HandoffAutoQuit.showsUserWindow([window, panel], modalWindow: nil), "ana olamayan iç panel")
        #expect(HandoffAutoQuit.showsUserWindow([window, panel], modalWindow: panel), "kipli panel")
        window.orderFrontRegardless()
        #expect(HandoffAutoQuit.showsUserWindow([window, panel], modalWindow: nil))
    }

    @Test func terminationReplyPromptsOnlyForUserLaunchWithActiveOperation() {
        var prompted = false
        let idle = AppDelegate.terminationReply(hasActiveOperation: false, isHandoffOnly: false) {
            prompted = true
            return false
        }
        #expect(idle == .terminateNow)
        #expect(!prompted)

        let handoff = AppDelegate.terminationReply(hasActiveOperation: true, isHandoffOnly: true) {
            prompted = true
            return false
        }
        #expect(handoff == .terminateNow)
        #expect(!prompted)

        let cancelActive = AppDelegate.terminationReply(hasActiveOperation: true, isHandoffOnly: false) {
            prompted = true
            return false
        }
        #expect(cancelActive == .terminateCancel)
        #expect(prompted)

        let confirmActive = AppDelegate.terminationReply(hasActiveOperation: true, isHandoffOnly: false) { true }
        #expect(confirmActive == .terminateNow)
    }
}
