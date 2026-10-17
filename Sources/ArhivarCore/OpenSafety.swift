import Foundation
import UniformTypeIdentifiers

/// Arşivden çıkarılan bir dosyayı açmadan önceki güvenlik denetimleri.
public enum OpenSafety {
    /// Açıldığında kod çalıştırabilen ya da sistem ayarı değiştirebilen türler.
    static let riskyTypes: [UTType] = [
        .executable, .script, .application, .applicationBundle, .unixExecutable, .internetLocation,
        .diskImage,
    ] + [
        "com.apple.installer-package-archive",
        "com.apple.mobileconfig",
        "com.apple.terminal.settings",
        "com.apple.automator-workflow",
        "com.apple.applescript.script",
        "com.apple.applescript.text",
        "com.apple.applescript.script-bundle",
        "com.apple.shortcut",
        "com.apple.systempreference.prefpane",
        "com.apple.quicklook.generator",
    ].compactMap { UTType($0) }

    /// Sistemin tür tanımı olmayabilen (dinamik UTI) riskli uzantılar: AppleScript, Kestirmeler, sistem eklentileri.
    static let riskyExtensions: Set<String> = ["scpt", "scptd", "applescript", "shortcut", "prefpane", "qlgenerator"]

    /// Dosya çalıştırılabilir ya da riskli bir türdeyse türün okunur adını (yoksa tanımlayıcısını) döndürür.
    public static func executableKind(of url: URL) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        if let type = values?.contentType, riskyTypes.contains(where: { type.conforms(to: $0) }) {
            return type.localizedDescription ?? type.identifier
        }
        if riskyExtensions.contains(resolved.pathExtension.lowercased()) {
            return values?.contentType?.localizedDescription ?? resolved.pathExtension
        }
        // Uzantısız Mach-O ya da betikler: çalıştırma (x) biti olan sıradan dosyalar.
        if values?.isRegularFile == true,
           let permissions = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.posixPermissions] as? NSNumber,
           permissions.uint16Value & 0o111 != 0 {
            return values?.contentType?.localizedDescription ?? "Unix executable"
        }
        return nil
    }

    /// Görünmez ya da yön değiştiren karakterler (ör. U+202E) bir adın gerçek uzantısını gizleyebilir:
    /// "fatura\u{202E}fdp.command", Finder'da "faturadnammoc.pdf" gibi görünür.
    public static func hasDeceptiveCharacters(_ name: String) -> Bool {
        name.unicodeScalars.contains(where: isDeceptive)
    }

    /// Gizli karakterleri görünür yer tutucularla değiştirir: "fatura⟦U+202E⟧fdp.command".
    public static func visibleName(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if isDeceptive(scalar) {
                result += String(format: "⟦U+%04X⟧", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Görünmeyen ama "harf" ya da "sembol" sayılan doldurma karakterleri: Braille boşluğu, Hangul dolgu harfleri.
    /// Bir adın sonundaki gerçek uzantıyı boşlukla itip gizleyebilirler ("fatura.pdf⠀⠀⠀⠀.app").
    static let blankFillers: Set<UInt32> = [0x2800, 0x3164, 0x115F, 0x1160, 0xFFA0]

    static func isDeceptive(_ scalar: Unicode.Scalar) -> Bool {
        if blankFillers.contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .format, .control, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }
}
