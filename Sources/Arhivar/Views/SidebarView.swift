import AppKit
import ArhivarCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var removeKey = RecentRemovalKey()

    var body: some View {
        List(selection: selection) {
            Section(settings.t(.sidebarLibrary)) {
                Label(settings.t(.sidebarHome), systemImage: "house")
                    .tag(SidebarItem.home)
            }

            Section {
                if model.recentArchives.isEmpty {
                    Text(settings.t(.sidebarNoRecents))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.recentArchives, id: \.self) { url in
                    Label {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(nsImage: FileIcons.icon(for: url))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    .tag(SidebarItem.recent(url))
                    .help(url.path)
                    // Üzerindeyken "Listeden Kaldır" kısayolu (varsayılan ⌫) bu satırı kaldırır.
                    .onHover { inside in
                        if inside { removeKey.hovered = url } else if removeKey.hovered == url { removeKey.hovered = nil }
                    }
                    .contextMenu {
                        Button(settings.t(.buttonShowInFinder)) { model.reveal(url) }
                        Divider()
                        Button(settings.t(.sidebarRemoveRecent), role: .destructive) { model.removeRecent(url) }
                        Button(settings.t(.menuClearRecents), role: .destructive) { model.clearRecents() }
                    }
                }
            } header: {
                HStack {
                    Text(settings.t(.sidebarRecent))
                    Spacer()
                    // Tüm listeyi temizler (dosyalara dokunulmaz); menüdeki "Son Arşivleri Temizle" ile aynı.
                    if !model.recentArchives.isEmpty {
                        Button {
                            model.clearRecents()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(settings.t(.menuClearRecents))
                        .accessibilityLabel(settings.t(.menuClearRecents))
                        .accessibilityIdentifier("arhivar.recents.clear")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            removeKey.install { url, event in
                guard settings.shortcut(for: .removeRecent).matches(event) else { return false }
                model.removeRecent(url)
                return true
            }
        }
        .onDisappear { removeKey.uninstall() }
    }

    /// İç içe gezinmede seçili kalan, diskteki en dış arşivdir; ona tıklamak yeniden okumadan geri döner
    /// (bkz. `AppModel.openArchive`).
    private var selection: Binding<SidebarItem?> {
        Binding {
            model.rootArchiveURL.map { SidebarItem.recent($0) } ?? .home
        } set: { item in
            switch item {
            case .home:
                model.closeArchive()
            case .recent(let url):
                if url != model.archiveURL { model.openArchive(url) }
            case nil:
                break
            }
        }
    }
}

/// Kenar çubuğunda imlecin üzerinde durduğu son arşiv satırını, "Listeden Kaldır" kısayoluyla kaldırır.
///
/// Odak tablodayken de çalışmalı (satırın üzerine gelip ⌫), bu yüzden SwiftUI'ın odak tabanlı tuş işleyicileri yerine
/// pencereye gelen tuş olayları yoklanır. Yazı yazılırken (metin alanı düzenlenirken), bir sayfa ya da başka bir
/// pencere öndeyken ve imleç bir satırın üzerinde değilken olaya dokunulmaz.
@MainActor
final class RecentRemovalKey {
    var hovered: URL?
    private var monitor: Any?

    /// - Parameter handle: Olay kısayolsa satırı kaldırıp true döndürür (olay tüketilir).
    func install(_ handle: @escaping @MainActor (URL, NSEvent) -> Bool) {
        uninstall()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Yerel olay izleyicisi ana iş parçacığında çağrılır; olay yalnızca tüketilip tüketilmediği söylenerek döner.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let url = self.hovered, Self.accepts(event), handle(url, event) else { return false }
                self.hovered = nil
                return true
            }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Olay ana pencereye mi geliyor ve orada metin düzenlenmiyor mu?
    static func accepts(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        return !(window.firstResponder is NSText)
    }
}
