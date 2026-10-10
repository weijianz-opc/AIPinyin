import Foundation
import Testing
@testable import AllInOneIMECore

struct LinkTests {
    static let x = "https://x.com/intent/post?text={input}"

    func linkPlugin(_ name: String = "x", url: String = x) -> InstalledPlugin {
        InstalledPlugin(manifest: PluginManifest(name: name, version: "1.0.0", minAppVersion: "0.5.0", type: .link, url: url),
                        directory: URL(fileURLWithPath: "/tmp/\(name)"), isLocal: true)
    }

    // MARK: Template

    @Test func templatesAreChecked() {
        #expect(LinkTemplate.problem(Self.x) == nil)
        #expect(LinkTemplate.problem("https://example.com/#compose={input}") == nil)  // in the fragment
        #expect(LinkTemplate.problem(nil) == .empty && LinkTemplate.problem("  ") == .empty)
        #expect(LinkTemplate.problem("http://x.com/post?text={input}") == .notHTTPS)
        #expect(LinkTemplate.problem("javascript:alert('{input}')") == .notHTTPS)
        #expect(LinkTemplate.problem("https://x.com/post?text=") == .placeholderCount)
        #expect(LinkTemplate.problem("https://x.com/post?a={input}&b={input}") == .placeholderCount)
        // The text never picks the host or the path.
        #expect(LinkTemplate.problem("https://{input}.example.com/?q=1") == .placeholderNotInQuery)
        #expect(LinkTemplate.problem("https://example.com/{input}") == .placeholderNotInQuery)
        #expect(LinkTemplate.problem("https:///?q={input}") == .invalid)
        #expect(LinkTemplate.problem("https://exa mple.com/?q={input}") == .invalid)
        #expect(LinkTemplate.host(Self.x) == "x.com" && LinkTemplate.host("https://{input}.com/?") == nil)
    }

    @Test func theTextIsEncodedAsAQueryValue() {
        #expect(LinkTemplate.encode("abc-XYZ_0.9~") == "abc-XYZ_0.9~")
        #expect(LinkTemplate.encode("今天 天气") == "%E4%BB%8A%E5%A4%A9%20%E5%A4%A9%E6%B0%94")
        #expect(LinkTemplate.encode("🎉") == "%F0%9F%8E%89")
        // Nothing can end the value or change its meaning; a space is %20, a newline %0A.
        #expect(LinkTemplate.encode("a&b=c#d+e f/g?h%") == "a%26b%3Dc%23d%2Be%20f%2Fg%3Fh%25")
        #expect(LinkTemplate.encode("line 1\nline 2") == "line%201%0Aline%202")
        let url = LinkTemplate.url(Self.x, input: "买了 AAPL & TSLA #美股 1+1")
        #expect(url?.absoluteString == "https://x.com/intent/post?text=%E4%B9%B0%E4%BA%86%20AAPL%20%26%20TSLA%20%23%E7%BE%8E%E8%82%A1%201%2B1")
        #expect(url?.host == "x.com")
        // What the site reads back is the text as typed.
        let value = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        #expect(value == "买了 AAPL & TSLA #美股 1+1")
        // Empty text opens the page with an empty value (the composer opens empty).
        #expect(LinkTemplate.url(Self.x, input: "")?.absoluteString == "https://x.com/intent/post?text=")
        #expect(LinkTemplate.url("http://x.com/?t={input}", input: "a") == nil)
    }

    // MARK: Manifests

    @Test func linkManifests() throws {
        let json = #"""
        { "name": "x", "version": "1.0.0", "api": 1, "minAppVersion": "0.5.0", "type": "link",
          "url": "https://x.com/intent/post?text={input}",
          "summary": {"en": "Post to X: opens the composer with your text", "zh": "发到 X：打开发帖框，文字已填好"},
          "author": "weijianz-opc", "icon": "bird", "color": "#000000" }
        """#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.type == .link && manifest.url == Self.x && manifest.script == nil && manifest.hosts.isEmpty)
        #expect(manifest.problem(appVersion: "0.5.0") == nil)
        #expect(manifest.problem(appVersion: "0.4.0") == "needs AllInOneIME 0.5.0 or later")
        #expect(manifest.destinationHosts == ["x.com"] && !manifest.typesLatin)
        var bad = manifest
        bad.url = nil
        #expect(bad.problem(appVersion: "1.0") == "no url")
        bad.url = "http://x.com/?text={input}"
        #expect(bad.problem(appVersion: "1.0") == "the url must start with https://")
        bad.url = "https://{input}/"
        #expect(bad.problem(appVersion: "1.0")?.contains("query") == true)
    }

    /// The plugins shipped in Plugins/ (published by the library, not installed with the app).
    @Test func shippedPluginsAreValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Plugins")
        let expected = [
            "bsky": "https://bsky.app/intent/compose?text={input}",
            "threads": "https://www.threads.net/intent/post?text={input}",
            "weibo": "https://service.weibo.com/share/share.php?title={input}",
            "x": "https://x.com/intent/post?text={input}",
        ]
        let (plugins, skipped) = PluginStore.load(from: root, appVersion: "0.5.0")
        #expect(skipped.isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: plugins.map { ($0.name, $0.manifest.url ?? "") }) == expected)
        for plugin in plugins {
            #expect(plugin.manifest.type == .link && plugin.manifest.icon != nil && plugin.manifest.color != nil)
            #expect(plugin.manifest.summary?.zh != nil && plugin.manifest.author != nil)
        }
    }

    // MARK: Commands

    @Test func linkCommandsInTheCatalog() {
        let google = CustomCommand(name: "google", type: .link, url: "https://www.google.com/search?q={input}")
        let catalog = Command.catalog([google, CustomCommand(name: "bad", type: .link, url: "https://google.com/{input}")],
                                      plugins: [linkPlugin()])
        let names = catalog.map(\.name)
        #expect(names.suffix(2) == ["x", "google"] && !names.contains("bad"))
        #expect(catalog.suffix(2).map(\.kind) == [.link, .link])
        #expect(catalog.suffix(2).map(\.linkTemplate) == [Self.x, "https://www.google.com/search?q={input}"])
        #expect(catalog.suffix(2).allSatisfy { $0.program == nil && !$0.typesLatin })
        // Not a command that runs inside a text.
        #expect(!catalog.suffix(2).contains(where: CommandPlan.canBeInner))
        #expect(Command.improve.linkTemplate == nil)
    }

    @Test func customLinkCommandsAreChecked() throws {
        var c = CustomCommand(name: "google", type: .link)
        #expect(c.problem(among: []) == .link(.empty) && !c.isValid)
        c.url = "http://www.google.com/search?q={input}"
        #expect(c.problem(among: []) == .link(.notHTTPS))
        c.url = "https://www.google.com/search?q={input}"
        #expect(c.problem(among: []) == nil && c.isValid && !c.typesLatin)
        #expect(c.problem(among: [], plugins: ["google"]) == .nameTaken)
        // Saved in the config like the other types.
        let saved = try JSONDecoder().decode(CustomCommand.self, from: JSONEncoder().encode(c))
        #expect(saved == c)
        let typed = try JSONDecoder().decode(CustomCommand.self, from: Data(#"{"name":"g","type":"link","url":"https://g.co/?q={input}"}"#.utf8))
        #expect(typed.type == .link && typed.isValid)
    }

    // MARK: Composer

    let space = KeyEvent(keyCode: VirtualKey.space, characters: " ")
    let at = KeyEvent(keyCode: 0x13, characters: "@", charactersIgnoringModifiers: "@", modifiers: .shift)

    func composer(_ commands: [Command]) -> Composer {
        let c = Composer(engine: FakeEngine())
        c.setInputMode(.english)
        c.commands = commands
        return c
    }

    func type(_ text: String, _ c: Composer) {
        for ch in text { _ = c.handleKeyDown(ch == "@" ? at : ch == " " ? space : k(String(ch))) }
    }

    @Test func aLinkCommandOpensTheBrowserAndInsertsNothing() {
        let catalog = Command.catalog([], plugins: [linkPlugin()])
        let c = composer(catalog)
        type("@x 今天 & 明天", c)
        #expect(c.draftCommand?.kind == .link)
        let effects = c.handleKeyDown(enterKey).effects
        let url = URL(string: "https://x.com/intent/post?text=%E4%BB%8A%E5%A4%A9%20%26%20%E6%98%8E%E5%A4%A9")!
        #expect(effects.contains(.openLink(url)) && effects.contains(.commandUsed("x")))
        #expect(commits(effects).isEmpty && c.draft.isEmpty && !c.isLevelTwo && c.phase == .idle)
    }

    @Test func aLinkCommandWithNothingAfterItTakesTheClipboard() {
        let c = composer(Command.catalog([], plugins: [linkPlugin()]))
        type("@x ", c)
        // Like any command: the clipboard's text, or else a hint; nothing opens empty.
        #expect(c.handleKeyDown(enterKey).effects == [.readClipboard(id: 1)])
        #expect(c.pasted(nil, id: 1) == [.notice("在命令后面写上内容")] && c.draft == "@x ")
    }

    @Test func secureInputAndLongTextsAreRefused() {
        let c = composer(Command.catalog([], plugins: [linkPlugin()]))
        type("@x 密码", c)
        c.secureInputActive = { true }
        let refused = c.handleKeyDown(enterKey).effects
        #expect(refused == [.updateMarkedText, .notice("系统安全输入已开启（密码框或锁屏），没有运行命令")])
        #expect(c.draft == "@x 密码")
        c.secureInputActive = { false }
        #expect(c.handleKeyDown(enterKey).effects.contains { if case .openLink = $0 { return true } else { return false } })

        let long = composer(Command.catalog([], plugins: [linkPlugin()]))
        long.messages = .english
        type("@x " + String(repeating: "a", count: LinkTemplate.maxInputLength + 1), long)
        #expect(long.handleKeyDown(enterKey).effects == [.updateMarkedText, .notice("Too long for a link: 4000 characters at most")])
        #expect(long.draft.count == LinkTemplate.maxInputLength + 4)  // kept, to shorten
        #expect(Composer.Messages.chinese.linkTooLong == "文字太长，放不进链接：最多 4000 字")
    }

    @Test func commandsInsideALinksTextRunFirst() async throws {
        let stock = CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"])
        let catalog = Command.catalog([stock], plugins: [linkPlugin()])
        let c = composer(catalog)
        type("@x 今天 @stock AAPL 涨了", c)
        let effects = c.handleKeyDown(enterKey).effects
        guard case let .startPlan(outer, plan, id)? = effects.first else {
            Issue.record("expected a plan, got \(effects)")
            return
        }
        #expect(outer?.kind == .link && plan.inner.map(\.argument) == ["AAPL"] && id == 1)
        #expect(effects.contains(.commandUsed("x")) && effects.contains(.commandUsed("stock")))
        // The outer step passes the text on; the composer then opens the link with it.
        let stream = CommandPipeline.run(plan, inner: { _, _ in LinkTemplate.passThrough("AAPL 336.64 USD") },
                                         outer: LinkTemplate.passThrough)
        var final = ""
        for try await update in stream where update.isFinal { final = update.result.versions.first?.text ?? "" }
        #expect(final == "今天 AAPL 336.64 USD 涨了")
        let opened = c.receive(ConversionResult(versions: [CandidateLine(final)]), isFinal: true, id: 1)
        #expect(opened.contains(.openLink(LinkTemplate.url(LinkTests.x, input: final)!)))
        #expect(!opened.contains(.commandUsed("x")))  // counted once, when it started
        #expect(commits(opened).isEmpty && c.phase == .idle && c.draft.isEmpty)

        // Too long once the outputs are in: the request fails, the draft stays to edit.
        let d = composer(catalog)
        type("@x @stock AAPL", d)
        _ = d.handleKeyDown(enterKey)
        _ = d.receive(ConversionResult(versions: [CandidateLine(String(repeating: "a", count: 4001))]), isFinal: true, id: 1)
        #expect(d.phase == .failed(Composer.Messages.chinese.linkTooLong))
    }
}
