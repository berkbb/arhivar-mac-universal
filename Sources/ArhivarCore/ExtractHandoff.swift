// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Penceresiz "Buraya Çıkar" isteği: başka bir uygulama (Descarcator madde 76) arşivleri Arhivar'a çağıranı bekletmeden
/// verir, Arhivar her birini yanına çıkarır ve sonucu arşiv başına bildirir.
///
/// Sözleşme (sürüm 1):
/// - İstek, standart "belgeleri aç" Apple olayıdır (`aevt`/`odoc`, doğrudan nesne dosya bağlantılarının listesi) ve ek
///   olarak `requestKeyword` (`'ArXh'`) parametresinde çağıranın opak istek kimliğini taşır. Çağıran olayı kendisi kurar
///   ve `NSWorkspace.OpenConfiguration.appleEvent` ile verir. Tarayıcı ve Finder bu parametreyi gönderemez: işaretsiz
///   açmalar (çift tık, "Birlikte Aç") bugünkü gibi pencerede açılır. URL şeması yoktur.
/// - Sonuç, `finishedNotification` adlı dağıtık bildirimdir: nesnesi istek kimliği, `userInfo`'su `version` ve
///   `results` (olaydaki her dosya için aynı sırayla bir `Status` değeri). Bildirim oturumdaki her süreçte görünür;
///   bu yüzden yol, dosya adı ya da hata metni taşımaz.
/// - Destek, Info.plist'teki `infoKey` (tamsayı, sözleşme sürümü) ile duyurulur; çağıran uygulamayı açmadan okur.
public enum ExtractHandoff {
    /// Info.plist anahtarı: değeri desteklenen sözleşme sürümü.
    public static let infoKey = "ArhivarExtractHandoff"
    public static let version = 1
    /// İstek kimliğini taşıyan `odoc` parametresi: 'ArXh'.
    public static let requestKeyword = fourCharCode("ArXh")
    public static let finishedNotification = "com.babadogantech.arhivar.extractHandoffFinished"
    public static let versionKey = "version"
    public static let resultsKey = "results"
    /// Kimlik en çok bu kadar karakterdir (UUID 36 karakter).
    public static let maxRequestIDLength = 64

    /// Bir arşivin sonucu. Değerler sözleşmenin parçasıdır; yeniden adlandırılmaz.
    public enum Status: String, Sendable, CaseIterable, Equatable {
        /// Çıkarıldı.
        case extracted
        /// Çıkarıldı, Arhivar uyarı kaydetti (ör. dışarıyı gösteren bağlantılar ayıklandı); ayrıntı Arhivar'ın günlüğünde.
        case warnings
        /// Çıkarılamadı (7zz hatası, boş alan, motor yok); ayrıntı Arhivar'ın günlüğünde.
        case failed
        /// Kullanıcı durdurdu ya da parola sorusunu kapattı.
        case cancelled
        /// Arhivar'ın çıkarabildiği bir arşiv adı değil; hiçbir şey yapılmadı.
        case skipped
    }

    static let coreEventClass = fourCharCode("aevt")
    static let openDocumentsID = fourCharCode("odoc")
    static let directObjectKeyword = fourCharCode("----")

    /// İşaretli bir istek: kimlik ve olaydaki dosyalar, olaydaki sırayla (dosya bağlantısı olmayan öğe nil; sonucu `skipped`).
    public struct Request: Equatable, Sendable {
        public let requestID: String
        public let urls: [URL?]
    }

    /// Olay işaretli bir istekse istek kimliği; değilse (sıradan açma, başka olay, geçersiz kimlik) nil.
    public static func requestID(in event: NSAppleEventDescriptor?) -> String? {
        guard let event, event.eventClass == coreEventClass, event.eventID == openDocumentsID,
              let value = event.paramDescriptor(forKeyword: requestKeyword)?.stringValue, isValidRequestID(value) else { return nil }
        return value
    }

    /// İşaretli istek ve dosyaları. Dosyalar `application(_:open:)`'a gelen listeden değil olayın kendisinden okunur:
    /// sonuçlar çağıranın gönderdiği sırayla ve sayıyla eşleşir.
    public static func request(in event: NSAppleEventDescriptor?) -> Request? {
        guard let event, let requestID = requestID(in: event) else { return nil }
        guard let direct = event.paramDescriptor(forKeyword: directObjectKeyword) else { return Request(requestID: requestID, urls: []) }
        let items: [NSAppleEventDescriptor]
        if direct.descriptorType == fourCharCode("list") {
            items = direct.numberOfItems > 0 ? (1...direct.numberOfItems).compactMap { direct.atIndex($0) } : []
        } else {
            items = [direct]
        }
        return Request(requestID: requestID, urls: items.map(fileURL(of:)))
    }

    /// Dosya başvurusu türleri: dosya bağlantısı, yer imi, takma ad, FSRef. `fileURLValue` metni de dosya yoluna çevirir;
    /// metin bir dosya sayılmaz.
    static let fileReferenceTypes: Set<DescType> = ["furl", "bmrk", "alis", "fsrf"].map(fourCharCode).reduce(into: []) { $0.insert($1) }

    static func fileURL(of item: NSAppleEventDescriptor) -> URL? {
        guard fileReferenceTypes.contains(item.descriptorType), let url = item.fileURLValue, url.isFileURL else { return nil }
        return url
    }

    /// 1…64 karakter, yalnızca ASCII harf, rakam ve "-".
    public static func isValidRequestID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maxRequestIDLength
            && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }

    /// Çağıranın göndereceği olay (testler ve çağıranlar için örnek). Hedef boştur: Launch Services olayı açtığı
    /// uygulamaya yöneltir.
    public static func openEvent(for urls: [URL], requestID: String) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: coreEventClass, eventID: openDocumentsID, targetDescriptor: .null(),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
        }
        event.setParam(list, forKeyword: directObjectKeyword)
        event.setParam(NSAppleEventDescriptor(string: requestID), forKeyword: requestKeyword)
        return event
    }

    /// Bildirimin `userInfo`'su: yalnızca sözleşme sürümü ve durum kodları.
    public static func userInfo(_ statuses: [Status]) -> [String: Any] {
        [versionKey: version, resultsKey: statuses.map(\.rawValue)]
    }

    /// Bildirimden durumlar; bilinmeyen bir kod ya da eksik alan varsa nil.
    public static func statuses(from userInfo: [AnyHashable: Any]?) -> [Status]? {
        guard let codes = userInfo?[resultsKey] as? [String] else { return nil }
        let statuses = codes.compactMap(Status.init(rawValue:))
        return statuses.count == codes.count ? statuses : nil
    }

    /// Sonucu oturumdaki dağıtık bildirim merkezine yazar.
    public static func post(requestID: String, statuses: [Status]) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(finishedNotification), object: requestID, userInfo: userInfo(statuses), deliverImmediately: true
        )
    }

    static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
