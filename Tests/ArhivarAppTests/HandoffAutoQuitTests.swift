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
    lazy var autoQuit = HandoffAutoQuit(
        sleep: { [clock] in await clock.sleep($0) },
        activity: { [unowned self] in self.activity },
        terminate: { [unowned self] in self.terminated += 1 }
    )

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
        let delegate = AppDelegate(autoQuit: reopened.autoQuit)
        await reopened.backgroundLaunchSettled()
        let task = reopened.autoQuit.pendingQuit
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        reopened.clock.advance()
        await task?.value
        #expect(reopened.terminated == 0 && reopened.autoQuit.launch == .user)

        let activated = Harness()
        let other = AppDelegate(autoQuit: activated.autoQuit)
        activated.autoQuit.handoffRequested()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        #expect(activated.autoQuit.launch == .user)
        withExtendedLifetime(other) {}
    }
}
