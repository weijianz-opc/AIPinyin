// Builds the README images from the panels rendered by `AllInOneIME --selftest`:
//   swift Scripts/make-readme-images.swift /tmp/allinoneime-selftest docs          Chinese interface and captions
//   swift Scripts/make-readme-images.swift /tmp/allinoneime-selftest docs/en en    English (the `-en` renders)
// demo.png      pinyin → translation, side by side, each under a text line with the inline (marked) text
// english.png   English typed directly → English polish (with jargon, 黑话); Chinese as the output language
// voice.png     dictation (hold right ⌥) after a command
// commands.png  the @ command palette → @question's answer
// open.png      @open: Spotlight as you type, and a path listing a folder (only macOS's own apps)
// panel-dark.png, settings.png   copies of the renders
import AppKit

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/allinoneime-selftest")
let output = URL(fileURLWithPath: args.count > 2 ? args[2] : "docs")
/// The interface the renders show and the captions' language: zh (the default) or en.
let language = args.count > 3 ? args[3] : "zh"
guard ["zh", "en"].contains(language) else {
    FileHandle.standardError.write(Data("unknown language '\(language)': zh or en\n".utf8))
    exit(2)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// A caption in the images' language.
func tr(_ chinese: String, _ english: String) -> String { language == "en" ? english : chinese }

/// A render of the self-test; with the English interface it is `<name>-en.png`.
func render(_ name: String) -> URL {
    source.appendingPathComponent(name + (language == "en" ? "-en" : "") + ".png")
}

func load(_ name: String) -> NSBitmapImageRep {
    let url = render(name)
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
            // Source-over: drawn as is (copy), the panel's rounded corners would punch holes in the image.
            step.panel.draw(in: NSRect(x: x, y: field.minY - 6 - size.height, width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += widths[index] + gap
        }
    }
    try image.write(to: output.appendingPathComponent(name))
}

try composite([
    Step(caption: tr("① 开头打 @improve，再打拼音", "① Type @improve, then pinyin"),
         marked: "improve › wo jin tian you dian bu shu fu", panel: load("1b-sentence-pinyin")),
    Step(caption: tr("② 按 ⏎：英文 + 中文改写", "② Press ⏎: English + Chinese rewrites"),
         marked: "improve › 我今天有点不舒服", panel: load("4-final-light")),
], to: "demo.png")

try composite([
    Step(caption: tr("@improve 加英文：英文润色（含黑话）", "@improve with English: English polish (incl. Jargon)"),
         marked: "improve › this is a blocker bug your team need fix it asap", panel: load("7-english-light")),
    Step(caption: tr("输出设成中文：中文润色 + 改写", "Output set to Chinese: Chinese polish + rewrites"),
         marked: "improve › 这个项目的进度太慢了", panel: load("7b-chinese-output")),
], to: "english.png")

try composite([
    Step(caption: tr("先打 @improve，再按住右 ⌥ 说话", "Type @improve, then hold right ⌥ to talk"),
         marked: "improve › 我今天有", panel: load("8-voice")),
], to: "voice.png")

try composite([
    Step(caption: tr("① 开头打 @：命令列表，打字母筛选", "① Type @ first: the command list; letters filter it"),
         marked: "@", panel: load("10-palette")),
    Step(caption: tr("② @question 加问题，按 ⏎：回答", "② @question and a question, press ⏎: the answer"),
         marked: "question › 什么是量子计算", panel: load("11-question")),
], to: "commands.png")

try composite([
    Step(caption: tr("① @open 加名字：边打边找", "① @open and a name: results as you type"),
         marked: "open › calculator", panel: load("12-open")),
    Step(caption: tr("② 以 / 开头是路径：列出文件夹，Tab 补全", "② A path (starts with /): lists the folder, Tab completes"),
         marked: "open › /System/Applications/", panel: load("12b-open-path")),
], to: "open.png")

for (from, to) in [("4-final-dark", "panel-dark.png"), ("6-settings", "settings.png")] {
    try? FileManager.default.removeItem(at: output.appendingPathComponent(to))
    try FileManager.default.copyItem(at: render(from), to: output.appendingPathComponent(to))
}
print("wrote \(output.path)/demo.png, english.png, voice.png, commands.png, open.png, panel-dark.png, settings.png")
