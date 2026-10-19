import Foundation

/// Bir alt sürecin tamamlanmış çıktısı.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 7zz (ve güncelleme betiği) çalıştırırken oluşabilecek hatalar.
public enum SevenZipError: Error, Equatable, Sendable {
    case engineNotFound
    case timedOut
    case cancelled
    case wrongPassword
    case notArchive
    case failed(code: Int32, message: String)

    /// 7zz sonucunu sınıflandırır. Başarıda, varsa uyarı metnini döndürür.
    @discardableResult
    public static func check(_ result: ProcessResult) throws -> String? {
        if result.exitCode == 0 { return nil }
        let combined = result.stdout + "\n" + result.stderr
        // "Enter password" istemi parola doğru verilse de çıktıda görünür; tek başına yanlış parola sayılmaz.
        // Parola bilinmiyorsa stdin boştur ve 7zz istemden sonra "Break signaled" ile durur: parola gerekli demektir.
        // İstem olmadan gelen "Break signaled" dışarıdan gönderilen SIGINT/SIGTERM'dir; parola hatası değildir.
        // (Kullanıcının iptali CommandRunner'da ayrıca .cancelled olarak ele alınır.)
        let passwordAborted = combined.range(of: "Break signaled", options: .caseInsensitive) != nil
            && combined.range(of: "Enter password", options: .caseInsensitive) != nil
        if combined.range(of: "wrong password", options: .caseInsensitive) != nil
            || combined.range(of: "Cannot open encrypted archive", options: .caseInsensitive) != nil
            || passwordAborted {
            throw SevenZipError.wrongPassword
        }
        // 7zz çıkış kodları: 1 = uyarı, 2 = ölümcül hata, 7 = komut satırı, 8 = bellek, 255 = kullanıcı durdurdu.
        if result.exitCode == 1 { return diagnostic(from: combined) }
        // 7zz hedef dışını gösteren bağlantıları yazmaz ve 2 ile çıkar; geri kalan her şey çıkarılmıştır.
        // Tek hata buysa işlem uyarıyla tamamlanmış sayılır.
        let errors = combined.split(whereSeparator: \.isNewline).filter { $0.contains("ERROR:") }
        // Arşiv düzeyinde bir hata bloğu ("ERRORS:" başlığı, ör. "Unexpected end of archive"; "Open Errors:") ayrı
        // satırlarda ve "ERROR:" içermeden yazılır: yalnızca bağlantı hatalarına bakıp kesik bir arşivi uyarıya indirgemeyelim.
        let archiveLevelError = combined.range(of: "ERRORS:") != nil || combined.range(of: "Open Errors:") != nil
        if result.exitCode == 2, !archiveLevelError, !errors.isEmpty, errors.allSatisfy({ $0.contains("Dangerous link path was ignored") }) {
            return diagnostic(from: combined)
        }
        // "Cannot open the file as archive", "Cannot open the file as [7z] archive", "Is not archive".
        // Arşiv düzeyinde bir hata bloğu da varsa (ör. yarım inmiş dosya: "Unexpected end of archive") nedeni gösteren
        // genel hata yeğlenir; "arşiv değil" demek yanıltırdı.
        if !archiveLevelError,
           combined.range(of: "open the file as", options: .caseInsensitive) != nil
            || combined.range(of: "is not archive", options: .caseInsensitive) != nil {
            throw SevenZipError.notArchive
        }
        if result.exitCode == 255 { throw SevenZipError.cancelled }
        throw SevenZipError.failed(code: result.exitCode, message: diagnostic(from: combined))
    }

    /// Sonuç, parola bilinmediği (ya da yanlış olduğu) için mi başarısız oldu?
    /// `try? check(...)` kullanılmaz: başarıda `check` nil döndürdüğü için `try?` sonucu da nil olur (SE-0230).
    public static func needsPassword(_ result: ProcessResult) -> Bool {
        do {
            try check(result)
            return false
        } catch {
            return error as? SevenZipError == .wrongPassword
        }
    }

    /// Çıktıdaki hata/uyarı satırlarını kısa bir özete indirger.
    static func diagnostic(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("\u{8}") }
        let markers = ["ERROR", "WARNING", "Error", "Warning", "Can not", "Cannot"]
        var interesting: [String] = []
        for (index, line) in lines.enumerated() where markers.contains(where: { line.contains($0) }) {
            interesting.append(line)
            // "ERRORS:" / "WARNINGS:" blok başlığının açıklaması bir sonraki satırdadır ("Unexpected end of archive").
            if line.hasSuffix("S:"), index + 1 < lines.count, !interesting.contains(lines[index + 1]) { interesting.append(lines[index + 1]) }
        }
        let chosen = interesting.isEmpty ? Array(lines.suffix(3)) : Array(interesting.prefix(6))
        return chosen.joined(separator: "\n")
    }
}

/// 7zz -bsp1 ilerleme çıktısındaki yüzdeleri okur.
public enum ProgressParser {
    /// Metindeki son ilerleme değerini döndürür (0...100).
    ///
    /// 7zz her güncellemeyi geri silme (\b) karakterleriyle ayrılmış " 26% 3 + dosya" biçiminde yazar.
    /// Yüzde yalnızca bir parçanın başında sayılır; dosya adındaki "50%" gibi metinler yok sayılır.
    public static func lastPercentage(in text: String) -> Int? {
        let segments = text.split(whereSeparator: { $0 == "\u{8}" || $0 == "\r" || $0 == "\n" })
        for segment in segments.reversed() {
            let trimmed = segment.drop(while: { $0 == " " })
            let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 3,
                  trimmed.dropFirst(digits.count).first == "%",
                  let value = Int(digits), value <= 100 else { continue }
            return value
        }
        return nil
    }
}

/// Alt süreçleri çalıştırır; ilerleme, zaman aşımı ve iptal desteği sunar.
public struct CommandRunner: Sendable {
    public let executableURL: URL
    /// Doluysa program sandbox-exec altında bu kurallarla çalıştırılır.
    public let sandbox: SandboxProfile?

    public init(executableURL: URL, sandbox: SandboxProfile? = nil) {
        self.executableURL = executableURL
        self.sandbox = sandbox
    }

    /// Süreci çalıştırır. Sıfırdan farklı çıkış kodu hata sayılmaz; sınıflandırma çağırana aittir.
    /// - Parameters:
    ///   - timeout: Saniye; aşılırsa süreç sonlandırılır ve `timedOut` fırlatılır.
    ///   - workingDirectory: Göreli yollar için çalışma klasörü.
    ///   - input: stdin'e yazılacak veri (ör. parola). Yoksa stdin boştur; parola sorulursa 7zz takılmaz, durur.
    ///   - onProgress: 0...1 aralığında ilerleme (stdout'taki yüzdelerden).
    /// Bir alt sürecin stdout'ta biriktirilebilecek en çok baytı. Kötü niyetli bir arşiv, metaverisinde on milyonlarca
    /// küçük girdi bildirip `7zz l -slt` ile gigabaytlarca çıktı ürettirebilir; tüm çıktı bellekte biriktiği için bu,
    /// arşiv yalnızca AÇILIRKEN belleği tüketirdi. Sınır aşılırsa süreç durdurulur ve işlem hatayla biter.
    public static let maxOutputBytes = 512 << 20

    public func run(
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        maxOutputBytes: Int = CommandRunner.maxOutputBytes,
        workingDirectory: URL? = nil,
        input: Data? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ProcessResult {
        let launch: (URL, [String])
        if let sandbox, SandboxProfile.isAvailable {
            launch = (SandboxProfile.launcher, sandbox.launchArguments(executable: executableURL, arguments: arguments))
        } else {
            launch = (executableURL, arguments)
        }
        let box = try ProcessBox(executableURL: launch.0, arguments: launch.1, input: input)
        if let workingDirectory { box.process.currentDirectoryURL = workingDirectory }
        let state = RunState(onProgress: onProgress, maxOutputBytes: maxOutputBytes)
        // Çıktı sınırı aşılırsa süreci durdur; drain EOF alır, bekleyen devam hata ile döner.
        state.onLimitExceeded = { box.terminate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let readers = DispatchGroup()
                readers.enter()
                readers.enter()

                box.process.terminationHandler = { finished in
                    let exitCode = finished.terminationStatus
                    // Tüm çıktı okunduktan sonra sonucu teslim et.
                    readers.notify(queue: .global()) {
                        continuation.resume(with: state.finish(exitCode: exitCode))
                    }
                }

                do {
                    try box.process.run()
                } catch {
                    box.process.terminationHandler = nil
                    continuation.resume(throwing: SevenZipError.engineNotFound)
                    return
                }

                DispatchQueue.global().async {
                    box.drain(box.stdoutPipe) { state.appendStdout($0) }
                    readers.leave()
                }
                DispatchQueue.global().async {
                    box.drain(box.stderrPipe) { state.appendStderr($0) }
                    readers.leave()
                }

                if state.isCancelled { box.terminate() }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if box.isRunning {
                            state.markTimedOut()
                            box.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            box.terminate()
        }
    }
}

/// Process ve borularını eşzamanlı kapanışlara güvenle taşımak için kutu.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    init(executableURL: URL, arguments: [String], input: Data?) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        if let input {
            // Veri süreç başlamadan boruya yazılıp yazma ucu kapatılır: çocuk süreç veriyi ve ardından EOF okur.
            // Böylece kapanmış boruya yazma (SIGPIPE) olamaz. Veri küçüktür, boru tamponuna sığar.
            let stdinPipe = Pipe()
            try stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try stdinPipe.fileHandleForWriting.close()
            process.standardInput = stdinPipe
        } else {
            // Parola sorulursa 7zz takılmasın; boş girdi alır ve "Break signaled" ile durur.
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var isRunning: Bool { process.isRunning }

    /// SIGTERM'i yok sayan (ör. bozuk başlıkta takılan) süreç bu süre sonunda SIGKILL ile durdurulur.
    static let killGracePeriod: TimeInterval = 2

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod) { [self] in
            // Süreç hâlâ çalışıyorsa zorla durdur; böylece sonlanma işleyicisi çalışır ve bekleyen devam (continuation) döner.
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func drain(_ pipe: Pipe, _ consume: (Data) -> Void) {
        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            consume(data)
        }
    }
}

/// Çıktıyı biriktiren ve ilerlemeyi bildiren, kilitle korunan durum.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var progressTail = ""
    private var lastProgress = -1
    private var cancelled = false
    private var timedOut = false
    private var overflowed = false
    private let maxOutputBytes: Int
    /// Çıktı sınırı aşıldığında bir kez çağrılır (süreci durdurmak için). Drain başlamadan ayarlanır.
    var onLimitExceeded: (@Sendable () -> Void)?
    private let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)?, maxOutputBytes: Int = CommandRunner.maxOutputBytes) {
        self.onProgress = onProgress
        self.maxOutputBytes = maxOutputBytes
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func markCancelled() { lock.withLock { cancelled = true } }
    func markTimedOut() { lock.withLock { timedOut = true } }

    func appendStdout(_ data: Data) {
        var report: Int?
        var fireLimit = false
        lock.withLock {
            if overflowed { return }
            if stdout.count + data.count > maxOutputBytes {
                // Sınır aşıldı: bu parçayı ve sonrasını biriktirme, süreci durdur.
                overflowed = true
                fireLimit = true
                return
            }
            stdout.append(data)
            guard onProgress != nil else { return }
            // Yüzdeler parçalar arasında bölünebilir; son birkaç karakter saklanır.
            progressTail = String((progressTail + String(decoding: data, as: UTF8.self)).suffix(64))
            if let value = ProgressParser.lastPercentage(in: progressTail), value != lastProgress {
                lastProgress = value
                report = value
            }
        }
        if fireLimit { onLimitExceeded?() }
        if let report { onProgress?(Double(report) / 100) }
    }

    func appendStderr(_ data: Data) {
        lock.withLock { stderr.append(data) }
    }

    func finish(exitCode: Int32) -> Result<ProcessResult, Error> {
        lock.withLock {
            if cancelled { return .failure(SevenZipError.cancelled) }
            if timedOut { return .failure(SevenZipError.timedOut) }
            if overflowed {
                return .failure(SevenZipError.failed(code: exitCode, message: "Archive output exceeded the size limit and was stopped."))
            }
            return .success(ProcessResult(
                exitCode: exitCode,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            ))
        }
    }
}
