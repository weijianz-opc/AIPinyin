# Changelog

[中文](CHANGELOG.md) | English

## 0.3.0 (2026-10-09)

### Added

- An installer: download `AllInOneIME-<version>.dmg` from [Releases](https://github.com/weijianz-opc/AllInOneIME/releases) and double-click "Install AllInOneIME" in it to install, update or uninstall; no more building with Xcode. Universal: it works on Macs with Apple silicon and Intel. It installs for the current user only, with no administrator password. The installer isn't notarized by Apple yet: the first time, click Open Anyway in System Settings → Privacy & Security; download it only from Releases.
- `@read <address>`: a web page's title and text (web pages, plain text, PDFs) as context for the AI inside a sentence, e.g. `@question 用一句话总结 @read https://…`.
- Commands that fetch something work inside a sentence: `@reply 告诉他 @stock AAPL 现在多少钱` runs @stock first and puts its output in place.
- Plugins: ready-made `@` commands (JavaScript in a separate process that can reach only the sites it declares); the first is `@stock` for stock quotes. A "Plugins" section in the settings.
- The command list shows at most 5, the most used lately first; type letters for the others.
- AllInOneIME Cloud: sign up with an email for 20 free requests a day, or subscribe for 3000 a month at $3 (Stripe), without an AWS account or API key of your own. The service is run by the developer (not in this repository).
- Besides Amazon Bedrock: the Claude API, the Gemini API and OpenAI-compatible services (DeepSeek, Qwen, Ollama, …), chosen under "AI Provider" in the settings; API keys are kept in the keychain.
- Your own `@` commands, added under "Custom @ Commands" in the settings (or in the config's `customCommands`), of three types: `prompt` (goes to the AI with your instruction), `run` (runs a program in the background, e.g. `python3 -c`; its output can be inserted) and `terminal` (runs in Terminal). See "Your own commands" in the README.
- ⌃V in a command (or in a sentence-mode draft) appends the clipboard text after what you've typed, in any app, terminals included. In terminals (Ghostty etc.) and Notes, the app takes ⌘V and pastes it itself; use ⌃V there.
- Development: `make dmg` builds the release installer (signed if there's a Developer ID certificate, and notarized too if `NOTARY_PROFILE` is set).

### Changed

- The input method carries its licenses (`LICENSE`, `THIRD_PARTY_NOTICES.md`). `THIRD_PARTY_NOTICES.md` now has the full license texts of the libraries compiled into librime (Boost, glog, LevelDB, yaml-cpp, OpenCC, Lua and others).

### Fixed

- A very long row in the candidate panel (such as a long `@question` answer) could lose its last line; it is shown in full now.
- The settings window explains `@improve` more clearly: "Chinese → translate to English / rewrite; English → polish the English / rewrite".

### Upgrade notes

- A copy installed from source (`make install`) can be updated with the installer, and the other way round: the bundle ID hasn't changed, so settings, learned words and the entry in your input sources are kept.
- The apps in the installer are ad-hoc signed: after switching to the installer, and after each update, macOS may ask for the microphone permission again.

## 0.2.0 (2026-10-09)

### Added

- `@` commands: type `@` at the start of a sentence for the command list (type letters to filter), and press the action key (⏎ by default) when done to run the command. When `@` isn't followed by a command (e.g. `@张三`, a name), it's inserted as usual.
  - `@improve`: translates or polishes, plus a few rewrites (Amazon Bedrock); what every sentence used to get.
  - `@question`: asks a question. The answer appears in the candidate panel; when inserted, it's joined into one line with control characters removed, so it's safe in a terminal too.
  - `@claude`: opens Claude Code in Terminal with what you wrote as the first message (needs the `claude` command installed on the Mac).
  - `@open`: lists matching files, folders and apps as you type (Spotlight); text starting with `~/` or `/` is listed as a path, Tab completes, ⏎ opens.
- Once the results are up, ⌘C copies the highlighted one (for `@open`, the path).
- ⌘V in a command (or in a sentence-mode draft) appends the clipboard text, up to 2000 characters at a time; ⏎ after a command with nothing written yet uses the clipboard text (this works in terminals too). Content that password managers mark as concealed isn't read.
- The version number is shown at the bottom of the settings window, in `make status` and by `allinoneime-cli --version`.

### Changed

- Without `@`, it's a regular pinyin input method: picking a word inserts it, ⏎ is Return, in English mode letters are typed directly, what you say while holding right ⌥ is inserted directly too, and nothing goes online.
- "Translate key" is now "Action key": ⏎ (the new default), Tap ⌥, ⌥Space or Space; it only applies to `@` commands and sentence mode. ⇧⏎ inserts as typed.
- The old behavior, where every sentence went into a draft and a key press produced the results, is now "Sentence mode", off by default. Turn it on in the settings, or toggle it with ⇧Space in Chinese mode (⇧Space used to turn the AI on and off).

### Fixed

- AllInOneIME had no name in the input source list in System Settings; it now shows AllInOneIME. The microphone and speech recognition permission prompts also follow the system language (Chinese / English).
- Ctrl+Space didn't get to AllInOneIME, or it switched back to U.S. after a while: `make install` now adds AllInOneIME to your input sources (only this one; other input sources are left alone), `make uninstall` removes only this one, and the `listed:` line of `make status` shows whether it's in the list.

### Upgrade notes

- To upgrade, run `make install` as usual, without uninstalling first; it adds AllInOneIME to your input sources, so you usually don't need to add it by hand.
- `translateKey` in the config is no longer read; `actionKey` replaces it, ⏎ by default. If you used Tap ⌥, ⌥Space or Space, choose it again under "Action key" in the settings.
- The old "AI translation and rewrites" switch (`aiEnabled`) is no longer read, and sentence mode (`sentenceMode`) is off by default: after upgrading, you get no results without `@`. For the old behavior, turn on sentence mode.
- Upgrading from an AIPinyin (AI 拼音) version: `make install` removes the old AIPinyin.app and "AI 拼音设置"; the added input source and the microphone permission are kept. On first launch, settings, the jargon list and learned words move to `~/.config/allinoneime` and `~/Library/Application Support/AllInOneIME`, logs to `~/Library/Logs/AllInOneIME`, and each old folder is left as a link to the new one.

## 0.1.0

All versions before 0.2.0 are labeled 0.1.0; the app was first called AIPinyin (AI 拼音).

- A local pinyin input method based on librime 1.16.1 and rime-ice (雾凇拼音); typing never goes online.
- Finish a sentence and press the "Translate key": it goes to Amazon Bedrock in your own AWS account (Claude Haiku 4.5 by default), which gives three English versions and several Chinese rewrites (Polish, Concise, Formal, Casual, Tactful).
- A settings window, and "AI 拼音设置", a launcher that opens it.
- Nothing is sent during secure input (password fields and the like).
- "Default input" (Chinese pinyin / English) and "Output" (English / Chinese): text in the other language is translated, text in the same language is polished, and rewrites are in the language you typed. English typed in English mode also goes into the draft (`englishAI` turns this off).
- The "Jargon" rewrite style: big-tech jargon in Chinese, Amazon-speak in English. It can use your own term list, and the candidate panel notes what the terms it used mean.
- Voice input: hold right ⌥ and talk; speech is recognized on the Mac (macOS 26 and later).
- The "Translate key" (`translateKey`) can be Tap ⌥ (default), ⌥Space or Space (at first, only Space).
- "Language" (`uiLanguage`): 中文, English or System; the settings window, the candidate panel hints and the input menu all follow it.
- Renamed to AllInOneIME, with a new icon; the launcher is now "AllInOneIME Settings" ("AllInOneIME 设置" on a Chinese system).
