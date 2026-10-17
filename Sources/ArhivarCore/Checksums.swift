import Foundation

/// Bir dosyanın sağlama değeri (ör. "SHA256" → "98ea…").
public struct Checksum: Sendable, Equatable {
    public let algorithm: String
    public let value: String

    public init(algorithm: String, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

extension SevenZipCommand {
    /// Sağlama değerleri için kullanılan algoritmalar (7zz -scrc adlarıyla).
    public static let checksumAlgorithms = ["CRC32", "SHA256", "BLAKE2sp"]

    /// `7zz h`: dosyanın CRC32, SHA-256 ve BLAKE2sp değerlerini hesaplar (ek bağımlılık yok).
    public static func hash(file: URL) -> [String] {
        ["h", "-bd"] + checksumAlgorithms.map { "-scrc" + $0 } + common + ["--", file.path]
    }
}

/// `7zz h` çıktısındaki "SHA256 for data: …" satırlarını okur.
public enum ChecksumParser {
    public static func parse(_ output: String) -> [Checksum] {
        var result: [Checksum] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: " for data:") else { continue }
            let algorithm = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !algorithm.isEmpty, !value.isEmpty, !algorithm.contains(" ") else { continue }
            result.append(Checksum(algorithm: algorithm, value: value))
        }
        return result
    }

    /// Kopyalanabilir metin: her satırda "ALGORİTMA: değer".
    public static func text(_ checksums: [Checksum]) -> String {
        checksums.map { "\($0.algorithm): \($0.value)" }.joined(separator: "\n")
    }
}
