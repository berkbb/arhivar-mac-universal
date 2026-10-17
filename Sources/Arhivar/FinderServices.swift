import AppKit

/// Info.plist'teki NSServices girdilerinin hedefi. Finder'da seçili dosyalar panodan okunur.
final class FinderServices: NSObject {
    /// "Arhivar ile Buraya Çıkar"
    @objc func extractHere(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        AppModel.shared.presentMainWindow()
        AppModel.shared.extractHere(urls)
    }

    /// "Arhivar ile Sıkıştır"
    @objc func compress(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        AppModel.shared.presentMainWindow()
        AppModel.shared.beginCreate(sources: urls)
    }

    /// "Arhivar ile Aç"
    @objc func openArchive(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = fileURLs(from: pasteboard).first else { return }
        AppModel.shared.presentMainWindow()
        AppModel.shared.openArchive(url)
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
