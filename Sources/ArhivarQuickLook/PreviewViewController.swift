import AppKit
import ArhivarCore
import Foundation
import QuickLookUI
import SwiftUI

/// Finder'dan çağrılan Hızlı Bakış (Quick Look) görünüm denetleyicisi.
public final class PreviewViewController: NSViewController, QLPreviewingController {

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        view.wantsLayer = true
    }

    /// Finder kullanıcısı bir arşiv dosyasındayken Boşluk tuşuna bastığında çağrılır.
    public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                guard let engineURL = EngineLocator.locate(customPath: nil) else {
                    presentError("7-Zip (7zz) motoru bulunamadı.", for: url)
                    handler(nil)
                    return
                }

                let profile = SandboxProfile.forOperation(archive: url, writable: [], protectPersonalData: true)
                let runner = CommandRunner(executableURL: engineURL, sandbox: profile)

                do {
                    let result = try await runner.run(SevenZipCommand.list(archive: url))
                    if SevenZipError.needsPassword(result) {
                        presentEncryptedHeaders(for: url)
                        handler(nil)
                        return
                    }

                    try SevenZipError.check(result)
                    let listing = ListingParser.parse(result.stdout, fallbackName: ArchiveNaming.streamItemName(for: url))
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
                } catch SevenZipError.wrongPassword {
                    presentEncryptedHeaders(for: url)
                    handler(nil)
                } catch {
                    presentError(error.localizedDescription, for: url)
                    handler(nil)
                }
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
