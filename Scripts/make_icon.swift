// Arhivar uygulama simgesini (AppIcon.icns) çizer.
// Kullanım: swift Scripts/make_icon.swift Resources/AppIcon.icns
import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// 1024×1024 koordinat sisteminde çizer (orijin sol altta).
func drawIcon(in ctx: CGContext) {
    // macOS simge ızgarası: 824 pt gövde, 100 pt kenar boşluğu.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = roundedRect(body, 186)

    // Gölge
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0x4F46E5))
    ctx.fillPath()
    ctx.restoreGState()

    // Arka plan: mor → mavi → turkuaz
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0x8B5CF6), rgb(0x3B82F6), rgb(0x14B8A6)], [0, 0.55, 1]),
        start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: []
    )
    // Cam parlaması
    ctx.drawLinearGradient(
        gradient([rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)], [0, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: []
    )
    ctx.restoreGState()

    // Kutu gövdesi
    let box = CGRect(x: 262, y: 220, width: 500, height: 390)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x1E1B4B, 0.35))
    ctx.addPath(roundedRect(box, 54))
    ctx.setFillColor(rgb(0xFFFFFF, 0.97))
    ctx.fillPath()
    ctx.restoreGState()

    // Kutunun alt kısmına hafif gölgelendirme
    ctx.saveGState()
    ctx.addPath(roundedRect(box, 54))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0xE0E7FF, 0), rgb(0xC7D2FE, 0.55)], [0, 1]),
        start: CGPoint(x: 512, y: 610), end: CGPoint(x: 512, y: 220), options: []
    )
    ctx.restoreGState()

    // Kapak
    let lid = CGRect(x: 230, y: 590, width: 564, height: 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x1E1B4B, 0.30))
    ctx.addPath(roundedRect(lid, 46))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Fermuar şeridi
    let track = CGRect(x: 484, y: 236, width: 56, height: 488)
    ctx.addPath(roundedRect(track, 16))
    ctx.setFillColor(rgb(0x4338CA))
    ctx.fillPath()

    // Fermuar dişleri
    ctx.setFillColor(rgb(0xFFFFFF, 0.92))
    var y: CGFloat = 262
    var left = true
    while y < 706 {
        let tooth = CGRect(x: left ? 490 : 512, y: y, width: 22, height: 13)
        ctx.addPath(roundedRect(tooth, 4))
        ctx.fillPath()
        y += 26
        left.toggle()
    }

    // Fermuar çekeceği
    let pull = CGRect(x: 470, y: 300, width: 84, height: 132)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x000000, 0.35))
    ctx.addPath(roundedRect(pull, 28))
    ctx.setFillColor(rgb(0x312E81))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(CGRect(x: 494, y: 330, width: 36, height: 56), 14))
    ctx.setFillColor(rgb(0xA5B4FC))
    ctx.fillPath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Arhivar-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
for (size, name) in variants {
    try png(size: size).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil başarısız oldu\n".data(using: .utf8)!)
    exit(1)
}
print("Simge oluşturuldu: \(outputPath)")
