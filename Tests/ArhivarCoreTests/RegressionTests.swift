import Foundation
import Testing
@testable import ArhivarCore

// Listede 9–14 numaralı hatalar için çekirdek testleri.

@Test func progressIgnoresPercentInFileNames() {
    // 7zz çıktısından alınmış gerçek biçim: geri silme karakterleriyle ayrılmış güncellemeler.
    let output = "  0%\u{8}\u{8}\u{8}\u{8}    \u{8}\u{8}\u{8}\u{8} 26% + src/50% indirim.bin\u{8}\u{8}\u{8}"
    #expect(ProgressParser.lastPercentage(in: output) == 26)
    #expect(ProgressParser.lastPercentage(in: " 54% + 100% bitti.txt") == 54)
    #expect(ProgressParser.lastPercentage(in: "+ 99%.txt") == nil)
}

@Test func recognisesTypedNotArchiveMessages() {
    #expect(throws: SevenZipError.notArchive) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: "Open ERROR: Cannot open the file as [7z] archive\n", stderr: ""))
    }
    #expect(throws: SevenZipError.notArchive) {
        try SevenZipError.check(ProcessResult(exitCode: 2, stdout: "", stderr: "Is not archive"))
    }
}

@Test func singleStreamArchivesGetAnEntry() {
    // .tar.bz2 / .tar.xz için 7zz -slt çıktısında Path satırı yoktur.
    let output = """
    --
    Path = yedek.tar.bz2
    Type = bzip2

    ----------
    Size =
    Packed Size =

    """
    let listing = ListingParser.parse(output, fallbackName: "yedek.tar")
    #expect(listing.entries.map(\.path) == ["yedek.tar"])
    #expect(ListingParser.parse(output).entries.isEmpty)
}

@Test func fallbackNameDoesNotOverrideRealPaths() {
    let output = "--\nType = zip\n\n----------\nPath = a.txt\nSize = 1\n\nPath = b.txt\nSize = 2\n"
    #expect(ListingParser.parse(output, fallbackName: "x").entries.map(\.path) == ["a.txt", "b.txt"])
}

@Test func streamItemNames() {
    #expect(ArchiveNaming.streamItemName(for: URL(fileURLWithPath: "/x/yedek.tar.xz")) == "yedek.tar")
    #expect(ArchiveNaming.streamItemName(for: URL(fileURLWithPath: "/x/yedek.tbz2")) == "yedek.tar")
    #expect(ArchiveNaming.streamItemName(for: URL(fileURLWithPath: "/x/rapor.pdf.gz")) == "rapor.pdf")
}

@Test func starInDestinationUsesWorkingDirectory() {
    let plain = ExtractOptions(archive: URL(fileURLWithPath: "/a.7z"), destination: URL(fileURLWithPath: "/out"), overwrite: .replace)
    #expect(plain.workingDirectory == nil)
    #expect(SevenZipCommand.extract(plain).contains("-o/out"))

    let starred = ExtractOptions(archive: URL(fileURLWithPath: "/a.7z"), destination: URL(fileURLWithPath: "/İş*Yedek"), overwrite: .replace)
    #expect(starred.workingDirectory?.path == "/İş*Yedek")
    #expect(SevenZipCommand.extract(starred).contains("-o."))
    #expect(!SevenZipCommand.extract(starred).contains { $0.hasPrefix("-o/") })
}
