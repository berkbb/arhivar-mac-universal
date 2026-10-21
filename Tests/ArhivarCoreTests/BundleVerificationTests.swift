import Foundation
import Testing

/// `Scripts/verify_bundle.sh`: derlenmiş paketin içeriği (7zz, Quick Look eklentisi ve dil dosyaları, libarchive
/// bağlantısı, imza). Paket henüz derlenmediyse (build/Arhivar.app yoksa) atlanır.
@Suite(.serialized) struct BundleVerificationTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = packageRoot.appendingPathComponent("Scripts/verify_bundle.sh")
    static let builtApp = packageRoot.appendingPathComponent("build/Arhivar.app")
    static let hasBuiltApp = FileManager.default.fileExists(atPath: builtApp.appendingPathComponent("Contents/Info.plist").path)

    private func verify(_ app: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script.path, app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    @Test(.enabled(if: hasBuiltApp, "build/Arhivar.app yok"))
    func builtBundlePassesVerification() throws {
        let result = try verify(Self.builtApp)
        #expect(result.status == 0, "\(result.output)")
    }

    /// Bugünkü sorunların tekrarı: eklentide eksik dil dosyası ve uygulamanın adını taşıyan InfoPlist.strings.
    @Test(.enabled(if: hasBuiltApp, "build/Arhivar.app yok"))
    func brokenBundleIsRejected() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ArhivarBundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let app = workspace.appendingPathComponent("Arhivar.app")
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [Self.builtApp.path, app.path]
        try copy.run()
        copy.waitUntilExit()
        #expect(copy.terminationStatus == 0)

        let resources = app.appendingPathComponent("Contents/PlugIns/ArhivarQuickLook.appex/Contents/Resources")
        try FileManager.default.removeItem(at: resources.appendingPathComponent("ro.lproj/Localizable.strings"))
        let english = resources.appendingPathComponent("en.lproj/InfoPlist.strings")
        try FileManager.default.removeItem(at: english)
        try FileManager.default.copyItem(at: app.appendingPathComponent("Contents/Resources/en.lproj/InfoPlist.strings"), to: english)

        let result = try verify(app)
        #expect(result.status != 0)
        #expect(result.output.contains("ro.lproj/Localizable.strings"))
        #expect(result.output.contains("en.lproj: eklentinin adı"))
    }

    @Test func missingBundleIsRejected() throws {
        let result = try verify(URL(fileURLWithPath: "/nonexistent/Arhivar.app"))
        #expect(result.status != 0)
    }
}
