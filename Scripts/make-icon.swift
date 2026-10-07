// Generates Resources/icon.tiff: a 16pt rounded badge with "AI" knocked out,
// with 1x and 2x representations. Run: swift Scripts/make-icon.swift Resources/icon.tiff
import AppKit

func rep(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 16, height: 16)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // The context already maps the rep's 16pt size onto its pixel grid; draw in points.
    let cg = ctx.cgContext

    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0.5, y: 1.5, width: 15, height: 13), xRadius: 3, yRadius: 3).fill()

    cg.setBlendMode(.destinationOut)
    let font = NSFont.systemFont(ofSize: 10, weight: .heavy)
    let text = NSAttributedString(string: "AI", attributes: [.font: font, .foregroundColor: NSColor.black])
    let size = text.size()
    text.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2 + 0.5))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/icon.tiff"
let image = NSImage(size: NSSize(width: 16, height: 16))
image.addRepresentation(rep(pixels: 16))
image.addRepresentation(rep(pixels: 32))
guard let tiff = image.tiffRepresentation else { fatalError("could not encode TIFF") }
try tiff.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
