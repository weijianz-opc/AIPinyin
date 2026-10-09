// Builds Resources/AppIcon.icns (the input method's and the AllInOneIME Settings app's icon) from the
// 1024 px master Resources/AppIcon.png. Run:
//   swift Scripts/make-app-icon.swift Resources/AppIcon.png Resources/AppIcon.icns
import AppKit

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources/AppIcon.png")
let out = args.count > 2 ? args[2] : "Resources/AppIcon.icns"
guard let master = NSImage(contentsOf: source) else { fatalError("can't read \(source.path)") }

/// The master scaled to `pixels` × `pixels`, as PNG.
func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out)")
