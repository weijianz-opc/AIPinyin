import AllInOneIMECore
import AppKit

/// The icons of the command list, like the colored squares of iOS Settings: one for each built-in
/// command, one for each kind of custom command, a plugin's own (or a puzzle piece). A custom command
/// or a plugin may name its own SF Symbol and color.
enum CommandIcons {
    static func icon(for command: Command) -> CandidateView.Icon {
        if let plugin = command.plugin {
            return CandidateView.Icon(symbol: plugin.manifest.icon ?? "puzzlepiece.extension.fill",
                                      color: color(plugin.manifest.color) ?? .systemPink)
        }
        if let custom = command.custom {
            let (symbol, fallback): (String, NSColor)
            switch custom.type {
            case .prompt: (symbol, fallback) = ("text.bubble.fill", .systemIndigo)
            case .run: (symbol, fallback) = ("chevron.left.forwardslash.chevron.right", .systemBrown)
            case .terminal: (symbol, fallback) = ("apple.terminal.fill", NSColor(white: 0.25, alpha: 1))
            }
            return CandidateView.Icon(symbol: custom.icon ?? symbol, color: color(custom.color) ?? fallback)
        }
        switch command {
        case .improve: return CandidateView.Icon(symbol: "wand.and.stars", color: .systemPurple)
        case .question: return CandidateView.Icon(symbol: "questionmark.bubble.fill", color: .systemBlue)
        case .claude: return CandidateView.Icon(symbol: "sparkles", color: .systemOrange)
        case .open: return CandidateView.Icon(symbol: "magnifyingglass", color: .systemGray)
        case .read: return CandidateView.Icon(symbol: "doc.richtext.fill", color: .systemTeal)
        case .tasks: return CandidateView.Icon(symbol: "checklist", color: .systemGreen)
        default: return CandidateView.Icon(symbol: "command", color: .systemGray)
        }
    }

    /// A background task's state in `@tasks`.
    static func icon(for progress: AgentSession.Progress) -> CandidateView.Icon {
        switch progress {
        case .done: return CandidateView.Icon(symbol: "checkmark", color: .systemGreen)
        case .working: return CandidateView.Icon(symbol: "hourglass", color: .systemOrange)
        case .needsYou: return CandidateView.Icon(symbol: "exclamationmark", color: .systemYellow)
        }
    }

    /// "blue", "systemBlue" or "#34C759"; nil for anything else.
    static func color(_ name: String?) -> NSColor? {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        if name.hasPrefix("#"), name.count == 7, let value = Int(name.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        let named: [String: NSColor] = [
            "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen,
            "mint": .systemMint, "teal": .systemTeal, "cyan": .systemCyan, "blue": .systemBlue,
            "indigo": .systemIndigo, "purple": .systemPurple, "pink": .systemPink, "brown": .systemBrown,
            "gray": .systemGray, "grey": .systemGray, "black": NSColor(white: 0.15, alpha: 1),
        ]
        return named[name.hasPrefix("system") ? String(name.dropFirst(6)) : name]
    }
}
