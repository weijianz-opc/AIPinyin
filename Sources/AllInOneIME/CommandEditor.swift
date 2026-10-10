import AllInOneIMECore
import SwiftUI

/// A custom @ command being added (`index` nil) or edited in the settings.
struct CommandEdit: Identifiable {
    let id = UUID()
    var index: Int?
    var command: CustomCommand
}

/// The form for one custom @ command: its name, what it does (an instruction for the AI, a program
/// to run, a program in Terminal, or a web page to open) and how. Saving hands the finished definition back.
struct CommandEditor: View {
    let original: CommandEdit
    /// The other custom commands and the installed plugins (their names are taken).
    let others: [CustomCommand]
    let plugins: [String]
    let onSave: (CustomCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var type: CustomCommand.CommandType
    @State private var summary: String
    @State private var prompt: String
    /// `argv` as one line: `python3 -c {input}`.
    @State private var commandLine: String
    /// `run`: the text goes to standard input instead of `{input}`.
    @State private var useStdin: Bool
    @State private var latin: Bool
    @State private var timeout: Double
    /// `link`: the web address, with `{input}`.
    @State private var url: String
    /// The program of the command line isn't on this Mac (looked up in the background).
    @State private var missingProgram: String?

    init(edit: CommandEdit, others: [CustomCommand], plugins: [String] = [], onSave: @escaping (CustomCommand) -> Void) {
        original = edit
        self.others = others
        self.plugins = plugins
        self.onSave = onSave
        let c = edit.command
        _name = State(initialValue: c.name)
        _type = State(initialValue: c.type)
        _summary = State(initialValue: c.summary ?? "")
        _prompt = State(initialValue: c.prompt ?? "")
        _commandLine = State(initialValue: CustomCommand.commandLine(c.argv ?? []))
        _useStdin = State(initialValue: c.stdin != nil)
        _latin = State(initialValue: c.typesLatin)
        _timeout = State(initialValue: c.timeout)
        _url = State(initialValue: c.url ?? "")
    }

    /// The definition as the form has it now (nil: the command line has an open quote).
    private var draft: CustomCommand? {
        var c = CustomCommand(name: name.trimmingCharacters(in: .whitespaces).lowercased(), type: type)
        let text = summary.trimmingCharacters(in: .whitespaces)
        c.summary = text.isEmpty ? nil : text
        switch type {
        case .prompt:
            c.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        case .run, .terminal:
            guard let argv = CustomCommand.arguments(fromCommandLine: commandLine) else { return nil }
            c.argv = argv
            if type == .run {
                if useStdin { c.stdin = CustomCommand.placeholder + "\n" }
                if timeout != CustomCommand.defaultTimeout { c.timeoutSeconds = timeout }
            }
        case .link:
            c.url = url.trimmingCharacters(in: .whitespaces)
        }
        // Stored only when it differs from the type's default (Latin for programs, as typed for the AI and pages).
        if latin != CustomCommand.typesLatinByDefault(type) { c.ascii = latin }
        return c
    }

    private var problem: String? {
        guard let draft else { return Self.describe(.unbalancedQuote) }
        return draft.problem(among: others, plugins: plugins).map(Self.describe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    HStack {
                        TextField(tr("名字", "Name"), text: $name, prompt: Text(tr("只用英文字母，比如 py", "Letters only, e.g. py")))
                        Menu(tr("从例子开始", "Start from an Example")) {
                            ForEach(Self.examples, id: \.name) { example in
                                Button("@\(example.name)  " + (example.summary ?? "")) { load(example) }
                            }
                        }
                        .fixedSize()
                    }
                    Picker(tr("做什么", "What it does"), selection: $type) {
                        Text(tr("AI 指令", "AI instruction")).tag(CustomCommand.CommandType.prompt)
                        Text(tr("运行程序", "Run a program")).tag(CustomCommand.CommandType.run)
                        Text(tr("在终端运行", "Run in Terminal")).tag(CustomCommand.CommandType.terminal)
                        Text(tr("打开网页", "Open a web page")).tag(CustomCommand.CommandType.link)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: type) { latin = CustomCommand.typesLatinByDefault(type) }
                    TextField(tr("说明", "Description"), text: $summary,
                              prompt: Text(tr("命令列表里显示，可以不填", "Shown in the command list (optional)")))
                }

                Section {
                    switch type {
                    case .prompt:
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 90)
                        Text(tr("告诉 AI 怎么处理命令后面写的内容，比如「把用户的话写成一条礼貌简短的回复」。回答出现在候选里，⏎ 上屏。",
                                "Tell the AI what to do with the text after the command, e.g. \"Write a short, polite reply to the user's message.\" The answer appears in the candidates; ⏎ inserts it."))
                            .font(.caption).foregroundStyle(.secondary)
                    case .link:
                        TextField(tr("网址", "Address"), text: $url, prompt: Text("https://www.google.com/search?q={input}"))
                            .font(.body.monospaced())
                        Text(tr("{input} 换成命令后面写的内容（自动编码），放在 ? 后面。按执行键在浏览器打开，不上屏。只能用 https://。",
                                "{input} becomes the text after the command (encoded), after the ?. The action key opens it in the browser; nothing is inserted. https:// only."))
                            .font(.caption).foregroundStyle(.secondary)
                    case .run, .terminal:
                        TextField(tr("命令", "Command"), text: $commandLine, prompt: Text("python3 -c {input}"))
                            .font(.body.monospaced())
                        Text(tr("{input} 换成命令后面写的内容，始终是一个参数，不经过 shell（要 shell 就写 zsh -c {input}）。参数里有空格时用引号。",
                                "{input} becomes the text after the command, always as one argument, never through a shell (for one, write zsh -c {input}). Quote arguments with spaces."))
                            .font(.caption).foregroundStyle(.secondary)
                        if type == .run {
                            Toggle(tr("把内容作为标准输入（命令里不用写 {input}）", "Send the text to standard input (no {input} needed)"),
                                   isOn: $useStdin)
                            Stepper(value: $timeout, in: 1...120, step: 1) {
                                Text(tr("最多运行 \(Int(timeout)) 秒", "Stop after \(Int(timeout)) s"))
                            }
                        }
                        if let missingProgram {
                            Label(tr("这台 Mac 上找不到 \(missingProgram)：装好之前，这个命令不会出现在列表里。",
                                     "\(missingProgram) isn't on this Mac: until it is, the command won't show up in the list."),
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Toggle(tr("用英文字母输入（写代码、路径时）", "Type English letters (for code and paths)"), isOn: $latin)
                }
                if type == .run || type == .terminal {
                    Text(tr("「运行程序」和「在终端运行」会在你的 Mac 上执行命令：只加你自己写的、信得过的。它们只在你按执行键时运行，密码框里不运行。",
                            "Programs run on your Mac: add only commands you wrote and trust. They run only when you press the action key, never in password fields."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("保存", "Save")) {
                    guard let draft else { return }
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
        .task(id: commandLine) { await checkProgram() }
        .task(id: type) { await checkProgram() }
    }

    private func load(_ example: CustomCommand) {
        var taken = Set(others.map { $0.name.lowercased() })
        taken.formUnion(Command.builtins.map(\.name))
        taken.formUnion(plugins)
        name = taken.contains(example.name) ? "" : example.name
        type = example.type
        summary = example.summary ?? ""
        prompt = example.prompt ?? ""
        commandLine = CustomCommand.commandLine(example.argv ?? [])
        useStdin = example.stdin != nil
        latin = example.typesLatin
        timeout = example.timeout
        url = example.url ?? ""
    }

    /// Looks the command line's program up in the user's shell PATH (the first time, the shell is asked).
    private func checkProgram() async {
        guard type == .run || type == .terminal, let program = CustomCommand.arguments(fromCommandLine: commandLine)?.first, !program.isEmpty else {
            missingProgram = nil
            return
        }
        let found = await Task.detached { CommandRunner.resolve(program, path: ShellEnvironment.current["PATH"]) != nil }.value
        missingProgram = found ? nil : program
    }

    static func describe(_ problem: CustomCommand.Problem) -> String {
        switch problem {
        case .emptyName: return tr("给命令起个名字", "Give the command a name")
        case .nameNotLetters: return tr("名字只能用英文字母（最多 24 个）", "Names are letters only (24 at most)")
        case .nameTaken: return tr("这个名字已经有命令在用了", "Another command has this name")
        case .emptyPrompt: return tr("写上给 AI 的指令", "Write the instruction for the AI")
        case .emptyCommand: return tr("写上要运行的命令", "Write the command to run")
        case .unbalancedQuote: return tr("命令里有引号没有配对", "A quote in the command isn't closed")
        case .link(.empty): return tr("写上要打开的网址", "Write the address to open")
        case .link(.notHTTPS): return tr("网址要以 https:// 开头", "The address must start with https://")
        case .link(.placeholderCount): return tr("网址里要有一个 {input}", "Put {input} in the address once")
        case .link(.placeholderNotInQuery): return tr("{input} 要放在 ? 后面", "Put {input} after the ? in the address")
        case .link(.invalid): return tr("网址格式不对", "The address isn't valid")
        }
    }

    /// The menu's starting points.
    static var examples: [CustomCommand] {
        [
            CustomCommand(name: "reply", type: .prompt, summary: tr("写一条回复", "Write a reply"),
                          prompt: "Write a short, polite reply to the user's message, in the language of the message."),
            CustomCommand(name: "ja", type: .prompt, summary: tr("翻译成日语", "Translate to Japanese"),
                          prompt: "Translate the user's text into natural Japanese. Reply with the translation only."),
            CustomCommand(name: "py", type: .run, summary: tr("运行 Python", "Run Python"), argv: ["python3", "-c", CustomCommand.placeholder]),
            CustomCommand(name: "bc", type: .run, summary: tr("用 bc 计算", "Calculate with bc"), argv: ["bc", "-l"],
                          stdin: CustomCommand.placeholder + "\n"),
            CustomCommand(name: "google", type: .link, summary: tr("用 Google 搜索", "Search with Google"),
                          url: "https://www.google.com/search?q=" + CustomCommand.placeholder),
            CustomCommand(name: "sh", type: .terminal, summary: tr("在终端运行", "Run in Terminal"),
                          argv: ["zsh", "-c", CustomCommand.placeholder + "; exec zsh"]),
        ]
    }
}
