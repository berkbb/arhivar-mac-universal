import AppKit
import ArhivarCore
import SwiftUI

/// Finder Hızlı Bakış (Quick Look) penceresinde gösterilen yerel arşiv önizleme görünümü.
public struct ArchiveQuickLookView: View {
    public let archiveURL: URL
    public let listing: ArchiveListing?
    public let statistics: ArchiveStatistics?
    public let nodes: [ArchiveNode]
    public let headersEncrypted: Bool
    public let isEncrypted: Bool
    public let errorMessage: String?

    public static let maxDisplayEntries = 300

    public init(
        archiveURL: URL,
        listing: ArchiveListing?,
        statistics: ArchiveStatistics?,
        nodes: [ArchiveNode],
        headersEncrypted: Bool = false,
        isEncrypted: Bool = false,
        errorMessage: String? = nil
    ) {
        self.archiveURL = archiveURL
        self.listing = listing
        self.statistics = statistics
        self.nodes = nodes
        self.headersEncrypted = headersEncrypted
        self.isEncrypted = isEncrypted
        self.errorMessage = errorMessage
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let errorMessage {
                errorStateView(errorMessage)
            } else if headersEncrypted {
                encryptedHeadersView
            } else if nodes.isEmpty {
                emptyStateView
            } else {
                contentTableView
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 640, idealWidth: 740, maxWidth: .infinity,
               minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Üst Başlık

    private var headerBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(archiveURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)

                    if let type = listing?.info.type ?? formatSuffix {
                        Text(type.uppercased())
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }

                    if isEncrypted || headersEncrypted {
                        Label("Şifreli", systemImage: "lock.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                if let stats = statistics {
                    HStack(spacing: 12) {
                        Text("\(stats.fileCount) dosya" + (stats.folderCount > 0 ? ", \(stats.folderCount) klasör" : ""))
                        Text("•")
                        Text("Açık: \(formatBytes(stats.totalSize))")
                        if stats.packedSize > 0 {
                            Text("•")
                            Text("Sıkıştırılmış: \(formatBytes(stats.packedSize))")
                            if let ratio = stats.ratio {
                                Text("(%\(Int((ratio * 100).rounded())))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - İçerik Tablosu

    private var contentTableView: some View {
        let displayList = Array(flattenedNodes.prefix(Self.maxDisplayEntries))

        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayList, id: \.id) { item in
                    rowView(for: item)
                    Divider().opacity(0.4)
                }

                if flattenedNodes.count > Self.maxDisplayEntries {
                    HStack {
                        Spacer()
                        Text("… ve \(flattenedNodes.count - Self.maxDisplayEntries) öğe daha. Tümünü görmek için Arhivar ile açın.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                        Spacer()
                    }
                }
            }
        }
    }

    private func rowView(for item: FlatNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: item.node))
                .foregroundStyle(iconColor(for: item.node))
                .frame(width: 18)

            Text(item.node.name)
                .font(.system(.body, design: .default))
                .lineLimit(1)
                .padding(.leading, CGFloat(item.depth * 14))

            Spacer()

            if let date = item.node.modified {
                Text(formatDate(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .trailing)
            }

            Text(item.node.isDirectory ? "—" : formatBytes(item.node.size))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    // MARK: - Alt Çubuk

    private var footerBar: some View {
        HStack {
            Text("Arhivar Hızlı Bakış")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("Açmak için çift tıklayın veya Arhivar'ı kullanın")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    // MARK: - Durum Görünümleri

    private var encryptedHeadersView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Parola Korumalı Arşiv")
                .font(.title3.bold())

            Text("Bu arşivin dosya listesi parola ile şifrelenmiştir.\nİçeriği görüntülemek için arşivi Arhivar ile açın.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    private func errorStateView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)

            Text("Arşiv Okunamadı")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Arşiv boş")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Yardımcılar

    private var formatSuffix: String? {
        let ext = archiveURL.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func iconName(for node: ArchiveNode) -> String {
        if node.isDirectory { return "folder.fill" }
        let ext = node.fileExtension
        switch ext {
        case "swift", "c", "cpp", "h", "m", "py", "js", "ts", "html", "css", "json", "xml", "sh":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return "photo"
        case "mp3", "wav", "m4a", "flac", "aac":
            return "music.note"
        case "mp4", "mov", "mkv", "avi":
            return "film"
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "rtf":
            return "doc.text"
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private func iconColor(for node: ArchiveNode) -> Color {
        if node.isDirectory { return .blue }
        let ext = node.fileExtension
        switch ext {
        case "swift", "py", "js", "ts", "sh":
            return .orange
        case "png", "jpg", "jpeg", "heic", "svg":
            return .purple
        case "pdf":
            return .red
        case "zip", "7z", "rar", "tar":
            return .green
        default:
            return .secondary
        }
    }

    private struct FlatNode: Identifiable {
        let id: String
        let node: ArchiveNode
        let depth: Int
    }

    private var flattenedNodes: [FlatNode] {
        var results: [FlatNode] = []
        func collect(_ nodes: [ArchiveNode], depth: Int) {
            for node in nodes {
                results.append(FlatNode(id: node.id, node: node, depth: depth))
                if let children = node.children, !children.isEmpty {
                    collect(children, depth: depth + 1)
                }
            }
        }
        collect(nodes, depth: 0)
        return results
    }
}
