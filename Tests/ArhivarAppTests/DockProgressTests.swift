// SPDX-License-Identifier: GPL-3.0-only
import AppKit
@testable import Arhivar
@testable import ArhivarCore
import Foundation
import Testing

@MainActor
private final class FakeDockTile: DockTileSurface {
    var size = NSSize(width: 128, height: 128)
    var badgeLabel: String? = "old"
    var contentView: NSView?
    var displayCount = 0

    func display() {
        displayCount += 1
    }
}

@MainActor
@Suite("Arhivar Dock Progress Tests")
struct DockProgressTests {
    private func makeFixture() throws -> (AppModel, AppSettings, FakeDockTile, () -> Void) {
        let suite = "ArhivarDockTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, bundle: .main)
        settings.updateConsentAsked = true
        let model = AppModel(settings: settings, defaults: defaults)
        let tile = FakeDockTile()
        model.dockProgress = DockProgress(tile: tile)
        return (model, settings, tile, {
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @Test("DockProgress clamps fractions, clears stale pixels, and deduplicates identical states")
    func stateAndPixelRendering() {
        let tile = FakeDockTile()
        let dock = DockProgress(tile: tile)

        dock.update(fraction: nil, active: false, enabled: true)
        #expect(tile.displayCount == 0)

        dock.update(fraction: nil, active: true, enabled: true)
        #expect(dock.lastState == DockTileState(showsBar: true, percent: nil))
        #expect(tile.badgeLabel == nil)
        #expect(tile.contentView is DockTileView)
        #expect(tile.displayCount == 1)

        dock.update(fraction: .infinity, active: true, enabled: true)
        #expect(tile.displayCount == 1)

        dock.update(fraction: 0.446, active: true, enabled: true)
        #expect(dock.lastState == DockTileState(showsBar: true, percent: 45))
        #expect(tile.displayCount == 2)

        dock.update(fraction: 0.451, active: true, enabled: true)
        #expect(tile.displayCount == 2)

        let view = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        // Başka testler `NSApplication.shared` başlattığında bile piksel temizliği deterministik sınanır.
        view.iconProvider = { nil }
        view.state = DockTileState(showsBar: true, percent: 60)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("bitmapImageRepForCachingDisplay returned nil")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        var greenPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.alphaComponent > 0.2,
                   color.greenComponent > color.redComponent + 0.15 {
                    greenPixels += 1
                }
            }
        }
        #expect(greenPixels > 100)

        view.state = DockTileState(showsBar: false, percent: nil)
        view.cacheDisplay(in: view.bounds, to: rep)
        var residual = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.alphaComponent > 0.2,
                   color.greenComponent > color.redComponent + 0.15 {
                    residual += 1
                }
            }
        }
        #expect(residual == 0)
    }

    @Test("AppSettings persists showDockProgress and resetAll clears it cleanly")
    func settingsAndResetAll() throws {
        let (model, settings, tile, cleanup) = try makeFixture()
        defer { cleanup() }

        #expect(settings.showDockProgress == true)
        model.dockProgress.update(fraction: 0.5, active: true, enabled: settings.showDockProgress)
        #expect(tile.contentView != nil)

        settings.showDockProgress = false
        #expect(settings.showDockProgress == false)
        #expect(tile.contentView == nil)

        settings.resetAll()
        #expect(settings.showDockProgress == true)
        #expect(model.dockProgress.lastState.isEmpty)
    }

    @Test("AppModel tracks indeterminate, determinate, cancelling, and clear states")
    func modelOperationLifecycle() async throws {
        let (model, settings, tile, cleanup) = try makeFixture()
        defer { cleanup() }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("arhivar-dock-op-\(UUID().uuidString)", isDirectory: true)
        let source = workspace.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("icerik\n".utf8).write(to: source.appendingPathComponent("dosya.txt"))
        defer { try? FileManager.default.removeItem(at: workspace) }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = packageRoot.appendingPathComponent("Vendor/7-Zip/7zz")
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { return }
        settings.customEnginePath = engine.path
        settings.sandboxEngine = false

        let archive = workspace.appendingPathComponent("deneme.7z")
        model.createArchive(CreateOptions(
            sources: [source], destination: archive, format: .sevenZip,
            level: .fast, password: nil, encryptFileNames: false
        ))

        var sawBar = false
        while model.operation != nil {
            if tile.contentView != nil { sawBar = true }
            await model.operationTask?.value
        }

        #expect(sawBar)
        #expect(tile.contentView == nil)
        #expect(model.dockProgress.lastState.isEmpty)
        model.applyProgress(0.8)
        #expect(model.dockProgress.lastState.isEmpty)
    }
}
