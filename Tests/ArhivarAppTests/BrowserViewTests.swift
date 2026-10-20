import AppKit
import SwiftUI
import Testing
@testable import Arhivar
@testable import ArhivarCore

private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appendingPathComponent("Vendor/7-Zip/7zz")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

/// Arayüzü ekran dışı gerçek bir pencerede çalıştırır: SwiftUI görünüm güncellemeleri (tablo satırları, yol çubuğu)
/// model testlerinin yakalayamadığı çökmeleri gösterir.
@Suite(.enabled(if: engineURL != nil, "7zz bulunamadı"), .serialized)
@MainActor
struct BrowserViewTests {
    let suiteName = "ArhivarBrowserTests-\(UUID().uuidString)"
    let workspace: URL
    let defaults: UserDefaults
    let settings: AppSettings
    let model: AppModel
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ArhivarBrowserTests-\(UUID().uuidString)"))

    init() throws {
        _ = NSApplication.shared
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults, bundle: .main)
        settings.customEnginePath = engineURL?.path
        settings.updateConsentAsked = true
        settings.revealAfterOperation = false
        model = AppModel(settings: settings, defaults: defaults)
    }

    private func cleanUp(_ window: NSWindow?) {
        window?.close()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: workspace)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Finder'ın "Sıkıştır" komutu gibi: kök klasör ve __MACOSX içeren bir zip.
    private func makeFinderZip() throws -> URL {
        let folder = workspace.appendingPathComponent("Şirket", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Dekont1.pdf", "EAR2026.pdf", "Ekran Resmi.png"] {
            let file = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
        }
        let macFolder = workspace.appendingPathComponent("__MACOSX", isDirectory: true)
            .appendingPathComponent("Şirket", isDirectory: true)
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
        try Data("._Dekont1".utf8).write(to: macFolder.appendingPathComponent("._Dekont1.pdf"))

        let zip = workspace.appendingPathComponent("Şirket.zip")
        let proc = Process()
        proc.executableURL = engineURL
        proc.currentDirectoryURL = workspace
        proc.arguments = ["a", "Şirket.zip", "Şirket", "__MACOSX", "-tzip", "-mx1", "-y"]
        try proc.run()
        proc.waitUntilExit()
        return zip
    }

    private func showWindow() -> NSWindow {
        let host = NSHostingController(rootView: ContentView().environment(model).environment(settings))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func render(_ window: NSWindow) async {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle() async {
        while model.operation != nil { await model.operationTask?.value }
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, !(table is NSOutlineView && table.numberOfColumns == 1) { return table }
        for subview in view.subviews { if let found = table(in: subview) { return found } }
        return nil
    }

    /// Klasörden yol çubuğuyla ya da ⌘↑ ile köke dönünce yeniden eklenen satırlar ortam nesnesi bulamayıp
    /// "No Observable object of type AppModel found" ile çöküyordu.
    @Test func returningToRootDoesNotCrash() async throws {
        let zip = try makeFinderZip()
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(zip)
        await settle()
        await render(window)
        #expect(model.displayNodes.map { $0.id.precomposedStringWithCanonicalMapping } == ["__MACOSX", "Şirket"])

        for back in [{ model.goTo("") }, { model.goUp() }] {
            model.primaryAction(["Şirket"])
            await render(window)
            #expect(model.currentFolder.precomposedStringWithCanonicalMapping == "Şirket")
            back()
            await render(window)
            #expect(model.currentFolder == "")
            #expect(model.displayNodes.map { $0.id.precomposedStringWithCanonicalMapping } == ["__MACOSX", "Şirket"])
        }

        // Ağaç görünümüne geçiş ve geri dönüş de satırları yeniden kurar.
        model.browserMode = .tree
        await render(window)
        model.browserMode = .folders
        await render(window)
        #expect(model.displayNodes.count == 2)
    }

    /// İç içe arşivden üstteki arşive dönüş de satırları baştan kurar.
    @Test func returningFromNestedArchiveDoesNotCrash() async throws {
        let zip = try makeFinderZip()
        let outer = workspace.appendingPathComponent("dis.7z")
        let runner = CommandRunner(executableURL: try #require(engineURL))
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(sources: [zip], destination: outer, format: .sevenZip, level: .fast))))
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(outer)
        await settle()
        await render(window)

        model.primaryAction(["Şirket.zip"])
        await settle()
        await render(window)
        #expect(model.archiveStack.count == 1)
        model.primaryAction(["Şirket"])
        await render(window)
        model.returnToArchive(level: 0)
        await render(window)
        #expect(model.archiveURL == outer)
        #expect(model.displayNodes.map(\.id) == ["Şirket.zip"])
    }

    /// ⌘C: tablo odaktayken seçili öğeler dosya olarak panoya gider; ⌘V panodaki dosyaları eklemeyi önerir.
    @Test func editMenuCopiesAndPastesFiles() async throws {
        let zip = try makeFinderZip()
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(zip)
        await settle()
        model.primaryAction(["Şirket"])
        model.selection = ["Şirket/Dekont1.pdf", "Şirket/EAR2026.pdf"]
        await render(window)
        if let table = table(in: try #require(window.contentView)) { window.makeFirstResponder(table) }
        #expect(!AppModel.isEditingText)

        pasteboard.clearContents()
        model.copyCommand(pasteboard: pasteboard)
        await settle()
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls.map(\.lastPathComponent) == ["Dekont1.pdf", "EAR2026.pdf"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "Dekont1.pdf")

        // Metin düzenlenirken arşiv öğeleri kopyalanmaz (komut metne gider).
        pasteboard.clearContents()
        model.copyCommand(editingText: true, pasteboard: pasteboard)
        await settle()
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)

        // Yapıştır: panodaki dosyalar onay sorularak eklenir; metin düzenlenirken eklenmez.
        let extra = workspace.appendingPathComponent("ek.txt")
        try Data("ek".utf8).write(to: extra)
        pasteboard.clearContents()
        pasteboard.writeObjects([extra as NSURL])
        model.pasteCommand(editingText: true, pasteboard: pasteboard)
        #expect(model.addRequest == nil)
        model.pasteCommand(pasteboard: pasteboard)
        #expect(model.addRequest?.sources == [extra])
    }

    /// ⌘A: `selectAll:` tabloya ulaşmadığı için menü komutu seçimi modelden kurar.
    @Test func editMenuSelectsAllItems() async throws {
        let zip = try makeFinderZip()
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(zip)
        await settle()
        model.primaryAction(["Şirket"])
        await render(window)
        if let table = table(in: try #require(window.contentView)) { window.makeFirstResponder(table) }

        model.selectAllCommand()
        await render(window)
        #expect(model.selection == ["Şirket/Dekont1.pdf", "Şirket/EAR2026.pdf", "Şirket/Ekran Resmi.png"])

        // Metin düzenlenirken seçim değişmez (komut metne gider); aramada yalnızca sonuçlar seçilir.
        model.selection = []
        model.selectAllCommand(editingText: true)
        #expect(model.selection.isEmpty)
        model.searchText = "pdf"
        await render(window)
        model.selectAllCommand()
        // Sonuçlar __MACOSX içindeki AppleDouble kopyalarını ("._Dekont1.pdf") da içerebilir.
        #expect(model.selection == Set(model.displayNodes.map(\.id)))
        #expect(model.selection.isSuperset(of: ["Şirket/Dekont1.pdf", "Şirket/EAR2026.pdf"]))
        #expect(!model.selection.contains("Şirket/Ekran Resmi.png"))
    }
}
