import Darwin
import Foundation
import Testing
@testable import ArhivarCore

// .agents/context/roadmap.md güvenlik denetimi turu: onaylanan ve düzeltilen açıklar.

private func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Denetim #8: ".term" (com.apple.terminal.session) açıldığında Terminal'de komut çalıştırır; uyarı gerektirir.
@Test func terminalSessionFilesAreRisky() throws {
    let dir = try tempDir("term"); defer { StagedExtraction.removeTree(at: dir) }
    for name in ["oturum.term", "ayar.terminal"] {
        let url = dir.appendingPathComponent(name)
        try Data("<plist/>".utf8).write(to: url)
        #expect(OpenSafety.executableKind(of: url) != nil, "\(name) riskli sayılmalı")
    }
    // Zararsız bir veri dosyası riskli sayılmaz.
    let plain = dir.appendingPathComponent("notlar.txt"); try Data("x".utf8).write(to: plain)
    #expect(OpenSafety.executableKind(of: plain) == nil)
}

/// Denetim #3: kişisel veri kara listesi yaygın bulut/geliştirici kimlik bilgisi konumlarını da kapsar.
@Test func denylistCoversCloudAndDevCredentials() {
    let home = URL(fileURLWithPath: "/Users/ornek")
    let denied = Set(SandboxProfile.personalDataDirectories(home: home).map(\.path))
    for path in [".config/gcloud", ".azure", ".oci", ".terraform.d", ".m2", ".gradle", ".cargo", ".gem", "Library/Application Support/Code"] {
        #expect(denied.contains("/Users/ornek/" + path), "\(path) korunmalı")
    }
}

/// Denetim #1: 7zz'nin dış ağacı gösteren bağlantı yerine bıraktığı 0 baytlık yer tutucu, salt okunur (0555) bir
/// klasörün içinde olsa bile silinir (yoksa "üzerine yaz" ile hedefteki gerçek dosyayı sıfırlardı).
@Test func linkPlaceholderRemovedInsideReadOnlyDirectory() throws {
    let root = try tempDir("yer"); defer { StagedExtraction.removeTree(at: root) }
    let ro = root.appendingPathComponent("ro", isDirectory: true)
    try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
    try Data().write(to: ro.appendingPathComponent("x")) // 0 baytlık yer tutucu
    chmod(ro.path, 0o555)

    #expect(StagedExtraction.removeLinkPlaceholders(in: root, links: ["ro/x"]) == ["ro/x"])
    #expect(StagedExtraction.itemType(ro.appendingPathComponent("x"), fileManager: .default) == nil)
    var info = stat(); _ = lstat(ro.path, &info)
    #expect(info.st_mode & 0o777 == 0o555, "klasör kipi geri yüklenmeli")
}

/// Denetim #4/#5: devasa çıktı üreten bir süreç belleği tüketmeden sınırda durdurulur ve işlem hatayla biter.
@Test func commandRunnerCapsHugeOutput() async {
    let runner = CommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat"))
    // /dev/zero sonsuz NUL üretir; 1 MiB sınırla süreç durdurulmalı ve çağrı takılmadan hata atmalı.
    await #expect(throws: (any Error).self) {
        _ = try await runner.run(["/dev/zero"], maxOutputBytes: 1 << 20)
    }
}
