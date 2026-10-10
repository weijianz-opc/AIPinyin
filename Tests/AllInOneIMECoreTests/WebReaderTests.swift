import Foundation
import PDFKit
import Testing
@testable import AllInOneIMECore

struct WebReaderTests {
    let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>Ignored &amp; title</title>
        <meta property="og:title" content="量子计算入门">
        <script>var tracking = "do not read";</script><style>p { color: red }</style></head>
        <body><nav>首页 | 新闻 | 登录</nav><header>Site header</header>
        <article><h1>量子计算入门</h1><p>量子计算利用&nbsp;量子比特。</p>
        <p>它和经典计算&mdash;不同&#xFF1A;可以同时&#22788;理多种状态 &lt;叠加&gt;。</p>
        <ul><li>叠加</li><li>纠缠</li></ul><!-- a comment --></article>
        <footer>© 2026 Example</footer></body></html>
        """

    @Test func extractsTheMainText() throws {
        let text = try WebReader.extract(Data(page.utf8), contentType: "text/html; charset=utf-8",
                                         url: URL(string: "https://example.com/q")!)
        #expect(text.hasPrefix("量子计算入门\nhttps://example.com/q\n\n"))
        #expect(text.contains("量子计算利用 量子比特。"))
        #expect(text.contains("它和经典计算—不同：可以同时处理多种状态 <叠加>。"))
        #expect(text.contains("• 叠加") && text.contains("• 纠缠"))
        for left in ["do not read", "color: red", "首页", "Site header", "© 2026", "a comment", "<p>"] {
            #expect(!text.contains(left), "\(left)")
        }
        // Without <article>/<main>: the body without navigation, header and footer.
        let plain = "<html><body><nav>Menu</nav><p>Hello</p><p>World</p><footer>Foot</footer></body></html>"
        let (_, body) = WebReader.html(plain)
        #expect(WebReader.tidy(body) == "Hello\nWorld")
        // A page drawn by JavaScript: a title and nothing to read.
        #expect(throws: WebReader.ReadError.empty) {
            try WebReader.extract(Data("<html><head><title>App</title></head><body><div id=root></div><script>render()</script></body></html>".utf8),
                                  contentType: "text/html", url: URL(string: "https://app.test/")!)
        }
    }

    @Test func chineseEncodingsAndOtherContent() throws {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let gbk = try #require("<html><head><meta charset=\"gb2312\"><title>新闻</title></head><body><p>今天天气很好</p></body></html>"
            .data(using: String.Encoding(rawValue: gb)))
        let text = try WebReader.extract(gbk, contentType: "text/html", url: URL(string: "https://news.example.cn/")!)
        #expect(text.contains("新闻") && text.contains("今天天气很好"))
        // Plain text as it is; images and the like aren't read.
        #expect(try WebReader.extract(Data("just text".utf8), contentType: "text/plain", url: URL(string: "https://a.test/x.txt")!)
            == "https://a.test/x.txt\n\njust text")
        #expect(throws: WebReader.ReadError.unsupported("image/png")) {
            try WebReader.extract(Data([0x89, 0x50]), contentType: "image/png", url: URL(string: "https://a.test/i.png")!)
        }
    }

    @Test func pdfText() throws {
        // A one-page PDF with a line of text, made here.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello PDF reader"))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let text = try WebReader.extract(data as Data, contentType: "application/pdf", url: URL(string: "https://a.test/doc.pdf")!)
        #expect(text.contains("Hello PDF reader"))
    }

    @Test func longPagesAreCut() throws {
        let long = "<p>" + String(repeating: "字", count: WebReader.maxChars + 500) + "</p>"
        let text = try WebReader.extract(Data(long.utf8), contentType: "text/html", url: URL(string: "https://a.test/")!)
        let body = text.components(separatedBy: "\n\n").last ?? ""
        #expect(body.count == WebReader.maxChars + 1 && body.hasSuffix("…"))
    }

    @Test func addresses() {
        #expect(WebReader.url(from: "example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(WebReader.url(from: "http://example.com")?.scheme == "http")
        #expect(WebReader.url(from: "file:///etc/passwd") == nil)
        #expect(WebReader.url(from: "javascript:alert(1)") == nil)
        #expect(WebReader.url(from: "hello") == nil)
        // Inside a text, the address is the argument; the punctuation after it isn't.
        let plan = CommandPlan.make("总结一下 @read https://example.com/a?b=1, 用一句话", commands: Command.builtins)
        #expect(plan.inner.map(\.argument) == ["https://example.com/a?b=1"] && plan.inner.first?.command == .read)
    }

    @Test func readsThroughTheNetwork() async throws {
        StubURLProtocol.register(host: "read.test", .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
                                                          chunks: [Data(page.utf8)]))
        let text = try await WebReader.read("read.test/article", session: StubURLProtocol.session())
        #expect(text.hasPrefix("量子计算入门\nhttps://read.test/article"))
        #expect(StubURLProtocol.lastRequest(host: "read.test")?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Mozilla/5.0") == true)
        StubURLProtocol.register(host: "missing.test", .init(status: 404, headers: [:], chunks: [Data("nope".utf8)]))
        await #expect(throws: WebReader.ReadError.http(404)) {
            _ = try await WebReader.read("https://missing.test/", session: StubURLProtocol.session())
        }
        StubURLProtocol.register(host: "huge.test", .init(status: 200, headers: ["Content-Type": "text/html"],
                                                          chunks: Array(repeating: Data(count: 1 << 20), count: 3)))
        await #expect(throws: WebReader.ReadError.tooLarge) {
            _ = try await WebReader.read("https://huge.test/", session: StubURLProtocol.session())
        }
    }
}
