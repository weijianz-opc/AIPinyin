// Builds the README images from the panels rendered by `AIPinyin --selftest`:
//   swift Scripts/make-readme-images.swift /tmp/aipinyin-selftest docs
// docs/demo.png      the two steps side by side, each under a text line with the inline (marked) text
// docs/panel-dark.png, docs/settings.png   copies of the renders
import AppKit

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/aipinyin-selftest")
let output = URL(fileURLWithPath: args.count > 2 ? args[2] : "docs")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func load(_ name: String) -> NSBitmapImageRep {
    let url = source.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
        fatalError("missing \(url.path); run `make selftest` first")
    }
    return rep
}

func png(_ size: NSSize, scale: CGFloat, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

struct Step {
    let caption: String
    let marked: String
    let panel: NSBitmapImageRep
}

let steps = [
    Step(caption: "① 打拼音：本地候选，和普通拼音输入法一样", marked: "wo jin tian you dian bu shu fu",
         panel: load("1b-sentence-pinyin.png")),
    Step(caption: "② 整句确认后再按空格：英文 + 中文改写", marked: "我今天有点不舒服",
         panel: load("4-final-light.png")),
]

// Renders are 2x bitmaps; lay out in points.
let scale: CGFloat = 2
let margin: CGFloat = 28, gap: CGFloat = 36, captionHeight: CGFloat = 30, fieldHeight: CGFloat = 40
let panelSizes = steps.map { NSSize(width: CGFloat($0.panel.pixelsWide) / scale, height: CGFloat($0.panel.pixelsHigh) / scale) }
let width = margin * 2 + panelSizes.map(\.width).reduce(0, +) + gap * CGFloat(steps.count - 1)
let height = margin * 2 + captionHeight + fieldHeight + 6 + (panelSizes.map(\.height).max() ?? 0)

let demo = png(NSSize(width: width, height: height), scale: scale) {
    NSColor(calibratedWhite: 0.955, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    var x = margin
    for (step, size) in zip(steps, panelSizes) {
        let top = height - margin
        NSAttributedString(string: step.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ]).draw(at: NSPoint(x: x, y: top - 20))
        // A text line with the input method's inline (underlined) text.
        let field = NSRect(x: x, y: top - captionHeight - fieldHeight, width: size.width, height: fieldHeight)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: field, xRadius: 8, yRadius: 8).fill()
        NSColor(white: 0.82, alpha: 1).setStroke()
        NSBezierPath(roundedRect: field.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        NSAttributedString(string: step.marked, attributes: [
            .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.black,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]).draw(at: NSPoint(x: field.minX + 12, y: field.minY + 9))
        NSColor.controlAccentColor.setFill()
        NSRect(x: field.minX + 12 + (step.marked as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 17)]).width + 2,
               y: field.minY + 9, width: 2, height: 21).fill()
        // The candidate panel just below the line, as on screen.
        step.panel.draw(in: NSRect(x: x, y: field.minY - 6 - size.height, width: size.width, height: size.height))
        x += size.width + gap
    }
}
try demo.write(to: output.appendingPathComponent("demo.png"))
for (from, to) in [("4-final-dark.png", "panel-dark.png"), ("6-settings.png", "settings.png")] {
    try? FileManager.default.removeItem(at: output.appendingPathComponent(to))
    try FileManager.default.copyItem(at: source.appendingPathComponent(from), to: output.appendingPathComponent(to))
}
print("wrote \(output.path)/demo.png, panel-dark.png, settings.png")
