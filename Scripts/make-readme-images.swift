// Builds the README images from the panels rendered by `AllInOneIME --selftest`:
//   swift Scripts/make-readme-images.swift /tmp/allinoneime-selftest docs
// docs/demo.png      pinyin → translation, side by side, each under a text line with the inline (marked) text
// docs/english.png   English typed directly → English polish (with 黑话); Chinese as the output language
// docs/voice.png     dictation (hold right ⌥)
// docs/panel-dark.png, docs/settings.png   copies of the renders
import AppKit

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/allinoneime-selftest")
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

/// Steps side by side: caption, a text line with the input method's inline (underlined) text, and
/// the candidate panel just below the line, as on screen.
func composite(_ steps: [Step], to name: String) throws {
    // Renders are 2x bitmaps; lay out in points.
    let scale: CGFloat = 2
    let margin: CGFloat = 28, gap: CGFloat = 36, captionHeight: CGFloat = 30, fieldHeight: CGFloat = 40
    let captionFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let fieldFont = NSFont.systemFont(ofSize: 17)
    let panelSizes = steps.map { NSSize(width: CGFloat($0.panel.pixelsWide) / scale, height: CGFloat($0.panel.pixelsHigh) / scale) }
    // A step is as wide as its panel, or its caption / text line if those are wider.
    let widths = zip(steps, panelSizes).map { step, size in
        max(size.width,
            (step.caption as NSString).size(withAttributes: [.font: captionFont]).width,
            (step.marked as NSString).size(withAttributes: [.font: fieldFont]).width + 30)
    }
    let width = margin * 2 + widths.reduce(0, +) + gap * CGFloat(steps.count - 1)
    let height = margin * 2 + captionHeight + fieldHeight + 6 + (panelSizes.map(\.height).max() ?? 0)

    let image = png(NSSize(width: width, height: height), scale: scale) {
        NSColor(calibratedWhite: 0.955, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x = margin
        for (index, step) in steps.enumerated() {
            let size = panelSizes[index]
            let top = height - margin
            NSAttributedString(string: step.caption, attributes: [
                .font: captionFont, .foregroundColor: NSColor(white: 0.15, alpha: 1),
            ]).draw(at: NSPoint(x: x, y: top - 20))
            let field = NSRect(x: x, y: top - captionHeight - fieldHeight, width: widths[index], height: fieldHeight)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: field, xRadius: 8, yRadius: 8).fill()
            NSColor(white: 0.82, alpha: 1).setStroke()
            NSBezierPath(roundedRect: field.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
            NSAttributedString(string: step.marked, attributes: [
                .font: fieldFont, .foregroundColor: NSColor.black,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]).draw(at: NSPoint(x: field.minX + 12, y: field.minY + 9))
            NSColor.controlAccentColor.setFill()
            NSRect(x: field.minX + 12 + (step.marked as NSString).size(withAttributes: [.font: fieldFont]).width + 2,
                   y: field.minY + 9, width: 2, height: 21).fill()
            step.panel.draw(in: NSRect(x: x, y: field.minY - 6 - size.height, width: size.width, height: size.height))
            x += widths[index] + gap
        }
    }
    try image.write(to: output.appendingPathComponent(name))
}

try composite([
    Step(caption: "① 开头打 @improve，再打拼音", marked: "@improve wo jin tian you dian bu shu fu",
         panel: load("1b-sentence-pinyin.png")),
    Step(caption: "② 按 ⏎：英文 + 中文改写", marked: "@improve 我今天有点不舒服",
         panel: load("4-final-light.png")),
], to: "demo.png")

try composite([
    Step(caption: "@improve 加英文：英文润色（含黑话）", marked: "@improve this is a blocker bug your team need fix it asap",
         panel: load("7-english-light.png")),
    Step(caption: "输出设成中文：中文润色 + 改写", marked: "@improve 这个项目的进度太慢了",
         panel: load("7b-chinese-output.png")),
], to: "english.png")

try composite([
    Step(caption: "按住右 ⌥ 说话，松开后进草稿", marked: "我今天有", panel: load("8-voice.png")),
], to: "voice.png")

for (from, to) in [("4-final-dark.png", "panel-dark.png"), ("6-settings.png", "settings.png")] {
    try? FileManager.default.removeItem(at: output.appendingPathComponent(to))
    try FileManager.default.copyItem(at: source.appendingPathComponent(from), to: output.appendingPathComponent(to))
}
print("wrote \(output.path)/demo.png, english.png, voice.png, panel-dark.png, settings.png")
