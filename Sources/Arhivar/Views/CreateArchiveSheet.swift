import AppKit
import ArhivarCore
import SwiftUI

struct CreateArchiveSheet: View {
    let request: CreateRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [URL] = []
    @State private var name = ""
    @State private var destinationFolder: URL?
    @State private var format: ArchiveFormat = .sevenZip
    @State private var level: CompressionLevel = .normal
    @State private var password = ""
    @State private var confirmation = ""
    @State private var encryptNames = true
    @State private var volumeSizeMB = 0
    @State private var excludeMetadata = false
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text(settings.t(.createTitle))
                    .font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 6)

            Form {
                sourcesSection
                outputSection
                optionsSection
                encryptionSection
                if let message = validationMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(settings.t(.buttonCancel), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(.createButton)) { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 580, height: 680)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
        .onAppear(perform: load)
    }

    // MARK: - Bölümler

    private var sourcesSection: some View {
        Section(settings.t(.createSources)) {
            if sources.isEmpty {
                Label(settings.t(.createDropHint), systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            ForEach(sources, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: FileIcons.icon(for: url))
                        .resizable()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Aynı adlı kaynakları ayırt etmek için bulundukları klasör gösterilir.
                        if duplicateNames.contains(url.lastPathComponent.lowercased()) {
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer()
                    Button {
                        sources.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(settings.t(.createRemove))
                }
            }
            Button(settings.t(.createAddFiles), systemImage: "plus") { chooseSources() }
        }
    }

    private var outputSection: some View {
        Section(settings.t(.createOutput)) {
            HStack {
                TextField(settings.t(.createArchiveName), text: $name)
                Text("." + format.fileExtension)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            LabeledContent(settings.t(.createDestination)) {
                HStack {
                    Text(destinationFolder?.path ?? "—")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Button(settings.t(.buttonChoose)) { chooseDestination() }
                }
            }
        }
    }

    private var optionsSection: some View {
        Section(settings.t(.createOptions)) {
            Picker(settings.t(.createFormat), selection: $format) {
                ForEach(ArchiveFormat.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(settings.t(.createLevel), selection: $level) {
                ForEach(CompressionLevel.allCases) { Text(settings.t($0.titleKey)).tag($0) }
            }
            .disabled(!format.supportsCompressionLevel)
            Picker(settings.t(.createSplit), selection: $volumeSizeMB) {
                Text(settings.t(.createSplitNone)).tag(0)
                ForEach(VolumeSize.presetsMB, id: \.self) { megabytes in
                    Text(settings.bytes(Int64(megabytes) * 1_048_576)).tag(megabytes)
                }
            }
            .disabled(!format.supportsVolumes)
            Toggle(settings.t(.excludeMacMetadata), isOn: $excludeMetadata)
        }
    }

    private var encryptionSection: some View {
        Section(settings.t(.createEncryption)) {
            if format.supportsEncryption {
                SecureField(settings.t(.createPassword), text: $password)
                SecureField(settings.t(.createPasswordConfirm), text: $confirmation)
                if format.supportsHeaderEncryption {
                    Toggle(settings.t(.createEncryptNames), isOn: $encryptNames)
                        .disabled(password.isEmpty)
                }
            } else {
                Text(settings.t(.createEncryptionUnsupported))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Doğrulama

    private var sanitizedName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // "." ve ".." gizli ya da bozuk adlar üretirdi (".7z", "..7z").
        return name == "." || name == ".." ? "" : name
    }

    private var destination: URL? {
        guard let destinationFolder, !sanitizedName.isEmpty else { return nil }
        return destinationFolder.appendingPathComponent(sanitizedName).appendingPathExtension(format.fileExtension)
    }

    private var singleFileProblem: Bool {
        format.singleFileOnly && (sources.count != 1 || sources.first.map(ArchiveNaming.defaultIsDirectory) == true)
    }

    private var passwordProblem: Bool {
        format.supportsEncryption && password != confirmation
    }

    /// Kaynakların hepsi atlanacak özel dosyalarsa (FIFO, soket, aygıt) arşivlenecek bir şey yoktur; sayfa kapandıktan
    /// sonra hata vermek yerine burada söylenir.
    private var onlySpecialProblem: Bool {
        SpecialFiles.containsOnlySpecialFiles(sources, followingSymlinks: !(settings.storeSymlinks && format.supportsSymlinks))
    }

    /// Farklı klasörlerden gelen aynı adlı kaynaklar (küçük harfle); 7zz "Duplicate filename" hatasıyla dururdu.
    private var duplicateNames: Set<String> {
        Set(AddPlan.duplicateNames(in: sources).map { $0.lowercased() })
    }

    private var validationMessage: String? {
        if onlySpecialProblem { return settings.t(.nothingToArchive) }
        if singleFileProblem { return settings.t(.createSingleFileOnly) }
        let duplicates = AddPlan.duplicateNames(in: sources)
        if !duplicates.isEmpty { return settings.t(.duplicateNames, duplicates.joined(separator: ", ")) }
        if passwordProblem {
            // Onay boşken düğmenin neden kapalı olduğu da söylenir.
            return settings.t(confirmation.isEmpty ? .createPasswordConfirmHint : .createPasswordMismatch)
        }
        // Bölünmüş arşivde diskte oluşan ilk dosya "ad.7z.001"dir.
        if let destination, FileManager.default.fileExists(atPath: firstOutput(for: destination).path) {
            return settings.t(.createExistsWarning)
        }
        return nil
    }

    private func firstOutput(for destination: URL) -> URL {
        CreateOptions(
            sources: sources, destination: destination, format: format, level: level,
            volumeSizeMB: volumeSizeMB > 0 ? volumeSizeMB : nil
        ).firstOutput
    }

    private var isValid: Bool {
        !sources.isEmpty && destination != nil && !singleFileProblem && !passwordProblem && duplicateNames.isEmpty && !onlySpecialProblem
    }

    // MARK: - Eylemler

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        format = settings.defaultFormat
        level = settings.defaultLevel
        excludeMetadata = settings.excludeMacMetadata
        add(request.sources)
    }

    private func add(_ urls: [URL]) {
        let fresh = urls.filter { $0.isFileURL && !sources.contains($0) }
        guard !fresh.isEmpty else { return }
        let wasEmpty = sources.isEmpty
        sources += fresh
        if wasEmpty || name.isEmpty { name = ArchiveNaming.suggestedName(for: sources) }
        if destinationFolder == nil { destinationFolder = sources.first?.deletingLastPathComponent() }
    }

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.prompt = settings.t(.panelAdd)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = destinationFolder
        if panel.runModal() == .OK { destinationFolder = panel.url }
    }

    private func create() {
        guard isValid, let destination else { return }
        let options = CreateOptions(
            sources: sources,
            destination: destination,
            format: format,
            level: level,
            password: format.supportsEncryption && !password.isEmpty ? password : nil,
            encryptFileNames: encryptNames,
            volumeSizeMB: volumeSizeMB > 0 && format.supportsVolumes ? volumeSizeMB : nil,
            multithreaded: settings.multithreaded,
            storeSymlinks: settings.storeSymlinks,
            excludeMacMetadata: excludeMetadata
        )
        dismiss()
        model.createArchive(options)
    }
}

struct PasswordSheet: View {
    let request: PasswordRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text(settings.t(.passwordTitle))
                .font(.title3.bold())
            Text(settings.t(.passwordMessage, request.archive.lastPathComponent))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(settings.t(.createPassword), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if request.isRetry {
                Label(settings.t(.passwordWrong), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Button(settings.t(.buttonCancel), role: .cancel) { model.cancelPasswordRequest() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(settings.t(.buttonUnlock), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 400)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        model.submitPassword(password)
    }
}
