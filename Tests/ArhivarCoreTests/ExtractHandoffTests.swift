// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import ArhivarCore

/// Penceresiz Buraya Çıkar sözleşmesi (`ExtractHandoff`): olay ayrıştırma, sonuç bildirimi ve Info.plist duyurusu.
/// Hiçbir olay gönderilmez, hiçbir bildirim yayımlanmaz, hiçbir uygulama açılmaz.
private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func plainOpenEvent(_ urls: [URL]) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(eventClass: ExtractHandoff.coreEventClass, eventID: ExtractHandoff.openDocumentsID,
                                       targetDescriptor: .null(), returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
    let list = NSAppleEventDescriptor.list()
    for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1) }
    event.setParam(list, forKeyword: ExtractHandoff.directObjectKeyword)
    return event
}

@Suite struct ExtractHandoffTests {
    let urls = [URL(fileURLWithPath: "/tmp/İndirilenler/paket.zip"), URL(fileURLWithPath: "/tmp/İndirilenler/film.part1.rar"),
                URL(fileURLWithPath: "/tmp/İndirilenler/not.txt")]

    @Test func markedOpenEventCarriesTheRequestAndTheFilesInOrder() throws {
        let id = UUID().uuidString
        let request = try #require(ExtractHandoff.request(in: ExtractHandoff.openEvent(for: urls, requestID: id)))
        #expect(request.requestID == id)
        #expect(request.urls == urls)
        #expect(ExtractHandoff.requestID(in: ExtractHandoff.openEvent(for: urls, requestID: id)) == id)
    }

    /// Finder çift tıkı, "Birlikte Aç" ve tarayıcıdan açma işaretsiz `odoc` gönderir: istek sayılmaz (bugünkü gibi açılır).
    @Test func plainOpensAreNotRequests() {
        #expect(ExtractHandoff.request(in: plainOpenEvent(urls)) == nil)
        #expect(ExtractHandoff.request(in: nil) == nil)
        // Başka bir olay (ör. URL açma `GURL`) işaret taşısa da istek değildir.
        let other = NSAppleEventDescriptor(eventClass: ExtractHandoff.fourCharCode("GURL"), eventID: ExtractHandoff.fourCharCode("GURL"),
                                           targetDescriptor: .null(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        other.setParam(NSAppleEventDescriptor(string: "abc"), forKeyword: ExtractHandoff.requestKeyword)
        #expect(ExtractHandoff.request(in: other) == nil)
    }

    @Test(arguments: ["", "a b", "../x", "kimlik/1", "çağrı", String(repeating: "a", count: 65), "id\n"])
    func invalidRequestIDsLeaveThePlainOpen(id: String) {
        let event = plainOpenEvent(urls)
        event.setParam(NSAppleEventDescriptor(string: id), forKeyword: ExtractHandoff.requestKeyword)
        #expect(ExtractHandoff.request(in: event) == nil)
    }

    @Test func singleFileAndNonFileItems() throws {
        let event = plainOpenEvent([])
        event.setParam(NSAppleEventDescriptor(fileURL: urls[0]), forKeyword: ExtractHandoff.directObjectKeyword)
        event.setParam(NSAppleEventDescriptor(string: "A-1"), forKeyword: ExtractHandoff.requestKeyword)
        #expect(ExtractHandoff.request(in: event)?.urls == [urls[0]])

        // Listede dosya olmayan öğe nil olur (sonucu "skipped"); sayı ve sıra korunur.
        let mixed = ExtractHandoff.openEvent(for: [urls[0]], requestID: "B-2")
        let list = try #require(mixed.paramDescriptor(forKeyword: ExtractHandoff.directObjectKeyword))
        list.insert(NSAppleEventDescriptor(string: "https://example.invalid/a.zip"), at: 2)
        #expect(ExtractHandoff.request(in: mixed)?.urls == [urls[0], nil])

        // Doğrudan nesnesi olmayan işaretli olay: boş istek.
        let empty = plainOpenEvent([])
        empty.setParam(NSAppleEventDescriptor(string: "C-3"), forKeyword: ExtractHandoff.requestKeyword)
        empty.removeParamDescriptor(withKeyword: ExtractHandoff.directObjectKeyword)
        #expect(ExtractHandoff.request(in: empty) == ExtractHandoff.Request(requestID: "C-3", urls: []))
    }

    /// Bildirim yalnızca sürüm ve durum kodları taşır: yol, ad ya da metin yok.
    @Test func resultsCarryOnlyStatusCodes() throws {
        let statuses: [ExtractHandoff.Status] = [.extracted, .warnings, .failed, .cancelled, .skipped]
        let info = ExtractHandoff.userInfo(statuses)
        #expect(Set(info.keys) == ["version", "results"])
        #expect(info["version"] as? Int == 1)
        #expect(info["results"] as? [String] == ["extracted", "warnings", "failed", "cancelled", "skipped"])
        #expect(ExtractHandoff.statuses(from: info) == statuses)
        #expect(PropertyListSerialization.propertyList(info, isValidFor: .binary))
        // Bilinmeyen kod ya da eksik alan: sonuç okunmaz.
        #expect(ExtractHandoff.statuses(from: ["results": ["extracted", "unknown"]]) == nil)
        #expect(ExtractHandoff.statuses(from: ["version": 1]) == nil)
        #expect(ExtractHandoff.statuses(from: nil) == nil)
        #expect(ExtractHandoff.requestKeyword == 0x4172_5868) // 'ArXh'
        #expect(ExtractHandoff.finishedNotification == "com.babadogantech.arhivar.extractHandoffFinished")
    }

    /// Çağıranlar desteği uygulamayı açmadan Info.plist'ten okur.
    @Test func infoPlistAnnouncesTheContract() throws {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Support/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist[ExtractHandoff.infoKey] as? Int == ExtractHandoff.version)
        // URL şeması yok: bir web sayfası çıkarmayı başlatamaz.
        #expect(plist["CFBundleURLTypes"] == nil)
    }
}
