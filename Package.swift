// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Arhivar",
    platforms: [.macOS(.v26)],
    targets: [
        // 7zz çalıştırma, çıktı ayrıştırma ve yerelleştirme mantığı (arayüzden bağımsız, test edilebilir).
        .target(name: "ArhivarCore"),
        // SwiftUI arayüzü.
        .executableTarget(
            name: "Arhivar",
            dependencies: ["ArhivarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ArhivarCoreTests", dependencies: ["ArhivarCore"]),
    ]
)
