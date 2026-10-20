// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Arhivar",
    platforms: [.macOS(.v26)],
    targets: [
        // 7zz çalıştırma, çıktı ayrıştırma ve yerelleştirme mantığı (arayüzden bağımsız, test edilebilir).
        .target(name: "ArhivarCore", dependencies: ["CLibArchive"]),
        // macOS'un yerleşik libarchive kitaplığı: 7zz çalıştırılamayan Quick Look kum havuzunda arşiv listesi için.
        .target(name: "CLibArchive", linkerSettings: [.linkedLibrary("archive")]),
        // SwiftUI arayüzü.
        .executableTarget(
            name: "Arhivar",
            dependencies: ["ArhivarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Finder Quick Look (Hızlı Bakış) önizleme eklentisi.
        .executableTarget(
            name: "ArhivarQuickLook",
            dependencies: ["ArhivarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ArhivarCoreTests", dependencies: ["ArhivarCore"]),
        // Uygulama modeli (AppModel) akışları; gerçek 7zz ile çalışır.
        .testTarget(name: "ArhivarAppTests", dependencies: ["Arhivar", "ArhivarCore"]),
    ]
)
