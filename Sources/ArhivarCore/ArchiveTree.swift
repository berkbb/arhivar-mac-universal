import Foundation

/// Tabloda gösterilen, klasör hiyerarşisine dönüştürülmüş arşiv öğesi.
public struct ArchiveNode: Identifiable, Sendable, Equatable {
    /// Normalleştirilmiş tam yol ("a/b/c.txt"); seçim, gezinme ve yol çubuğu bunu kullanır.
    public let id: String
    public var name: String
    public let isDirectory: Bool
    public let size: Int64
    public let packedSize: Int64?
    public let modified: Date?
    public let isEncrypted: Bool
    public let method: String?
    public var children: [ArchiveNode]?
    /// 7zz'ye verilecek ham yol (ör. "./a/b/c.txt"); çoğu arşivde `id` ile aynıdır.
    public let archivePath: String

    public init(
        id: String, name: String, isDirectory: Bool, size: Int64, packedSize: Int64?,
        modified: Date?, isEncrypted: Bool, method: String?, children: [ArchiveNode]?, archivePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isEncrypted = isEncrypted
        self.method = method
        self.children = children
        self.archivePath = archivePath ?? id
    }

    public var fileExtension: String { (id as NSString).pathExtension.lowercased() }

    // Sıralama için isteğe bağlı olmayan değerler.
    public var sortPackedSize: Int64 { packedSize ?? -1 }
    public var sortDate: Date { modified ?? .distantPast }
    public var sortMethod: String { method ?? "" }
}

private final class TreeBuilderNode {
    let path: String
    let name: String
    /// 7zz'nin bu düğümü tanıdığı ham yol (ara klasörlerde bir alt girdinin ham yolundan türetilir).
    var archivePath: String
    var entry: ArchiveEntry?
    var isDirectory: Bool
    var children: [String: TreeBuilderNode] = [:]
    var order: [String] = []

    init(path: String, name: String, archivePath: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.archivePath = archivePath
        self.isDirectory = isDirectory
    }
}

public enum ArchiveTree {
    /// Düz girdi listesini klasör ağacına çevirir; arşivde açıkça bulunmayan ara klasörleri de oluşturur.
    public static func build(from entries: [ArchiveEntry]) -> [ArchiveNode] {
        let root = TreeBuilderNode(path: "", name: "", archivePath: "", isDirectory: true)
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { continue }
            // Ham yol normalden farklıysa (ör. "./a/b") ara klasörlerin ham yolu da ondan türetilir.
            let raw = entry.archivePath == entry.path ? nil : entry.archivePath
            var current = root
            var currentPath = ""
            for (index, component) in components.enumerated() {
                currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
                let isLast = index == components.count - 1
                if let existing = current.children[component] {
                    current = existing
                } else {
                    let archivePath = isLast ? entry.archivePath : raw.map { rawPrefix($0, components: index + 1) } ?? currentPath
                    let node = TreeBuilderNode(path: currentPath, name: component, archivePath: archivePath, isDirectory: !isLast || entry.isDirectory)
                    current.children[component] = node
                    current.order.append(component)
                    current = node
                }
                if isLast {
                    current.entry = entry
                    // Kendi girdisi olan düğümde 7zz'nin yazdığı yol türetilmiş olandan önceliklidir.
                    current.archivePath = entry.archivePath
                    if entry.isDirectory { current.isDirectory = true }
                } else {
                    current.isDirectory = true
                }
            }
        }
        return root.order.compactMap { root.children[$0].map(convert) }
    }

    /// Ham yolun ilk `count` anlamlı bileşenini (boş ve "." bileşenler sayılmaz) yazıldığı gibi döndürür:
    /// "./a//b/c.txt", 2 → "./a//b".
    static func rawPrefix(_ raw: String, components count: Int) -> String {
        var seen = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            let end = raw[index...].firstIndex(of: "/") ?? raw.endIndex
            let component = raw[index..<end]
            if !component.isEmpty && component != "." {
                seen += 1
                if seen == count { return String(raw[..<end]) }
            }
            guard end < raw.endIndex else { break }
            index = raw.index(after: end)
        }
        return raw
    }

    private static func convert(_ node: TreeBuilderNode) -> ArchiveNode {
        // Kimlik her zaman normalleştirilmiş yoldur; ham yol (sondaki "/" ya da "./" ile) yol çubuğuyla eşleşmezdi.
        if node.isDirectory {
            let children = node.order.compactMap { node.children[$0].map(convert) }
            let packed = children.compactMap(\.packedSize)
            return ArchiveNode(
                id: node.path,
                name: node.name,
                isDirectory: true,
                size: children.lazy.map(\.size).saturatingSum(),
                packedSize: packed.isEmpty ? nil : packed.saturatingSum(),
                modified: node.entry?.modified,
                isEncrypted: node.entry?.isEncrypted ?? false,
                method: nil,
                children: children,
                archivePath: node.archivePath
            )
        }
        return ArchiveNode(
            id: node.path,
            name: node.name,
            isDirectory: false,
            size: node.entry?.size ?? 0,
            packedSize: node.entry?.packedSize,
            modified: node.entry?.modified,
            isEncrypted: node.entry?.isEncrypted ?? false,
            method: node.entry?.method,
            children: nil,
            archivePath: node.archivePath
        )
    }

    /// Ad sütunu için Finder sıralaması: büyük/küçük harf duyarsız, sayılar sayı olarak ("dosya2" < "dosya10"), yerele uygun ("Çanta" < "Zebra").
    public static let nameComparator = KeyPathComparator(\ArchiveNode.name, comparator: .localizedStandard)

    /// Klasörler önce gelecek şekilde, alt düzeyler dahil sıralar.
    public static func sorted(_ nodes: [ArchiveNode], using comparators: [KeyPathComparator<ArchiveNode>]) -> [ArchiveNode] {
        nodes
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                for comparator in comparators {
                    let result = comparator.compare(lhs, rhs)
                    if result != .orderedSame { return result == .orderedAscending }
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { node in
                var copy = node
                copy.children = node.children.map { sorted($0, using: comparators) }
                return copy
            }
    }

    /// Adı sorguyu içeren tüm öğeleri, tam yollarıyla düz bir liste olarak döndürür.
    public static func search(_ nodes: [ArchiveNode], query: String) -> [ArchiveNode] {
        var results: [ArchiveNode] = []
        func visit(_ node: ArchiveNode) {
            if node.name.localizedCaseInsensitiveContains(query) {
                var match = node
                match.name = node.id
                match.children = nil
                results.append(match)
            }
            node.children?.forEach(visit)
        }
        nodes.forEach(visit)
        return results
    }

    /// Kimliğe göre hızlı erişim için düz dizin.
    public static func index(_ nodes: [ArchiveNode]) -> [String: ArchiveNode] {
        var result: [String: ArchiveNode] = [:]
        func visit(_ node: ArchiveNode) {
            result[node.id] = node
            node.children?.forEach(visit)
        }
        nodes.forEach(visit)
        return result
    }
}
