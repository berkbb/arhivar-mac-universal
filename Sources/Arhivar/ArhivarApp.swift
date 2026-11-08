// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ArhivarCore
@preconcurrency import QuickLookUI
import SwiftUI

@main
struct ArhivarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var model = AppModel.shared

    var body: some Scene {
        let _ = settings.customShortcuts
        let _ = settings.quickLookShortcut
        Window(settings.t(.appName), id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(settings)
                .frame(minWidth: 780, minHeight: 500)
                .task { await model.launch() }
                .onAppear { appDelegate.mainWindowAppeared() }
        }
        .defaultSize(width: 1060, height: 700)
        // SwiftUI ana pencereyi açılışta kendisi açmaz: penceresiz bir istek için başlatılan Arhivar pencere göstermez.
        // Diğer her açılışta pencereyi `AppDelegate.launchFinished` açar.
        .defaultLaunchBehavior(.suppressed)
        .commands { AppCommands(model: model, settings: settings) }

        Window(settings.t(.menuAbout), id: WindowID.about) {
            AboutView()
                .environment(model)
                .environment(settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        // Konsol benzeri günlük; Pencere menüsündeki "Günlüğü Göster" (⌥⌘L) ile açılır.
        Window(settings.t(.logTitle), id: WindowID.log) {
            LogView(store: LogStore.shared)
                .environment(settings)
        }
        .defaultSize(width: 960, height: 560)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Ana pencere işlemleri (gerçekte `AppModel` ve `NSApp`; testler sayar).
    struct MainWindowActions {
        /// Ana pencereyi uygulamayı etkinleştirmeden açar (`AppModel.openMainWindow`).
        var open: () -> Void
        /// Ana pencere bu oturumda bir istekle öne getirildi mi (`AppModel.mainWindowRequested`; ör. parola sorusu)?
        var wasRequested: () -> Bool
        /// Ekrandaki pencereleri kapatır (yalnızca penceresiz açılışta, istenmemiş pencere için çağrılır).
        var close: () -> Void
    }

    private let services = FinderServices()
    private var keyMonitor: Any?
    /// Yalnızca penceresiz bir istek için açıldıysa istekler bitince kapanma (Descarcator madde 506).
    let autoQuit: HandoffAutoQuit
    private let mainWindow: MainWindowActions

    override convenience init() {
        let autoQuit = HandoffAutoQuit(
            activity: {
                var activity = AppModel.shared.handoffAutoQuitActivity
                // Yalnızca kullanıcının pencereleri, sayfalar ve kipli uyarılar sayılır; sistemin iç pencereleri değil.
                activity.windowVisible = HandoffAutoQuit.showsUserWindow(NSApp?.windows ?? [], modalWindow: NSApp?.modalWindow)
                return activity
            },
            terminate: { NSApp?.terminate(nil) }
        )
        self.init(
            autoQuit: autoQuit,
            mainWindow: MainWindowActions(
                open: { AppModel.shared.openMainWindow() },
                wasRequested: { AppModel.shared.mainWindowRequested },
                close: {
                    // SwiftUI pencereyi göstermeyi bitirsin; kapatma bir sonraki turda yapılır ve karar yeniden denetlenir.
                    DispatchQueue.main.async {
                        guard autoQuit.launch == .handoffOnly, !AppModel.shared.mainWindowRequested else { return }
                        let windows = (NSApp?.windows ?? []).filter { $0.canBecomeMain && $0.isVisible }
                        guard !windows.isEmpty else { return }
                        AppLog.shared.info(.app, "Closed \(windows.count) window(s) that opened by themselves during a background-only launch")
                        windows.forEach { $0.close() }
                    }
                }
            )
        )
        // Uygulama nesnesi kurulurken bağlanır: istekle açılışta `odoc`, `applicationDidFinishLaunching`'den önce gelir.
        AppModel.shared.onHandoffsSettled = { [autoQuit] in autoQuit.handoffsSettled() }
    }

    init(autoQuit: HandoffAutoQuit, mainWindow: MainWindowActions) {
        self.autoQuit = autoQuit
        self.mainWindow = mainWindow
        super.init()
        services.onUserRequest = { [autoQuit] in autoQuit.userEngaged(.service) }
        // Etkinleştirme bildirimi doğrudan izlenir (SwiftUI'nin temsilci aktarımına bağlı kalmaz): Dock tıklaması, ⌘⇥,
        // menü ya da pencere; kullanıcı uygulamayı kullanıyor.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationActivated(_:)), name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc func applicationActivated(_ notification: Notification) {
        autoQuit.userEngaged(.activated)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belgesiz, olağan açılış kullanıcınındır; istekle (belgeyle) açılışta bu değer false'tur.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        launchFinished(isDefaultLaunch: isDefaultLaunch)
        // Finder sağ tık menüsündeki "Hızlı Eylemler / Servisler" öğeleri.
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        setupSpaceKeyMonitor()
        // Yeni derlemenin ilk açılışında paket Launch Services'a yeniden kaydedilir; Finder belge simgelerini buradan okur.
        FinderIconRefresh.registerIfBuildChanged()
        // Eski paket kimliğinin varsayılan uygulama seçimleri taşınır, Mac'te kalan kayıtları bir kez silinir.
        Task { await LegacyIdentityMigration.run() }
    }

    /// Açılışın sonu (açılıştaki `odoc` gelmiştir). SwiftUI ana pencereyi kendisi açmadığından, penceresiz bir istek için
    /// başlatılmadıysa (olağan açılış, açma, Finder servisi, geri yüklenen oturum) ana pencere burada açılır; açıksa
    /// yalnızca öne gelir. Penceresiz açılışta macOS'un geri yüklediği pencere kapatılır.
    func launchFinished(isDefaultLaunch: Bool) {
        autoQuit.launchFinished(isDefaultLaunch: isDefaultLaunch)
        if autoQuit.launch == .handoffOnly {
            closeUnrequestedWindows()
        } else {
            mainWindow.open()
        }
    }

    /// Ana pencerenin içeriği belirdi. Penceresiz açılışta kimse istemediyse (macOS'un durum geri yüklemesi) kapatılır.
    func mainWindowAppeared() {
        closeUnrequestedWindows()
    }

    private func closeUnrequestedWindows() {
        guard autoQuit.launch == .handoffOnly, !mainWindow.wasRequested() else { return }
        mainWindow.close()
    }

    private func setupSpaceKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Space tuşu: tuş kodu 49, hiçbir değiştirici tuş (Cmd, Shift, Ctrl, Option) basılı olmamalı
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            guard event.keyCode == 49, modifiers.isEmpty else {
                return event
            }

            // Tercih Boşluk tuşuna izin vermiyorsa tuşu işletme
            guard AppSettings.shared.quickLookShortcut.allowsSpace else {
                return event
            }

            // Metin düzenleniyorsa (arama, ad değiştirme, parola vb.) boşluk tuşu metne gitmeli
            if AppModel.isEditingText {
                return event
            }

            let model = AppModel.shared

            // Hızlı Bakış açıksa Space tuşu önizlemeyi kapatır
            if model.quickLookURL != nil {
                model.toggleQuickLook()
                return nil
            }

            // Arşiv açıkken tek bir dosya seçiliyse Hızlı Bakış ile önizlenir
            guard model.listing != nil,
                  model.canOperate,
                  model.selection.count == 1,
                  !model.selectionIsSymbolicLink,
                  let single = model.selection.first,
                  let node = model.node(single),
                  !node.isDirectory else {
                return event
            }

            model.toggleQuickLook(single)
            return nil
        }
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookCoordinator.shared
            panel.delegate = QuickLookCoordinator.shared
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            QuickLookCoordinator.shared.handlePanelDidClose()
        }
    }

    /// Finder'dan "Birlikte Aç" ile gelen arşivler.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Başka bir uygulamanın (Descarcator) penceresiz Buraya Çıkar isteği: `odoc` olayında yalnızca çağıranın
        // ekleyebildiği istek kimliği parametresi vardır (`ExtractHandoff`). Pencere açılmaz; işaretsiz açma bugünkü gibi.
        if let request = ExtractHandoff.request(in: NSAppleEventManager.shared().currentAppleEvent) {
            autoQuit.handoffRequested()
            // İlk istekten önce macOS'un geri yüklediği (ya da açılış sonunda açılan) pencere kullanıcının değildir.
            closeUnrequestedWindows()
            AppModel.shared.extractHereInBackground(request.urls, requestID: request.requestID)
            return
        }
        autoQuit.userEngaged(.open)
        AppModel.shared.presentMainWindow()
        AppModel.shared.handleOpenRequest(urls)
    }

    /// Dock simgesine tıklama: kullanıcı uygulamayı istiyor, penceresiz açılış kapanmaz. Görünen pencere yoksa ana pencere
    /// açılır (SwiftUI açılışta bastırılan sahneyi kendisi açmayabilir); true: olağan davranış (küçültülmüş pencere geri gelir).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        autoQuit.userEngaged(.reopen)
        if !flag { mainWindow.open() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.discardTemporaryFiles()
    }

    /// Son pencere kapanınca uygulama kapanır; penceresiz açılışta kapanma kararı `HandoffAutoQuit`'tedir (süren istek
    /// yarıda kalmaz).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        autoQuit.lastWindowClosed()
    }
}

struct AppCommands: Commands {
    let model: AppModel
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Uygulama Finder servisi ya da "Birlikte Aç" ile başlatıldığında SwiftUI ana pencereyi açmaz.
        // Menü komutları pencere olmadan da kurulduğu için pencere açma eylemi buradan modele verilir.
        let _ = model.registerWindowOpener { [openWindow] in openWindow(id: WindowID.main) }
        CommandGroup(replacing: .appInfo) {
            Button(settings.t(.menuAbout)) { openWindow(id: WindowID.about) }
            Button(settings.t(.menuCheckUpdates)) {
                Task { await model.checkForUpdates(interactive: true) }
            }
            Button(settings.t(.menuCheckAppUpdates)) {
                Task { await model.checkForAppUpdate(interactive: true) }
            }
        }

        CommandGroup(replacing: .newItem) {
            // İşlem sürerken yeni arşiv ve aç kapalıdır: istekleri işlem bitene kadar sessizce yok sayılırdı.
            let newArchive = settings.shortcut(for: .newArchive)
            Button(settings.t(.menuNewArchive)) {
                openWindow(id: WindowID.main)
                model.beginCreate()
            }
            .keyboardShortcut(newArchive.keyEquivalent, modifiers: newArchive.eventModifiers)
            .disabled(model.operation != nil)

            let openArchive = settings.shortcut(for: .openArchive)
            Button(settings.t(.menuOpenArchive)) {
                openWindow(id: WindowID.main)
                model.presentOpenPanel()
            }
            .keyboardShortcut(openArchive.keyEquivalent, modifiers: openArchive.eventModifiers)
            .disabled(model.operation != nil)
            Divider()
            // İşlem sürerken kapatılmaz: işlem bitince listeyi yeniden okuyup arşivi geri getirirdi.
            Button(settings.t(.menuCloseArchive)) { model.closeArchive() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!model.canOperate)
        }

        // ⌘C / ⌘V arşiv tablosunda dosya kopyalar ve ekler; metin alanlarında her zamanki gibi çalışır.
        // Standart grup değiştirildiği için Kes, Yapıştır ve Stili Eşleştir, Tümünü Seç de odaktaki öğeye iletilir.
        CommandGroup(replacing: .pasteboard) {
            Button(settings.t(.editCut)) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button(settings.t(.contextCopy)) { model.copyCommand() }
                .keyboardShortcut("c")
            Button(settings.t(.editPaste)) { model.pasteCommand() }
                .keyboardShortcut("v")
            Button(settings.t(.editPasteMatchStyle)) { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Button(settings.t(.editSelectAll)) { model.selectAllCommand() }
                .keyboardShortcut("a")
        }

        CommandMenu(settings.t(.menuArchive)) {
            let extract = settings.shortcut(for: .extract)
            Button(settings.t(.menuExtractAll)) { model.extract(selectedOnly: false) }
                .keyboardShortcut(extract.keyEquivalent, modifiers: extract.eventModifiers)
                .disabled(!model.canOperate)

            let extractSel = settings.shortcut(for: .extractSelected)
            Button(settings.t(.menuExtractSelected)) { model.extract(selectedOnly: true) }
                .keyboardShortcut(extractSel.keyEquivalent, modifiers: extractSel.eventModifiers)
                .disabled(!model.canOperate || model.selection.isEmpty)

            let test = settings.shortcut(for: .test)
            Button(settings.t(.menuTestArchive)) { model.testArchive() }
                .keyboardShortcut(test.keyEquivalent, modifiers: test.eventModifiers)
                .disabled(!model.canOperate)

            if settings.quickLookShortcut.allowsCmdY {
                Button(settings.t(.contextQuickLook)) { model.toggleQuickLook() }
                    .keyboardShortcut("y")
                    .disabled(!model.canOperate || model.selection.count != 1 || model.selectionIsSymbolicLink)
            } else {
                Button(settings.t(.contextQuickLook)) { model.toggleQuickLook() }
                    .disabled(!model.canOperate || model.selection.count != 1 || model.selectionIsSymbolicLink)
            }
            // Finder'daki gibi: seçili klasöre girer ya da dosyayı açar (arşivse içine girer).
            let open = settings.shortcut(for: .open)
            Button(settings.t(.contextOpen)) { model.primaryAction(model.selection) }
                .keyboardShortcut(open.keyEquivalent, modifiers: open.eventModifiers)
                .disabled(!model.canOperate || model.selection.count != 1 || model.selectionIsSymbolicLink)
            Button(settings.t(.contextChecksums)) { model.showChecksums() }
                .disabled(
                    !model.canOperate || model.selection.count != 1 || model.selection.first.flatMap(model.node)?.isDirectory != false
                        || model.selectionIsSymbolicLink
                )
            let info = settings.shortcut(for: .info)
            Button(settings.t(.toolbarInfo)) { model.showInfo.toggle() }
                .keyboardShortcut(info.keyEquivalent, modifiers: info.eventModifiers)
                .disabled(model.listing == nil)
            Divider()
            Button(settings.t(.editAddFiles)) { model.presentAddPanel() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!model.canOperate || !model.isEditable)
            Button(settings.t(.editRename)) { model.requestRename() }
                .disabled(!model.canOperate || !model.isEditable || model.selection.count != 1)
            Button(settings.t(.editDelete)) { model.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canOperate || !model.isEditable || model.selection.isEmpty)
            Divider()
            let parent = settings.shortcut(for: .parent)
            Button(settings.t(.navUp)) { model.goUp() }
                .keyboardShortcut(parent.keyEquivalent, modifiers: parent.eventModifiers)
                .disabled(!model.canGoUp || model.operation != nil)
            Divider()
            Button(settings.t(.menuShowInFinder)) { model.revealArchive() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.archiveURL == nil)
            let clearRecents = settings.shortcut(for: .clearRecents)
            Button(settings.t(.menuClearRecents)) { model.clearRecents() }
                .keyboardShortcut(clearRecents.keyEquivalent, modifiers: clearRecents.eventModifiers)
                .disabled(model.recentArchives.isEmpty)
        }

        CommandGroup(before: .toolbar) {
            Button(settings.t(.viewFolders)) { model.browserMode = .folders }
                .keyboardShortcut("1")
            Button(settings.t(.viewTree)) { model.browserMode = .tree }
                .keyboardShortcut("2")
            Divider()
        }

        CommandGroup(before: .windowList) {
            Button(settings.t(.menuShowLog)) { openWindow(id: WindowID.log) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button(settings.t(.menuManual)) { model.openManual() }
            Button(settings.t(.menuWebsite)) { NSWorkspace.shared.open(AppLinks.website) }
        }
    }
}
