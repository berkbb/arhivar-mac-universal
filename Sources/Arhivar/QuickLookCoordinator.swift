import AppKit
@preconcurrency import QuickLookUI

/// macOS yerel `QLPreviewPanel` denetleyicisi.
/// SwiftUI'ın `.quickLookPreview` değiştiricisi macOS üzerinde arka arkaya hızlı açıp kapamada
/// (`Cmd+Y` / `Space`) `_QuickLook_SwiftUI` içinde `NSNotFound` (`Int.max`) indeksiyle `EXC_BREAKPOINT`
/// çökmesine yol açar. Bu koordinatör, AppKit'in yerleşik ve kararlı `QLPreviewPanel.shared()` tekilini
/// doğrudan yöneterek çökmeyi önler.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    private(set) var currentURL: URL?
    private var isClosingInternally = false
    private var closeObserver: Any?
    var onClose: (@MainActor () -> Void)?

    private var isTesting: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains { $0.contains("Testing") || $0.contains("xctest") }
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    func show(url: URL, onClose: (@MainActor () -> Void)? = nil) {
        self.currentURL = url
        self.onClose = onClose

        guard !isTesting else { return }

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()

        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handlePanelDidClose()
                }
            }
        }

        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard currentURL != nil || isVisible else { return }
        isClosingInternally = true
        defer { isClosingInternally = false }

        currentURL = nil
        let callback = onClose
        onClose = nil

        if !isTesting, isVisible, let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
        }
        callback?()
    }

    func handlePanelDidClose() {
        guard !isClosingInternally, currentURL != nil, !isTesting else { return }
        currentURL = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            currentURL == nil ? 0 : 1
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard index == 0, let currentURL else { return nil }
            return currentURL as NSURL
        }
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event else { return false }
        let shouldClose = event.type == .keyDown && (event.keyCode == 49 || event.keyCode == 53)
        if shouldClose {
            MainActor.assumeIsolated {
                self.close()
            }
            return true
        }
        return false
    }
}
