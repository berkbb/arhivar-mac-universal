import Foundation
import Testing
@testable import ArhivarCore

private let archive = URL(fileURLWithPath: "/tmp/ornek.7z")

@Test func editCommands() {
    #expect(SevenZipCommand.add(archive: archive, names: ["a", "-b"], password: "p", encryptHeaders: true)
        == ["a", "-bsp1", "-bb0", "-y", "-sccUTF-8", "-pp", "-mhe=on", "--", "/tmp/ornek.7z", "a", "-b"])
    #expect(!SevenZipCommand.add(archive: archive, names: ["a"], encryptHeaders: true).contains("-mhe=on"))
    #expect(SevenZipCommand.delete(archive: archive, items: ["x/y"])
        == ["d", "-bsp1", "-bb0", "-y", "-spd", "-sccUTF-8", "--", "/tmp/ornek.7z", "x/y"])
    #expect(SevenZipCommand.rename(archive: archive, from: "a/b", to: "a/c").suffix(3) == ["/tmp/ornek.7z", "a/b", "a/c"])
}

@Test func editableTypes() {
    #expect(ArchiveCapabilities.isEditable(type: "7z", url: archive))
    #expect(ArchiveCapabilities.isEditable(type: "zip", url: URL(fileURLWithPath: "/x/a.zip")))
    #expect(!ArchiveCapabilities.isEditable(type: "Rar5", url: URL(fileURLWithPath: "/x/a.rar")))
    #expect(!ArchiveCapabilities.isEditable(type: "gzip", url: URL(fileURLWithPath: "/x/a.gz")))
    #expect(!ArchiveCapabilities.isEditable(type: "7z", url: URL(fileURLWithPath: "/x/a.7z.001")))
    #expect(!ArchiveCapabilities.isEditable(type: nil, url: archive))
}

@Test func navigationHelpers() {
    #expect(ArchiveTree.breadcrumbs(for: "").isEmpty)
    let crumbs = ArchiveTree.breadcrumbs(for: "a/b/c")
    #expect(crumbs.map(\.name) == ["a", "b", "c"])
    #expect(crumbs.map(\.path) == ["a", "a/b", "a/b/c"])
    #expect(ArchiveTree.parent(of: "a/b/c") == "a/b")
    #expect(ArchiveTree.parent(of: "a") == "")
    #expect(ArchiveTree.renamedPath("a/b/c.txt", to: "d.txt") == "a/b/d.txt")
    #expect(ArchiveTree.renamedPath("kok", to: "yeni") == "yeni")
    #expect(ArchiveTree.isValidName("rapor.pdf"))
    #expect(!ArchiveTree.isValidName("  "))
    #expect(!ArchiveTree.isValidName("a/b"))
    #expect(!ArchiveTree.isValidName(".."))
}

@Test func folderContentsAreShallow() {
    let tree = ArchiveTree.build(from: [
        ArchiveEntry(path: "docs/a.txt", size: 1),
        ArchiveEntry(path: "docs/sub/b.txt", size: 2),
        ArchiveEntry(path: "c.txt", size: 3),
    ])
    let index = ArchiveTree.index(tree)
    let root = ArchiveTree.contents(of: "", roots: tree, index: index)
    #expect(Set(root.map(\.id)) == ["docs", "c.txt"])
    #expect(root.allSatisfy { $0.children == nil })
    #expect(root.first { $0.id == "docs" }?.isDirectory == true)
    let docs = ArchiveTree.contents(of: "docs", roots: tree, index: index)
    #expect(Set(docs.map(\.id)) == ["docs/a.txt", "docs/sub"])
    #expect(ArchiveTree.contents(of: "yok", roots: tree, index: index).isEmpty)
}

@Test func choosesNewestEngine() {
    let a = URL(fileURLWithPath: "/a/7zz"), b = URL(fileURLWithPath: "/b/7zz"), c = URL(fileURLWithPath: "/c/7zz")
    #expect(EngineLocator.newest([(a, "26.04"), (b, "26.10"), (c, nil)]) == b)
    #expect(EngineLocator.newest([(a, "26.04"), (b, "26.04")]) == a)
    #expect(EngineLocator.newest([(c, nil)]) == nil)
}

@Test func updaterLetsScriptChooseTarget() {
    let script = URL(fileURLWithPath: "/x/update-7zip.sh")
    #expect(EngineUpdater(scriptURL: script).arguments(command: "check") == ["/x/update-7zip.sh", "check"])
    #expect(EngineUpdater(scriptURL: script, targets: ["--app", "/A.app"]).arguments(command: "install")
        == ["/x/update-7zip.sh", "install", "--app", "/A.app"])
}

@Test func addPlanWithoutStagingForRootOfSameFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let plan = try AddPlan.make(
        sources: [URL(fileURLWithPath: "/x/a.txt"), URL(fileURLWithPath: "/x/b")], into: "", stagingRoot: root
    )
    #expect(plan.workingDirectory.path == "/x")
    #expect(plan.names == ["a.txt", "b"])
    #expect(plan.stagingDirectory == nil)
}

@Test func addPlanStagesIntoSubfolder() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("kaynak/not.txt")
    try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "x".write(to: source, atomically: true, encoding: .utf8)

    let plan = try AddPlan.make(sources: [source], into: "belgeler/2026", stagingRoot: root.appendingPathComponent("staging"))
    #expect(plan.names == ["belgeler"])
    let staging = try #require(plan.stagingDirectory)
    #expect(plan.workingDirectory == staging)
    #expect(fileManager.fileExists(atPath: staging.appendingPathComponent("belgeler/2026/not.txt").path))
}
