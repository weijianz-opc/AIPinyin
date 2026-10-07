// Generates Resources/AppIcon.icns: a blue rounded square with "AI 拼". Run:
//   swift Scripts/make-app-icon.swift Resources/AppIcon.icns
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: the shape fills about 80% of the canvas.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.12, green: 0.33, blue: 0.86, alpha: 1))!.draw(in: shape, angle: -90)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let top = NSAttributedString(string: "AI", attributes: [
        .font: NSFont.systemFont(ofSize: rect.height * 0.36, weight: .heavy),
        .foregroundColor: NSColor.white, .paragraphStyle: style,
    ])
    let bottom = NSAttributedString(string: "拼", attributes: [
        .font: NSFont.systemFont(ofSize: rect.height * 0.27, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: style,
    ])
    top.draw(in: NSRect(x: rect.minX, y: rect.midY - rect.height * 0.02, width: rect.width, height: rect.height * 0.45))
    bottom.draw(in: NSRect(x: rect.minX, y: rect.minY + rect.height * 0.1, width: rect.width, height: rect.height * 0.36))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
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
