import AppKit
import ArhivarCore
import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)

            VStack(spacing: 5) {
                Text(settings.t(.appName))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(settings.t(.aboutVersion, AppInfo.version, AppInfo.build))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(settings.t(.appTagline))
                    .font(.callout)
            }

            Divider().padding(.horizontal, 50)

            VStack(spacing: 8) {
                Label(settings.t(.aboutPoweredBy, model.engineVersion ?? settings.t(.unknown)), systemImage: "cpu")
                    .font(.callout.weight(.medium))
                Text(settings.t(.aboutEngineCredit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(settings.t(.menuWebsite), systemImage: "globe") { openURL(AppLinks.website) }
                        Button(settings.t(.menuManual), systemImage: "book") { model.openManual() }
                        Button(settings.t(.aboutRepository), systemImage: "chevron.left.forwardslash.chevron.right") { openURL(AppLinks.repository) }
                    }
                    HStack(spacing: 8) {
                        Button(settings.t(.aboutAppLicense), systemImage: "doc.text") {
                            model.openBundledDocument("Arhivar-License", extension: "txt")
                        }
                        Button(settings.t(.aboutLicense), systemImage: "doc.text.magnifyingglass") { model.openLicense() }
                        Button(settings.t(.aboutNotices), systemImage: "list.bullet.rectangle") {
                            model.openBundledDocument("Third-Party-Notices", extension: "txt")
                        }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Text(settings.t(.aboutCopyright, AppInfo.currentYear))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 500)
        .containerBackground(.thickMaterial, for: .window)
        .windowMinimizeBehavior(.disabled)
    }
}
