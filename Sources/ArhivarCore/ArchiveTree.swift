import Foundation

/// Tabloda gösterilen, klasör hiyerarşisine dönüştürülmüş arşiv öğesi.
public struct ArchiveNode: Identifiable, Sendable, Equatable {
    /// 7zz'ye verilecek tam yol.
    public let id: String
    public var name: String
    public let isDirectory: Bool
    public let size: Int64
    public let packedSize: Int64?
    public let modified: Date?
    public let isEncrypted: Bool
    public let method: String?
    public var children: [ArchiveNode]?

    public init(
        id: String, name: String, isDirectory: Bool, size: Int64, packedSize: Int64?,
        modified: Date?, isEncrypted: Bool, method: String?, children: [ArchiveNode]?
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
    var entry: ArchiveEntry?
    var isDirectory: Bool
    var children: [String: TreeBuilderNode] = [:]
    var order: [String] = []

    init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }
}

public enum ArchiveTree {
    /// Düz girdi listesini klasör ağacına çevirir; arşivde açıkça bulunmayan ara klasörleri de oluşturur.
    public static func build(from entries: [ArchiveEntry]) -> [ArchiveNode] {
        let root = TreeBuilderNode(path: "", name: "", isDirectory: true)
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { continue }
            var current = root
            var currentPath = ""
            for (index, component) in components.enumerated() {
                currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
                let isLast = index == components.count - 1
                if let existing = current.children[component] {
                    current = existing
                } else {
                    let node = TreeBuilderNode(path: currentPath, name: component, isDirectory: !isLast || entry.isDirectory)
                    current.children[component] = node
                    current.order.append(component)
                    current = node
                }
                if isLast {
                    current.entry = entry
                    if entry.isDirectory { current.isDirectory = true }
                } else {
                    current.isDirectory = true
                }
            }
        }
        return root.order.compactMap { root.children[$0].map(convert) }
    }

    private static func convert(_ node: TreeBuilderNode) -> ArchiveNode {
        if node.isDirectory {
            let children = node.order.compactMap { node.children[$0].map(convert) }
            let packed = children.compactMap(\.packedSize)
            return ArchiveNode(
                id: node.entry?.path ?? node.path,
                name: node.name,
                isDirectory: true,
                size: children.reduce(0) { $0 + $1.size },
                packedSize: packed.isEmpty ? nil : packed.reduce(0, +),
                modified: node.entry?.modified,
                isEncrypted: node.entry?.isEncrypted ?? false,
                method: nil,
                children: children
            )
        }
        return ArchiveNode(
            id: node.entry?.path ?? node.path,
            name: node.name,
            isDirectory: false,
            size: node.entry?.size ?? 0,
            packedSize: node.entry?.packedSize,
            modified: node.entry?.modified,
            isEncrypted: node.entry?.isEncrypted ?? false,
            method: node.entry?.method,
            children: nil
        )
    }

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
