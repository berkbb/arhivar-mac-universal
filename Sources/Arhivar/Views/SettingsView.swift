import AppKit
import ArhivarCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            Tab(settings.t(.settingsGeneral), systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab(settings.t(.settingsCompression), systemImage: "archivebox") {
                CompressionSettingsView()
            }
            Tab(settings.t(.settingsAdvanced), systemImage: "wrench.and.screwdriver") {
                AdvancedSettingsView()
            }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var showRestartAlert = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(settings.t(.settingsLanguage), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text("\(language.flag)  \(language.nativeName ?? settings.t(.languageSystem))")
                            .tag(language)
                    }
                }
                .onChange(of: settings.language) { old, new in
                    if old != new {
                        showRestartAlert = true
                    }
                }
                Picker(settings.t(.settingsAppearance), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(settings.t(appearance.titleKey), systemImage: appearance.systemImage)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.t(.restartMenuBarNotice))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(settings.t(.settingsExtraction)) {
                Picker(settings.t(.settingsExtractTo), selection: $settings.extractLocation) {
                    ForEach(ExtractLocation.allCases) { Text(settings.t($0.titleKey)).tag($0) }
                }
                if settings.extractLocation == .custom {
                    LabeledContent(settings.t(.settingsCustomFolder)) {
                        HStack {
                            Text(settings.customExtractFolder ?? "—")
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button(settings.t(.buttonChoose)) { chooseFolder() }
                        }
                    }
                }
                Picker(settings.t(.settingsSubfolder), selection: $settings.subfolderMode) {
                    ForEach(SubfolderMode.allCases) { Text(settings.t($0.titleKey)).tag($0) }
                }
                Picker(settings.t(.settingsOverwrite), selection: $settings.overwriteMode) {
                    ForEach(OverwriteMode.allCases) { Text(settings.t($0.titleKey)).tag($0) }
                }
                Toggle(settings.t(.settingsReveal), isOn: $settings.revealAfterOperation)
            }
        }
        .formStyle(.grouped)
        .alert(settings.t(.restartWarningTitle), isPresented: $showRestartAlert) {
            Button(settings.t(.buttonOK), role: .cancel) { }
        } message: {
            Text(settings.t(.restartMenuBarNotice))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.customExtractFolder = url.path
        }
    }
}

private struct CompressionSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(settings.t(.settingsDefaults)) {
                Picker(settings.t(.settingsDefaultFormat), selection: $settings.defaultFormat) {
                    ForEach(ArchiveFormat.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(settings.t(.settingsDefaultLevel), selection: $settings.defaultLevel) {
                    ForEach(CompressionLevel.allCases) { Text(settings.t($0.titleKey)).tag($0) }
                }
                Toggle(settings.t(.settingsMultithread), isOn: $settings.multithreaded)
                Toggle(settings.t(.excludeMacMetadata), isOn: $settings.excludeMacMetadata)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(settings.t(.settingsStoreSymlinks), isOn: $settings.storeSymlinks)
                    Text(settings.t(.settingsStoreSymlinksNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(settings.t(.settingsEngine)) {
                LabeledContent(settings.t(.settingsEnginePath)) {
                    Text(model.engineURL?.path ?? settings.t(.settingsEngineNotFound))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(settings.t(.settingsEngineVersion)) {
                    engineVersionLabel
                }
                Toggle(settings.t(.settingsEngineUseCustom), isOn: useCustomEngine)
                if let path = settings.customEnginePath {
                    LabeledContent("7zz") {
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Button(settings.t(.buttonChoose)) { chooseEngine() }
                        }
                    }
                }
                Button(settings.t(.settingsEngineCheck)) {
                    Task { await model.refreshEngine() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(settings.t(.settingsSandbox), isOn: $settings.sandboxEngine)
                        .disabled(!SandboxProfile.isAvailable)
                    Text(settings.t(.settingsSandboxNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                updateStatus
                HStack {
                    Button(settings.t(.updateCheck)) {
                        Task { await model.checkForUpdates(interactive: false) }
                    }
                    .disabled(model.updateState == .checking || isInstalling)
                    if case .available(let latest, _) = model.updateState {
                        Button(settings.t(.updateInstall, latest)) {
                            Task { await model.installUpdate() }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            } header: {
                Text(settings.t(.updateSection))
            } footer: {
                Text(settings.t(.updateSource))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(settings.t(.appUpdateSection)) {
                LabeledContent(settings.t(.settingsEngineVersion), value: "\(AppInfo.version) (\(AppInfo.build))")
                appUpdateStatus
                HStack {
                    Button(settings.t(.updateCheck)) {
                        Task { await model.checkForAppUpdate(interactive: false) }
                    }
                    .disabled(model.appUpdateState == .checking)
                    if case .available = model.appUpdateState {
                        Button(settings.t(.appUpdateDownload)) { model.openAppDownload() }
                            .buttonStyle(.glassProminent)
                    }
                }
                // Arhivar ve 7-Zip için ortak açılış denetimi; elle değiştirmek de izin yanıtı sayılır.
                Toggle(settings.t(.updateAutoCheck), isOn: $settings.checkUpdatesAtLaunch)
                    .onChange(of: settings.checkUpdatesAtLaunch) { settings.updateConsentAsked = true }
            }

            Section {
                Button(settings.t(.settingsReset), role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(settings.t(.settingsResetConfirm), isPresented: $confirmReset) {
            Button(settings.t(.settingsReset), role: .destructive) {
                model.browserMode = .folders
                settings.resetAll()
                Task { await model.refreshEngine() }
            }
        }
    }

    private var isInstalling: Bool {
        if case .installing = model.updateState { return true }
        return false
    }

    @ViewBuilder
    private var engineVersionLabel: some View {
        switch model.engineStatus {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let version):
            Label(version, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .missing:
            Label(settings.t(.settingsEngineNotFound), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .blocked:
            Label(settings.t(.engineBlockedTitle), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.updateState {
        case .idle:
            EmptyView()
        case .checking:
            Label { Text(settings.t(.updateChecking)) } icon: { ProgressView().controlSize(.small) }
        case .available(let latest, let installed):
            Label(settings.t(.updateAvailable, latest, installed ?? settings.t(.unknown)), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        case .upToDate(let version):
            Label(settings.t(.updateUpToDate, version), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing(let version):
            Label { Text(settings.t(.updateInstalling, version)) } icon: { ProgressView().controlSize(.small) }
        case .installed(let version):
            Label(settings.t(.updateInstalled, version), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var appUpdateStatus: some View {
        switch model.appUpdateState {
        case .idle:
            EmptyView()
        case .checking:
            Label { Text(settings.t(.updateChecking)) } icon: { ProgressView().controlSize(.small) }
        case .available(let release):
            Label(settings.t(.appUpdateAvailable, release.version, AppInfo.version), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        case .upToDate:
            Label(settings.t(.appUpdateUpToDate, AppInfo.version), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var useCustomEngine: Binding<Bool> {
        Binding {
            settings.customEnginePath != nil
        } set: { enabled in
            if enabled {
                chooseEngine()
            } else {
                settings.customEnginePath = nil
                Task { await model.refreshEngine() }
            }
        }
    }

    private func chooseEngine() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.customEnginePath = url.path
            Task { await model.refreshEngine() }
        }
    }
}
