import Foundation
import Testing
@testable import AllInOneIMECore

struct MessagingTests {
    let contacts = [
        Contact(name: "张三", handles: ["+1 (555) 010-0100", "zhangsan@example.com"]),
        Contact(name: "张思远", handles: ["13800001111"]),
        Contact(name: "John Appleseed", otherNames: ["Johnny"], handles: ["john@apple.com"]),
        Contact(name: "李四", otherNames: ["", "Acme"], handles: ["+86 139 0000 2222"]),
    ]

    func handles(_ query: String, recent: [String] = []) -> [String] {
        RecipientSearch.results(query, contacts: contacts, recent: recent).map(\.handle)
    }

    @Test func findsByNamePinyinAndInitials() {
        #expect(Contact.pinyin(of: "张三") == ("zhangsan", "zs"))
        #expect(Contact.pinyin(of: "John") == ("", ""))
        #expect(handles("张") == ["+1 (555) 010-0100", "zhangsan@example.com", "13800001111"])  // one row per handle
        #expect(handles("zs") == ["+1 (555) 010-0100", "zhangsan@example.com", "13800001111"])  // initials
        #expect(handles("zhangsan") == ["+1 (555) 010-0100", "zhangsan@example.com"])  // full pinyin
        #expect(handles("zhangsi") == ["13800001111"])
        #expect(handles("li") == ["+86 139 0000 2222"])
        #expect(handles("app") == ["john@apple.com"])  // a word of the name
        #expect(handles("JOHNNY") == ["john@apple.com"])  // the nickname, any case
        #expect(handles("acme") == ["+86 139 0000 2222"])  // the company
        #expect(RecipientSearch.results("三", contacts: contacts, recent: []).first == Recipient(name: "张三", handle: "+1 (555) 010-0100"))
        #expect(handles("nobody").isEmpty)
    }

    @Test func findsByDigitsAndEmail() {
        #expect(handles("1555") == ["+1 (555) 010-0100"])  // the digits, whatever the punctuation
        #expect(handles("0000") == ["13800001111", "+86 139 0000 2222"])
        #expect(handles("example") == ["zhangsan@example.com"])
        #expect(handles("john@") == ["john@apple.com"])
        // A whole number or address no contact has is offered as it is, last.
        #expect(RecipientSearch.results("+1 555 999 0000", contacts: contacts, recent: []) == [Recipient(name: "", handle: "+1 555 999 0000")])
        #expect(handles("bob@example.org") == ["bob@example.org"])
        #expect(handles("13800001111") == ["13800001111"])  // a contact's: not twice
        #expect(RecipientSearch.typedHandle("1234") == nil && RecipientSearch.typedHandle("a@b") == nil
                && RecipientSearch.typedHandle("zs") == nil)
    }

    @Test func recentRecipientsComeFirst() {
        #expect(handles("zs", recent: ["13800001111"]) == ["13800001111", "+1 (555) 010-0100", "zhangsan@example.com"])
        // Nothing typed: the recent ones, with the contact's name (another way of writing the number too).
        #expect(RecipientSearch.results("", contacts: contacts, recent: ["13900002222", "+44 20 7946 0000"])
            == [Recipient(name: "李四", handle: "+86 139 0000 2222"), Recipient(name: "", handle: "+44 20 7946 0000")])
        #expect(RecipientSearch.results("", contacts: contacts, recent: []).isEmpty)
        #expect(RecipientSearch.sameHandle("+86 138 0000 1111", "13800001111") && RecipientSearch.sameHandle("A@b.com", "a@B.com"))
        #expect(!RecipientSearch.sameHandle("1111", "21111"))
        let recent = RecipientSearch.remember("+86 13800001111", in: ["a@b.com", "138 0000 1111"] + (1...10).map { "\($0)@x.com" })
        #expect(recent.count == RecipientSearch.recentLimit && recent.prefix(2) == ["+86 13800001111", "a@b.com"])
    }

    @Test func atMostEightRows() {
        let many = (1...20).map { Contact(name: "张\($0)", handles: ["\($0)@x.com"]) }
        #expect(RecipientSearch.results("张", contacts: many, recent: []).count == 8)
    }

    @Test func namesFromTheCard() {
        #expect(Contact.displayName(given: "三", family: "张") == "张三")
        #expect(Contact.displayName(given: "John", family: "Appleseed") == "John Appleseed")
        #expect(Contact.displayName(given: "", family: "", nickname: "", organization: "Acme") == "Acme")
    }

    /// The handle and the text are the script's arguments: nothing typed becomes AppleScript.
    @Test func theScriptTakesArgumentsNotText() throws {
        let text = "\" & (do shell script \"say hi\") & \"\nline 2"
        let handle = "+1 555 0100\" to buddy \"x"
        #expect(MessageScript.osascriptArguments(handle: handle, text: text) == ["-", handle, text])
        let script = MessageScript.iMessage
        #expect(script.hasPrefix("on run argv") && script.contains("item 1 of argv") && script.contains("item 2 of argv"))
        #expect(script.contains("send theText to participant theHandle of theAccount"))
        // A stand-in with the same start (no Messages): osascript hands the arguments back unchanged.
        let lines = script.components(separatedBy: "\n")
        let standIn = lines.prefix(3).joined(separator: "\n") + "\n\treturn theHandle & \"|\" & theText\nend run\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = MessageScript.osascriptArguments(handle: handle, text: text)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(standIn.utf8))
        try input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0 && out.trimmingCharacters(in: .newlines) == handle + "|" + text)
    }

    @Test func sendErrorsKeepOnlyTheNumber() {
        #expect(MessageSendError.from(osascriptError: "execution error: Not authorized to send Apple events to Messages. (-1743)") == .notPermitted)
        #expect(MessageSendError.from(osascriptError: "execution error: Messages got an error: Can’t get participant \"x\". (-1728)")
            == .failed(code: -1728))
        #expect(MessageSendError.from(osascriptError: "") == .failed(code: 0))
    }

    @Test func theTextGoesOnUnchanged() async throws {
        var last: ConversionUpdate?
        for try await update in CommandPipeline.unchanged("你好 Apple 336") { last = update }
        #expect(last?.isFinal == true && last?.result.versions.first?.text == "你好 Apple 336")
    }
}

/// `@imessage`: pick the recipient in the panel, write, ⏎ shows the message to confirm, ⏎ sends.
extension ComposerTests {
    var zhang: Recipient { Recipient(name: "张三", handle: "+1 555 0100") }
    var si: Recipient { Recipient(name: "张思", handle: "zs@example.com") }

    func sends(_ effects: [Composer.Effect]) -> [Composer.Effect] {
        effects.filter { if case .sendMessage = $0 { return true } else { return false } }
    }

    /// "@imessage " picked from the list, "zs" typed, two contacts found.
    func imessage(key: ActionKey = .enter) -> (Composer, FakeEngine) {
        let (c, e) = composer(key: key)
        _ = c.handleKeyDown(at)
        type("ime", c)
        _ = c.handleKeyDown(tab)
        type("zs", c)
        _ = c.receiveRecipients([zhang, si], for: "zs")
        return (c, e)
    }

    @Test func imessagePicksARecipientThenConfirmsBeforeSending() {
        let (c, e) = composer(key: .enter)
        _ = c.handleKeyDown(at)
        type("ime", c)
        _ = c.handleKeyDown(tab)
        // Names, pinyin, numbers: typed as letters, and the recent recipients are asked for at once.
        #expect(c.draft == "@imessage " && e.ascii && c.recipientQuery == "")
        type("zs", c)
        #expect(c.recipientQuery == "zs" && c.draft == "@imessage zs" && c.currentRecipients.isEmpty)
        #expect(c.receiveRecipients([zhang], for: "z").isEmpty)  // stale: the text has changed since
        #expect(c.receiveRecipients([zhang, si], for: "zs") == [.showPanel])
        _ = c.handleKeyDown(downKey)
        #expect(c.recipientHighlight == 1)
        _ = c.handleKeyDown(upKey)
        #expect(c.handleKeyDown(tab).effects == [.updateMarkedText, .showPanel])
        // Picked: shown like a chip, the search text gone, Chinese back for the message.
        #expect(c.messageRecipient == zhang && c.draft == "@imessage " && !e.ascii && c.recipientQuery == nil)
        #expect(c.markedText == "imessage › 张三 › ")
        type("nihao", c)
        _ = c.handleKeyDown(spaceKey)
        #expect(c.markedText == "imessage › 张三 › 你好")
        // ⏎: the message to confirm; nothing sent or inserted.
        let confirm = c.handleKeyDown(enterKey)
        #expect(sends(confirm.effects).isEmpty && commits(confirm).isEmpty && c.phase == .choosing)
        #expect(c.choices == [Composer.Choice(label: "⏎", kind: .send, text: "你好", isComplete: true)] && c.highlighted == 0)
        #expect(c.markedText == "imessage › 张三 › 你好")
        // Space or a digit don't send it.
        #expect(sends(c.handleKeyDown(spaceKey).effects).isEmpty && sends(c.handleKeyDown(k("1")).effects).isEmpty && c.phase == .choosing)
        // Esc: back to writing it, the recipient kept.
        _ = c.handleKeyDown(escKey)
        #expect(c.phase == .drafting && c.draft == "@imessage 你好" && c.messageRecipient == zhang)
        _ = c.handleKeyDown(enterKey)
        let sent = c.handleKeyDown(enterKey)
        #expect(sends(sent.effects) == [.sendMessage(zhang, text: "你好", command: .imessage)])
        #expect(commits(sent).isEmpty && sent.effects.contains(.updateMarkedText) && sent.effects.contains(.commandUsed("imessage")))
        #expect(c.draft.isEmpty && c.phase == .idle && c.messageRecipient == nil && c.markedText.isEmpty)
    }

    @Test func imessageRecipientByDigitClickOrReturn() {
        // A digit after a name picks that row.
        let (d, _) = imessage()
        _ = d.handleKeyDown(k("2"))
        #expect(d.messageRecipient == si && d.draft == "@imessage ")
        // A click.
        let (c, _) = imessage()
        _ = c.choose(index: 1)
        #expect(c.messageRecipient == si)
        // ⏎ picks the highlighted one (it doesn't send).
        let (r, _) = imessage()
        let picked = r.handleKeyDown(enterKey)
        #expect(r.messageRecipient == zhang && sends(picked.effects).isEmpty && r.phase == .drafting)
        // ⌫ right after the recipient: back to picking one.
        _ = r.handleKeyDown(backspaceKey)
        #expect(r.messageRecipient == nil && r.draft == "@imessage " && r.recipientQuery == "")
        // While a number is typed, digits are part of it.
        let (n, _) = composer(key: .enter)
        _ = n.handleKeyDown(at)
        type("ime", n)
        _ = n.handleKeyDown(tab)
        type("555", n)
        _ = n.receiveRecipients([zhang], for: "555")
        _ = n.handleKeyDown(k("1"))
        #expect(n.messageRecipient == nil && n.recipientQuery == "5551")
    }

    @Test func imessageNeedsARecipient() {
        let (c, _) = composer(key: .enter)
        _ = c.handleKeyDown(at)
        type("ime", c)
        _ = c.handleKeyDown(tab)
        type("bob", c)
        let response = c.handleKeyDown(enterKey)  // nothing found (yet)
        #expect(response.effects.contains(.notice(c.messages.pickRecipient)) && sends(response.effects).isEmpty)
        #expect(c.phase == .drafting && c.draft == "@imessage bob")
        // Esc clears it all.
        _ = c.handleKeyDown(escKey)
        #expect(c.draft.isEmpty && c.messageRecipient == nil && c.phase == .idle)
    }

    @Test func imessageRunsCommandsInsideTheMessageFirst() {
        let (c, _) = composer(key: .enter)
        let stock = CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"])
        c.commands = Command.catalog([stock])
        _ = c.handleKeyDown(at)
        type("ime", c)
        _ = c.handleKeyDown(tab)
        type("zs", c)
        _ = c.receiveRecipients([zhang], for: "zs")
        _ = c.handleKeyDown(tab)
        _ = c.handleKeyDown(at)
        type("st", c)
        _ = c.handleKeyDown(tab)
        type("AAPL", c)
        #expect(c.draft == "@imessage @stock AAPL" && c.markedText == "imessage › 张三 › stock › AAPL")
        let run = c.handleKeyDown(enterKey)
        let plan = CommandPlan.make("@stock AAPL", commands: c.commands)
        #expect(run.effects.first == .startPlan(outer: .imessage, plan: plan, id: 1) && sends(run.effects).isEmpty)
        #expect(plan.inner.map(\.argument) == ["AAPL"])
        _ = c.receive(ConversionResult(versions: [CandidateLine("Apple Inc. AAPL 336.64 USD")]), isFinal: true, id: 1)
        #expect(c.phase == .choosing && c.choices.first?.text == "Apple Inc. AAPL 336.64 USD" && c.choices.first?.kind == .send)
        let sent = c.handleKeyDown(enterKey)
        #expect(sends(sent.effects) == [.sendMessage(zhang, text: "Apple Inc. AAPL 336.64 USD", command: .imessage)] && commits(sent).isEmpty)
    }

    @Test func imessageFailedCommandIsNeverInserted() {
        let (c, _) = imessage(key: .optionTap)
        let stock = CustomCommand(name: "stock", type: .run, argv: ["stock", "{input}"])
        c.commands = Command.catalog([stock])
        _ = c.handleKeyDown(tab)
        type("@stock X", c)
        _ = tapOption(c)
        _ = c.fail("@stock: failed", id: 1)
        let retry = c.handleKeyDown(enterKey)  // Return isn't the action key here: it tries again, inserting nothing
        #expect(commits(retry).isEmpty && sends(retry.effects).isEmpty && retry.effects.contains { if case .startPlan = $0 { return true } else { return false } })
    }

    @Test func imessageIsRefusedDuringSecureInput() {
        let (c, _) = imessage()
        c.secureInputActive = { true }
        _ = c.handleKeyDown(tab)
        type("hi", c)
        _ = c.handleKeyDown(spaceKey)
        let response = c.handleKeyDown(enterKey)
        #expect(response.effects.contains(.notice(c.messages.secureInputCommand)) && c.phase == .drafting && sends(response.effects).isEmpty)
    }
}
