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
                let fallbackName = ArchiveNaming.streamItemName(for: url)
                let listing: ArchiveListing
                if let result = await runEngineList(for: url) {
                    if SevenZipError.needsPassword(result) {
                        presentEncryptedHeaders(for: url)
                        handler(nil)
                        return
                    }
                    try SevenZipError.check(result)
                    listing = ListingParser.parse(result.stdout, fallbackName: fallbackName)
                } else {
                    // Quick Look kum havuzu ("quicklook-preview") alt süreç başlatmayı yasaklar: liste süreç içinde okunur.
                    listing = try await Task.detached {
                        try LibArchiveReader.list(archive: url, fallbackName: fallbackName)
                    }.value
                }
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
                presentError(error.localizedDescription, for: url)
                handler(nil)
            }
        }
    }

    /// 7zz ile listeler; motor bulunamaz ya da başlatılamazsa (kum havuzu engeli) nil döner.
    private func runEngineList(for url: URL) async -> ProcessResult? {
        guard let engineURL = EngineLocator.locate(customPath: nil) else { return nil }
        let profile = SandboxProfile.forOperation(archive: url, writable: [], protectPersonalData: true)
        if let result = try? await CommandRunner(executableURL: engineURL, sandbox: profile).run(SevenZipCommand.list(archive: url)) {
            return result
        }
        // Quick Look eklenti ortamında sandbox-exec kısıtlıysa doğrudan 7zz ile çalıştır:
        return try? await CommandRunner(executableURL: engineURL).run(SevenZipCommand.list(archive: url))
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
