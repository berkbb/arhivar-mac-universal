import Foundation
import Testing

/// Arayüz metinleri yalnızca dil tablolarından gelmelidir (tr/en/ro birebir). Bu bekçi, SwiftUI görünümlerinde
/// doğrudan yazılmış metni ("Şifreli", "Archive") arar; Hızlı Bakış ekranındaki gömülü Türkçe metin gibi bir
/// gerilemenin fark edilmeden kalmasını önler. Simgeler, ayırıcılar ("•", "—") ve yalnızca kod eklemeleri serbesttir.
@Suite struct HardcodedTextGuardTests {
    static let sourceFolders = ["Sources/Arhivar", "Sources/ArhivarQuickLook"]
    /// Her dilde aynı yazılan özel adlar (program ve ürün adları); çevrilmezler.
    static let untranslatableNames: Set<String> = ["7zz", "7-Zip", "Arhivar"]

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// İlk bağımsız değişkeni bir dize olan görünüm kurucuları ve değiştiricileri.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:Text|Label|Button|Toggle|Section|Picker|Menu|TextField|SecureField|ContentUnavailableView|LabeledContent)|\.(?:help|navigationTitle|navigationSubtitle|alert|confirmationDialog))\(\s*"((?:[^"\\]|\\.)*)""#
    )

    /// Dizedeki "\(…)" eklemelerini (iç içe ayraçlarla) atar; geriye kalan görünür metindir.
    static func visibleText(of literal: String) -> String {
        var result = ""
        var characters = Array(literal)[...]
        while let character = characters.popFirst() {
            if character == "\\", characters.first == "(" {
                characters.removeFirst()
                var depth = 1
                while depth > 0, let next = characters.popFirst() {
                    if next == "(" { depth += 1 } else if next == ")" { depth -= 1 }
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func violations(in source: String) -> [String] {
        var found: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let literalRange = Range(match.range(at: 1), in: text) else { continue }
                let visible = visibleText(of: String(text[literalRange]))
                if visible.contains(where: \.isLetter), !untranslatableNames.contains(visible) {
                    found.append(text.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return found
    }

    @Test func viewsHaveNoHardcodedText() throws {
        var report: [String] = []
        for folder in Self.sourceFolders {
            let root = Self.packageRoot.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty, "\(folder) içinde Swift dosyası bulunamadı")
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                let relativePath = file.path.replacingOccurrences(of: Self.packageRoot.path + "/", with: "")
                report += Self.violations(in: source).map { "\(relativePath): \($0)" }
            }
        }
        #expect(report.isEmpty, "Dil tablosu yerine gömülü metin:\n\(report.joined(separator: "\n"))")
    }

    /// Bekçinin kendisi: gerçek ihlali yakalar, serbest kalıplara takılmaz.
    @Test func guardCatchesLiteralsAndIgnoresAllowedPatterns() {
        #expect(Self.violations(in: #"Text("Arşiv Okunamadı")"#).count == 1)
        #expect(Self.violations(in: #"Label("Şifreli", systemImage: "lock.fill")"#).count == 1)
        #expect(Self.violations(in: #".help("Open archive")"#).count == 1)
        #expect(Self.violations(in: #"Text("\(stats.fileCount) dosya")"#).count == 1)

        #expect(Self.violations(in: #"Text(settings.t(.qlTitle))"#).isEmpty)
        #expect(Self.violations(in: #"Text("•")"#).isEmpty)
        #expect(Self.violations(in: #"Text("—")"#).isEmpty)
        #expect(Self.violations(in: #"Text("\(language.flag)  \(language.nativeName ?? settings.t(.languageSystem))")"#).isEmpty)
        #expect(Self.violations(in: #"// Text("Eski metin")"#).isEmpty)
        #expect(Self.violations(in: #"LabeledContent("7zz") {"#).isEmpty)
        #expect(Self.violations(in: #"Text("7zz bulunamadı")"#).count == 1)
        #expect(Self.visibleText(of: #"\(a(b(c))) x"#) == " x")
    }
}
