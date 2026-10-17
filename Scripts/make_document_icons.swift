// Arhivar varsayılan uygulama olduğunda Finder'da arşivlerin gösterdiği belge simgelerini çizer.
// Her biçim ailesi kendi rengini, çizimini ve etiketini alır: ZIP, 7Z, RAR, TAR ailesi, disk görüntüleri, genel arşiv.
// (Biçim başına ayrı simgeler toplam ~10 MB tutuyordu; altı aile simgesi ~1,5 MB.)
//
// Kullanım: swift Scripts/make_document_icons.swift Resources/DocumentIcons [--preview önizleme.png]
import AppKit

// MARK: - Yardımcılar

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

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// Bir yolu üstten alta doğrusal geçişle doldurur.
func fillGradient(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([top, bottom], [0, 1]), start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

func withShadow(_ ctx: CGContext, offset: CGFloat, blur: CGFloat, color: CGColor, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur, color: color)
    body()
    ctx.restoreGState()
}

// MARK: - Aileler

struct Family {
    /// .icns dosyasının adı (Info.plist'teki CFBundleTypeIconFile).
    let name: String
    /// Sayfanın altındaki etiket (yoksa yalnızca çizim).
    let label: String?
    /// Aile rengi: açık ve koyu ton.
    let light: UInt32
    let dark: UInt32
    let glyph: (CGContext, Family, CGRect) -> Void
}

// MARK: - Çizimler (1024 tuvalinde, verilen alana ortalanır)

/// Fermuar: boydan boya dişli dikey şerit ve üstte çekece (ZIP).
func zipper(_ ctx: CGContext, _ family: Family, _ area: CGRect) {
    let width = area.width * 0.24
    let track = CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: area.height)
    withShadow(ctx, offset: 6, blur: 14, color: rgb(family.dark, 0.35)) {
        fillGradient(ctx, roundedRect(track, width * 0.28), top: rgb(family.light), bottom: rgb(family.dark))
    }
    // Dişler: iki sıra, birbirine geçmeli.
    let toothWidth = width * 0.42, toothHeight = width * 0.16, step = toothHeight * 1.9
    var y = track.minY + toothHeight
    var left = true
    while y < track.maxY - toothHeight * 2 {
        let x = left ? track.midX - toothWidth + width * 0.04 : track.midX - width * 0.04
        fill(ctx, roundedRect(CGRect(x: x, y: y, width: toothWidth, height: toothHeight), toothHeight * 0.35), rgb(0xFFFFFF, 0.95))
        y += step
        left.toggle()
    }
    // Çekece: şeridin üst kısmında, gövde ve tutma halkası.
    let slider = CGRect(x: track.midX - width * 0.62, y: track.maxY - track.height * 0.34, width: width * 1.24, height: width * 0.9)
    let tab = CGRect(x: track.midX - width * 0.42, y: slider.minY - width * 1.55, width: width * 0.84, height: width * 1.75)
    withShadow(ctx, offset: 6, blur: 12, color: rgb(0x000000, 0.35)) {
        fill(ctx, roundedRect(tab, width * 0.36), rgb(family.dark))
        fill(ctx, roundedRect(slider, width * 0.3), rgb(family.dark))
    }
    fill(ctx, roundedRect(tab.insetBy(dx: width * 0.2, dy: width * 0.32).offsetBy(dx: 0, dy: -width * 0.12), width * 0.16), rgb(family.light, 0.9))
}

/// Arhivar kutusu: kapak, gövde ve isteğe bağlı fermuar (7Z, genel arşiv).
func box(_ ctx: CGContext, _ family: Family, _ area: CGRect, zipped: Bool) {
    let body = CGRect(x: area.minX + area.width * 0.06, y: area.minY, width: area.width * 0.88, height: area.height * 0.7)
    let lid = CGRect(x: area.minX, y: body.maxY - area.height * 0.04, width: area.width, height: area.height * 0.3)
    withShadow(ctx, offset: 8, blur: 18, color: rgb(family.dark, 0.35)) {
        fillGradient(ctx, roundedRect(body, area.width * 0.09), top: rgb(family.light), bottom: rgb(family.dark))
    }
    withShadow(ctx, offset: 6, blur: 14, color: rgb(family.dark, 0.4)) {
        fillGradient(ctx, roundedRect(lid, area.width * 0.08), top: rgb(family.light), bottom: rgb(family.light))
    }
    // Kapakta parlama
    ctx.saveGState()
    ctx.addPath(roundedRect(lid, area.width * 0.08))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)], [0, 1]), start: CGPoint(x: lid.midX, y: lid.maxY), end: CGPoint(x: lid.midX, y: lid.minY), options: [])
    ctx.restoreGState()
    if zipped {
        let width = area.width * 0.11
        let track = CGRect(x: area.midX - width / 2, y: body.minY + body.height * 0.08, width: width, height: lid.maxY - body.minY - body.height * 0.14)
        fill(ctx, roundedRect(track, width * 0.3), rgb(0xFFFFFF, 0.95))
        let tooth = width * 0.34
        var y = track.minY + tooth
        var left = true
        while y < track.maxY - tooth * 1.5 {
            let x = left ? track.midX - tooth - 1 : track.midX + 1
            fill(ctx, roundedRect(CGRect(x: x, y: y, width: tooth, height: tooth * 0.6), tooth * 0.2), rgb(family.dark, 0.9))
            y += tooth * 1.2
            left.toggle()
        }
        let pull = CGRect(x: track.midX - width * 0.85, y: body.minY + body.height * 0.22, width: width * 1.7, height: width * 2.5)
        withShadow(ctx, offset: 5, blur: 10, color: rgb(0x000000, 0.35)) {
            fill(ctx, roundedRect(pull, width * 0.55), rgb(0xFFFFFF))
        }
        fill(ctx, roundedRect(pull.insetBy(dx: width * 0.5, dy: width * 0.55), width * 0.3), rgb(family.dark))
    } else {
        // Etiket yuvası
        let slot = CGRect(x: area.midX - area.width * 0.2, y: body.minY + body.height * 0.52, width: area.width * 0.4, height: body.height * 0.16)
        fill(ctx, roundedRect(slot, slot.height / 2), rgb(0xFFFFFF, 0.92))
    }
}

/// Kemerle bağlı üç cilt (RAR).
func books(_ ctx: CGContext, _ family: Family, _ area: CGRect) {
    let width = area.width * 0.28, gap = area.width * 0.06
    let total = width * 3 + gap * 2
    let shades: [(UInt32, UInt32)] = [(family.light, family.dark), (family.dark, family.light), (family.light, family.dark)]
    for index in 0..<3 {
        let x = area.midX - total / 2 + CGFloat(index) * (width + gap)
        let height = area.height * (index == 1 ? 1 : 0.9)
        let book = CGRect(x: x, y: area.minY, width: width, height: height)
        withShadow(ctx, offset: 6, blur: 14, color: rgb(family.dark, 0.35)) {
            fillGradient(ctx, roundedRect(book, width * 0.16), top: rgb(shades[index].0), bottom: rgb(shades[index].1))
        }
        // Sırt çizgileri
        for line in [0.78, 0.18] {
            fill(ctx, roundedRect(CGRect(x: x + width * 0.18, y: area.minY + height * line, width: width * 0.64, height: width * 0.1), width * 0.05), rgb(0xFFFFFF, 0.55))
        }
    }
    // Kemer ve tokası
    let belt = CGRect(x: area.midX - total / 2 - area.width * 0.04, y: area.minY + area.height * 0.4, width: total + area.width * 0.08, height: area.height * 0.13)
    withShadow(ctx, offset: 5, blur: 10, color: rgb(0x000000, 0.3)) {
        fill(ctx, roundedRect(belt, belt.height * 0.3), rgb(0x3F3F46))
    }
    let buckle = CGRect(x: area.midX - belt.height * 0.75, y: belt.minY - belt.height * 0.2, width: belt.height * 1.5, height: belt.height * 1.4)
    ctx.addPath(roundedRect(buckle, belt.height * 0.25))
    ctx.setStrokeColor(rgb(0xFACC15))
    ctx.setLineWidth(belt.height * 0.22)
    ctx.strokePath()
}

/// Üst üste katmanlar (TAR ailesi: bir kutuda toplanmış dosyalar).
func layers(_ ctx: CGContext, _ family: Family, _ area: CGRect) {
    let slab = area.height * 0.26
    for index in (0..<3).reversed() {
        let inset = CGFloat(index) * area.width * 0.07
        let rect = CGRect(x: area.minX + inset, y: area.minY + CGFloat(2 - index) * slab * 1.18, width: area.width - inset * 2, height: slab)
        let tone = index == 0 ? family.dark : (index == 1 ? family.light : family.light)
        withShadow(ctx, offset: 6, blur: 14, color: rgb(family.dark, 0.35)) {
            fillGradient(ctx, roundedRect(rect, slab * 0.28), top: rgb(tone), bottom: rgb(index == 0 ? family.dark : family.dark, index == 0 ? 1 : 0.85))
        }
        // Parlama ve çizgi
        fill(ctx, roundedRect(CGRect(x: rect.minX + rect.width * 0.1, y: rect.midY - slab * 0.06, width: rect.width * 0.8, height: slab * 0.12), slab * 0.06), rgb(0xFFFFFF, 0.6))
    }
}

/// Disk: halkalar, ortadaki delik ve parlama (ISO, DMG ve diğer disk görüntüleri).
func disc(_ ctx: CGContext, _ family: Family, _ area: CGRect) {
    let diameter = min(area.width, area.height)
    let rect = CGRect(x: area.midX - diameter / 2, y: area.midY - diameter / 2, width: diameter, height: diameter)
    withShadow(ctx, offset: 8, blur: 18, color: rgb(family.dark, 0.4)) {
        ctx.addEllipse(in: rect)
        ctx.setFillColor(rgb(family.dark))
        ctx.fillPath()
    }
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(family.light), rgb(family.dark)], [0, 1]), start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Işık yansıması: köşegen bir şerit
    ctx.drawLinearGradient(
        gradient([rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)], [0.35, 0.5, 0.65]),
        start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: []
    )
    ctx.restoreGState()
    // İz halkaları
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.28))
    ctx.setLineWidth(diameter * 0.012)
    for scale in [0.82, 0.66] {
        let ring = rect.insetBy(dx: diameter * (1 - scale) / 2, dy: diameter * (1 - scale) / 2)
        ctx.strokeEllipse(in: ring)
    }
    // Göbek ve delik
    let hub = rect.insetBy(dx: diameter * 0.34, dy: diameter * 0.34)
    fill(ctx, CGPath(ellipseIn: hub, transform: nil), rgb(0xFFFFFF, 0.9))
    let hole = rect.insetBy(dx: diameter * 0.44, dy: diameter * 0.44)
    fill(ctx, CGPath(ellipseIn: hole, transform: nil), rgb(0xF1F5F9))
    ctx.addEllipse(in: hole)
    ctx.setStrokeColor(rgb(family.dark, 0.5))
    ctx.setLineWidth(diameter * 0.012)
    ctx.strokePath()
}

let families: [Family] = [
    Family(name: "zip", label: "ZIP", light: 0x60A5FA, dark: 0x1D4ED8) { zipper($0, $1, $2) },
    Family(name: "7z", label: "7Z", light: 0xA78BFA, dark: 0x4F46E5) { box($0, $1, $2, zipped: true) },
    Family(name: "rar", label: "RAR", light: 0xFB7185, dark: 0xBE123C) { books($0, $1, $2) },
    Family(name: "tar", label: "TAR", light: 0xFDBA74, dark: 0xEA580C) { layers($0, $1, $2) },
    Family(name: "disk", label: "IMG", light: 0x5EEAD4, dark: 0x0F766E) { disc($0, $1, $2) },
    Family(name: "archive", label: nil, light: 0x94A3B8, dark: 0x475569) { box($0, $1, $2, zipped: false) },
]

// MARK: - Sayfa

/// macOS belge simgesi: kıvrık köşeli beyaz sayfa, ortada aile çizimi, altta renkli etiket.
/// 32 piksel ve altında etiket okunmaz; yalnızca çizim büyütülerek gösterilir.
func drawDocument(_ family: Family, in ctx: CGContext, pixelSize: Int) {
    let compact = pixelSize <= 32
    let page = CGRect(x: 184, y: 56, width: 656, height: 912)
    let fold: CGFloat = 190
    let radius: CGFloat = 44

    // Kıvrık köşeli sayfa yolu (sağ üst köşe kesik).
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: page.minX + radius, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX - radius, y: page.minY))
    outline.addArc(tangent1End: CGPoint(x: page.maxX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: page.minY + radius), radius: radius)
    outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    outline.addLine(to: CGPoint(x: page.minX + radius, y: page.maxY))
    outline.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.maxY - radius), radius: radius)
    outline.addLine(to: CGPoint(x: page.minX, y: page.minY + radius))
    outline.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: page.minX + radius, y: page.minY), radius: radius)
    outline.closeSubpath()

    withShadow(ctx, offset: 10, blur: 24, color: rgb(0x000000, 0.28)) {
        fill(ctx, outline, rgb(0xFFFFFF))
    }
    fillGradient(ctx, outline, top: rgb(0xFFFFFF), bottom: rgb(0xF1F5F9))
    // Sayfanın üstünde ailenin renginde ince bir parıltı
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(family.light, 0.16), rgb(family.light, 0)], [0, 1]), start: CGPoint(x: page.midX, y: page.maxY), end: CGPoint(x: page.midX, y: page.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(outline)
    ctx.setStrokeColor(rgb(0x0F172A, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Kıvrık köşe
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 36))
    corner.addArc(tangent1End: CGPoint(x: page.maxX - fold, y: page.maxY - fold), tangent2End: CGPoint(x: page.maxX - fold + 36, y: page.maxY - fold), radius: 36)
    corner.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    corner.closeSubpath()
    withShadow(ctx, offset: 6, blur: 14, color: rgb(0x000000, 0.2)) {
        fillGradient(ctx, corner, top: rgb(0xE2E8F0), bottom: rgb(0xFFFFFF))
    }
    ctx.addPath(corner)
    ctx.setStrokeColor(rgb(0x0F172A, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Aile çizimi
    let glyphArea = compact
        ? CGRect(x: page.minX + 96, y: page.minY + 150, width: page.width - 192, height: 540)
        : (family.label == nil
            ? CGRect(x: page.minX + 120, y: page.minY + 170, width: page.width - 240, height: 470)
            : CGRect(x: page.minX + 140, y: page.minY + 330, width: page.width - 280, height: 380))
    family.glyph(ctx, family, glyphArea)

    // Etiket
    guard !compact, let label = family.label else { return }
    let pill = CGRect(x: page.minX + 96, y: page.minY + 96, width: page.width - 192, height: 168)
    withShadow(ctx, offset: 6, blur: 14, color: rgb(family.dark, 0.35)) {
        fillGradient(ctx, roundedRect(pill, 52), top: rgb(family.light), bottom: rgb(family.dark))
    }
    // Uzun etiketler (QCOW2, LZMA) şeride sığacak kadar küçültülür.
    func makeText(_ size: CGFloat) -> (NSAttributedString, NSFont) {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return (NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white, .kern: size * 0.03]), font)
    }
    var (text, font) = makeText(124)
    var bounds = text.boundingRect(with: CGSize(width: 2000, height: 400), options: [.usesLineFragmentOrigin])
    let room = pill.width - 72
    if bounds.width > room {
        (text, font) = makeText(124 * room / bounds.width)
        bounds = text.boundingRect(with: CGSize(width: 2000, height: 400), options: [.usesLineFragmentOrigin])
    }
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(at: CGPoint(x: pill.midX - bounds.width / 2, y: pill.midY - bounds.height / 2 - font.descender * 0.35))
    NSGraphicsContext.current = previous
}

// MARK: - Çıktı

func png(_ family: Family, size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawDocument(family, in: ctx, pixelSize: size)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = Array(CommandLine.arguments.dropFirst())
let outputDirectory = URL(fileURLWithPath: arguments.first ?? "DocumentIcons", isDirectory: true)
let previewPath = arguments.firstIndex(of: "--preview").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    // 1024 piksel (512@2x) eklenmez: belge simgeleri bu boyutta gösterilmez ve dosya boyutunu ikiye katlıyordu.
    (512, "512x512"),
]

for family in families {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("Arhivar-\(family.name)-\(UUID().uuidString).iconset", isDirectory: true)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: iconset) }
    for (size, name) in variants {
        try png(family, size: size).write(to: iconset.appendingPathComponent("icon_\(name).png"))
    }
    let output = outputDirectory.appendingPathComponent("\(family.name).icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write("iconutil başarısız oldu: \(family.name)\n".data(using: .utf8)!)
        exit(1)
    }
    print("Belge simgesi oluşturuldu: \(output.path)")
}

// İsteğe bağlı önizleme: tüm simgeler 160 px boyutunda, yan yana.
if let previewPath {
    let cell = 180, columns = 6, rows = (families.count + columns - 1) / columns
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: cell * columns, pixelsHigh: cell * rows, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.setFillColor(rgb(0xE5E7EB))
    ctx.fill(CGRect(x: 0, y: 0, width: cell * columns, height: cell * rows))
    ctx.interpolationQuality = .high
    for (index, family) in families.enumerated() {
        let image = NSImage(data: png(family, size: 256))!
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let column = index % columns, row = rows - 1 - index / columns
        ctx.draw(cg, in: CGRect(x: column * cell + 10, y: row * cell + 10, width: 160, height: 160))
    }
    context.flushGraphics()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewPath))
    print("Önizleme: \(previewPath)")
}
