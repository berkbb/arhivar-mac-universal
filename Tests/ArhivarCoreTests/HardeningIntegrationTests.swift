import Darwin
import Foundation
import Testing
@testable import ArhivarCore

/// .agents/context/roadmap.md'deki 13 açık madde için gerçek 7zz ile senaryolar. Vendor/7-Zip/7zz yoksa atlanır.
private let engineURL: URL? = {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ProcessInfo.processInfo.environment["ARHIVAR_7ZZ"],
        packageRoot.appendingPathComponent("Vendor/7-Zip/7zz").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

/// 7zz'nin kendisi yazmadığı girdiler ("a/../x", aynı yollu yinelenen girdiler) için en küçük ustar yazıcısı.
struct TarBuilder {
    private(set) var data = Data()

    mutating func file(_ name: String, _ contents: String) {
        add(name, type: UInt8(ascii: "0"), body: Data(contents.utf8))
    }

    var archive: Data { data + Data(count: 1024) }

    private mutating func add(_ name: String, type: UInt8, body: Data) {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            let bytes = Array(text.utf8)
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        put(name, at: 0)
        put("0000644\0", at: 100)
        put("0000000\0", at: 108)
        put("0000000\0", at: 116)
        put(String(format: "%011o\0", body.count), at: 124)
        put(String(format: "%011o\0", 1_700_000_000), at: 136)
        put("        ", at: 148)
        header[156] = type
        put("ustar\0", at: 257)
        put("00", at: 263)
        put(String(format: "%06o\0 ", header.reduce(0) { $0 + Int($1) }), at: 148)
        data.append(contentsOf: header)
        data.append(body)
        data.append(Data(count: (512 - body.count % 512) % 512))
    }
}

@Suite(.enabled(if: engineURL != nil, "7zz bulunamadı"), .serialized)
struct HardeningIntegrationTests {
    let runner = CommandRunner(executableURL: engineURL ?? URL(fileURLWithPath: "/usr/bin/false"))
    let workspace: URL
    let fileManager = FileManager.default

    init() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArhivarSert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("kaynak/a/b"), withIntermediateDirectories: true)
        try "f\n".write(to: workspace.appendingPathComponent("kaynak/a/b/f.txt"), atomically: true, encoding: .utf8)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: workspace) }

    private func create(_ options: CreateOptions) async throws {
        try SevenZipError.check(try await runner.run(SevenZipCommand.create(options), timeout: 30, input: options.input))
    }

    private func list(_ archive: URL) async throws -> ArchiveListing {
        let result = try await runner.run(SevenZipCommand.list(archive: archive), timeout: 30)
        try SevenZipError.check(result)
        return ListingParser.parse(result.stdout, fallbackName: ArchiveNaming.streamItemName(for: archive))
    }

    /// P0-1: zip arşiv yorumu sahte bir ayraç ve girdi içerse de listeye girmez, türü değiştirmez.
    @Test func zipCommentCannotInjectEntries() async throws {
        defer { cleanUp() }
        let archive = workspace.appendingPathComponent("yorum.zip")
        try await create(CreateOptions(sources: [workspace.appendingPathComponent("kaynak/a/b/f.txt")], destination: archive, format: .zip, level: .store))
        // Yorumsuz zip'in son 22 baytı "dizin sonu" kaydıdır; son iki bayt yorum uzunluğudur.
        var data = try Data(contentsOf: archive)
        let comment = Data("bir\nType = 7z\n}\n----------\nPath = sahte.txt\nSize = 999999\n".utf8)
        data[data.count - 2] = UInt8(comment.count & 0xFF)
        data[data.count - 1] = UInt8(comment.count >> 8)
        try (data + comment).write(to: archive)

        let listing = try await list(archive)
        #expect(listing.entries.map(\.path) == ["f.txt"])
        #expect(listing.info.type == "zip")
        #expect(listing.info.comment == "bir\nType = 7z\n}\n----------\nPath = sahte.txt\nSize = 999999")
    }

    /// P0-5: adında "*" geçen arşiv açılırken, sınanırken, çıkarılırken ve sağlama değeri alınırken yanındaki
    /// eşleşen arşivler işe karışmaz.
    @Test func starredArchiveNamesAreLiteral() async throws {
        defer { cleanUp() }
        let starred = workspace.appendingPathComponent("yedek*1.7z")
        let other = workspace.appendingPathComponent("yedekX1.7z")
        try await create(CreateOptions(sources: [workspace.appendingPathComponent("kaynak/a/b/f.txt")], destination: starred, format: .sevenZip, level: .fast))
        let extra = workspace.appendingPathComponent("baska.txt")
        try "b".write(to: extra, atomically: true, encoding: .utf8)
        try await create(CreateOptions(sources: [extra], destination: other, format: .sevenZip, level: .fast))

        #expect(try await list(starred).entries.map(\.path) == ["f.txt"])
        let output = workspace.appendingPathComponent("cikti", isDirectory: true)
        let options = ExtractOptions(archive: starred, destination: output, overwrite: .replace)
        try SevenZipError.check(try await runner.run(SevenZipCommand.extract(options), timeout: 30))
        #expect(try fileManager.contentsOfDirectory(atPath: output.path) == ["f.txt"])
        let hash = try await runner.run(SevenZipCommand.hash(file: starred), timeout: 30)
        try SevenZipError.check(hash)
        let sums = ChecksumParser.parse(hash.stdout)
        #expect(!sums.isEmpty)
        // Birden çok dosyanın birleşik değeri "-00000002" gibi bir sayaçla biter.
        #expect(!sums.contains { $0.value.contains("-") })
    }

}
