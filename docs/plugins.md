# Plugins: plan

@ commands come in three tiers: **built-in** (`@improve`, `@question`, `@claude`, `@open`), **plugins**
installed from the plugin library (what not everyone wants, like `@stock`), and the user's **custom**
commands (Settings → Custom @ Commands). When names clash: built-in > plugin > custom.

## What a plugin is

A folder in `~/.config/allinoneime/plugins/<name>/`:

- `plugin.json`, the manifest:
  ```json
  { "name": "stock", "version": "1.0.0", "api": 1, "minAppVersion": "0.3.0",
    "type": "script",
    "summary": {"en": "Stock quotes: @stock AAPL 600519 700", "zh": "股票行情：@stock AAPL 600519 700"},
    "script": "main.js", "hosts": ["query1.finance.yahoo.com"],
    "timeoutSeconds": 10, "ascii": true,
    "author": "weijianz-opc", "homepage": "https://github.com/weijianz-opc/AllInOneIME-plugins",
    "icon": "chart.line.uptrend.xyaxis", "color": "green" }
  ```
  `type` is `script` (JavaScript, below), `prompt` (an AI instruction in `prompt`, like a custom command) or
  `link` (a web address opened in the browser, below).
  `icon` (an SF Symbol name) and `color` (`blue`, `green`, … or `#RRGGBB`) draw it in the command list.
- `main.js` for a script plugin: `function run(input) { return "one line" }`. A `throw` is the error shown.
- `install.json`, written when installed from the library: `{version, files: {name: sha256}, source: "registry"}`.
  A folder without it is a **local** plugin (an author's, not reviewed).

## Link plugins

A `link` plugin runs no code: the text after the command goes into a web address, which opens in the default
browser. Nothing is inserted; the draft is cleared, as when `@open` opens something. Made for "share" and
"compose" pages, where the user posts it themselves, signed in as usual:

```json
{ "name": "x", "version": "1.0.0", "api": 1, "minAppVersion": "0.5.0", "type": "link",
  "url": "https://x.com/intent/post?text={input}",
  "summary": {"en": "Post to X: opens the composer with your text", "zh": "发到 X：打开发帖框，文字已填好"},
  "author": "weijianz-opc", "icon": "bird", "color": "#000000" }
```

- `url` is required: `https://`, with `{input}` exactly once, in the query or the fragment (after `?` or `#`), so
  the text can never choose the host or the path. Its host is the plugin's host ("the text after @x goes to
  x.com"); `script` and `hosts` aren't used.
- The text is percent-encoded as a query value: everything but `A–Z a–z 0–9 - . _ ~` as UTF-8, a space as `%20`
  (not `+`), a newline as `%0A`. At most 4000 characters (longer: an error, and the draft stays).
- Nothing after the command: like any command, the action key takes the clipboard's text (with none, it asks
  for some); the page never opens empty from the input method.
- Not a command inside a text (it fetches nothing), but it can be the outer one: `@x 今天 @stock AAPL 涨了` runs
  `@stock` first and opens the link with its output in the text.
- Refused during secure input, like every command.
- Custom commands have the same type (`{"name": "google", "type": "link", "url": "https://www.google.com/search?q={input}"}`,
  or "Open a web page" in Settings → Custom @ Commands).

[Plugins/](../Plugins/) in the repository has `@x`, `@threads`, `@bsky` and `@weibo`; the library publishes them.

## How a script runs

In JavaScriptCore (part of macOS: nothing to install), in a **child process**: `AllInOneIME --run-plugin <dir>`
with the text on standard input, the result on standard output. JavaScriptCore can't stop a running script, so
a stuck plugin must not run inside the input method; a child process is killed by the existing runner (timeout,
output limit, Esc), the same path as custom `run` commands.

The script sees nothing but `fetch`:

```js
fetch(url, {headers}) → {status, ok, text, json()}              // throws when the request fails
fetch([url, …], {headers}) → [{status, ok, text, json()} | {ok: false, error}]   // in parallel
```

- HTTPS only, and only to the manifest's `hosts` (redirects too); no cookies, no cache.
- At most 8 requests a run, 1 MB a response, 5 s a request; the run itself ends after `timeoutSeconds` (≤ 20).
- No file system, processes, environment, timers or clipboard: a bare `JSContext` has none of them.
- Secure input (password fields) refuses plugins like any command.

## The library (milestone 2, done)

A public repo [`weijianz-opc/AllInOneIME-plugins`](https://github.com/weijianz-opc/AllInOneIME-plugins), served from
`https://raw.githubusercontent.com/weijianz-opc/AllInOneIME-plugins/main/` (`PluginLibrary.defaultBaseURL`):

- `plugins/<name>/<version>/`: `plugin.json` and its files. A version folder never changes once published (CI
  refuses a pull request that modifies one); an update is a new folder.
- `index.json`, every version (newest first):
  ```json
  { "schema": 1, "generated": "2026-10-10T12:00:00Z",
    "plugins": [{ "name": "stock", "version": "1.0.0", "api": 1, "minAppVersion": "0.2.0", "type": "script",
                  "summary": {"en": "…", "zh": "…"}, "hosts": ["query1.finance.yahoo.com"],
                  "author": "…", "homepage": "…", "icon": "…", "color": "green",
                  "base": "plugins/stock/1.0.0/", "files": {"main.js": "<sha256>", "plugin.json": "<sha256>"} }] }
  ```
  A `link` plugin's entry also carries its `url`.
- `index.json.sig`: the Ed25519 signature (base64) of the exact bytes of `index.json`. The public key is built into
  the app (`PluginLibrary.publicKey`); the private key lives only in the maintainer's login keychain. Hashes alone
  aren't enough: whoever can push to the repo could change files and hashes together.
- `scripts/build-index` (a Swift script, CryptoKit) validates every plugin (schema, name = folder, https host names,
  sizes, plain file names, no `eval(` / `Function(` / `new Function`), writes `index.json` and signs it with the key
  from the keychain. CI runs it with `--validate` on pull requests and `--check` on main (the index matches the
  plugins, the signature is valid); CI can't sign. Only the maintainer merges.

In the app (`PluginLibrary`, Settings → Plugins → "Browse Library…"):

- Network only when the user opens or refreshes the library, or installs: no background polling.
- The signature is verified **before** the index is parsed; an unknown `schema` is refused. Offered is, per plugin,
  the newest version whose `api`, `minAppVersion` and `type` this app supports.
- Installing first shows what the plugin contacts ("what you type after @stock goes to query1.finance.yahoo.com").
  Then: names must be 1–24 lowercase letters, file names plain (no `/`, `..`, leading `.`, `install.json`), `base`
  a plain relative path under the library. Every file is downloaded into `<name>.tmp/` and checked against its sha256;
  `plugin.json` must match the entry (name, version, hosts) and be usable; `install.json` is written; then the folder
  is swapped into place in one step (`renamex_np` with `RENAME_SWAP`). Any failure removes the temporary folder and
  leaves the installed version as it was.
- A library plugin with a newer version in the index gets an "Update" button (in the library list and next to the
  installed plugin); updates are manual. A local plugin (no `install.json`) of the same name is never overwritten:
  the library shows it as local.
- Installing or removing a plugin rescans the plugins folder, so the command list has it at the next keystroke.

## Milestones

1. **@stock end to end, installed by hand** (this branch): manifest and store, the JavaScript host with
   `fetch`, the child-process runner, plugins in the command list, a Plugins section in Settings (installed
   plugins, uninstall, open the folder), tests with recorded Yahoo responses.
2. **Library** (done): signed index, browse / install / update in Settings, the registry repo with CI and a signing script.
3. **More**: prompt plugins in the library, update all, author documentation.

## Commands inside a text (nested @)

`@reply 告诉他 @stock AAPL 现在多少钱`: commands that fetch something (plugins and custom programs) can sit
inside the text. They run first, together; each one's output takes its place; then the outer command (or
@improve, without one) works on the result. An inner command is a known name after `@` (not after a letter or
digit: `a@b.com` stays text), a space, and its argument: a word, plus the words right after it without lowercase
letters (`AAPL TSLA`, `600519 700`; `@stock SNDK is good to buy` takes `SNDK`), or the text in 「…」 / quotes. `@张三` and anything else stay as typed.

**One model call at most.** Only commands that run code or fetch data go inside a text; the AI runs once, as the
outer command. An AI command inside a text (`@question …` after `@reply`) stays text, and the model never plans
the order: whoever needs that much opens a session (`@claude`) or Terminal. This keeps every command quick,
predictable and one request's worth of cost.

Commands that **send** something run last, on the final text, only after the user confirms in the candidate panel.
The first one is built in: `@imessage` picks the recipient from Contacts in the panel, runs the commands inside the
message, shows "Send to 张三 (…): …" and sends only on a second ⏎ (Esc goes back to editing); nothing is inserted.
The recipient model and the sender (`Recipient`, `MessageSender`) are meant for more of them. Next: plugins that send
(`@slack 张三`), with stored credentials (keychain) and their own targets (person, thread) to pick from the candidates.
