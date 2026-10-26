import AppKit
import SwiftUI
import Testing
@testable import Arhivar
@testable import ArhivarCore

/// Günlük penceresi (Konsol benzeri): kayıtlar tabloda görünür, "Hatalar ve Sorunlar" ve arama süzer, yeni kayıtlar
/// pencere açıkken eklenir, Temizle günlüğü boşaltır. Uygulamanın gösterdiği hatalar günlüğe yazılır.
@Suite(.serialized)
@MainActor
struct LogViewTests {
    let suiteName = "ArhivarLogViewTests-\(UUID().uuidString)"
    let directory: URL
    let defaults: UserDefaults
    let settings: AppSettings

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults, bundle: .main)
    }

    private func cleanUp(_ window: NSWindow?) {
        window?.close()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func render(_ window: NSWindow) async {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews { if let found = table(in: subview) { return found } }
        return nil
    }

    @Test func windowListsFiltersAndClears() async throws {
        let log = AppLog(directory: directory)
        log.info(.app, "Arhivar started")
        log.info(.drag, "Drag #1 started with 1 item(s): extracting before the drop")
        log.warning(.drag, "Drag #1: drop request waited 900 ms for the extraction")
        log.error(.engine, "7zz x: 7zz failed with exit code 2", detail: "ERROR: Ekran Resmi.png")
        let store = LogStore(log: log)
        let window = NSWindow(contentViewController: NSHostingController(rootView: LogView(store: store).environment(settings)))
        window.setContentSize(NSSize(width: 900, height: 520))
        window.makeKeyAndOrderFront(nil)
        defer { cleanUp(window) }
        await render(window)
        let content = try #require(window.contentView)
        let tableView = try #require(table(in: content))
        #expect(tableView.numberOfRows == 4)

        store.scope = .problems
        await render(window)
        #expect(store.visibleEntries.map(\.level) == [.warning, .error])
        #expect(tableView.numberOfRows == 2)

        // Arama özet ve ayrıntıda aranır, büyük/küçük harf duyarsız.
        store.scope = .all
        store.searchText = "ekran resmi"
        await render(window)
        #expect(store.visibleEntries.map(\.category) == [.engine])
        store.searchText = ""

        // Pencere açıkken gelen kayıt (başka bir iş parçacığından) tabloya eklenir.
        await Task.detached { log.error(.drag, "Drag #2: extraction cancelled") }.value
        for _ in 0..<20 where store.entries.count < 5 { await render(window) }
        #expect(store.entries.count == 5)
        #expect(tableView.numberOfRows == 5)
        #expect(store.hasFile)

        store.clear()
        await render(window)
        #expect(store.entries.isEmpty)
        #expect(tableView.numberOfRows == 0)
        #expect(!store.hasFile)
    }

    /// Bozuk bir zip açılınca gösterilen hata günlükte hem teknik türüyle hem de kullanıcının gördüğü uyarı olarak yer
    /// alır; Konsol'a açık giden özet dosya adı içermez.
    @Test func shownErrorsAreLogged() async throws {
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/7-Zip/7zz")
        try #require(FileManager.default.isExecutableFile(atPath: engine.path))
        defer { cleanUp(nil) }
        settings.customEnginePath = engine.path
        settings.updateConsentAsked = true
        let model = AppModel(settings: settings, defaults: defaults)
        await model.refreshEngine()
        #expect(AppLog.shared.entries.contains { $0.category == .engine && $0.message.contains("ready") })

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appendingPathComponent("gizli-rapor.zip")
        try Data("arşiv değil".utf8).write(to: fake)
        let before = AppLog.shared.entries.last?.id ?? -1
        model.openArchive(fake)
        while model.operation != nil { await model.operationTask?.value }
        #expect(model.alert != nil)
        // Başka testler de ortak günlüğe yazar: kayıtlar iletileriyle bulunur.
        let new = AppLog.shared.entries.filter { $0.id > before }
        // 7zz bozuk dosyayı arşiv düzeyinde bir hatayla (çıkış kodu 2) bildirir; ayrıntı (yol içerir) Konsol'da gizlidir.
        let failure = try #require(new.first { $0.category == .archive && $0.level == .error && $0.detail?.contains("gizli-rapor.zip") == true })
        #expect(failure.message == "Operation failed: 7zz failed with exit code 2")
        let alert = try #require(new.first { $0.message.hasPrefix("Alert shown") && $0.detail == model.alert?.message })
        #expect(alert.level == .error)
        #expect(!new.contains { $0.message.contains("gizli-rapor") })
    }
}
