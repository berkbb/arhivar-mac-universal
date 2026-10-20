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
        Window(settings.t(.appName), id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(settings)
                .frame(minWidth: 780, minHeight: 500)
                .task { await model.launch() }
        }
        .defaultSize(width: 1060, height: 700)
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
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = FinderServices()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder sağ tık menüsündeki "Hızlı Eylemler / Servisler" öğeleri.
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        setupSpaceKeyMonitor()
    }

    private func setupSpaceKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Space tuşu: tuş kodu 49, hiçbir değiştirici tuş (Cmd, Shift, Ctrl, Option) basılı olmamalı
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            guard event.keyCode == 49, modifiers.isEmpty else {
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
        AppModel.shared.presentMainWindow()
        AppModel.shared.handleOpenRequest(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.discardTemporaryFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
            Button(settings.t(.menuNewArchive)) {
                openWindow(id: WindowID.main)
                model.beginCreate()
            }
            .keyboardShortcut("n")
            .disabled(model.operation != nil)
            Button(settings.t(.menuOpenArchive)) {
                openWindow(id: WindowID.main)
                model.presentOpenPanel()
            }
            .keyboardShortcut("o")
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
            Button(settings.t(.menuExtractAll)) { model.extract(selectedOnly: false) }
                .keyboardShortcut("e")
                .disabled(!model.canOperate)
            Button(settings.t(.menuExtractSelected)) { model.extract(selectedOnly: true) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canOperate || model.selection.isEmpty)
            Button(settings.t(.menuTestArchive)) { model.testArchive() }
                .keyboardShortcut("t")
                .disabled(!model.canOperate)
            Button(settings.t(.contextQuickLook)) { model.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(!model.canOperate || model.selection.count != 1 || model.selectionIsSymbolicLink)
            // Finder'daki gibi: ⌘↓ seçili klasöre girer ya da dosyayı açar (arşivse içine girer).
            Button(settings.t(.contextOpen)) { model.primaryAction(model.selection) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!model.canOperate || model.selection.count != 1 || model.selectionIsSymbolicLink)
            Button(settings.t(.contextChecksums)) { model.showChecksums() }
                .disabled(
                    !model.canOperate || model.selection.count != 1 || model.selection.first.flatMap(model.node)?.isDirectory != false
                        || model.selectionIsSymbolicLink
                )
            Button(settings.t(.toolbarInfo)) { model.showInfo.toggle() }
                .keyboardShortcut("i")
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
            Button(settings.t(.navUp)) { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp || model.operation != nil)
            Divider()
            Button(settings.t(.menuShowInFinder)) { model.revealArchive() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.archiveURL == nil)
            Button(settings.t(.menuClearRecents)) { model.clearRecents() }
                .disabled(model.recentArchives.isEmpty)
        }

        CommandGroup(before: .toolbar) {
            Button(settings.t(.viewFolders)) { model.browserMode = .folders }
                .keyboardShortcut("1")
            Button(settings.t(.viewTree)) { model.browserMode = .tree }
                .keyboardShortcut("2")
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button(settings.t(.menuManual)) { model.openManual() }
            Button(settings.t(.menuWebsite)) { NSWorkspace.shared.open(AppLinks.website) }
        }
    }
}
