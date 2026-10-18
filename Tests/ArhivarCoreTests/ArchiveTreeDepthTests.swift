import Foundation
import Testing
@testable import ArhivarCore

// Yığın taşması güvenliği: değer tipli gösterim ağacı özyinelemeli tüketilir (convert/sorted/search/index, SwiftUI
// Table, ARC yıkımı). Kötü niyetli bir arşiv binlerce bileşenli bir yol bildirip arşiv yalnızca AÇILIRKEN uygulamayı
// çökertebiliyordu (SIGBUS). ArchiveTree.build artık derinliği `maxDepth` ile sınırlar.

/// Ağacın en büyük derinliği (özyinelemesiz; testin kendisi derin ağaçta taşmasın diye açık yığınla).
private func treeDepth(_ nodes: [ArchiveNode]) -> Int {
    var maxDepth = 0
    var stack: [(ArchiveNode, Int)] = nodes.map { ($0, 1) }
    while let (node, depth) = stack.popLast() {
        maxDepth = Swift.max(maxDepth, depth)
        for child in node.children ?? [] { stack.append((child, depth + 1)) }
    }
    return maxDepth
}

@Test func deeplyNestedEntryIsCappedAndDoesNotCrash() {
    let deep = (0..<5_000).map { "k\($0)" }.joined(separator: "/")
    let entries = [ArchiveEntry(path: deep, archivePath: deep, size: 42)]
    let tree = ArchiveTree.build(from: entries)
    // Ağaç `maxDepth` ile sınırlanır; derin kuyruk gösterilmez. Özyinelemeli tüketiciler çökmemeli.
    #expect(treeDepth(tree) == ArchiveTree.maxDepth)
    let sorted = ArchiveTree.sorted(tree, using: [ArchiveTree.nameComparator])
    #expect(treeDepth(sorted) == ArchiveTree.maxDepth)
    #expect(ArchiveTree.search(tree, query: "k4999").isEmpty) // sınırın ötesindeki ad ağaçta yok
    #expect(ArchiveTree.index(tree).count == ArchiveTree.maxDepth)
}

@Test func deepEntryStaysInListingForStatsAndExtraction() {
    // Ağaçta gösterilmese de girdi listede kalır: sayımlar ve "Tümünü Çıkar" (7zz'ye düz yol verilir) etkilenmez.
    let deep = (0..<5_000).map { "k\($0)" }.joined(separator: "/")
    let stats = ArchiveStatistics(listing: ArchiveListing(info: ArchiveInfo(), entries: [ArchiveEntry(path: deep, archivePath: deep, size: 42)]))
    #expect(stats.fileCount == 1)
    #expect(stats.totalSize == 42)
}

@Test func normalDepthIsUnaffected() {
    let tree = ArchiveTree.build(from: [ArchiveEntry(path: "a/b/c/d.txt", archivePath: "a/b/c/d.txt", size: 1)])
    #expect(treeDepth(tree) == 4)
    #expect(ArchiveTree.index(tree)["a/b/c/d.txt"] != nil)
    // Tam olarak sınır derinliğindeki bir dosya hâlâ eklenir.
    let atCap = (0..<ArchiveTree.maxDepth).map { "k\($0)" }.joined(separator: "/")
    #expect(ArchiveTree.index(ArchiveTree.build(from: [ArchiveEntry(path: atCap, archivePath: atCap)]))[atCap] != nil)
}
