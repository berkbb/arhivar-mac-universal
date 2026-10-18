import ArhivarCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List(selection: selection) {
            Section(settings.t(.sidebarLibrary)) {
                Label(settings.t(.sidebarHome), systemImage: "house")
                    .tag(SidebarItem.home)
            }

            Section(settings.t(.sidebarRecent)) {
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
                    .contextMenu {
                        Button(settings.t(.buttonShowInFinder)) { model.reveal(url) }
                        Divider()
                        Button(settings.t(.sidebarRemoveRecent), role: .destructive) { model.removeRecent(url) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
