// Generates Resources/icon.tiff, the input method's menu-bar icon: the ∞-and-cursor mark of
// Resources/AppIcon.png knocked out of a 16 pt rounded badge, in 1x and 2x. macOS draws it as a
// template image (only its alpha counts). Run:
//   swift Scripts/make-icon.swift Resources/AppIcon.png Resources/icon.tiff
import AppKit

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources/AppIcon.png")
let out = args.count > 2 ? args[2] : "Resources/icon.tiff"

func bitmap(_ width: Int, _ height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
}

/// The light ribbon and bar of the app icon as a black image whose alpha follows their brightness,
/// cropped to the mark. The dark blue background, its rim and most of the glow fall below the ramp.
func mark() -> NSImage {
    guard let icon = NSImage(contentsOf: source) else { fatalError("can't read \(source.path)") }
    let n = 1024
    let rgba = bitmap(n, n)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rgba)
    icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.restoreGraphicsState()

    let pixels = rgba.bitmapData!
    // The rounded square first: its bright rim is not part of the mark.
    var (left, top, right, bottom) = (n, n, -1, -1)
    for y in 0..<n {
        for x in 0..<n where pixels[(y * n + x) * 4 + 3] > 128 {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
        }
    }
    let margin = (right - left) * 8 / 100
    var alpha = [UInt8](repeating: 0, count: n * n)
    var (minX, minY, maxX, maxY) = (n, n, -1, -1)
    for y in (top + margin)...(bottom - margin) {
        for x in (left + margin)...(right - margin) {
            let i = (y * n + x) * 4
            let a = Double(pixels[i + 3])
            guard a > 128 else { continue }
            // The rep is premultiplied: divide by alpha for the luminance (0–255).
            let luminance = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1])
                             + 0.0722 * Double(pixels[i + 2])) * 255 / a
            let value = min(max((luminance - 95) / (165 - 95), 0), 1)
            alpha[y * n + x] = UInt8(value * 255)
            if value > 0.25 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    guard maxX > minX, maxY > minY else { fatalError("no light mark found in \(source.path)") }
    let width = maxX - minX + 1, height = maxY - minY + 1
    let crop = bitmap(width, height)
    let target = crop.bitmapData!
    for y in 0..<height {
        for x in 0..<width {
            let o = (y * width + x) * 4
            target[o] = 0; target[o + 1] = 0; target[o + 2] = 0  // black (premultiplied)
            target[o + 3] = alpha[(y + minY) * n + x + minX]
        }
    }
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(crop)
    return image
}

let glyph = mark()

func rep(pixels: Int) -> NSBitmapImageRep {
    let rep = bitmap(pixels, pixels)
    rep.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // The context maps the rep's 16 pt size onto its pixel grid; draw in points.
    let badge = NSRect(x: 0.5, y: 1.5, width: 15, height: 13)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
    // The mark, as large as fits with a margin, knocked out of the badge.
    let room = badge.insetBy(dx: 1.6, dy: 1.2)
    let scale = min(room.width / glyph.size.width, room.height / glyph.size.height)
    let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
    glyph.draw(in: NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2,
                          width: size.width, height: size.height),
               from: .zero, operation: .destinationOut, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: NSSize(width: 16, height: 16))
image.addRepresentation(rep(pixels: 16))
image.addRepresentation(rep(pixels: 32))
guard let tiff = image.tiffRepresentation else { fatalError("could not encode TIFF") }
try tiff.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
