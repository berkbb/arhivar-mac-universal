import AppKit
import ArhivarCore
import Foundation
import Observation

enum EngineStatus: Equatable {
    case checking
    case ready(version: String)
    case missing
    case blocked
}

enum UpdateState: Equatable {
    case idle
    case checking
    case available(latest: String, installed: String?)
    case upToDate(version: String)
    case installing(version: String)
    case installed(version: String)
    case failed(message: String)
}

struct OperationState: Identifiable {
    let id = UUID()
    let titleKey: LKey
    var progress: Double?
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
    let revealURL: URL?
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
}

/// Parola sorulduktan sonra yeniden denenecek işlem.
enum PendingAction {
    case open
    case extract(items: [String], destination: URL?)
    case test
    case openItem(path: String)
    case quickLook(path: String)
    case add(sources: [URL])
    case delete(items: [String])
    case rename(path: String, newName: String)
}

struct PasswordRequest: Identifiable {
    let id = UUID()
    let archive: URL
    let isRetry: Bool
    let action: PendingAction
}

enum BrowserMode: String, CaseIterable, Identifiable {
    case folders
    case tree

    var id: String { rawValue }
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let path: String
    var name: String
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    let items: [String]
}

struct AddRequest: Identifiable {
    let id = UUID()
    let sources: [URL]
}

struct CreateRequest: Identifiable {
    let id = UUID()
    var sources: [URL]
}

enum SidebarItem: Hashable {
    case home
    case recent(URL)
}

/// Uygulamanın tüm durumu ve 7zz işlemleri.
@Observable
final class AppModel {
    static let shared = AppModel(settings: .shared)

    let settings: AppSettings

    var engineStatus: EngineStatus = .checking
    private(set) var engineURL: URL?
    var updateState: UpdateState = .idle

    private(set) var archiveURL: URL?
    private(set) var listing: ArchiveListing?
    private(set) var statistics: ArchiveStatistics?
    private(set) var tree: [ArchiveNode] = [] { didSet { nodeIndex = ArchiveTree.index(tree); rebuildDisplay() } }
    private(set) var displayNodes: [ArchiveNode] = []
    var searchText = "" { didSet { rebuildDisplay() } }
    var currentFolder = "" { didSet { rebuildDisplay() } }
    var browserMode: BrowserMode = .folders {
        didSet {
            defaults.set(browserMode.rawValue, forKey: Self.browserModeKey)
            rebuildDisplay()
        }
    }
    var sortOrder: [KeyPathComparator<ArchiveNode>] = [KeyPathComparator(\.name)] { didSet { rebuildDisplay() } }
    var selection: Set<ArchiveNode.ID> = []

    private(set) var recentArchives: [URL] = []
    private(set) var operation: OperationState?
    var toast: Toast?
    var alert: AlertItem?
    var passwordRequest: PasswordRequest?
    var createRequest: CreateRequest?
    var isDropTargeted = false
    var showInfo = false
    var quickLookURL: URL?
    var renameRequest: RenameRequest?
    var deleteRequest: DeleteRequest?
    var addRequest: AddRequest?
    private(set) var isEditable = false

    @ObservationIgnored private var nodeIndex: [String: ArchiveNode] = [:]
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var headersEncrypted = false
    @ObservationIgnored private var serviceQueue: [URL] = []
    /// Açık arşivin önizleme ve sürükleme dosyaları; arşiv kapanınca ve uygulamadan çıkışta silinir.
    @ObservationIgnored private var sessionRoot: URL?
    @ObservationIgnored private var serviceTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var previewCache: [String: URL] = [:]

    private static let recentsKey = "recentArchives"
    private static let maxRecents = 12
    private static let browserModeKey = "browserMode"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: Self.recentsKey) ?? []
        recentArchives = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        browserMode = BrowserMode(rawValue: defaults.string(forKey: Self.browserModeKey) ?? "") ?? .folders
    }

    var engineVersion: String? {
        if case .ready(let version) = engineStatus { return version }
        return nil
    }

    var canOperate: Bool { listing != nil && operation == nil }

    func node(_ id: ArchiveNode.ID) -> ArchiveNode? { nodeIndex[id] }

    private func t(_ key: LKey) -> String { settings.t(key) }
    private func t(_ key: LKey, _ arguments: any CVarArg...) -> String {
        String(format: settings.t(key), locale: settings.locale, arguments: arguments)
    }

    // MARK: - Açılış ve motor

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        settings.applyAppearance()
        // Önceki çalıştırmalardan (ör. çökme sonrası) kalan geçici klasörleri temizle.
        ItemExtractor.sweepStale(olderThan: 6 * 3600)
        await refreshEngine()
        if settings.checkUpdatesAtLaunch {
            await checkForUpdates(interactive: false)
        }
    }

    func refreshEngine() async {
        engineStatus = .checking
        let fileManager = FileManager.default
        let candidates = EngineLocator.candidates(customPath: settings.customEnginePath)
            .filter { fileManager.isExecutableFile(atPath: $0.path) }
        guard !candidates.isEmpty else {
            engineURL = nil
            engineStatus = .missing
            return
        }
        // Kullanıcının seçtiği 7zz her zaman kullanılır; aksi hâlde bulunanların en yenisi seçilir.
        let custom = settings.customEnginePath.map { URL(fileURLWithPath: $0) }
        let probeList = candidates.first == custom ? [candidates[0]] : candidates
        var probed: [(url: URL, version: String?)] = []
        var blocked = false
        for url in probeList {
            do {
                let result = try await CommandRunner(executableURL: url).run([], timeout: 10)
                probed.append((url, EngineLocator.parseVersion(result.stdout)))
            } catch SevenZipError.timedOut {
                blocked = true
            } catch {
                continue
            }
        }
        if let best = EngineLocator.newest(probed), let version = probed.first(where: { $0.url == best })?.version {
            engineURL = best
            engineStatus = .ready(version: version)
        } else {
            engineURL = probeList.first
            engineStatus = blocked ? .blocked : .missing
        }
    }

    // MARK: - Güncelleme

    private var updater: EngineUpdater? {
        Bundle.main.url(forResource: "update-7zip", withExtension: "sh").map { EngineUpdater(scriptURL: $0) }
    }

    func checkForUpdates(interactive: Bool) async {
        guard let updater, updateState != .checking else { return }
        updateState = .checking
        do {
            let result = try await updater.check()
            let latest = result.latestVersion ?? t(.unknown)
            if result.status == .updateAvailable {
                updateState = .available(latest: latest, installed: result.currentVersion)
                if interactive {
                    alert = AlertItem(
                        title: t(.menuCheckUpdates),
                        message: t(.updateAvailable, latest, result.currentVersion ?? t(.unknown)),
                        actionTitle: t(.updateInstall, latest),
                        action: { [weak self] in Task { await self?.installUpdate() } }
                    )
                }
            } else {
                updateState = .upToDate(version: result.currentVersion ?? engineVersion ?? latest)
                if interactive {
                    alert = AlertItem(title: t(.menuCheckUpdates), message: t(.updateUpToDate, engineVersion ?? latest))
                }
            }
        } catch {
            updateState = .failed(message: message(for: error))
            if interactive { alert = AlertItem(title: t(.updateFailed), message: message(for: error)) }
        }
    }

    func installUpdate() async {
        guard let updater else { return }
        if case .installing = updateState { return }
        let target: String
        if case .available(let latest, _) = updateState { target = latest } else { target = "" }
        updateState = .installing(version: target)
        do {
            let result = try await updater.install()
            await refreshEngine()
            let version = engineVersion ?? result.latestVersion ?? target
            updateState = result.status == .installed ? .installed(version: version) : .upToDate(version: version)
            if result.status == .installed {
                showToast(t(.updateInstalled, version), systemImage: "arrow.down.circle.fill")
            }
        } catch {
            updateState = .failed(message: message(for: error))
            alert = AlertItem(title: t(.updateFailed), message: message(for: error))
        }
    }

    // MARK: - Arşiv açma

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.message = t(.panelOpenArchive)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openArchive(url)
        }
    }

    func openArchive(_ url: URL) {
        loadArchive(url, password: url == archiveURL ? password : nil)
    }

    private func loadArchive(_ url: URL, password candidate: String?) {
        perform(.progressReading, archive: url, retry: .open, usedPassword: candidate != nil) { runner, _ in
            try await self.readListing(of: url, runner: runner, keepFolder: false, password: candidate)
            self.addRecent(url)
        }
    }

    /// Listeyi 7zz'den okur ve görünüm durumunu günceller.
    private func readListing(of url: URL, runner: CommandRunner, keepFolder: Bool, password candidate: String?) async throws {
        let currentPassword = candidate
        let result = try await runner.run(SevenZipCommand.list(archive: url, password: currentPassword))
        try SevenZipError.check(result)
        let listing = ListingParser.parse(result.stdout, fallbackName: ArchiveNaming.streamItemName(for: url))

        // Adlar şifreliyse (7z -mhe) parolasız liste başarısız olur; eklemelerde de korunmalı.
        var encryptedHeaders = false
        if currentPassword != nil, listing.info.type == "7z" {
            let plain = try? await runner.run(SevenZipCommand.list(archive: url))
            encryptedHeaders = plain.map { (try? SevenZipError.check($0)) == nil } ?? false
        }

        let folder = currentFolder
        // Başka bir arşive geçiliyorsa öncekinin geçici dosyalarını sil.
        if url != archiveURL { discardSessionDirectory() }
        archiveURL = url
        password = currentPassword
        self.listing = listing
        statistics = ArchiveStatistics(listing: listing)
        headersEncrypted = encryptedHeaders
        isEditable = ArchiveCapabilities.isEditable(type: listing.info.type, url: url)
        previewCache = [:]
        selection = []
        if !keepFolder { searchText = "" }
        tree = ArchiveTree.build(from: listing.entries)
        currentFolder = keepFolder && node(folder)?.isDirectory == true ? folder : ""
    }

    func closeArchive() {
        archiveURL = nil
        listing = nil
        statistics = nil
        tree = []
        selection = []
        searchText = ""
        currentFolder = ""
        password = nil
        headersEncrypted = false
        isEditable = false
        discardSessionDirectory()
        previewCache = [:]
        quickLookURL = nil
        showInfo = false
    }

    /// Finder'dan "Birlikte Aç" / Dock: arşivler her zaman açılır (açık arşive eklenmez); diğer dosyalar yeni arşiv sayfasına gider.
    func handleOpenRequest(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if let archive = files.first(where: { ArchiveNaming.isArchive($0) && !ArchiveNaming.defaultIsDirectory($0) }) {
            openArchive(archive)
        } else if !files.isEmpty {
            beginCreate(sources: files)
        }
    }

    /// Bırakılan öğeler: düzenlenebilir bir arşiv açıksa eklemeyi önerir; yoksa tek arşiv → aç, diğerleri → yeni arşiv.
    func handleDrop(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if listing != nil, isEditable, operation == nil {
            addRequest = AddRequest(sources: files)
        } else if files.count == 1, let url = files.first, ArchiveNaming.isArchive(url), !ArchiveNaming.defaultIsDirectory(url) {
            openArchive(url)
        } else {
            beginCreate(sources: files)
        }
    }

    // MARK: - Klasör gezinme

    var breadcrumbs: [(name: String, path: String)] { ArchiveTree.breadcrumbs(for: currentFolder) }

    func enterFolder(_ path: String) {
        guard node(path)?.isDirectory == true else { return }
        searchText = ""
        currentFolder = path
        selection = []
    }

    func goUp() {
        guard !currentFolder.isEmpty else { return }
        let previous = currentFolder
        currentFolder = ArchiveTree.parent(of: previous)
        selection = [previous]
    }

    func goTo(_ path: String) {
        searchText = ""
        currentFolder = path
        selection = []
    }

    /// Çift tık / Return: klasöre gir ya da dosyayı aç.
    func primaryAction(_ ids: Set<ArchiveNode.ID>) {
        guard ids.count == 1, let id = ids.first, let node = node(id) else { return }
        if node.isDirectory {
            if browserMode == .folders || !searchText.isEmpty {
                browserMode = .folders
                enterFolder(id)
            }
        } else {
            openItem(id)
        }
    }

    // MARK: - Çıkarma, test, önizleme

    func extract(selectedOnly: Bool) {
        extract(items: selectedOnly ? selection.sorted() : [])
    }

    func extract(items: [String]) {
        guard let archive = archiveURL, operation == nil else { return }
        if needsPassword(for: items) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .extract(items: items, destination: nil))
            return
        }
        guard let destination = chooseExtractDestination(for: archive) else { return }
        runExtract(archive: archive, items: items, destination: destination, password: password)
    }

    private func runExtract(archive: URL, items: [String], destination: URL, password: String?) {
        let options = ExtractOptions(
            archive: archive, destination: destination, items: items,
            password: password, overwrite: settings.overwriteMode
        )
        // Karantina aktarımı için incelenecek kök adlar: seçili öğeler ya da açık arşivin kökleri.
        let roots = !items.isEmpty ? items : (archive == archiveURL ? tree.map(\.id) : [])
        perform(.progressExtracting, archive: archive, retry: .extract(items: items, destination: destination), usedPassword: password != nil) { runner, progress in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let start = Date()
            let result = try await runner.run(SevenZipCommand.extract(options), workingDirectory: options.workingDirectory, onProgress: progress)
            let warning = try SevenZipError.check(result)
            Quarantine.propagate(from: archive, to: destination, roots: roots, since: start)
            self.finish(message: self.t(.toastExtracted, destination.lastPathComponent), reveal: destination, warning: warning)
        }
    }

    func testArchive() {
        guard let archive = archiveURL, operation == nil else { return }
        if needsPassword(for: []) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .test)
            return
        }
        let currentPassword = password
        perform(.progressTesting, archive: archive, retry: .test) { runner, progress in
            let result = try await runner.run(SevenZipCommand.test(archive: archive, password: currentPassword), onProgress: progress)
            let warning = try SevenZipError.check(result)
            if let warning {
                self.alert = AlertItem(title: self.t(.warningTitle), message: warning)
            } else {
                self.showToast(self.t(.toastTestPassed, archive.lastPathComponent), systemImage: "checkmark.seal.fill")
            }
        }
    }

    /// Bir dosyayı geçici klasöre çıkarıp varsayılan uygulamasıyla açar.
    func openItem(_ path: String) {
        guard node(path)?.isDirectory == false else { return }
        withExtractedItem(path, retry: .openItem(path: path)) { url in
            if let reason = self.openRisk(for: url, path: path) {
                // Çalıştırılabilir ya da adı yanıltıcı dosyalar sormadan Terminal'e / Yükleyici'ye verilmez.
                let name = OpenSafety.visibleName((path as NSString).lastPathComponent)
                self.alert = AlertItem(
                    title: self.t(.openRiskyTitle),
                    message: self.t(.openRiskyMessage, name, reason),
                    actionTitle: self.t(.openAnyway),
                    action: { NSWorkspace.shared.open(url) }
                )
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Açmadan önce onay gerektiren bir durum varsa nedenini döndürür.
    func openRisk(for url: URL, path: String) -> String? {
        if OpenSafety.hasDeceptiveCharacters(path) { return t(.deceptiveNameReason) }
        return OpenSafety.executableKind(of: url)
    }

    /// Boşluk tuşu: seçili dosyayı Hızlı Bakış ile önizler; açıksa kapatır.
    func toggleQuickLook(_ path: String? = nil) {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let path = path ?? selection.sorted().first, node(path)?.isDirectory == false else { return }
        withExtractedItem(path, retry: .quickLook(path: path)) { self.quickLookURL = $0 }
    }

    /// Öğeyi (önbellekte yoksa) geçici klasöre çıkarır ve sonucu verir.
    private func withExtractedItem(_ path: String, retry: PendingAction, _ completion: @escaping (URL) -> Void) {
        guard let archive = archiveURL, operation == nil else { return }
        if let cached = previewCache[path], FileManager.default.fileExists(atPath: cached.path) {
            completion(cached)
            return
        }
        if needsPassword(for: [path]) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: retry)
            return
        }
        let currentPassword = password
        perform(.progressExtracting, archive: archive, retry: retry) { runner, progress in
            let extractor = ItemExtractor(runner: runner, archive: archive, password: currentPassword, root: self.sessionDirectory())
            let url = try await extractor.extract(path, onProgress: progress)
            self.previewCache[path] = url
            completion(url)
        }
    }

    /// Açık arşivin geçici klasörü (yalnızca kullanıcıya açık, 0700).
    private func sessionDirectory() -> URL {
        if let sessionRoot { return sessionRoot }
        let fileManager = FileManager.default
        let root = ItemExtractor.temporaryRoot
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sessionRoot = url
        return url
    }

    private func discardSessionDirectory() {
        if let sessionRoot { try? FileManager.default.removeItem(at: sessionRoot) }
        sessionRoot = nil
        previewCache = [:]
        quickLookURL = nil
    }

    /// Uygulamadan çıkarken çağrılır: çözülmüş önizleme dosyaları diskte kalmasın.
    func discardTemporaryFiles() {
        discardSessionDirectory()
    }

    /// Listeden Finder'a sürüklenecek öğe; parola gerekiyorsa ve bilinmiyorsa sürükleme kapalıdır.
    func dragItem(for node: ArchiveNode) -> ArchiveItemTransfer? {
        guard let archive = archiveURL, let engineURL, !needsPassword(for: [node.id]) else { return nil }
        let extractor = ItemExtractor(runner: CommandRunner(executableURL: engineURL), archive: archive, password: password, root: sessionDirectory())
        let name = (node.id as NSString).lastPathComponent
        return ArchiveItemTransfer(extractor: extractor, path: node.id, name: name)
    }

    // MARK: - Arşivi düzenleme

    /// Şifreli girdisi olan bir arşivi düzenlemek için parola gerekir (yeni dosyalar da şifrelensin).
    private var needsPasswordForEdit: Bool {
        password == nil && (statistics?.isEncrypted ?? false)
    }

    func presentAddPanel() {
        guard isEditable else { return }
        let panel = NSOpenPanel()
        panel.prompt = t(.panelAdd)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func confirmAdd() {
        guard let request = addRequest else { return }
        addRequest = nil
        addFiles(request.sources)
    }

    func addFiles(_ sources: [URL]) {
        guard let archive = archiveURL, isEditable, !sources.isEmpty, operation == nil else { return }
        if needsPasswordForEdit {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .add(sources: sources))
            return
        }
        let folder = browserMode == .folders ? currentFolder : ""
        let currentPassword = password
        let encryptHeaders = headersEncrypted
        perform(.progressUpdating, archive: archive, retry: .add(sources: sources)) { runner, progress in
            let plan = try AddPlan.make(sources: sources, into: folder, stagingRoot: ItemExtractor.temporaryRoot)
            defer {
                if let staging = plan.stagingDirectory { try? FileManager.default.removeItem(at: staging) }
            }
            let command = SevenZipCommand.add(archive: archive, names: plan.names, password: currentPassword, encryptHeaders: encryptHeaders)
            let result = try await runner.run(command, workingDirectory: plan.workingDirectory, onProgress: progress)
            let warning = try SevenZipError.check(result)
            try await self.readListing(of: archive, runner: runner, keepFolder: true, password: currentPassword)
            self.finishEdit(warning: warning)
        }
    }

    func requestDelete(_ items: [String]? = nil) {
        let items = items ?? selection.sorted()
        guard isEditable, !items.isEmpty, operation == nil else { return }
        deleteRequest = DeleteRequest(items: items)
    }

    func confirmDelete() {
        guard let request = deleteRequest else { return }
        deleteRequest = nil
        deleteItems(request.items)
    }

    private func deleteItems(_ items: [String]) {
        guard let archive = archiveURL, isEditable, operation == nil else { return }
        if headersEncrypted && password == nil {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .delete(items: items))
            return
        }
        let currentPassword = password
        perform(.progressUpdating, archive: archive, retry: .delete(items: items)) { runner, progress in
            let result = try await runner.run(SevenZipCommand.delete(archive: archive, items: items, password: currentPassword), onProgress: progress)
            let warning = try SevenZipError.check(result)
            try await self.readListing(of: archive, runner: runner, keepFolder: true, password: currentPassword)
            self.finishEdit(warning: warning)
        }
    }

    func requestRename(_ path: String? = nil) {
        let path = path ?? (selection.count == 1 ? selection.first : nil)
        guard isEditable, operation == nil, let path, node(path) != nil else { return }
        renameRequest = RenameRequest(path: path, name: (path as NSString).lastPathComponent)
    }

    func rename(_ path: String, to newName: String) {
        renameRequest = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let archive = archiveURL, isEditable, ArchiveTree.isValidName(name) else { return }
        let newPath = ArchiveTree.renamedPath(path, to: name)
        guard newPath != path else { return }
        if headersEncrypted && password == nil {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .rename(path: path, newName: name))
            return
        }
        let currentPassword = password
        perform(.progressUpdating, archive: archive, retry: .rename(path: path, newName: name)) { runner, _ in
            let result = try await runner.run(SevenZipCommand.rename(archive: archive, from: path, to: newPath, password: currentPassword))
            let warning = try SevenZipError.check(result)
            try await self.readListing(of: archive, runner: runner, keepFolder: true, password: currentPassword)
            self.selection = [newPath]
            self.finishEdit(warning: warning)
        }
    }

    private func finishEdit(warning: String?) {
        if let warning {
            alert = AlertItem(title: t(.warningTitle), message: warning)
        } else {
            showToast(t(.toastUpdated), systemImage: "checkmark.circle.fill")
        }
    }

    // MARK: - Finder servisleri

    /// "Arhivar ile Buraya Çıkar": arşivleri yanlarına (ayarlara göre alt klasöre) sırayla çıkarır.
    /// Açık arşivin parolasına dokunmaz; parola isteyen bir arşivde kuyruk yanıt gelene kadar bekler.
    func extractHere(_ archives: [URL]) {
        serviceQueue += archives.filter { ArchiveNaming.isArchive($0) }
        guard serviceTask == nil, !serviceQueue.isEmpty else { return }
        serviceTask = Task {
            while !serviceQueue.isEmpty {
                let archive = serviceQueue.removeFirst()
                await waitUntilIdle()
                let base = archive.deletingLastPathComponent()
                let destination = settings.extractIntoSubfolder
                    ? base.appendingPathComponent(ArchiveNaming.baseName(of: archive), isDirectory: true)
                    : base
                runExtract(archive: archive, items: [], destination: destination, password: nil)
                // Parola sorulursa, yeniden deneme de bitene kadar sıradakine geçme.
                await waitUntilIdle()
            }
            serviceTask = nil
        }
    }

    /// Kuyruktaki işlerin bitmesini bekler (testler ve sıralı servisler için).
    var serviceQueueTask: Task<Void, Never>? { serviceTask }

    private func waitUntilIdle() async {
        while operation != nil || passwordRequest != nil {
            await operationTask?.value
            if passwordRequest != nil { try? await Task.sleep(for: .milliseconds(150)) }
        }
    }

    private func needsPassword(for items: [String]) -> Bool {
        guard password == nil, let entries = listing?.entries else { return false }
        return entries.contains { entry in
            entry.isEncrypted && (items.isEmpty || items.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") })
        }
    }

    private func chooseExtractDestination(for archive: URL) -> URL? {
        var base: URL?
        switch settings.extractLocation {
        case .nextToArchive:
            base = archive.deletingLastPathComponent()
        case .custom:
            base = settings.customExtractFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        case .ask:
            base = nil
        }
        if base == nil {
            let panel = NSOpenPanel()
            panel.message = t(.panelChooseDestination)
            panel.prompt = t(.panelExtract)
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = archive.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            base = url
        }
        guard let base else { return nil }
        return settings.extractIntoSubfolder
            ? base.appendingPathComponent(ArchiveNaming.baseName(of: archive), isDirectory: true)
            : base
    }

    // MARK: - Oluşturma

    func beginCreate(sources: [URL] = []) {
        createRequest = CreateRequest(sources: sources)
    }

    func createArchive(_ options: CreateOptions) {
        perform(.progressCreating, archive: nil, retry: nil) { runner, progress in
            let result = try await runner.run(SevenZipCommand.create(options), onProgress: progress)
            let warning = try SevenZipError.check(result)
            let exists = FileManager.default.fileExists(atPath: options.destination.path)
            if exists { self.addRecent(options.destination) }
            self.finish(
                message: self.t(.toastCreated, options.destination.lastPathComponent),
                reveal: exists ? options.destination : options.destination.deletingLastPathComponent(),
                warning: warning
            )
        }
    }

    // MARK: - Parola

    func submitPassword(_ value: String) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        // Parola yalnızca açık arşive aitse saklanır; başka bir arşivin işi (ör. Buraya Çıkar) kendi parolasını taşır.
        let isCurrentArchive = request.archive == archiveURL
        if isCurrentArchive { password = value }
        switch request.action {
        case .open:
            loadArchive(request.archive, password: value)
        case .extract(let items, let destination):
            if let destination {
                runExtract(archive: request.archive, items: items, destination: destination, password: value)
            } else if isCurrentArchive {
                extract(items: items)
            }
        case .test:
            testArchive()
        case .openItem(let path):
            openItem(path)
        case .quickLook(let path):
            toggleQuickLook(path)
        case .add(let sources):
            addFiles(sources)
        case .delete(let items):
            deleteItems(items)
        case .rename(let path, let newName):
            rename(path, to: newName)
        }
    }

    func cancelPasswordRequest() {
        passwordRequest = nil
    }

    // MARK: - Ortak işlem altyapısı

    func cancelOperation() {
        currentTask?.cancel()
    }

    /// Süren işlem (varsa); sıralı işlemler bunun bitmesini bekler.
    var operationTask: Task<Void, Never>? { currentTask }

    private func perform(
        _ title: LKey,
        archive: URL?,
        retry: PendingAction?,
        usedPassword: Bool? = nil,
        _ body: @escaping (CommandRunner, @escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        let usedPassword = usedPassword ?? (archive != nil && archive == archiveURL && password != nil)
        guard operation == nil else { return }
        guard let engineURL, engineStatus != .missing else {
            alert = AlertItem(title: t(.engineMissingTitle), message: t(.errorEngineNotFound))
            return
        }
        let runner = CommandRunner(executableURL: engineURL)
        operation = OperationState(titleKey: title, progress: nil)
        currentTask = Task {
            defer {
                operation = nil
                currentTask = nil
            }
            do {
                try await body(runner) { value in
                    Task { @MainActor in self.operation?.progress = value }
                }
            } catch {
                handle(error, archive: archive, retry: retry, usedPassword: usedPassword)
            }
        }
    }

    private func handle(_ error: Error, archive: URL?, retry: PendingAction?, usedPassword: Bool) {
        if let error = error as? SevenZipError {
            switch error {
            case .cancelled:
                return
            case .wrongPassword:
                if let archive, let retry {
                    if archive == archiveURL { password = nil }
                    passwordRequest = PasswordRequest(archive: archive, isRetry: usedPassword, action: retry)
                    return
                }
            default:
                break
            }
        }
        alert = AlertItem(title: t(.errorTitle), message: message(for: error))
    }

    private func message(for error: Error) -> String {
        guard let error = error as? SevenZipError else { return error.localizedDescription }
        switch error {
        case .engineNotFound: return t(.errorEngineNotFound)
        case .timedOut: return t(.errorEngineTimeout)
        case .cancelled: return t(.errorCancelled)
        case .wrongPassword: return t(.errorWrongPassword)
        case .notArchive: return t(.errorNotArchive)
        case .failed(let code, let detail):
            let summary = t(.errorFailed, Int(code))
            return detail.isEmpty ? summary : summary + "\n\n" + detail
        }
    }

    private func finish(message: String, reveal url: URL, warning: String?) {
        if let warning {
            alert = AlertItem(title: t(.warningTitle), message: warning)
        } else {
            showToast(message, systemImage: "checkmark.circle.fill", revealURL: url)
        }
        if settings.revealAfterOperation {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func showToast(_ message: String, systemImage: String, revealURL: URL? = nil) {
        toast = Toast(message: message, systemImage: systemImage, revealURL: revealURL)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Görünüm verisi

    private func rebuildDisplay() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [ArchiveNode]
        if !query.isEmpty {
            source = ArchiveTree.search(tree, query: query)
        } else if browserMode == .folders {
            source = ArchiveTree.contents(of: currentFolder, roots: tree, index: nodeIndex)
        } else {
            source = tree
        }
        displayNodes = ArchiveTree.sorted(source, using: sortOrder)
    }

    // MARK: - Son arşivler ve Finder

    private func addRecent(_ url: URL) {
        recentArchives.removeAll { $0 == url }
        recentArchives.insert(url, at: 0)
        recentArchives = Array(recentArchives.prefix(Self.maxRecents))
        saveRecents()
    }

    func removeRecent(_ url: URL) {
        recentArchives.removeAll { $0 == url }
        saveRecents()
    }

    func clearRecents() {
        recentArchives = []
        saveRecents()
    }

    private func saveRecents() {
        defaults.set(recentArchives.map(\.path), forKey: Self.recentsKey)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealArchive() {
        if let archiveURL { reveal(archiveURL) }
    }

    func openManual() {
        let candidates = [
            EngineLocator.managedEngineDirectory.appendingPathComponent("MANUAL/start.htm"),
            Bundle.main.url(forResource: "start", withExtension: "htm", subdirectory: "Manual"),
        ].compactMap { $0 }
        if let manual = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(manual)
        } else {
            NSWorkspace.shared.open(AppLinks.website)
        }
    }

    func openLicense() {
        let candidates = [
            EngineLocator.managedEngineDirectory.appendingPathComponent("License.txt"),
            Bundle.main.url(forResource: "7-Zip-License", withExtension: "txt"),
        ].compactMap { $0 }
        if let license = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(license)
        } else {
            NSWorkspace.shared.open(AppLinks.license)
        }
    }
}

extension AppModel {
    /// Uygulamayla gelen bir belgeyi (lisans, bildirimler) açar.
    func openBundledDocument(_ name: String, extension ext: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            NSWorkspace.shared.open(url)
        }
    }
}

enum AppLinks {
    static let website = URL(string: "https://www.7-zip.org")!
    static let license = URL(string: "https://www.7-zip.org/license.txt")!
    static let releases = URL(string: "https://github.com/ip7z/7zip/releases")!
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var currentYear: String { String(Calendar.current.component(.year, from: .now)) }
}

enum WindowID {
    static let main = "main"
    static let about = "about"
}
