import AppKit
import SwiftUI
import Testing
@testable import Arhivar
@testable import ArhivarCore

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Hakkında penceresindeki lisanslar düzenlenebilir bir metin düzenleyicide değil, uygulama içinde salt okunur açılır.
@Suite(.serialized)
@MainActor
struct LicenseViewerTests {
    private func makeWorkspace() throws -> (root: URL, resources: URL, engine: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArhivarLicenseTests-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let engine = root.appendingPathComponent("Engine", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        return (root, resources, engine)
    }

    /// build_app.sh'ın pakete kopyaladığı dosyalar, değiştirilmeden gösterilir (7-Zip'in CRLF'i LF olur).
    @Test func bundledFilesAreShownVerbatim() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let sources = [
            ("LICENSE", "Arhivar-License.txt"),
            ("THIRD_PARTY_NOTICES.md", "Third-Party-Notices.txt"),
            ("Vendor/7-Zip/License.txt", "7-Zip-License.txt"),
        ]
        for (source, name) in sources {
            try FileManager.default.copyItem(
                at: packageRoot.appendingPathComponent(source), to: workspace.resources.appendingPathComponent(name))
        }

        func original(_ path: String) throws -> String {
            try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
        }
        let app = try #require(LicenseDocument.app.text(resources: workspace.resources, engineDirectory: workspace.engine))
        #expect(app == (try original("LICENSE")))
        #expect(app.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(app.contains("Version 3, 29 June 2007"))
        let notices = try #require(
            LicenseDocument.notices.text(resources: workspace.resources, engineDirectory: workspace.engine))
        #expect(notices == (try original("THIRD_PARTY_NOTICES.md")))
        let sevenZip = try #require(
            LicenseDocument.sevenZip.text(resources: workspace.resources, engineDirectory: workspace.engine))
        #expect(sevenZip == (try original("Vendor/7-Zip/License.txt")).replacingOccurrences(of: "\r\n", with: "\n"))
        #expect(!sevenZip.contains("\r"))
        #expect(sevenZip.contains("GNU LGPL"))
    }

    /// Güncellenen motorun kendi lisansı önceliklidir; o yoksa ya da boşsa paketteki gösterilir.
    @Test func sevenZipPrefersUpdatedEngineLicense() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let bundled = workspace.resources.appendingPathComponent("7-Zip-License.txt")
        let updated = workspace.engine.appendingPathComponent("License.txt")
        try Data("bundled".utf8).write(to: bundled)
        try Data("updated\r\nline".utf8).write(to: updated)

        func text() -> String? { LicenseDocument.sevenZip.text(resources: workspace.resources, engineDirectory: workspace.engine) }
        #expect(text() == "updated\nline")
        try Data().write(to: updated)
        #expect(text() == "bundled")
        try FileManager.default.removeItem(at: updated)
        #expect(text() == "bundled")
        try FileManager.default.removeItem(at: bundled)
        #expect(text() == nil)
        #expect(LicenseDocument.sevenZip.fallbackURL == AppLinks.license)
    }

    /// Dosya yoksa sayfa boş açılmaz: Arhivar lisansı ve bildirimler için metin yoktur, gidilecek adres de yoktur.
    @Test func missingFilesHaveNoText() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        for document in [LicenseDocument.app, .notices] {
            #expect(document.text(resources: workspace.resources, engineDirectory: workspace.engine) == nil)
            #expect(document.text(resources: nil, engineDirectory: workspace.engine) == nil)
            #expect(document.fallbackURL == nil)
        }
    }

    /// Görüntüleyicinin aradığı adlar, paketleyicinin kopyaladığı adlarla aynı kalmalı.
    @Test func buildScriptBundlesEveryLicenseFile() throws {
        let script = try String(contentsOf: packageRoot.appendingPathComponent("Scripts/build_app.sh"), encoding: .utf8)
        let resources = URL(fileURLWithPath: "/Resources")
        for document in LicenseDocument.allCases {
            let names = document.candidates(resources: resources, engineDirectory: URL(fileURLWithPath: "/Engine"))
                .filter { $0.deletingLastPathComponent().path == resources.path }
                .map(\.lastPathComponent)
            #expect(!names.isEmpty, "\(document)")
            for name in names {
                #expect(script.contains("Contents/Resources/\(name)"), "\(name)")
            }
        }
    }

    /// Her belge, salt okunur sayfada gerçek bir pencerede çizilir.
    @Test func sheetRendersEveryDocument() throws {
        _ = NSApplication.shared
        let suiteName = "ArhivarLicenseTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, bundle: .main)

        for document in LicenseDocument.allCases {
            let item = LicenseViewerItem(document: document, text: String(repeating: "Lorem ipsum dolor sit amet.\n", count: 400))
            let host = NSHostingView(rootView: LicenseViewerSheet(item: item).environment(settings))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.layoutIfNeeded()
            window.displayIfNeeded()
            #expect(host.fittingSize == NSSize(width: 640, height: 540), "\(document)")
            window.close()
        }
    }
}
