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

    /// Yalnızca simgeden oluşan düğmeler ("label: { Image(…) }"): VoiceOver'ın okuyacağı bir ad yoktur, `.help`
    /// yalnızca fareyle üzerine gelince görünen ipucudur. Düğmenin değiştiricilerinde `.accessibilityLabel` aranır.
    static func unlabeledIconButtons(in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var found: [String] = []
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasSuffix("} label: {") {
            // Etiket gövdesi: kapanan ayraca kadar olan satırlar.
            var depth = 1
            var body: [String] = []
            var end = index + 1
            while end < lines.count, depth > 0 {
                for character in lines[end] {
                    if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
                }
                if depth > 0 { body.append(lines[end]) }
                end += 1
            }
            let content = body.joined(separator: "\n")
            let iconOnly = content.contains("Image(") && !content.contains("Text(") && !content.contains("Label(")
            guard iconOnly else { continue }
            // Düğmenin değiştirici zinciri: kapanıştan sonraki "." ile başlayan satırlar.
            var modifiers: [String] = []
            var next = end
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                modifiers.append(lines[next])
                next += 1
            }
            if !modifiers.contains(where: { $0.contains(".accessibilityLabel(") }) {
                found.append("\(index + 1): \(body.first?.trimmingCharacters(in: .whitespaces) ?? "")")
            }
        }
        return found
    }

    @Test func iconOnlyButtonsHaveAccessibilityLabels() throws {
        var report: [String] = []
        for folder in Self.sourceFolders {
            let root = Self.packageRoot.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                report += Self.unlabeledIconButtons(in: source).map { "\(file.lastPathComponent):\($0)" }
            }
        }
        #expect(report.isEmpty, "Erişilebilirlik adı olmayan simge düğmeleri:\n\(report.joined(separator: "\n"))")
    }

    @Test func iconButtonGuardDetectsMissingLabel() {
        let unlabeled = """
        Button {
            model.goUp()
        } label: {
            Image(systemName: "chevron.up")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(settings.t(.navUp))
        """
        #expect(Self.unlabeledIconButtons(in: unlabeled).count == 1)
        #expect(Self.unlabeledIconButtons(in: unlabeled + "\n.accessibilityLabel(settings.t(.navUp))").isEmpty)
        let withText = """
        Button {
            go()
        } label: {
            HStack {
                Image(systemName: "folder")
                Text(name)
            }
        }
        """
        #expect(Self.unlabeledIconButtons(in: withText).isEmpty)
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
