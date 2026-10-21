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
    /// Vazgeç'e basıldı; 7zz duruyor ve yarım dosyalar siliniyor (büyük çıkarmada birkaç saniye sürebilir).
    var isCancelling = false
}

/// Biten işlemin sonucu: ilerleme penceresi başarıda tamamlanmış görünüp kısa bir an bekler, iptal ve hatada hemen kapanır.
enum OperationOutcome: Equatable {
    case succeeded
    case cancelled
    case failed
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
    /// Vazgeç düğmesinin başlığı ve eylemi (varsayılan: "Vazgeç", eylemsiz).
    var cancelTitle: String?
    var cancelAction: (() -> Void)?
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case available(AppRelease)
    case upToDate
    case failed(message: String)
}

/// Parola sorulduktan sonra yeniden denenecek işlem.
enum PendingAction {
    case open
    /// `destination`: alt klasör kuralı uygulanmadan önceki hedef; `stripping`: hedefe yazılırken atılacak iç klasör yolu.
    case extract(items: [String], destination: URL?, stripping: String)
    case test
    case openItem(path: String)
    case quickLook(path: String)
    case add(sources: [URL], folder: String?)
    case delete(items: [String])
    case rename(path: String, newName: String)
    /// Arşiv içindeki bir arşive girmek için önce öğenin çıkarılması (açık arşivin parolası).
    case browse(path: String)
    /// İç içe açılan arşivin kendi parolası.
    case openNested
    case copy(items: [String])
    case checksums(path: String)
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
    /// Eklenecek arşiv klasörü (ör. yol çubuğundaki bir klasöre bırakıldıysa); nil ise o anki klasör.
    var folder: String?
}

/// İç içe açılan bir arşivin üstündeki (geri dönülecek) arşivin durumu.
struct ArchiveContext {
    let url: URL
    let password: String?
    let listing: ArchiveListing
    let headersEncrypted: Bool
    let isEditable: Bool
    let sessionRoot: URL?
    let previewCache: [String: URL]
    let currentFolder: String
    let selection: Set<String>
    let tree: [ArchiveNode]
    let nodeIndex: [String: ArchiveNode]
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
    /// Arhivar'ın kendi güncelleme durumu (GitHub Releases).
    var appUpdateState: AppUpdateState = .idle

    private(set) var archiveURL: URL?
    private(set) var listing: ArchiveListing?
    private(set) var statistics: ArchiveStatistics?
    private(set) var tree: [ArchiveNode] = []
    private(set) var displayNodes: [ArchiveNode] = []
    /// 1.000+ öğeli büyük arşivlerde arka plan araması sürerken true olur.
    private(set) var isSearching = false
    var searchText = "" { didSet { rebuildDisplay() } }
    var currentFolder = "" { didSet { rebuildDisplay() } }
    var browserMode: BrowserMode = .folders {
        didSet {
            defaults.set(browserMode.rawValue, forKey: Self.browserModeKey)
            rebuildDisplay()
        }
    }
    var sortOrder: [KeyPathComparator<ArchiveNode>] = [ArchiveTree.nameComparator] { didSet { rebuildDisplay() } }
    var selection: Set<ArchiveNode.ID> = [] {
        didSet {
            guard selection != oldValue else { return }
            if quickLookURL != nil,
               selection.count == 1,
               let single = selection.first,
               let node = node(single),
               !node.isDirectory,
               !isSymbolicLink(single) {
                toggleQuickLook(single)
            }
        }
    }

    private(set) var recentArchives: [URL] = []
    private(set) var operation: OperationState?
    /// Son biten işlemin sonucu; `operation` nil olmadan önce yazılır.
    private(set) var lastOperationOutcome: OperationOutcome?
    var toast: Toast?
    var alert: AlertItem? { didSet { if alert == nil { schedulePendingConsent() } } }
    var passwordRequest: PasswordRequest? { didSet { if passwordRequest == nil { schedulePendingConsent() } } }
    var createRequest: CreateRequest?
    var isDropTargeted = false
    var showInfo = false
    var quickLookURL: URL? {
        didSet {
            guard quickLookURL != oldValue else { return }
            if let url = quickLookURL {
                QuickLookCoordinator.shared.show(url: url) { [weak self] in
                    self?.quickLookURL = nil
                }
            } else {
                QuickLookCoordinator.shared.close()
            }
        }
    }
    var renameRequest: RenameRequest?
    var deleteRequest: DeleteRequest?
    var addRequest: AddRequest?
    private(set) var isEditable = false
    /// İç içe açılan arşivlerde üstteki arşivler (en dıştaki ilk sırada); boşsa açık arşiv en üst düzeydedir.
    private(set) var archiveStack: [ArchiveContext] = []

    @ObservationIgnored private var nodeIndex: [String: ArchiveNode] = [:]
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var headersEncrypted = false
    @ObservationIgnored private var serviceQueue: [URL] = []
    /// Bir işlem sürerken istenen son arşiv (ör. Finder'dan art arda açma); işlem bitince açılır.
    @ObservationIgnored private var pendingOpen: URL?
    @ObservationIgnored private var pendingOpenTask: Task<Void, Never>?
    /// Açık arşivin önizleme ve sürükleme dosyaları; arşiv kapanınca ve uygulamadan çıkışta silinir.
    @ObservationIgnored private var sessionRoot: URL?
    @ObservationIgnored private var serviceTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var previewCache: [String: URL] = [:]
    /// Güncelleme izni, açılışta başka bir işlem ya da uyarı varken sorulamadıysa sonra sorulur.
    @ObservationIgnored private var consentPending = false
    /// Açık arşivdeki sembolik bağlantı girdilerinin yolları (bkz. `ItemExtractor.symbolicLinks`).
    @ObservationIgnored private var symbolicLinks: Set<String> = []
    /// Açık arşivdeki sabit bağlantı girdilerinin yolları (bkz. `ItemExtractor.hardLinks`).
    @ObservationIgnored private var hardLinks: Set<String> = []
    /// Birden çok görünüm durumu birlikte değişirken tablo verisi her adımda değil, sonunda bir kez hesaplanır.
    @ObservationIgnored private var displayUpdatesPaused = false
    /// Tablo verisinin kaç kez yeniden hesaplandığı (testler için).
    @ObservationIgnored private(set) var displayRebuildCount = 0

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

    /// Arşiv neden düzenlenemiyor: biçim (rar, gz, bölünmüş, iç içe) ya da konum (salt okunur, kilitli, salt okunur disk).
    var readOnlyReason: LKey {
        guard let archiveURL, archiveStack.isEmpty,
              ArchiveCapabilities.supportsEditing(type: listing?.info.type, url: archiveURL, volumes: listing?.info.volumes),
              !ArchiveCapabilities.isWritable(archiveURL) else { return .readOnlyArchive }
        return .readOnlyLocation
    }

    func node(_ id: ArchiveNode.ID) -> ArchiveNode? { nodeIndex[id] }

    /// Görünümdeki (normalleştirilmiş) kimliğin 7zz'nin tanıdığı ham yolu ("./a/b" gibi arşivler için).
    func archivePath(for id: ArchiveNode.ID) -> String { node(id)?.archivePath ?? id }

    /// İç içe gezinmede en dıştaki (diskteki gerçek) arşiv; değilse açık arşivin kendisi.
    var rootArchiveURL: URL? { archiveStack.first?.url ?? archiveURL }

    /// Bilgi panelindeki konum: iç içe arşivde "dış.zip › iç.tar".
    var locationDescription: String? {
        guard let archiveURL else { return nil }
        guard let root = archiveStack.first?.url else { return archiveURL.deletingLastPathComponent().path }
        let chain = archiveStack.dropFirst().map(\.url.lastPathComponent) + [archiveURL.lastPathComponent]
        return ([root.path] + chain).joined(separator: " › ")
    }

    private func t(_ key: LKey) -> String { settings.t(key) }
    private func t(_ key: LKey, _ arguments: any CVarArg...) -> String {
        String(format: settings.t(key), locale: settings.locale, arguments: arguments)
    }

    // MARK: - Pencere

    @ObservationIgnored private var openMainWindowAction: (() -> Void)?

    func registerWindowOpener(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    /// Ana pencereyi açar (kapalıysa ya da hiç açılmadıysa) ve öne getirir.
    /// Finder servisleri ve "Birlikte Aç" uygulamayı penceresiz başlatabilir; işlem göstergesinin görünmesi için gerekir.
    func presentMainWindow(attempt: Int = 0) {
        NSApp?.activate()
        guard let openMainWindowAction else {
            // Menü komutları henüz kurulmadıysa (çok erken soğuk açılış) kısa bir süre sonra yeniden dene.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.presentMainWindow(attempt: attempt + 1) }
            }
            return
        }
        openMainWindowAction()
        // Etkinleştirme reddedilse bile pencere öne gelsin.
        DispatchQueue.main.async {
            (NSApp?.windows ?? [])
                .filter { $0.canBecomeMain && $0.isVisible }
                .forEach { $0.orderFrontRegardless() }
        }
    }

    // MARK: - Açılış ve motor

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        settings.applyAppearance()
        // Önceki çalıştırmalardan (ör. çökme sonrası) kalan geçici klasörleri temizle.
        ItemExtractor.sweepStale(olderThan: 6 * 3600)
        await refreshEngine()
        if !settings.updateConsentAsked {
            // "Birlikte Aç" ile soğuk açılışta arşivin uyarısı ya da parola isteğiyle çakışmasın; boşta kalınca sorulur.
            consentPending = true
            presentPendingConsentIfIdle()
        } else if settings.checkUpdatesAtLaunch {
            await checkForUpdates(interactive: false)
            await checkForAppUpdate(interactive: false)
        }
    }

    /// Bekleyen izin sorusunu, ekranda başka bir işlem, uyarı ya da sayfa yoksa gösterir.
    private func presentPendingConsentIfIdle() {
        guard consentPending, operation == nil, passwordRequest == nil, alert == nil, createRequest == nil else { return }
        consentPending = false
        askUpdateConsent()
    }

    /// Bir uyarı ya da sayfa kapanırken yenisi aynı anda gösterilemez; bir sonraki turda dener.
    private func schedulePendingConsent() {
        guard consentPending else { return }
        Task { @MainActor in self.presentPendingConsentIfIdle() }
    }

    /// İlk açılışta, GitHub'a bağlanmadan önce bir kez izin ister.
    private func askUpdateConsent() {
        alert = AlertItem(
            title: t(.consentTitle),
            message: t(.consentMessage),
            actionTitle: t(.consentAllow),
            action: { [weak self] in self?.respondToUpdateConsent(true) },
            cancelTitle: t(.consentDeny),
            cancelAction: { [weak self] in self?.respondToUpdateConsent(false) }
        )
    }

    func respondToUpdateConsent(_ allow: Bool) {
        settings.updateConsentAsked = true
        settings.checkUpdatesAtLaunch = allow
        guard allow else { return }
        Task {
            await checkForUpdates(interactive: false)
            await checkForAppUpdate(interactive: false)
        }
    }

    // MARK: - Arhivar güncellemesi

    func checkForAppUpdate(interactive: Bool) async {
        guard appUpdateState != .checking else { return }
        appUpdateState = .checking
        do {
            let release = try await AppUpdateChecker.latest(repository: AppInfo.repository)
            if AppUpdateChecker.isNewer(release.version, than: AppInfo.version) {
                appUpdateState = .available(release)
                if interactive {
                    alert = AlertItem(
                        title: t(.menuCheckAppUpdates),
                        message: t(.appUpdateAvailable, release.version, AppInfo.version),
                        actionTitle: t(.appUpdateDownload),
                        action: { [weak self] in self?.openAppDownload() }
                    )
                }
            } else {
                appUpdateState = .upToDate
                if interactive { alert = AlertItem(title: t(.menuCheckAppUpdates), message: t(.appUpdateUpToDate, AppInfo.version)) }
            }
        } catch {
            let message = (error as? AppUpdateChecker.CheckError) == .noReleases ? t(.appUpdateNoReleases) : error.localizedDescription
            appUpdateState = .failed(message: message)
            if interactive { alert = AlertItem(title: t(.updateFailed), message: message) }
        }
    }

    /// Ad-hoc imzalı uygulama kendini kurmaz; indirme bağlantısı (yoksa sürüm sayfası) tarayıcıda açılır.
    func openAppDownload() {
        guard case .available(let release) = appUpdateState else {
            NSWorkspace.shared.open(AppLinks.releases)
            return
        }
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    /// Motor en az bir kez denetlendi mi? Finder servisleri ve "Birlikte Aç" uygulama açılırken hemen gelebilir.
    @ObservationIgnored private var engineChecked = false
    @ObservationIgnored private var engineProbe: Task<Void, Never>?

    /// Motor henüz denetlenmediyse denetler; süren bir denetim varsa onu bekler.
    func ensureEngine() async {
        if engineChecked { return }
        if let engineProbe {
            await engineProbe.value
            return
        }
        await refreshEngine()
    }

    func refreshEngine() async {
        if let engineProbe {
            await engineProbe.value
            return
        }
        let probe = Task { await self.probeEngine() }
        engineProbe = probe
        await probe.value
        engineProbe = nil
        engineChecked = true
    }

    private func probeEngine() async {
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
        // Kullanılan 7zz'nin sürümü betiğe verilir: paket yazılamadığında betik henüz boş olan yedek klasöre bakıp
        // "kurulu değil" sanmasın. Kullanıcının seçtiği 7zz güncellenmediği için onun sürümü verilmez.
        let current = settings.customEnginePath == nil ? engineVersion : nil
        return Bundle.main.url(forResource: "update-7zip", withExtension: "sh").map { EngineUpdater(scriptURL: $0, currentVersion: current) }
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

    /// ⌘O. İşlem sürerken seçilen arşiv açılamazdı (işlem bitene kadar yok sayılırdı); panel hiç açılmaz.
    func presentOpenPanel() {
        guard operation == nil else { return }
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
        // İşlem sürerken gelen istek yok sayılmaz: işlem (ve sorulan parola) bitince en son istenen arşiv açılır.
        // Aradaki istekler atlanır; kullanıcı yalnızca son seçtiğini görmek ister.
        if operation != nil {
            pendingOpen = url
            guard pendingOpenTask == nil else { return }
            pendingOpenTask = Task {
                await waitUntilIdle()
                pendingOpenTask = nil
                guard let next = pendingOpen else { return }
                pendingOpen = nil
                openArchive(next)
            }
            return
        }
        // Sembolik bağlantı üzerinden verilen arşiv gerçek dosyasıyla açılır: yerinde düzenleme bağlantıyı bozmasın,
        // kum havuzu ve karantina gerçek dosyaya baksın. (Yalnızca son bileşen bağlantıysa; /private gibi yazım korunur.)
        var url = url
        if StagedExtraction.itemType(url) == .typeSymbolicLink { url = url.resolvingSymlinksInPath() }
        // Bölünmüş arşivin herhangi bir parçası seçildiyse ilk parçadan açılır.
        url = ArchiveNaming.firstVolume(of: url)
        // İç içe gezinirken en dıştaki arşiv yeniden seçildiyse (kenar çubuğu) diskten yeniden okunmaz:
        // ona dönülür, parolası ve klasörü korunur.
        if url == rootArchiveURL, !archiveStack.isEmpty {
            returnToArchive(level: 0)
            return
        }
        loadArchive(url, password: url == archiveURL ? password : nil)
    }

    private func loadArchive(_ url: URL, password candidate: String?) {
        perform(.progressReading, archive: url, retry: .open, usedPassword: candidate != nil) { runner, _ in
            try await self.readListing(of: url, runner: runner, keepFolder: false, password: candidate)
            self.addRecent(url)
        }
    }

    /// 7zz'den okunmuş, henüz görünüme uygulanmamış liste.
    private struct LoadedListing: Sendable {
        let url: URL
        let password: String?
        let listing: ArchiveListing
        let headersEncrypted: Bool
        let tree: [ArchiveNode]
        let nodeIndex: [String: ArchiveNode]
    }

    private func fetchListing(of url: URL, runner: CommandRunner, password currentPassword: String?) async throws -> LoadedListing {
        let runner = confined(runner, archive: url)
        let result = try await runner.run(SevenZipCommand.list(archive: url), input: SevenZipCommand.passwordInput(currentPassword))
        try SevenZipError.check(result)
        let listing = ListingParser.parse(result.stdout, fallbackName: ArchiveNaming.streamItemName(for: url))

        // Adlar şifreliyse (7z -mhe) parolasız liste parola ister; eklemelerde de korunmalı.
        // Parolasız liste başarılıysa adlar açıktır (-mhe=off).
        var encryptedHeaders = false
        if currentPassword != nil, listing.info.type == "7z" {
            do {
                encryptedHeaders = SevenZipError.needsPassword(try await runner.run(SevenZipCommand.list(archive: url)))
            } catch SevenZipError.cancelled {
                // Kullanıcının iptali bu ek sorgu sırasında gelirse yutulmasın; arşiv açılmasın.
                throw SevenZipError.cancelled
            } catch {
                // Sorgu yapılamadıysa adlar açık varsayılır.
            }
        }

        try Task.checkCancellation()

        // 500k+ dosyalık devasa arşivlerde ağaç ve indeks inşasını arka planda koştur:
        let (tree, nodeIndex) = await Task.detached(priority: .userInitiated) {
            let builtTree = ArchiveTree.build(from: listing.entries)
            let index = ArchiveTree.index(builtTree)
            return (builtTree, index)
        }.value

        return LoadedListing(
            url: url, password: currentPassword, listing: listing, headersEncrypted: encryptedHeaders,
            tree: tree, nodeIndex: nodeIndex
        )
    }

    /// Listeyi 7zz'den okur ve görünüm durumunu günceller.
    private func readListing(of url: URL, runner: CommandRunner, keepFolder: Bool, password candidate: String?) async throws {
        let loaded = try await fetchListing(of: url, runner: runner, password: candidate)
        if url != archiveURL {
            // Başka bir arşive geçiliyorsa öncekilerin (iç içe olanlar dahil) geçici dosyalarını sil.
            discardAllSessions()
        } else {
            // Aynı arşiv yeniden okunuyor (ör. düzenlemeden sonra): eski önizlemeler artık içerikle uyuşmayabilir.
            discardSessionDirectory()
        }
        apply(loaded, keepFolder: keepFolder)
    }

    private func apply(_ loaded: LoadedListing, keepFolder: Bool) {
        let folder = currentFolder
        archiveURL = loaded.url
        password = loaded.password
        listing = loaded.listing
        statistics = ArchiveStatistics(listing: loaded.listing)
        headersEncrypted = loaded.headersEncrypted
        // İç içe açılan arşiv geçici bir kopyadır; değişiklikler kaybolacağı için düzenlenemez.
        // Çok parçalı (bölünmüş) arşivler, salt okunur (kilitli) arşiv ya da salt okunur diskteki arşiv de düzenlenemez: 7zz "Permission denied" ya da güncelleme hatası verirdi.
        isEditable = archiveStack.isEmpty && ArchiveCapabilities.isEditable(
            type: loaded.listing.info.type, url: loaded.url, volumes: loaded.listing.info.volumes
        )
        symbolicLinks = Self.symbolicLinks(in: loaded.listing)
        hardLinks = Set(loaded.listing.entries.lazy.filter(\.isHardLink).map(\.path))
        // Başka bir arşive geçildi: önceki arşiv için bekleyen parola isteği (ör. Hızlı Bakış) yenisine uygulanmasın.
        if let pending = passwordRequest, Self.targetsOpenArchive(pending), pending.archive != loaded.url { passwordRequest = nil }
        previewCache = [:]
        selection = []
        updatingDisplayOnce {
            if !keepFolder { searchText = "" }
            tree = loaded.tree
            nodeIndex = loaded.nodeIndex
            currentFolder = keepFolder && node(folder)?.isDirectory == true ? folder : ""
        }
    }

    private static func symbolicLinks(in listing: ArchiveListing) -> Set<String> {
        Set(listing.entries.lazy.filter(\.isSymbolicLink).map(\.path))
    }

    /// ⇧⌘W. Süren bir işlem (ekleme, silme, iç arşive girme) bitince listeyi yeniden okuyup kapanan arşivi geri
    /// getirirdi; işlem sırasında kapatılmaz.
    func closeArchive() {
        guard operation == nil else { return }
        resetArchiveState()
    }

    /// Açık arşive ait her durumu siler (kapatma; düzenlemeden sonra yeniden listeleme başarısız olduğunda).
    private func resetArchiveState() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        discardAllSessions()
        // Kapanan arşive bağlı parola isteği (ör. Hızlı Bakış) arşivsiz bir sayfa olarak kalmasın.
        if let pending = passwordRequest, Self.targetsOpenArchive(pending) { passwordRequest = nil }
        archiveURL = nil
        listing = nil
        statistics = nil
        symbolicLinks = []
        hardLinks = []
        updatingDisplayOnce {
            tree = []
            nodeIndex = [:]
            searchText = ""
            currentFolder = ""
            displayNodes = []
        }
        selection = []
        password = nil
        headersEncrypted = false
        isEditable = false
        previewCache = [:]
        quickLookURL = nil
        showInfo = false
    }

    // MARK: - İç içe arşivler

    /// Arşivin içindeki bir arşivi (ör. .zip içindeki .tar.gz) geçici klasöre çıkarıp tarayıcıda açar.
    func browseArchive(_ path: String) {
        guard let archive = archiveURL, operation == nil, node(path)?.isDirectory == false, !refuseSymbolicLink(path) else { return }
        if needsPassword(for: [path]) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .browse(path: path))
            return
        }
        let currentPassword = password
        perform(.progressReading, archive: archive, retry: .browse(path: path)) { runner, progress in
            let url = try await self.extractedItem(path, runner: runner, password: currentPassword, progress: progress)
            try await self.enterNested(url, runner: runner, password: nil)
        }
    }

    /// İç içe arşivi açar; kendi parolası gerekiyorsa sorar (üstteki arşiv açık kalır).
    private func enterNested(_ url: URL, runner: CommandRunner, password candidate: String?) async throws {
        let loaded: LoadedListing
        do {
            loaded = try await fetchListing(of: url, runner: runner, password: candidate)
        } catch SevenZipError.wrongPassword {
            passwordRequest = PasswordRequest(archive: url, isRetry: candidate != nil, action: .openNested)
            return
        }
        guard let archiveURL, let listing else { return }
        archiveStack.append(ArchiveContext(
            url: archiveURL, password: password, listing: listing, headersEncrypted: headersEncrypted, isEditable: isEditable,
            sessionRoot: sessionRoot, previewCache: previewCache, currentFolder: currentFolder, selection: selection,
            tree: tree, nodeIndex: nodeIndex
        ))
        // Üstteki arşivin geçici klasörü (iç arşivin kendisi orada) açık kalır; iç arşiv kendi klasörünü kullanır.
        sessionRoot = nil
        quickLookURL = nil
        apply(loaded, keepFolder: false)
    }

    private func openNested(_ url: URL, password value: String) {
        perform(.progressReading, archive: nil, retry: nil) { runner, _ in
            try await self.enterNested(url, runner: runner, password: value)
        }
    }

    /// Yol çubuğundan ya da ⌘↑ ile üstteki bir arşive döner (`level`: `archiveStack` içindeki sıra).
    func returnToArchive(level: Int) {
        guard operation == nil, archiveStack.indices.contains(level) else { return }
        while archiveStack.count > level {
            discardSessionDirectory()
            let context = archiveStack.removeLast()
            archiveURL = context.url
            password = context.password
            listing = context.listing
            statistics = ArchiveStatistics(listing: context.listing)
            headersEncrypted = context.headersEncrypted
            isEditable = context.isEditable
            sessionRoot = context.sessionRoot
            if archiveStack.count == level {
                symbolicLinks = Self.symbolicLinks(in: context.listing)
                hardLinks = Set(context.listing.entries.lazy.filter(\.isHardLink).map(\.path))
                updatingDisplayOnce {
                    searchText = ""
                    tree = context.tree
                    nodeIndex = context.nodeIndex
                    currentFolder = node(context.currentFolder)?.isDirectory == true ? context.currentFolder : ""
                }
                selection = context.selection
                previewCache = context.previewCache
            }
        }
    }

    /// Açık arşivin ve iç içe gezinmede üstteki tüm arşivlerin geçici klasörlerini siler.
    private func discardAllSessions() {
        discardSessionDirectory()
        for context in archiveStack {
            if let root = context.sessionRoot { StagedExtraction.removeTree(at: root) }
        }
        archiveStack = []
    }

    /// Finder'dan "Birlikte Aç" / Dock: yalnızca arşivler geldiyse ilki açılır (açık arşive eklenmez);
    /// arşivlerle birlikte başka dosyalar da geldiyse hepsi, sürükle-bırakta olduğu gibi yeni arşiv sayfasına gider.
    func handleOpenRequest(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if files.allSatisfy(isOpenableArchive), let archive = files.first {
            openArchive(archive)
        } else {
            beginCreate(sources: files)
        }
    }

    private func isOpenableArchive(_ url: URL) -> Bool {
        ArchiveNaming.isArchive(url) && !ArchiveNaming.defaultIsDirectory(url)
    }

    /// Bırakılan öğeler: düzenlenebilir bir arşiv açıksa eklemeyi önerir; yoksa tek arşiv → aç, diğerleri → yeni arşiv.
    func handleDrop(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        // İşlem sürerken bırakılanlar yok sayılır (yeni arşiv sayfası işlemin üstünde açılmasın).
        guard !files.isEmpty, operation == nil else { return }
        if listing != nil, isEditable {
            addRequest = AddRequest(sources: files)
        } else if files.count == 1, let url = files.first, isOpenableArchive(url) {
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

    /// Tabloda açık klasörün içeriği mi gösteriliyor? (Ağaç görünümü ve arama sonuçları tüm arşivi gösterir.)
    var showsFolderPath: Bool { browserMode == .folders && searchText.isEmpty }

    /// Yol çubuğu: klasör görünümünde ve iç içe açılmış bir arşivde (üstteki arşive dönüş yolu her görünümde kalır).
    var showsPathBar: Bool { showsFolderPath || !archiveStack.isEmpty }

    /// Bir üst klasör; iç içe açılmış bir arşivin kökündeyse onu içeren arşive döner. Ağaç görünümünde ve aramada
    /// klasör yolu yoktur; orada yalnızca üstteki arşive dönülür.
    var canGoUp: Bool { listing != nil && ((showsFolderPath && !currentFolder.isEmpty) || !archiveStack.isEmpty) }

    func goUp() {
        if currentFolder.isEmpty || !showsFolderPath {
            if !archiveStack.isEmpty { returnToArchive(level: archiveStack.count - 1) }
            return
        }
        let previous = currentFolder
        currentFolder = ArchiveTree.parent(of: previous)
        selection = [previous]
    }

    func goTo(_ path: String) {
        searchText = ""
        currentFolder = path
        selection = []
    }

    /// Çift tık / Return / ⌘↓: klasöre gir, arşivse içine gir, değilse dosyayı aç.
    func primaryAction(_ ids: Set<ArchiveNode.ID>) {
        guard ids.count == 1, let id = ids.first, let node = node(id) else { return }
        if node.isDirectory {
            // Ağaç görünümünde ve aramada da klasöre girilir (bağlam menüsündeki "Aç" gibi).
            browserMode = .folders
            enterFolder(id)
        } else if ArchiveNaming.isBrowsable(node.name) {
            browseArchive(id)
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
        // Klasör görünümünde bir alt klasördeyken seçilen öğeler, o klasörün yolu olmadan hedefe yazılır
        // (Finder'a sürüklemedeki gibi). Arama sonuçları ve ağaç görünümü tam yolu korur.
        let folder = browserMode == .folders && searchText.isEmpty ? currentFolder : ""
        let stripping = !items.isEmpty && !folder.isEmpty && items.allSatisfy({ $0.hasPrefix(folder + "/") }) ? folder : ""
        if needsPassword(for: items) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .extract(items: items, destination: nil, stripping: stripping))
            return
        }
        guard let destination = chooseExtractDestination(for: archive) else { return }
        runExtract(archive: archive, items: items, base: destination, stripping: stripping, password: password)
    }

    /// - Parameters:
    ///   - items: Görünümdeki (normalleştirilmiş) yollar; boşsa tüm arşiv.
    ///   - base: Alt klasör kuralı uygulanmadan önceki hedef klasör.
    ///   - stripping: Hedefe yazarken atılacak iç klasör yolu.
    private func runExtract(archive: URL, items: [String], base: URL, stripping: String, password: String?) {
        let policy = settings.overwriteMode
        let subfolderMode = settings.subfolderMode
        let archiveName = ArchiveNaming.baseName(of: archive)
        let isOpenArchive = archive == archiveURL
        let knownEntries = isOpenArchive ? listing?.entries : nil
        let rawItems = isOpenArchive ? items.map(archivePath(for:)) : items
        let retry = PendingAction.extract(items: items, destination: base, stripping: stripping)
        perform(.progressExtracting, archive: archive, retry: retry, usedPassword: password != nil) { runner, progress in
            // 1. Boş alan. Açık arşivin listesi yoksa (ör. Buraya Çıkar) önce listelenir; parola gerekirse burada sorulur.
            var entries = knownEntries
            if entries == nil {
                let listed = try await self.confined(runner, archive: archive).run(SevenZipCommand.list(archive: archive), input: SevenZipCommand.passwordInput(password))
                try SevenZipError.check(listed)
                entries = ListingParser.parse(listed.stdout, fallbackName: ArchiveNaming.streamItemName(for: archive)).entries
            }
            try InsufficientSpaceError.check(required: DiskSpace.requiredBytes(for: items, in: entries ?? []), at: base)

            // 2. Hedefle aynı birimdeki hazırlık klasörüne çıkar; iptal ya da hata hedefi değiştirmez.
            let staging = try StagedExtraction.makeStagingDirectory(for: base)
            // Hazırlık klasörü her durumda silinir; ana iş parçacığı dışında (bkz. discardStaging).
            do {
                let options = ExtractOptions(archive: archive, destination: staging, items: rawItems, password: password, overwrite: .replace)
                let result = try await self.confined(runner, archive: archive, writable: [staging]).run(
                    SevenZipCommand.extract(options), workingDirectory: options.workingDirectory, input: options.input, onProgress: progress
                )
                var warnings = [try SevenZipError.check(result)].compactMap { $0 }
                // İptal 7zz bittikten sonra geldiyse: sonraki adımlar (bağlantı ayıklama, karantina, birleştirme) iptali
                // denetlemez; hazırlık klasörü atılır, hedefe dokunulmaz.
                if Task.isCancelled { throw SevenZipError.cancelled }

                // 3. Taşınacak içerik: alt klasördeyken seçilenler o klasörün yolu olmadan hedefe gider.
                let content = StagedExtraction.contentRoot(in: staging, stripping: stripping)
                // 7zz seçilen öğeyi eşleştiremezse (ör. adında satır sonu olan girdi listede "_" ile yazılır) 0 ile biter ama
                // hiçbir şey çıkmaz; "çıkarıldı" denmesin.
                if !items.isEmpty, ((try? StagedExtraction.entries(ofDirectory: content.path)) ?? []).isEmpty {
                    throw SevenZipError.failed(code: result.exitCode, message: items.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                }

                // 4. 7zz'nin reddettiği bağlantıların 0 baytlık yer tutucularını sil (hedefteki dosyaları ezmesinler);
                // taşınan içeriğin dışını gösteren bağlantıları ayıkla, karantina işaretini aktar.
                // Sembolik VE sabit bağlantılar: 7zz dışarıyı göstereni reddedip yerine 0 baytlık dosya bırakır.
                let links = (entries ?? []).filter { $0.isSymbolicLink || $0.isHardLink }.map(\.path)
                let placeholders = StagedExtraction.removeLinkPlaceholders(in: staging, links: links)
                let prefix = content == staging ? "" : stripping + "/"
                let escaping = StagedExtraction.secureSymlinks(in: content, extractionRoot: staging).map { prefix + $0 }
                let removedLinks = Array(Set(placeholders + escaping)).sorted()
                if !removedLinks.isEmpty {
                    warnings.append(self.t(.warningRemovedLinks, removedLinks.prefix(10).joined(separator: ", ")))
                }
                Quarantine.propagate(from: archive, to: staging, since: .distantPast)

                // 5. Alt klasör kuralına göre hedefi belirle ve seçilen üzerine yazma kuralıyla taşı.
                let destination = StagedExtraction.destination(for: content, base: base, archiveName: archiveName, mode: subfolderMode)
                // Tüm arşiv akıllı kuralla doğrudan hedefe çıkıyorsa Finder'ın eklediği üst veri (__MACOSX, .DS_Store, ._*)
                // hedefe dağılmaz. Kullanıcının açıkça seçtiği öğelere dokunulmaz.
                if items.isEmpty {
                    StagedExtraction.leaveOutRootMetadata(in: content, destination: destination, base: base, mode: subfolderMode)
                }
                // Birleştirme başladıktan sonra iptal edilmez (yarım hedef kalmasın); son fırsat burası.
                if Task.isCancelled { throw SevenZipError.cancelled }
                let changed = try StagedExtraction.merge(from: content, into: destination, policy: policy)
                // Doğrudan hedefe tek anlamlı öğe çıktıysa Finder o öğeyi seçsin (macOS üst verileri sayılmaz).
                let meaningfulChanged = changed.filter { !StagedExtraction.isMacMetadata($0.lastPathComponent, in: destination) }
                let targetItems = meaningfulChanged.isEmpty ? changed : meaningfulChanged
                let reveal = destination == base && targetItems.count == 1 ? targetItems[0] : destination
                let warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
                self.finish(message: self.t(.toastExtracted, reveal.lastPathComponent), reveal: reveal, warning: warning)
            } catch {
                await Self.discardStaging(staging)
                throw error
            }
            await Self.discardStaging(staging)
        }
    }

    /// 7zz'nin bildirdiği ilerleme. Yüzde bayt üzerinden hesaplanır: çok sayıda küçük dosyada (ör. 4.000 dosya, birkaç KB)
    /// iş bitene kadar "%0" kalır. Çubuk %0'da takılı görünmesin diye gerçek bir değer gelene kadar belirsiz kalır.
    func applyProgress(_ value: Double) {
        // İptal sürerken gelen son bildirimler çubuğu yeniden doldurmasın.
        guard let current = operation, !current.isCancelling else { return }
        guard value > 0 || current.progress != nil else { return }
        operation?.progress = value
    }

    /// Hazırlık klasörünü ana iş parçacığı dışında siler ve bitmesini bekler. İptal edilen büyük bir çıkarmada on binlerce
    /// yarım dosya kalır (16.000 dosya ≈ 2,5 sn); ana iş parçacığında silmek arayüzü saniyelerce donduruyordu.
    nonisolated private static func discardStaging(_ staging: URL) async {
        await Task.detached(priority: .userInitiated) { StagedExtraction.removeTree(at: staging) }.value
    }

    func testArchive() {
        guard let archive = archiveURL, operation == nil else { return }
        if needsPassword(for: []) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .test)
            return
        }
        let currentPassword = password
        perform(.progressTesting, archive: archive, retry: .test) { runner, progress in
            let result = try await self.confined(runner, archive: archive).run(SevenZipCommand.test(archive: archive), input: SevenZipCommand.passwordInput(currentPassword), onProgress: progress)
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
        guard node(path)?.isDirectory == false, !refuseSymbolicLink(path) else { return }
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
    /// Bağlam menüsünden başka bir öğe için çağrılırsa önizleme o öğeye geçer.
    func toggleQuickLook(_ path: String? = nil) {
        if let current = quickLookURL {
            guard let path, previewCache[path] != current else {
                quickLookURL = nil
                return
            }
        }
        guard let path = path ?? selection.sorted().first, node(path)?.isDirectory == false, !refuseSymbolicLink(path) else { return }
        withExtractedItem(path, retry: .quickLook(path: path)) { self.quickLookURL = $0 }
    }

    /// Öğe arşivde bir sembolik bağlantı mı? (Tek başına açılamaz, önizlenemez, kopyalanamaz, sürüklenemez.)
    func isSymbolicLink(_ id: ArchiveNode.ID) -> Bool { symbolicLinks.contains(id) }

    /// Tek seçili öğe bir sembolik bağlantı mı? (Menüde Hızlı Bakış, Aç ve sağlama değerleri kapalıdır.)
    var selectionIsSymbolicLink: Bool { selection.count == 1 && selection.first.map(isSymbolicLink) == true }

    /// Sembolik bağlantıyı tek başına açma, önizleme ya da sağlama değeri isteği: gösterdiği yer çıkarılmadığı için
    /// 7zz'yi çalıştırmak yerine nedeni açıklanır.
    /// - Returns: Öğe bir bağlantıysa (istek reddedildiyse) true.
    private func refuseSymbolicLink(_ path: String) -> Bool {
        guard isSymbolicLink(path) else { return false }
        alert = AlertItem(title: t(.warningTitle), message: t(.symbolicLinkItem, OpenSafety.visibleName((path as NSString).lastPathComponent)))
        return true
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
            completion(try await self.extractedItem(path, runner: runner, password: currentPassword, progress: progress))
        }
    }

    /// Açık arşivdeki bir öğeyi oturum klasörüne çıkarır (önbellekte varsa onu verir). Bir işlemin içinden çağrılır.
    private func extractedItem(
        _ path: String, runner: CommandRunner, password currentPassword: String?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let cached = previewCache[path], FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let archive = archiveURL else { throw SevenZipError.cancelled }
        let session = sessionDirectory()
        let extractor = ItemExtractor(
            runner: confined(runner, archive: archive, writable: [session]), archive: archive, password: currentPassword, root: session,
            symbolicLinks: symbolicLinks, hardLinks: hardLinks
        )
        let url = try await extractor.extract(archivePath(for: path), expectedSize: node(path)?.size, onProgress: progress)
        previewCache[path] = url
        return url
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
        if let sessionRoot { StagedExtraction.removeTree(at: sessionRoot) }
        sessionRoot = nil
        previewCache = [:]
        quickLookURL = nil
    }

    /// Uygulamadan çıkarken çağrılır: çözülmüş önizleme dosyaları diskte kalmasın.
    /// İç içe gezinmede üstteki arşivlerin geçici klasörleri (iç arşivin kopyası, önizlemeler) de silinir.
    func discardTemporaryFiles() {
        discardAllSessions()
    }

    /// Listeden Finder'a sürüklenecek öğe; parola gerekiyorsa ve bilinmiyorsa sürükleme kapalıdır.
    func dragItem(for node: ArchiveNode) -> ArchiveItemTransfer? {
        // Tek başına bir bağlantı taşındığı yerde dışarıyı gösterir ya da boşa düşer; sürüklenmez.
        guard let archive = archiveURL, let engineURL, !isSymbolicLink(node.id), !needsPassword(for: [node.id]) else { return nil }
        let session = sessionDirectory()
        let runner = confined(CommandRunner(executableURL: engineURL), archive: archive, writable: [session])
        let extractor = ItemExtractor(runner: runner, archive: archive, password: password, root: session, symbolicLinks: symbolicLinks, hardLinks: hardLinks)
        let name = (node.id as NSString).lastPathComponent
        return ArchiveItemTransfer(extractor: extractor, path: node.archivePath, name: name, size: node.size)
    }

    // MARK: - Kopyala, yapıştır, sağlama değerleri

    /// ⌘C: seçili öğeleri oturum klasörüne çıkarır ve dosya olarak panoya koyar; Finder'da ⌘V ile yapıştırılabilir.
    /// (Geçici dosyalar arşiv kapanınca silinir; yapıştırma arşiv açıkken yapılmalıdır.)
    func copyItems(_ ids: [String]? = nil, to pasteboard: NSPasteboard = .general) {
        let requested = ids ?? selection.sorted()
        guard let archive = archiveURL, operation == nil, !requested.isEmpty else { return }
        // Seçimdeki (ör. ⌘A) tek başına bağlantılar atlanır, kalanlar kopyalanır; yalnızca bağlantılar seçildiyse
        // nedeni açıklanır. Seçilen klasörlerin içindeki bağlantılar ise klasörle birlikte (güvenli olanlar) gelir.
        let items = requested.filter { !isSymbolicLink($0) }
        guard !items.isEmpty else {
            _ = refuseSymbolicLink(requested[0])
            return
        }
        if needsPassword(for: items) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .copy(items: items))
            return
        }
        let currentPassword = password
        let entries = listing?.entries ?? []
        let links = symbolicLinks, hard = hardLinks
        perform(.progressCopying, archive: archive, retry: .copy(items: items)) { runner, progress in
            let session = self.sessionDirectory()
            let extractor = ItemExtractor(
                runner: self.confined(runner, archive: archive, writable: [session]), archive: archive, password: currentPassword, root: session,
                symbolicLinks: links, hardLinks: hard
            )
            let urls = try await extractor.extract(
                items.map(self.archivePath(for:)), expectedSize: DiskSpace.requiredBytes(for: items, in: entries), onProgress: progress
            )
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            self.showToast(self.t(.toastCopied, urls.count), systemImage: "doc.on.doc.fill")
        }
    }

    /// Bir metin alanı (arama, ad, parola) düzenleniyor mu? Düzen menüsü komutları o zaman metne gider.
    static var isEditingText: Bool { NSApp?.keyWindow?.firstResponder is NSText }

    /// Düzen › Kopyala (⌘C). SwiftUI'nin `onCopyCommand`'ı hiyerarşik tabloda çağrılmadığı için menü komutu
    /// yönlendirir: metin düzenleniyorsa sistem kopyalaması, değilse seçili arşiv öğeleri dosya olarak.
    func copyCommand(editingText: Bool = AppModel.isEditingText, pasteboard: NSPasteboard = .general) {
        if !editingText, listing != nil, operation == nil, !selection.isEmpty {
            copyItems(to: pasteboard)
        } else {
            NSApp?.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
    }

    /// Düzen › Yapıştır (⌘V): metin düzenleniyorsa sistem yapıştırması, değilse panodaki dosyaları arşive ekleme.
    func pasteCommand(editingText: Bool = AppModel.isEditingText, pasteboard: NSPasteboard = .general) {
        if !editingText, listing != nil, isEditable, operation == nil, Self.hasFiles(pasteboard) {
            pasteFiles(from: pasteboard)
        } else {
            NSApp?.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
    }

    /// Düzen › Tümünü Seç (⌘A): `selectAll:` da hiyerarşik tabloya ulaşmaz. Metin düzenleniyorsa metne gider;
    /// değilse tabloda görünen öğelerin (açık klasörün içeriği ya da arama sonuçları) tümü seçilir.
    func selectAllCommand(editingText: Bool = AppModel.isEditingText) {
        if !editingText, listing != nil {
            selection = Set(displayNodes.map(\.id))
        } else {
            NSApp?.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// ⌘V: panodaki dosyaları (onay sorarak) düzenlenebilir arşivin açık klasörüne ekler.
    func pasteFiles(from pasteboard: NSPasteboard = .general) {
        guard listing != nil, isEditable, operation == nil else { return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        addRequest = AddRequest(sources: urls)
    }

    /// Seçili dosyanın CRC32, SHA-256 ve BLAKE2sp değerlerini (7zz h) gösterir.
    func showChecksums(_ path: String? = nil) {
        guard let path = path ?? (selection.count == 1 ? selection.first : nil), node(path)?.isDirectory == false,
              let archive = archiveURL, operation == nil, !refuseSymbolicLink(path) else { return }
        if needsPassword(for: [path]) {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .checksums(path: path))
            return
        }
        let currentPassword = password
        perform(.progressChecksums, archive: archive, retry: .checksums(path: path)) { runner, progress in
            let file = try await self.extractedItem(path, runner: runner, password: currentPassword, progress: progress)
            let result = try await self.confined(runner, archive: file).run(SevenZipCommand.hash(file: file))
            try SevenZipError.check(result)
            let text = ChecksumParser.text(ChecksumParser.parse(result.stdout))
            let name = OpenSafety.visibleName((path as NSString).lastPathComponent)
            self.alert = AlertItem(
                title: self.t(.checksumsTitle, name),
                message: text,
                actionTitle: self.t(.buttonCopy),
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                cancelTitle: self.t(.buttonOK)
            )
        }
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
        addFiles(request.sources, into: request.folder)
    }

    /// - Parameter folder: Arşivdeki hedef klasör; nil ise klasör görünümünde açık olan klasör.
    func addFiles(_ sources: [URL], into folder: String? = nil) {
        guard let archive = archiveURL, isEditable, !sources.isEmpty, operation == nil else { return }
        if needsPasswordForEdit {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .add(sources: sources, folder: folder))
            return
        }
        // Arşiv içindeki klasörün 7zz'nin tanıdığı yazımı ("./belgeler" gibi) korunur.
        let target = folder ?? (browserMode == .folders ? currentFolder : "")
        let folderPath = target.isEmpty ? "" : archivePath(for: target)
        let currentPassword = password
        let encryptHeaders = headersEncrypted
        let archiveType = listing?.info.type
        let storeSymlinks = settings.storeSymlinks
        let excludeMetadata = settings.excludeMacMetadata
        perform(.progressUpdating, archive: archive, retry: .add(sources: sources, folder: folder)) { runner, progress in
            // 7zz arşivin güncellenmiş kopyasını yanına yazar: arşiv kadar (tar'da eklenenler kadar da) yer gerekir.
            let compresses = archiveType?.lowercased() != "tar"
            let sourceBytes = compresses ? 0 : await Self.measure(sources)
            try self.checkSpaceForWriting(archive: archive, sourceBytes: sourceBytes, compresses: compresses)
            let plan = try AddPlan.make(
                sources: sources, into: folderPath, stagingRoot: ItemExtractor.temporaryRoot, followingSymlinks: !storeSymlinks
            )
            defer {
                if let staging = plan.stagingDirectory { StagedExtraction.removeTree(at: staging) }
            }
            // FIFO, soket ve aygıt dosyaları eklenmez: 7zz bir FIFO'yu okurken sonsuza dek bekler.
            let excluded = await Self.specialFiles(
                in: plan.names.map { plan.workingDirectory.appendingPathComponent($0) }, followingSymlinks: !storeSymlinks
            )
            let work = try self.editWorkDirectory(for: archive)
            defer { StagedExtraction.removeTree(at: work) }
            let command = SevenZipCommand.add(
                archive: archive, names: plan.names, password: currentPassword, encryptHeaders: encryptHeaders,
                archiveType: archiveType, storeSymlinks: storeSymlinks, excludeMacMetadata: excludeMetadata, excluding: excluded,
                workDirectory: work
            )
            // Kişisel veri klasörleri kapalı kalır; yalnızca kullanıcının oradan açıkça seçtiği kaynaklar okunabilir
            // (başka bir kaynaktaki bağlantı "~/.ssh" içindeki bir anahtarı arşive taşımasın). 7zz'nin çalışma klasörü
            // (kaynakların üst klasörü) yasaklı olsa da göreli adlar çözülür; klasörün kendisine izin gerekmez.
            let writer = self.confined(runner, archive: archive, writable: [work], writableFiles: [archive], readable: sources)
            // 7zz arşivi yeni bir inode olarak yazar: karantina işareti, Finder etiketleri ve kip (0600) kaybolmasın.
            let preserved = PreservedAttributes(of: archive)
            defer { preserved?.restore(to: archive) }
            let result = try await writer.run(command, workingDirectory: plan.workingDirectory, input: SevenZipCommand.passwordInput(currentPassword), onProgress: progress)
            let warning = try SevenZipError.check(result)
            try await self.relistAfterEdit(of: archive, runner: runner, password: currentPassword)
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
        let rawItems = items.map(archivePath(for:))
        perform(.progressUpdating, archive: archive, retry: .delete(items: items)) { runner, progress in
            try self.checkSpaceForWriting(archive: archive, sourceBytes: 0, compresses: true)
            let work = try self.editWorkDirectory(for: archive)
            defer { StagedExtraction.removeTree(at: work) }
            let preserved = PreservedAttributes(of: archive)
            defer { preserved?.restore(to: archive) }
            let result = try await self.confined(runner, archive: archive, writable: [work], writableFiles: [archive]).run(SevenZipCommand.delete(archive: archive, items: rawItems, workDirectory: work), input: SevenZipCommand.passwordInput(currentPassword), onProgress: progress)
            let warning = try SevenZipError.check(result)
            try await self.relistAfterEdit(of: archive, runner: runner, password: currentPassword)
            self.finishEdit(warning: warning)
        }
    }

    func requestRename(_ path: String? = nil) {
        let path = path ?? (selection.count == 1 ? selection.first : nil)
        guard isEditable, operation == nil, let path, node(path) != nil else { return }
        renameRequest = RenameRequest(path: path, name: (path as NSString).lastPathComponent)
    }

    /// Yeni ad aynı klasördeki başka bir öğeninkiyle çakışıyor mu? `7zz rn` buna izin verir ve arşivde aynı yollu
    /// iki girdi oluşur. APFS gibi büyük/küçük harf duyarsız denetlenir; öğenin kendi adının harf değişikliği serbesttir.
    func renameConflicts(_ path: String, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = ArchiveTree.parent(of: path)
        let siblings = parent.isEmpty ? tree : (node(parent)?.children ?? [])
        return siblings.contains { $0.id != path && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    func rename(_ path: String, to newName: String) {
        renameRequest = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let archive = archiveURL, isEditable, ArchiveTree.isValidName(name) else { return }
        let newPath = ArchiveTree.renamedPath(path, to: name)
        guard newPath != path else { return }
        guard !renameConflicts(path, to: name) else {
            alert = AlertItem(title: t(.errorTitle), message: t(.renameExists, OpenSafety.visibleName(name)))
            return
        }
        if headersEncrypted && password == nil {
            passwordRequest = PasswordRequest(archive: archive, isRetry: false, action: .rename(path: path, newName: name))
            return
        }
        let currentPassword = password
        // 7zz eski adı ham yazımıyla tanır; yeni ad da aynı üst klasör yazımıyla verilir.
        let rawPath = archivePath(for: path)
        let rawNewPath = ArchiveTree.renamedPath(rawPath, to: name)
        perform(.progressUpdating, archive: archive, retry: .rename(path: path, newName: name)) { runner, _ in
            try self.checkSpaceForWriting(archive: archive, sourceBytes: 0, compresses: true)
            let work = try self.editWorkDirectory(for: archive)
            defer { StagedExtraction.removeTree(at: work) }
            let preserved = PreservedAttributes(of: archive)
            defer { preserved?.restore(to: archive) }
            let result = try await self.confined(runner, archive: archive, writable: [work], writableFiles: [archive]).run(SevenZipCommand.rename(archive: archive, from: rawPath, to: rawNewPath, workDirectory: work), input: SevenZipCommand.passwordInput(currentPassword))
            let warning = try SevenZipError.check(result)
            try await self.relistAfterEdit(of: archive, runner: runner, password: currentPassword)
            self.selection = [newPath]
            self.finishEdit(warning: warning)
        }
    }

    /// Arşiv yazmadan önce hedef birimde yer olduğunu denetler (bkz. `DiskSpace.requiredForWriting`).
    private func checkSpaceForWriting(archive: URL?, sourceBytes: Int64, compresses: Bool, at directory: URL? = nil) throws {
        let existing = archive.map { DiskSpace.totalSize(of: [$0]) } ?? 0
        let required = DiskSpace.requiredForWriting(sourceBytes: sourceBytes, compresses: compresses, existingArchiveBytes: existing)
        guard required > 0, let location = directory ?? archive?.deletingLastPathComponent() else { return }
        try InsufficientSpaceError.check(required: required, at: location)
    }

    /// Kaynakların toplam boyutu; büyük klasörlerde arayüzü dondurmamak için arka planda ölçülür.
    nonisolated private static func measure(_ urls: [URL]) async -> Int64 {
        await Task.detached(priority: .userInitiated) { DiskSpace.totalSize(of: urls) }.value
    }

    /// Kaynaklardaki özel dosyaların (FIFO, soket, aygıt) arşivdeki yolları; arka planda taranır.
    nonisolated private static func specialFiles(in urls: [URL], followingSymlinks: Bool) async -> [String] {
        await Task.detached(priority: .userInitiated) { SpecialFiles.archivePaths(in: urls, followingSymlinks: followingSymlinks) }.value
    }

    /// Düzenleme diske yazıldı; eski liste artık yanlıştır. Yeniden listeleme iptal EDİLEMEZ (kısa sürer; iptal
    /// edilseydi silinen öğe seçilebilir, eski önizleme açılabilir kalırdı). Gerçekten başarısız olursa eski liste
    /// gösterilmez, arşiv kapatılır ve hata bildirilir.
    func relistAfterEdit(of archive: URL, runner: CommandRunner, password: String?) async throws {
        // Yapısal olmayan görev iptali devralmaz; `.value` beklemesi dış görev iptal edilse de kesilmez.
        let listing = Task { try await self.fetchListing(of: archive, runner: runner, password: password) }
        do {
            let loaded = try await listing.value
            discardSessionDirectory()
            apply(loaded, keepFolder: true)
        } catch {
            resetArchiveState()
            throw error
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
        // Bölünmüş arşivin parçaları ilk parçaya çevrilir; aynı arşiv iki kez çıkarılmaz.
        for archive in archives where ArchiveNaming.isArchive(archive) {
            let first = ArchiveNaming.firstVolume(of: archive)
            if !serviceQueue.contains(first) { serviceQueue.append(first) }
        }
        guard serviceTask == nil, !serviceQueue.isEmpty else { return }
        serviceTask = Task {
            while let archive = serviceQueue.first {
                await waitUntilIdle()
                // Beklerken iptal kuyruğu boşalttıysa bu arşiv de çıkarılmaz (baş öğe önce kuyruktan alınsaydı kaçardı).
                guard serviceQueue.first == archive else { continue }
                serviceQueue.removeFirst()
                // Açık (ya da iç içe gezinmede en dıştaki) arşivin bilinen parolası kullanılır: parolasız deneme
                // "yanlış parola" sayılıp açık arşivin parolasını silerdi.
                runExtract(archive: archive, items: [], base: archive.deletingLastPathComponent(), stripping: "", password: knownPassword(for: archive))
                // Parola sorulursa, yeniden deneme de bitene kadar sıradakine geçme.
                await waitUntilIdle()
            }
            serviceTask = nil
        }
    }

    /// Arşivin bu oturumda doğrulanmış parolası: açık arşivinki ya da iç içe gezinmede en dıştaki arşivinki.
    private func knownPassword(for archive: URL) -> String? {
        if archive == archiveURL { return password }
        if let root = archiveStack.first, root.url == archive { return root.password }
        return nil
    }

    /// Kuyruktaki işlerin bitmesini bekler (testler ve sıralı servisler için).
    var serviceQueueTask: Task<Void, Never>? { serviceTask }

    /// İşlem sürerken istenen arşivin açılmasını bekler (testler için).
    var pendingOpenQueueTask: Task<Void, Never>? { pendingOpenTask }

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

    /// Çıkarma hedefi (alt klasör kuralı uygulanmadan). İç içe açılmış bir arşivde "arşivin yanı",
    /// geçici kopyanın değil diskteki en dış arşivin yanıdır.
    private func chooseExtractDestination(for archive: URL) -> URL? {
        let location = archive == archiveURL ? (rootArchiveURL ?? archive) : archive
        var base: URL?
        switch settings.extractLocation {
        case .nextToArchive:
            base = location.deletingLastPathComponent()
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
            panel.directoryURL = location.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            base = url
        }
        // Arşiv adıyla klasör (alt klasör kuralı) çıkarma bittikten sonra, içeriğe bakılarak belirlenir.
        return base
    }

    // MARK: - Oluşturma

    /// ⌘N, araç çubuğu, Finder servisi. İşlem sürerken açılan sayfadaki "Oluştur" sessizce yok sayılırdı.
    func beginCreate(sources: [URL] = []) {
        guard operation == nil else { return }
        createRequest = CreateRequest(sources: sources)
    }

    func createArchive(_ options: CreateOptions) {
        perform(.progressCreating, archive: nil, retry: nil) { runner, progress in
            // Oluşturma sayfası aynı adlı kaynakları zaten engeller; model doğrudan çağrıldığında da 7zz'nin
            // "Duplicate filename on disk" hatası yerine anlaşılır bir ileti verilsin.
            let duplicates = AddPlan.duplicateNames(in: options.sources)
            guard duplicates.isEmpty else { throw AddPlan.DuplicateNameError(names: duplicates) }
            // Kaynakların hepsi atlanan özel dosyalarsa (FIFO, soket) boş bir arşiv oluşturulmaz.
            let followsLinks = !(options.storeSymlinks && options.format.supportsSymlinks)
            guard !SpecialFiles.containsOnlySpecialFiles(options.sources, followingSymlinks: followsLinks) else {
                throw AddPlan.NothingToArchiveError()
            }
            // Aynı adlı bir klasör arşivle değiştirilmez (bkz. `installArchive`); 7zz sıkıştırmayı boşuna yapmasın diye
            // baştan reddedilir.
            let first = options.firstOutput
            if StagedExtraction.itemType(first) == .typeDirectory {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: first.path])
            }
            let fileManager = FileManager.default
            let directory = options.destination.deletingLastPathComponent()
            let name = options.destination.lastPathComponent
            let isTwoStep = options.format.tarCompression != nil

            // Sıkıştırmasız biçimler (ve tar.* biçimlerinin ara tar dosyası) kaynakların tamamı kadar yer ister.
            let needsSourceSize = !options.compresses || isTwoStep
            let sourceBytes = needsSourceSize ? await Self.measure(options.sources) : 0
            try self.checkSpaceForWriting(archive: nil, sourceBytes: sourceBytes, compresses: !needsSourceSize, at: directory)

            // FIFO, soket ve aygıt dosyaları arşive alınmaz: 7zz bir FIFO'yu okurken sonsuza dek bekler.
            var staged = options
            staged.excludedPaths = await Self.specialFiles(in: options.sources, followingSymlinks: followsLinks)

            // Arşiv hedefle aynı birimdeki bir hazırlık klasöründe oluşturulur, yalnızca başarıda yerine taşınır:
            // aynı adlı eski arşive eklenmez (onun yerini alır), iptal ya da hata hedefte yarım bir dosya bırakmaz.
            let staging = try StagedExtraction.makeStagingDirectory(for: directory)
            defer { StagedExtraction.removeTree(at: staging) }
            staged.destination = staging.appendingPathComponent(name)
            // Kişisel veri klasörleri, kullanıcı oradan açıkça bir kaynak seçmedikçe okunamaz.
            let writer = self.confined(runner, archive: staged.destination, writable: [staging], readable: options.sources)

            var warnings: [String] = []
            if isTwoStep {
                // tar.*: önce ayrı bir klasöre sıkıştırmasız tar, sonra hazırlık klasörüne sıkıştırılmış hâli yazılır.
                let tarFolder = staging.appendingPathComponent("tar", isDirectory: true)
                try fileManager.createDirectory(at: tarFolder, withIntermediateDirectories: false)
                let stage = SevenZipCommand.tarStage(for: options.destination, in: tarFolder)
                let first = try await writer.run(SevenZipCommand.create(staged, tarStage: stage)) { progress($0 * 0.5) }
                if let warning = try SevenZipError.check(first) { warnings.append(warning) }
                let command = SevenZipCommand.compressTarStage(staged, tarStage: stage) ?? []
                let second = try await writer.run(command) { progress(0.5 + $0 * 0.5) }
                if let warning = try SevenZipError.check(second) { warnings.append(warning) }
            } else {
                let result = try await writer.run(SevenZipCommand.create(staged), input: staged.input, onProgress: progress)
                if let warning = try SevenZipError.check(result) { warnings.append(warning) }
            }

            // Bölünmüş arşivde açılacak dosya "ad.7z.001"dir; hedefteki eski parçalar yenileriyle değiştirilir.
            let output = try StagedExtraction.installArchive(named: name, from: staging, into: directory, split: options.isSplit)
            self.addRecent(output)
            self.finish(
                message: self.t(.toastCreated, output.lastPathComponent),
                reveal: output,
                warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
            )
        }
    }

    // MARK: - Parola

    /// İstek açık arşive mi aittir (parola o arşiv için saklanır ve eylem onun üzerinde çalışır)? Kendi arşivini taşıyan
    /// eylemler (açma, iç arşiv, Buraya Çıkar) bağlı değildir.
    private static func targetsOpenArchive(_ request: PasswordRequest) -> Bool {
        switch request.action {
        case .open, .openNested: return false
        case .extract(_, let destination, _): return destination == nil
        default: return true
        }
    }

    func submitPassword(_ value: String) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        // Bu arada başka bir arşiv açıldıysa (⌘O) eski arşivin isteği yenisine uygulanmaz.
        if Self.targetsOpenArchive(request), request.archive != archiveURL { return }
        // Parola yalnızca açık arşive aitse saklanır; başka bir arşivin işi (ör. Buraya Çıkar) kendi parolasını taşır.
        let isCurrentArchive = request.archive == archiveURL
        if isCurrentArchive { password = value }
        switch request.action {
        case .open:
            loadArchive(request.archive, password: value)
        case .extract(let items, let destination, let stripping):
            if let destination {
                runExtract(archive: request.archive, items: items, base: destination, stripping: stripping, password: value)
            } else if isCurrentArchive {
                extract(items: items)
            }
        case .test:
            testArchive()
        case .openItem(let path):
            openItem(path)
        case .quickLook(let path):
            toggleQuickLook(path)
        case .add(let sources, let folder):
            addFiles(sources, into: folder)
        case .delete(let items):
            deleteItems(items)
        case .rename(let path, let newName):
            rename(path, to: newName)
        case .browse(let path):
            browseArchive(path)
        case .openNested:
            openNested(request.archive, password: value)
        case .copy(let items):
            copyItems(items)
        case .checksums(let path):
            showChecksums(path)
        }
    }

    func cancelPasswordRequest() {
        passwordRequest = nil
    }

    // MARK: - Ortak işlem altyapısı

    /// İptal, Finder'dan gelen "Buraya Çıkar" kuyruğunun tamamını durdurur; sıradaki arşive geçilmez.
    func cancelOperation() {
        // Pencere hemen "İptal ediliyor…" gösterir: durma ve temizlik sürerken tıklamanın alındığı görülsün.
        if currentTask != nil, operation?.isCancelling == false {
            operation?.isCancelling = true
            operation?.progress = nil
        }
        serviceQueue.removeAll()
        // İptal bekleyen açma isteğini de kapsar: kullanıcı durdurmak istedi, ardından başka arşiv açılmamalı.
        pendingOpen = nil
        currentTask?.cancel()
    }

    /// 7zz'yi işleme uygun kum havuzu kurallarıyla çalıştıran kopya: ağ kapalı, yalnızca `writable` klasörlerine yazar,
    /// arşiv okunurken kişisel veri klasörlerini okuyamaz. Ayarlar › Gelişmiş'ten kapatılabilir.
    /// `readable`: kullanıcının seçtiği kaynaklar (oluşturma, ekleme); kişisel bir klasörün içindelerse klasör kapalı kalır,
    /// yalnızca o kaynaklar okunabilir.
    func confined(_ runner: CommandRunner, archive: URL, writable: [URL] = [], writableFiles: [URL] = [], readable: [URL] = []) -> CommandRunner {
        guard settings.sandboxEngine else { return runner }
        return runner.sandboxed(.forOperation(archive: archive, writable: writable, writableFiles: writableFiles, readable: readable))
    }

    /// Yerinde düzenlemede 7zz'nin geçici arşiv kopyasını yazacağı, arşivle aynı birimdeki klasör (`-w`). Böylece kum
    /// havuzunda yalnızca bu klasör ve arşivin kendisi yazılabilir olur; arşivin klasörünün tamamı değil.
    private func editWorkDirectory(for archive: URL) throws -> URL {
        try StagedExtraction.makeStagingDirectory(for: archive.deletingLastPathComponent())
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
        if !engineChecked {
            // Uygulama yeni açıldı (ör. Finder sağ tık menüsünden); motor bulunana kadar "Açılıyor" göster, sonra devam et.
            operation = OperationState(titleKey: .progressPreparing, progress: nil)
            currentTask = Task {
                await ensureEngine()
                operation = nil
                currentTask = nil
                // Motor denetlenirken iptal edildiyse işlem başlamaz; bekleyen izin sorusu yine sorulabilir.
                guard !Task.isCancelled else { presentPendingConsentIfIdle(); return }
                perform(title, archive: archive, retry: retry, usedPassword: usedPassword, body)
            }
            return
        }
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
                presentPendingConsentIfIdle()
            }
            do {
                try await body(runner) { value in
                    Task { @MainActor in self.applyProgress(value) }
                }
                lastOperationOutcome = Task.isCancelled ? .cancelled : .succeeded
            } catch {
                let cancelled = Task.isCancelled || (error as? SevenZipError) == .cancelled
                lastOperationOutcome = cancelled ? .cancelled : .failed
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
        if let space = error as? InsufficientSpaceError {
            return t(.errorDiskSpace, settings.bytes(space.required), settings.bytes(space.available))
        }
        if let duplicate = error as? AddPlan.DuplicateNameError {
            return t(.duplicateNames, duplicate.names.joined(separator: ", "))
        }
        if error is AddPlan.NothingToArchiveError {
            return t(.nothingToArchive)
        }
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteFileExists, let path = cocoa.userInfo[NSFilePathErrorKey] as? String {
            return t(.renameExists, OpenSafety.visibleName((path as NSString).lastPathComponent))
        }
        if let link = error as? ItemExtractor.SymbolicLinkError {
            let name = link.paths.first.map { (ListingParser.normalizedPath($0) as NSString).lastPathComponent } ?? ""
            return t(.symbolicLinkItem, OpenSafety.visibleName(name))
        }
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

    /// `changes` içindeki durum değişiklikleri (ağaç, klasör, arama) tablo verisini bir kez yeniden hesaplatır.
    /// Ağaç önce değişince tablo eski klasörle bir kez boşuna hesaplanıyordu.
    private func updatingDisplayOnce(_ changes: () -> Void) {
        displayUpdatesPaused = true
        changes()
        displayUpdatesPaused = false
        rebuildDisplay()
    }

    private func rebuildDisplay() {
        guard !displayUpdatesPaused else { return }
        displayRebuildCount += 1
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        searchTask?.cancel()

        if query.isEmpty {
            isSearching = false
            let source: [ArchiveNode]
            if browserMode == .folders {
                source = ArchiveTree.contents(of: currentFolder, roots: tree, index: nodeIndex)
            } else {
                source = tree
            }
            displayNodes = ArchiveTree.sorted(source, using: sortOrder)
            return
        }

        let currentTree = tree
        let comparators = sortOrder

        // Küçük ve orta boy arşivlerde (< 1.000 düğüm) veya testlerde anında senkron çalış:
        if nodeIndex.count < 1000 {
            isSearching = false
            let source = ArchiveTree.search(currentTree, query: query)
            displayNodes = ArchiveTree.sorted(source, using: comparators)
            return
        }

        // 1.000+ düğümlü büyük arşivlerde ana thread'i dondurmamak için asenkron koştur:
        isSearching = true
        displayNodes = []
        searchTask = Task { @MainActor [weak self] in
            // Kullanıcı seri yazıyorsa (burst) 60ms bekle:
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }

            let matches = await Task.detached(priority: .userInitiated) {
                let raw = ArchiveTree.search(currentTree, query: query)
                return ArchiveTree.sorted(raw, using: comparators)
            }.value

            if Task.isCancelled { return }
            guard let self, self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.displayNodes = matches
            self.isSearching = false
        }
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

    /// İç içe gezinmede geçici kopya yerine diskteki en dış arşiv gösterilir.
    func revealArchive() {
        if let rootArchiveURL { reveal(rootArchiveURL) }
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
}

enum AppLinks {
    static let website = URL(string: "https://www.7-zip.org")!
    static let license = URL(string: "https://www.7-zip.org/license.txt")!
    static let sevenZipReleases = URL(string: "https://github.com/ip7z/7zip/releases")!
    static var repository: URL { URL(string: "https://github.com/\(AppInfo.repository)")! }
    static var releases: URL { URL(string: "https://github.com/\(AppInfo.repository)/releases")! }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    /// GitHub deposu ("sahip/ad"); tek kaynağı Info.plist'teki ArhivarRepository anahtarıdır.
    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "ArhivarRepository") as? String ?? "berkbb/arhivar-mac-universal"
    }
    static var currentYear: String { String(Calendar.current.component(.year, from: .now)) }
}

enum WindowID {
    static let main = "main"
    static let about = "about"
}
