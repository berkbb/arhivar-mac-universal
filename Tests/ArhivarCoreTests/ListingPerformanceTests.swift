import Foundation
import Testing
@testable import ArhivarCore

/// 200 bin girdili sentetik bir `7zz l -slt` çıktısı; ayrıştırma süresi yalnızca raporlanır (zamana bağlı kırılgan doğrulama yok).
private func syntheticListing(count: Int) -> String {
    var output = "--\nPath = buyuk.7z\nType = 7z\n\n----------\n"
    output.reserveCapacity(count * 160)
    for index in 0..<count {
        output += "Path = klasor\(index % 100)/dosya\(index).txt\nSize = \(index)\nPacked Size = \nModified = 2026-0\(index % 9 + 1)-1\(index % 9) 1\(index % 10):3\(index % 10):4\(index % 10).1234567\nAttributes = A -rw-r--r--\nCRC = ABCD1234\nEncrypted = -\nMethod = LZMA2:24\nBlock = 0\n\n"
    }
    return output
}

@Test func parsesLargeListingQuickly() {
    let output = syntheticListing(count: 200_000)
    let clock = ContinuousClock()
    var listing: ArchiveListing?
    let elapsed = clock.measure { listing = ListingParser.parse(output) }
    print("ListingParser 200k girdi: \(elapsed)")
    #expect(listing?.entries.count == 200_000)
    #expect(listing?.entries.allSatisfy { $0.modified != nil } == true)
}
