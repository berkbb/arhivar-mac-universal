import ArhivarCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// İşlem bittiğinde en az süre dolana kadar gösterilen son durum (ilerleme tamamlanmış olarak).
    @State private var finishingOperation: OperationState?
    @State private var lastOperation: OperationState?
    @State private var overlayShownAt = ContinuousClock.now
    @State private var lingerTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
        } detail: {
            ZStack {
                if model.listing != nil {
                    ArchiveBrowserView()
                        .transition(.opacity)
                } else {
                    WelcomeView()
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.listing != nil)
        }
        .navigationTitle(model.archiveURL?.lastPathComponent ?? settings.t(.appName))
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return !urls.isEmpty
        } isTargeted: { model.isDropTargeted = $0 }
        .overlay {
            if let operation = model.operation ?? finishingOperation {
                ProgressOverlay(operation: operation, isFinishing: model.operation == nil)
                    // Bitmiş işlemin kalan gösterimi tıklamaları engellemesin.
                    .allowsHitTesting(model.operation != nil)
            }
        }
        .onChange(of: model.operation?.id, initial: true) { _, id in operationChanged(id) }
        .onChange(of: model.operation?.progress) { _, _ in lastOperation = model.operation ?? lastOperation }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35), value: model.operation != nil || finishingOperation != nil)
        .sheet(item: $model.createRequest) { CreateArchiveSheet(request: $0) }
        .sheet(item: $model.passwordRequest) { PasswordSheet(request: $0) }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { alert in
            if let actionTitle = alert.actionTitle, let action = alert.action {
                Button(actionTitle, action: action)
                Button(alert.cancelTitle ?? settings.t(.buttonCancel), role: .cancel) { alert.cancelAction?() }
            } else {
                Button(settings.t(.buttonOK)) {}
            }
        } message: { alert in
            Text(alert.message)
        }
        .modifier(EditDialogs())
    }

    /// İşlem başladığında zamanı kaydeder; bittiğinde pencere en az süreyi doldurmadıysa son durumu (ilerleme
    /// tamamlanmış olarak) kalan süre boyunca gösterir. Model zamanlaması değişmez: yalnızca görünüm bekletilir.
    private func operationChanged(_ id: OperationState.ID?) {
        if id != nil {
            lingerTask?.cancel()
            lingerTask = nil
            finishingOperation = nil
            if lastOperation == nil { overlayShownAt = .now }
            lastOperation = model.operation
            return
        }
        guard let last = lastOperation else { return }
        lastOperation = nil
        guard let remaining = OverlayTiming.remaining(shownAt: overlayShownAt, now: .now) else { return }
        finishingOperation = OverlayTiming.finished(last)
        lingerTask = Task {
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            finishingOperation = nil
        }
    }

    private var subtitle: String {
        guard let statistics = model.statistics else { return "" }
        let type = model.listing?.info.type.map { "\($0) · " } ?? ""
        return type + settings.t(.statusItems, statistics.fileCount + statistics.folderCount)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.listing != nil {
                Picker(settings.t(.viewModeLabel), selection: Binding(get: { model.browserMode }, set: { model.browserMode = $0 })) {
                    Label(settings.t(.viewFolders), systemImage: "folder").tag(BrowserMode.folders)
                    Label(settings.t(.viewTree), systemImage: "list.bullet.indent").tag(BrowserMode.tree)
                }
                .pickerStyle(.segmented)
                .help(settings.t(.viewModeLabel))
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label(settings.t(.toolbarOpen), systemImage: "folder")
            }
            .help(settings.t(.menuOpenArchive))
            .disabled(model.operation != nil)

            Button {
                model.beginCreate()
            } label: {
                Label(settings.t(.toolbarCreate), systemImage: "archivebox")
            }
            .help(settings.t(.menuNewArchive))
            .disabled(model.operation != nil)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button(settings.t(.menuExtractAll)) { model.extract(selectedOnly: false) }
                Button(settings.t(.menuExtractSelected)) { model.extract(selectedOnly: true) }
                    .disabled(model.selection.isEmpty)
            } label: {
                Label(settings.t(.toolbarExtract), systemImage: "arrow.up.bin")
            } primaryAction: {
                model.extract(selectedOnly: !model.selection.isEmpty)
            }
            .help(settings.t(.menuExtractAll))
            .disabled(!model.canOperate)

            Button {
                model.testArchive()
            } label: {
                Label(settings.t(.toolbarTest), systemImage: "checkmark.seal")
            }
            .help(settings.t(.menuTestArchive))
            .disabled(!model.canOperate)

            Button {
                model.presentAddPanel()
            } label: {
                Label(settings.t(.toolbarAdd), systemImage: "plus.rectangle.on.folder")
            }
            .help(model.isEditable ? settings.t(.editAddFiles) : settings.t(model.readOnlyReason))
            .disabled(!model.canOperate || !model.isEditable)

            InfoToolbarButton()
        }
    }
}

private struct InfoToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        Button {
            model.showInfo.toggle()
        } label: {
            Label(settings.t(.toolbarInfo), systemImage: "info.circle")
        }
        .help(settings.t(.infoTitle))
        .disabled(model.listing == nil)
        .popover(isPresented: $model.showInfo, arrowEdge: .bottom) {
            ArchiveInfoView()
        }
    }
}

/// Arşiv düzenleme onayları: ekleme, silme ve yeniden adlandırma.
private struct EditDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var newName = ""

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .confirmationDialog(
                addTitle,
                isPresented: Binding(get: { model.addRequest != nil }, set: { if !$0 { model.addRequest = nil } }),
                titleVisibility: .visible
            ) {
                Button(settings.t(.buttonAdd)) { model.confirmAdd() }
                Button(settings.t(.buttonCancel), role: .cancel) { model.addRequest = nil }
            }
            .confirmationDialog(
                settings.t(.deleteConfirmTitle, model.deleteRequest?.items.count ?? 0),
                isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } }),
                titleVisibility: .visible
            ) {
                Button(settings.t(.buttonDelete), role: .destructive) { model.confirmDelete() }
                Button(settings.t(.buttonCancel), role: .cancel) { model.deleteRequest = nil }
            } message: {
                Text(settings.t(.deleteConfirmMessage))
            }
            .alert(
                settings.t(.renameTitle),
                isPresented: Binding(get: { model.renameRequest != nil }, set: { if !$0 { model.renameRequest = nil } }),
                presenting: model.renameRequest
            ) { request in
                TextField(settings.t(.renameField), text: $newName)
                Button(settings.t(.buttonRename)) { model.rename(request.path, to: newName) }
                    .disabled(!ArchiveTree.isValidName(newName) || model.renameConflicts(request.path, to: newName))
                Button(settings.t(.buttonCancel), role: .cancel) { model.renameRequest = nil }
            }
            .onChange(of: model.renameRequest?.id) {
                newName = model.renameRequest?.name ?? ""
            }
    }

    private var addTitle: String {
        let count = model.addRequest?.sources.count ?? 0
        let name = model.archiveURL?.lastPathComponent ?? ""
        return settings.t(.addConfirmTitle, count, name)
    }
}

/// İlerleme penceresinin gösterim süresi hesabı (görünümden ayrı, test edilebilir).
enum OverlayTiming {
    /// Pencere bir kez göründüyse en az bu kadar ekranda kalır: hızlı işlemlerde göz kırpar gibi açılıp
    /// kapanmasın, yumuşakça belirip kaybolsun.
    static let minimumDuration: Duration = .milliseconds(700)

    /// İşlem bittiğinde pencerenin daha ne kadar gösterileceği; en az süre dolduysa nil (hemen kapanır).
    static func remaining(
        shownAt: ContinuousClock.Instant, now: ContinuousClock.Instant, minimum: Duration = minimumDuration
    ) -> Duration? {
        let remaining = minimum - (now - shownAt)
        return remaining > .zero ? remaining : nil
    }

    /// Kalan süre boyunca gösterilen bitmiş durum: ilerleme çubuğu varsa tamamlanmış (%100) görünür.
    static func finished(_ operation: OperationState) -> OperationState {
        var finished = operation
        if finished.progress != nil { finished.progress = 1 }
        return finished
    }
}
