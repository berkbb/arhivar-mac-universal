import AppKit
import ArhivarCore
import Foundation
import QuickLookUI
import SwiftUI

/// Finder'dan çağrılan Hızlı Bakış (Quick Look) görünüm denetleyicisi.
@objc(PreviewViewController)
public final class PreviewViewController: NSViewController, QLPreviewingController {

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 500))
        view.wantsLayer = true
        preferredContentSize = NSSize(width: 740, height: 500)
    }

    /// Finder kullanıcısı bir arşiv dosyasındayken Boşluk tuşuna bastığında çağrılır.
    public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        preferredContentSize = NSSize(width: 740, height: 500)
        let isAccessing = url.startAccessingSecurityScopedResource()

        Task { @MainActor in
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                // Quick Look kum havuzu alt süreç başlatmayı yasaklar: 7zz başlatılamazsa liste süreç içinde okunur.
                let listing = try await PreviewListing.load(archive: url)
                let statistics = ArchiveStatistics(listing: listing)
                let tree = ArchiveTree.build(from: listing.entries)
                let isEncrypted = listing.entries.contains { $0.isEncrypted }

                presentContent(
                    for: url,
                    listing: listing,
                    statistics: statistics,
                    nodes: tree,
                    isEncrypted: isEncrypted
                )
                handler(nil)
            } catch SevenZipError.wrongPassword, LibArchiveReader.ReadError.encryptedHeaders {
                presentEncryptedHeaders(for: url)
                handler(nil)
            } catch {
                let l10n = QuickLookStrings.shared
                presentError(l10n.strings.previewErrorMessage(for: error, language: l10n.languageCode), for: url)
                handler(nil)
            }
        }
    }

    // MARK: - Görünüm Sunumu

    private func presentContent(
        for url: URL,
        listing: ArchiveListing,
        statistics: ArchiveStatistics,
        nodes: [ArchiveNode],
        isEncrypted: Bool
    ) {
        let previewView = ArchiveQuickLookView(
            archiveURL: url,
            listing: listing,
            statistics: statistics,
            nodes: nodes,
            headersEncrypted: false,
            isEncrypted: isEncrypted
        )
        embed(previewView)
    }

    private func presentEncryptedHeaders(for url: URL) {
        let previewView = ArchiveQuickLookView(
            archiveURL: url,
            listing: nil,
            statistics: nil,
            nodes: [],
            headersEncrypted: true,
            isEncrypted: true
        )
        embed(previewView)
    }

    private func presentError(_ message: String, for url: URL) {
        let previewView = ArchiveQuickLookView(
            archiveURL: url,
            listing: nil,
            statistics: nil,
            nodes: [],
            errorMessage: message
        )
        embed(previewView)
    }

    private func embed<V: View>(_ swiftUIView: V) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let hostingView = NSHostingView(rootView: swiftUIView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
