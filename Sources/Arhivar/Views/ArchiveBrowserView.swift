import AppKit
import ArhivarCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        Table(model.displayNodes, children: \.children, selection: $model.selection, sortOrder: $model.sortOrder) {
            // Finder sıralaması: "dosya2" < "dosya10", büyük/küçük harf duyarsız, yerele uygun ("Çanta" < "Zebra").
            TableColumn(settings.t(.columnName), value: \.name, comparator: .localizedStandard) { node in
                NameCell(node: node)
            }
            .width(min: 220, ideal: 380)

            TableColumn(settings.t(.columnSize), value: \.size) { node in
                Text(settings.bytes(node.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(settings.t(.columnPacked), value: \.sortPackedSize) { node in
                Text(node.packedSize.map(settings.bytes) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn(settings.t(.columnModified), value: \.sortDate) { node in
                Text(settings.date(node.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn(settings.t(.columnMethod), value: \.sortMethod) { node in
                Text(node.method ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: ArchiveNode.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            model.primaryAction(ids)
        }
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            model.primaryAction(model.selection)
            return .handled
        }
        // ⌘C seçili öğeleri çıkarıp dosya olarak panoya koyar (iş bitince); ⌘V panodaki dosyaları ekler.
        .onCopyCommand {
            model.copyItems()
            return []
        }
        .onPasteCommand(of: [.fileURL]) { _ in
            model.pasteFiles()
        }
        .quickLookPreview($model.quickLookURL)
        .overlay {
            if model.displayNodes.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView(settings.t(.noSearchResults, model.searchText), systemImage: "magnifyingglass")
                } else if model.tree.isEmpty {
                    ContentUnavailableView(settings.t(.emptyArchive), systemImage: "archivebox")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.browserMode == .folders && model.searchText.isEmpty {
                PathBar()
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView()
                .padding(10)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text(settings.t(.searchPrompt)))
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<ArchiveNode.ID>) -> some View {
        let single = ids.count == 1 ? ids.first.flatMap(model.node) : nil
        if let single {
            if single.isDirectory {
                Button(settings.t(.contextOpen), systemImage: "folder") {
                    model.browserMode = .folders
                    model.enterFolder(single.id)
                }
            } else {
                if ArchiveNaming.isBrowsable(single.name) {
                    Button(settings.t(.contextBrowse), systemImage: "archivebox") { model.browseArchive(single.id) }
                }
                Button(settings.t(.contextQuickLook), systemImage: "eye") { model.toggleQuickLook(single.id) }
                Button(settings.t(.contextOpen), systemImage: "arrow.up.forward.app") { model.openItem(single.id) }
                Button(settings.t(.contextChecksums), systemImage: "number") { model.showChecksums(single.id) }
            }
        }
        if !ids.isEmpty {
            Button(settings.t(.contextExtract), systemImage: "arrow.up.bin") { model.extract(items: ids.sorted()) }
            Button(settings.t(.contextCopy), systemImage: "doc.on.doc") { model.copyItems(ids.sorted()) }
        }
        if model.isEditable {
            Divider()
            if let single {
                Button(settings.t(.editRename), systemImage: "pencil") { model.requestRename(single.id) }
            }
            if !ids.isEmpty {
                Button(settings.t(.editDelete), systemImage: "trash", role: .destructive) { model.requestDelete(ids.sorted()) }
            }
            Button(settings.t(.editAddFiles), systemImage: "plus") { model.presentAddPanel() }
        }
    }
}

private struct NameCell: View {
    let node: ArchiveNode
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let content = HStack(spacing: 7) {
            Image(nsImage: FileIcons.icon(for: node))
                .resizable()
                .frame(width: 18, height: 18)
            // Gizli yön/biçim karakterleri görünür yer tutucularla gösterilir.
            Text(OpenSafety.visibleName(node.name))
                .lineLimit(1)
                .truncationMode(.middle)
            if OpenSafety.hasDeceptiveCharacters(node.name) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(settings.t(.deceptiveNameHelp))
                    .accessibilityLabel(settings.t(.deceptiveNameHelp))
            }
            if node.isEncrypted {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Finder'a sürükleyince öğe o anda çıkarılır.
        if let item = model.dragItem(for: node) {
            content.draggable(item) {
                Label {
                    Text((node.id as NSString).lastPathComponent)
                } icon: {
                    Image(nsImage: FileIcons.icon(for: node))
                }
                .padding(6)
            }
        } else {
            content
        }
    }
}

/// Klasör görünümünde üst klasör düğmesi ve tıklanabilir yol.
private struct PathBar: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoUp)
            .help(settings.t(.navUp))

            Divider().frame(height: 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    // İç içe açılmış arşivde üstteki arşivler: tıklayınca o arşive dönülür.
                    ForEach(Array(model.archiveStack.enumerated()), id: \.offset) { level, context in
                        parentCrumb(context.url, level: level)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    crumb(
                        title: model.archiveURL?.lastPathComponent ?? settings.t(.appName),
                        icon: model.archiveURL.map(FileIcons.icon(for:)),
                        path: "",
                        isLast: model.currentFolder.isEmpty
                    )
                    let crumbs = model.breadcrumbs
                    ForEach(Array(crumbs.enumerated()), id: \.element.path) { index, item in
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        crumb(title: item.name, icon: FileIcons.folderIcon, path: item.path, isLast: index == crumbs.count - 1)
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private func parentCrumb(_ url: URL, level: Int) -> some View {
        Button {
            model.returnToArchive(level: level)
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: FileIcons.icon(for: url)).resizable().frame(width: 16, height: 16)
                Text(url.lastPathComponent).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(settings.t(.navParentArchive, url.lastPathComponent))
        .disabled(model.operation != nil)
    }

    private func crumb(title: String, icon: NSImage?, path: String, isLast: Bool) -> some View {
        Button {
            model.goTo(path)
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(title)
                    .lineLimit(1)
                    .fontWeight(isLast ? .semibold : .regular)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isLast ? .primary : .secondary)
        .dropDestination(for: URL.self) { urls, _ in
            // Dosyaları yoldaki bir klasörün üzerine bırakınca oraya ekle. Hedef klasör isteğin içinde taşınır;
            // onay penceresinde vazgeçilirse açık klasör değişmemiş olur.
            let files = urls.filter(\.isFileURL)
            guard model.isEditable, model.operation == nil, !files.isEmpty else { return false }
            model.addRequest = AddRequest(sources: files, folder: path)
            return true
        }
    }
}

struct StatusBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let statistics = model.statistics {
            HStack(spacing: 18) {
                if let type = model.listing?.info.type {
                    Label(type, systemImage: "shippingbox")
                }
                Text(settings.t(.statusItems, statistics.fileCount + statistics.folderCount))
                Text(settings.t(.statusSize, settings.bytes(statistics.totalSize)))
                Text(settings.t(.statusPacked, settings.bytes(statistics.packedSize)))
                if let ratio = statistics.ratio {
                    Text(settings.t(.statusRatio, settings.percent(ratio)))
                }
                if statistics.isEncrypted {
                    Label(settings.t(.statusEncrypted), systemImage: "lock.fill")
                }
                Spacer(minLength: 0)
                if !model.selection.isEmpty {
                    Text(settings.t(.statusSelected, model.selection.count))
                        .foregroundStyle(.tint)
                }
            }
            .lineLimit(1)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

struct ArchiveInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(settings.t(.infoTitle), systemImage: "info.circle.fill")
                .font(.headline)
            if let listing = model.listing, let statistics = model.statistics, let url = model.archiveURL {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    row(.infoLocation, model.locationDescription ?? url.deletingLastPathComponent().path)
                    row(.infoType, listing.info.type ?? settings.t(.unknown))
                    row(.infoMethod, listing.info.method ?? "—")
                    row(.infoSolid, settings.t(listing.info.isSolid ? .yes : .no))
                    if let blocks = listing.info.blocks {
                        row(.infoBlocks, blocks.formatted(.number.locale(settings.locale)))
                    }
                    if let volumes = listing.info.volumes, volumes > 1 {
                        row(.infoVolumes, volumes.formatted(.number.locale(settings.locale)))
                    }
                    row(.infoArchiveSize, settings.bytes(statistics.packedSize))
                    row(.infoUnpackedSize, settings.bytes(statistics.totalSize))
                    row(.infoRatio, statistics.ratio.map(settings.percent) ?? "—")
                    row(.infoFiles, "\(statistics.fileCount)")
                    row(.infoFolders, "\(statistics.folderCount)")
                    row(.infoEncrypted, settings.t(statistics.isEncrypted ? .yes : .no))
                    if let comment = listing.info.comment {
                        row(.infoComment, comment, lines: 8)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func row(_ key: LKey, _ value: String, lines: Int = 2) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(settings.t(key))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(lines)
                .truncationMode(.middle)
        }
    }
}

struct ProgressOverlay: View {
    let operation: OperationState
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.14))
                .ignoresSafeArea()
            VStack(spacing: 16) {
                // İşleme göre canlandırılan simge; Hareketi Azalt açıksa durağan kalır.
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce.up.byLayer, options: .repeating.speed(0.7), isActive: !reduceMotion)
                    .frame(height: 56)
                    .accessibilityHidden(true)
                Text(settings.t(operation.titleKey))
                    .font(.headline)
                if let progress = operation.progress {
                    ProgressView(value: progress)
                        .frame(width: 300)
                    Text(settings.percent(progress))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                }
                Button(settings.t(.buttonCancel), role: .cancel) { model.cancelOperation() }
                    .buttonStyle(.glass)
            }
            .padding(30)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .transition(.opacity)
    }

    private var symbol: String {
        switch operation.titleKey {
        case .progressReading, .progressPreparing: "doc.zipper"
        case .progressExtracting: "arrow.up.bin"
        case .progressCreating: "archivebox"
        case .progressTesting: "checkmark.seal"
        case .progressUpdating: "arrow.triangle.2.circlepath"
        default: "shippingbox"
        }
    }
}

struct ToastView: View {
    let toast: Toast
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(.green)
            Text(toast.message)
                .lineLimit(1)
            if let url = toast.revealURL {
                Button(settings.t(.buttonShowInFinder)) { model.reveal(url) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Finder'ın kendi dosya simgeleri; uzantı başına önbelleklenir.
enum FileIcons {
    private static var byExtension: [String: NSImage] = [:]
    /// Yol başına simgeler (son arşivler, oluşturma kaynakları, iç içe arşivler); sınırsız büyümesin.
    private static var byPath: [String: NSImage] = [:]
    static let maxCachedPaths = 256

    static var folderIcon: NSImage {
        if let cached = byExtension["/folder"] { return cached }
        let image = NSWorkspace.shared.icon(for: .folder)
        byExtension["/folder"] = image
        return image
    }

    static func icon(for node: ArchiveNode) -> NSImage {
        let key = node.isDirectory ? "/folder" : node.fileExtension
        if let cached = byExtension[key] { return cached }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: node.fileExtension) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        byExtension[key] = image
        return image
    }

    static func icon(for url: URL) -> NSImage {
        if let cached = byPath[url.path] { return cached }
        if byPath.count >= maxCachedPaths { byPath.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        byPath[url.path] = image
        return image
    }
}
