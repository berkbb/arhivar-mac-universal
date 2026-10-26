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
        await model.searchTask?.value
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

    /// Tablonun sürükleme başlarken her sürüklenen satır için istediği yazıcılar (NSTableView'un yaptığı gibi).
    private func dragWriters(_ outline: NSOutlineView, rows: [Int]) -> [any NSPasteboardWriting] {
        rows.compactMap { row in
            outline.item(atRow: row).flatMap { outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: $0) }
        }
    }

    /// Finder'ın bırakmada yaptığı gibi sürükleme panosundaki dosya URL'lerini okur (öğeler o anda çıkarılır).
    private func droppedFiles(_ writers: [any NSPasteboardWriting]) -> [URL] {
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
        return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// ⌘A ile seçilip masaüstüne sürüklenen satırlar: sürükleme hücrede değil satırdaydı, yalnızca tıklanan satır
    /// taşınabiliyordu; çoklu seçim masaüstüne hiç bırakılamıyor, hücredeki sürükleme hareketi de tıklama, seçim ve
    /// sağ tık menüsünü geciktiriyordu. Seçili her satır Finder'ın tanıdığı bir dosya URL'si vermeli ve hepsi bırakılınca
    /// tek 7zz çalıştırmasıyla çıkarılmalı.
    @Test func selectedRowsDragToFinderTogether() async throws {
        let zip = try makeFinderZip()
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(zip)
        await settle()
        model.primaryAction(["Şirket"])
        model.selectAllCommand()
        await render(window)
        let content = try #require(window.contentView)
        let outline = try #require(table(in: content) as? NSOutlineView)
        #expect(outline.numberOfRows == 3)
        // Satırlar çizilirken sürükleme öğesi (çıkarıcı, geçici klasör) kurulmaz; yalnızca sürükleme başlarken.
        #expect(model.dragItemCount == 0)

        let writers = dragWriters(outline, rows: Array(0..<outline.numberOfRows))
        #expect(writers.count == 3)
        // Öğeler sürükleme başlarken, aynı olay döngüsünde kurulur: bırakılınca tek toplulukta çıkarılmalarının koşulu.
        #expect(model.dragItemCount == 3)
        for writer in writers {
            #expect(writer.writableTypes(for: pasteboard).contains(.fileURL))
        }
        let urls = droppedFiles(writers)
        try #require(urls.count == 3)
        #expect(urls.map(\.lastPathComponent) == ["Dekont1.pdf", "EAR2026.pdf", "Ekran Resmi.png"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "Dekont1.pdf")
        #expect(try String(contentsOf: urls[2], encoding: .utf8) == "Ekran Resmi.png")
        // Tek çıkarma: hepsi aynı geçici klasörde.
        #expect(Set(urls.map { $0.deletingLastPathComponent().deletingLastPathComponent() }).count == 1)

        // Sonraki sürükleme (tek satır) yeni bir çıkarma kurar; önceki topluluğa eklenmez.
        await render(window)
        let single = droppedFiles(dragWriters(outline, rows: [1]))
        #expect(single.map(\.lastPathComponent) == ["EAR2026.pdf"])
        #expect(single.first?.deletingLastPathComponent() != urls[1].deletingLastPathComponent())
        let siblings = try FileManager.default.contentsOfDirectory(atPath: try #require(single.first).deletingLastPathComponent().path)
        #expect(siblings == ["EAR2026.pdf"])
    }

    /// Günlükte iletisi `text` içeren kaydı bekler (en çok 20 sn).
    private func waitForLog(_ text: String) async -> AppLog.Entry? {
        for _ in 0..<400 {
            if let entry = AppLog.shared.entries.last(where: { $0.message.contains(text) }) { return entry }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Word'e resimler tek tek sürüklenince 3-4 bırakmadan sonra sürükleme duruyordu: her bırakmada Word dosyayı istiyor,
    /// SwiftUI isteği ana iş parçacığını durdurarak yanıtlıyor, 7zz ancak o anda çalışıyordu. Çıkarma sürükleme
    /// başlarken başlamalı; art arda tek satırlık sürüklemelerin her birinde dosya bırakmadan önce hazır olmalı ve
    /// bırakma isteği beklemeden yanıtlanmalı. Adımlar günlüğe yazılır.
    @Test func singleRowDragsExtractBeforeEachDrop() async throws {
        let zip = try makeFinderZip()
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(zip)
        await settle()
        model.primaryAction(["Şirket"])
        await render(window)
        let content = try #require(window.contentView)
        let outline = try #require(table(in: content) as? NSOutlineView)
        #expect(outline.numberOfRows == 3)

        var folders: Set<URL> = []
        var numbers: [Int] = []
        for round in 0..<8 {
            let row = round % 3
            let writers = dragWriters(outline, rows: [row])
            #expect(writers.count == 1)
            let batch = try #require(model.lastDragBatch)
            numbers.append(batch.number)
            // Satır eklenince (sonraki olay turunda) çıkarma kendiliğinden başlar ve bırakmadan önce biter.
            let extracted = await waitForLog("Drag #\(batch.number): extracted 1 item(s)")
            #expect(extracted != nil)
            #expect(batch.hasStarted)

            let clock = ContinuousClock.now
            let urls = droppedFiles(writers)
            #expect(ContinuousClock.now - clock < .milliseconds(300))
            try #require(urls.count == 1)
            let name = ["Dekont1.pdf", "EAR2026.pdf", "Ekran Resmi.png"][row]
            #expect(urls[0].lastPathComponent == name)
            #expect(try String(contentsOf: urls[0], encoding: .utf8) == name)
            folders.insert(urls[0].deletingLastPathComponent())
            await render(window)
        }
        // Her sürükleme kendi çıkarmasıdır; hiçbiri hata ya da uyarı bırakmadı.
        #expect(folders.count == 8)
        #expect(Set(numbers).count == 8)
        #expect(model.alert == nil)
        // Başka testler de ortak günlüğe yazar: yalnızca bu sürüklemelerin kayıtlarına bakılır.
        let own = AppLog.shared.entries.filter { entry in numbers.contains { entry.message.hasPrefix("Drag #\($0)") } }
        #expect(own.filter { $0.message.contains("extracting before the drop") }.count == 8)
        #expect(!own.contains { $0.level.isProblem })
    }

    /// Önceden başlayan çıkarma başarısız olursa (ör. arşiv dosyası bu arada silindi) vazgeçilen bir sürükleme uyarı
    /// göstermez; hata günlükte görünür. Öğe bir yere bırakılınca neden söylenir.
    @Test func failedEarlyExtractionAlertsOnlyOnDrop() async throws {
        let zip = try makeFinderZip()
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(zip)
        await settle()
        model.primaryAction(["Şirket"])
        await render(window)
        let content = try #require(window.contentView)
        let outline = try #require(table(in: content) as? NSOutlineView)
        try FileManager.default.removeItem(at: zip)

        let writers = dragWriters(outline, rows: [0])
        let batch = try #require(model.lastDragBatch)
        let failed = await waitForLog("Drag #\(batch.number): extraction")
        #expect(failed?.level == .error)
        await render(window)
        #expect(model.alert == nil)

        // SwiftUI dışa aktarma hata verince boş bir URL bırakır; hiçbir dosya bırakılmaz.
        #expect(droppedFiles(writers).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(AppLog.shared.entries.contains { $0.message == "Drag #\(batch.number): drop target requested the files (1 item(s))" })
        await render(window)
        #expect(model.alert != nil)
        #expect(AppLog.shared.entries.contains { $0.level == .error && $0.message.hasPrefix("Alert shown") })
    }

    /// Klasördeki dosyalardan arşiv kurar (yol → içerik); `links` sembolik bağlantılardır (ad → hedef).
    private func makeArchive(
        _ name: String, files: [String: String], links: [String: String] = [:], password: String? = nil
    ) async throws -> URL {
        let source = workspace.appendingPathComponent("kaynak-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for (path, target) in links {
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent(path).path, withDestinationPath: target)
        }
        let archive = workspace.appendingPathComponent(name)
        let tops = Set(files.keys.map { String($0.split(separator: "/")[0]) }).union(links.keys).sorted()
        let options = CreateOptions(
            sources: tops.map { source.appendingPathComponent($0) }, destination: archive, format: .sevenZip, level: .fast, password: password
        )
        let runner = CommandRunner(executableURL: try #require(engineURL))
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(options), input: options.input))
        return archive
    }

    /// Sürüklenen satırların Finder'a bırakılınca verdiği dosyalar: ad → içerik (klasörse içindeki dosya sayısı).
    private func dropped(_ outline: NSOutlineView, rows: [Int]) throws -> [(name: String, content: String)] {
        try droppedFiles(dragWriters(outline, rows: rows)).map { url in
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            if isDirectory.boolValue {
                let count = FileManager.default.enumerator(atPath: url.path)?.allObjects.count ?? 0
                return (url.lastPathComponent.precomposedStringWithCanonicalMapping, "\(count) öğe")
            }
            return (url.lastPathComponent.precomposedStringWithCanonicalMapping, try String(contentsOf: url, encoding: .utf8))
        }
    }

    /// Ağaç görünümü, açılmış klasörün alt satırları, klasör satırları ve arama sonuçları da Finder'a sürüklenir.
    /// ⌘A içindeki tek başına bir sembolik bağlantı sürüklenmez, kalanlar sürüklenir. Aramada farklı klasörlerdeki aynı
    /// adlı dosyalar birbirine karışmaz.
    @Test func rowsDragToFinderInEveryBrowserMode() async throws {
        let archive = try await makeArchive(
            "kipler.7z",
            files: ["A/oku.txt": "A", "A/alt/derin.txt": "derin", "B/oku.txt": "B", "kök.txt": "kök"],
            links: ["bağ": "kök.txt"]
        )
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .tree
        model.openArchive(archive)
        await settle()
        await render(window)
        let content = try #require(window.contentView)
        let outline = try #require(table(in: content) as? NSOutlineView)
        #expect(model.isSymbolicLink("bağ"))

        // ⌘A (ağaç): bağlantı dışındaki her satır sürüklenir; klasörler içerikleriyle gelir.
        model.selectAllCommand()
        await render(window)
        let rows = Array(0..<outline.numberOfRows)
        #expect(rows.count == 4)
        #expect(dragWriters(outline, rows: rows).count == 3)
        let all = try dropped(outline, rows: rows)
        #expect(Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.content) }) == ["A": "3 öğe", "B": "1 öğe", "kök.txt": "kök"])

        // Açılmış klasörün alt satırları da tek tek sürüklenir.
        await render(window)
        let folderRow = try #require(rows.first { (try? dropped(outline, rows: [$0]).first?.name) == "A" })
        outline.expandItem(outline.item(atRow: folderRow))
        await render(window)
        #expect(outline.numberOfRows == 6)
        let expanded = try (0..<outline.numberOfRows).flatMap { try dropped(outline, rows: [$0]) }
        #expect(expanded.contains { $0.name == "oku.txt" && $0.content == "A" })
        #expect(expanded.contains { $0.name == "alt" && $0.content == "1 öğe" })
        // Klasör ve içindeki bir dosya birlikte (⇧ ile aralık seçimi): ikisi de tek çıkarmayla gelir.
        await render(window)
        let child = try #require(expanded.firstIndex { $0.name == "oku.txt" && $0.content == "A" })
        let parentAndChild = try dropped(outline, rows: [folderRow, child])
        #expect(parentAndChild.map(\.name) == ["A", "oku.txt"])
        #expect(parentAndChild.map(\.content) == ["3 öğe", "A"])

        // Arama: iki ayrı "oku.txt" birlikte sürüklenir, içerikleri karışmaz.
        model.searchText = "oku"
        await settle()
        await render(window)
        #expect(outline.numberOfRows == 2)
        let found = try dropped(outline, rows: [0, 1])
        #expect(found.map(\.name) == ["oku.txt", "oku.txt"])
        #expect(Set(found.map(\.content)) == ["A", "B"])
    }

    /// Parolalı arşivde (parola girildikten sonra) ve iç içe açılmış arşivde de seçili satırlar Finder'a sürüklenir.
    @Test func protectedAndNestedArchivesDragToFinder() async throws {
        let protected = try await makeArchive("gizli.7z", files: ["gizli/bir.txt": "bir", "gizli/iki.txt": "iki"], password: "Parola-1")
        let window = showWindow()
        defer { cleanUp(window) }
        await model.refreshEngine()
        model.browserMode = .folders
        model.openArchive(protected)
        await settle()
        #expect(model.passwordRequest != nil)
        model.submitPassword("Parola-1")
        await settle()
        model.primaryAction(["gizli"])
        model.selectAllCommand()
        await render(window)
        let content = try #require(window.contentView)
        var outline = try #require(table(in: content) as? NSOutlineView)
        let secret = try dropped(outline, rows: [0, 1])
        #expect(secret.map(\.name) == ["bir.txt", "iki.txt"])
        #expect(secret.map(\.content) == ["bir", "iki"])

        // İç içe: dış arşivdeki zip açılır, içindeki dosyalar sürüklenir.
        let zip = try makeFinderZip()
        let outer = workspace.appendingPathComponent("dis.7z")
        let runner = CommandRunner(executableURL: try #require(engineURL))
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(CreateOptions(sources: [zip], destination: outer, format: .sevenZip, level: .fast))))
        model.openArchive(outer)
        await settle()
        model.primaryAction(["Şirket.zip"])
        await settle()
        #expect(model.archiveStack.count == 1)
        model.primaryAction(["Şirket"])
        model.selectAllCommand()
        await render(window)
        outline = try #require(table(in: content) as? NSOutlineView)
        let inner = try dropped(outline, rows: Array(0..<outline.numberOfRows))
        #expect(inner.map(\.name) == ["Dekont1.pdf", "EAR2026.pdf", "Ekran Resmi.png"])
        #expect(inner.map(\.content) == ["Dekont1.pdf", "EAR2026.pdf", "Ekran Resmi.png"])
    }
}
