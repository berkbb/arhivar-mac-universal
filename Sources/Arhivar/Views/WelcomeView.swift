import AppKit
import ArhivarCore
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

                VStack(spacing: 8) {
                    Text(settings.t(.welcomeTitle))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(settings.t(.welcomeSubtitle))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            model.presentOpenPanel()
                        } label: {
                            Label(settings.t(.menuOpenArchive), systemImage: "folder")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)

                        Button {
                            model.beginCreate()
                        } label: {
                            Label(settings.t(.menuNewArchive), systemImage: "archivebox")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                    }
                    .controlSize(.extraLarge)
                }

                DropZone(isTargeted: model.isDropTargeted, hint: settings.t(.welcomeDropHint))

                Text(settings.t(.welcomeSupportedFormats))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                EngineStatusView()
                UpdateBanner()
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
        }
    }
}

private struct DropZone: View {
    let isTargeted: Bool
    let hint: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .symbolEffect(.bounce, value: isTargeted)
            Text(hint)
                .font(.headline)
        }
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        .frame(maxWidth: 480, minHeight: 140)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
        }
        .scaleEffect(isTargeted ? 1.03 : 1)
        .animation(.spring(duration: 0.3), value: isTargeted)
    }
}

/// 7zz'nin durumunu gösterir; sorun varsa çözüm yollarını sunar.
struct EngineStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        switch model.engineStatus {
        case .checking:
            Label(settings.t(.engineChecking), systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .ready(let version):
            Label(settings.t(.engineReady, version), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .missing:
            warning(title: settings.t(.engineMissingTitle), message: settings.t(.engineMissingMessage))
        case .blocked:
            warning(title: settings.t(.engineBlockedTitle), message: settings.t(.engineBlockedMessage))
        }
    }

    private func warning(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(settings.t(.updateCheck)) {
                        Task { await model.checkForUpdates(interactive: true) }
                    }
                    SettingsLink { Text(settings.t(.buttonOpenSettings)) }
                    Button(settings.t(.settingsEngineCheck)) {
                        Task { await model.refreshEngine() }
                    }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
    }
}

/// Yeni Arhivar ya da 7-Zip sürümü bulunduğunda gösterilir.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 12) {
            appBanner
            engineBanner
        }
    }

    /// Açılıştaki otomatik denetim yalnızca Ayarlar › Gelişmiş'te görünmesin; yeni Arhivar sürümü burada da duyurulur.
    @ViewBuilder
    private var appBanner: some View {
        if case .available(let release) = model.appUpdateState {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(settings.t(.appUpdateAvailable, release.version, AppInfo.version))
                    .font(.callout)
                Spacer(minLength: 8)
                Button(settings.t(.appUpdateDownload)) { model.openAppDownload() }
                    .buttonStyle(.glassProminent)
            }
            .padding(14)
            .frame(maxWidth: 520)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var engineBanner: some View {
        switch model.updateState {
        case .available(let latest, let installed):
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(settings.t(.updateAvailable, latest, installed ?? settings.t(.unknown)))
                    .font(.callout)
                Spacer(minLength: 8)
                Button(settings.t(.updateInstall, latest)) {
                    Task { await model.installUpdate() }
                }
                .buttonStyle(.glassProminent)
            }
            .padding(14)
            .frame(maxWidth: 520)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        case .installing(let version):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(settings.t(.updateInstalling, version)).font(.callout)
            }
            .padding(14)
            .glassEffect(.regular, in: .capsule)
        default:
            EmptyView()
        }
    }
}
