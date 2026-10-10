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
  `type` is `script` (JavaScript, below) or `prompt` (an AI instruction in `prompt`, like a custom command).
  `icon` (an SF Symbol name) and `color` (`blue`, `green`, … or `#RRGGBB`) draw it in the command list.
- `main.js` for a script plugin: `function run(input) { return "one line" }`. A `throw` is the error shown.
- `install.json`, written when installed from the library: `{version, files: {name: sha256}, source: "registry"}`.
  A folder without it is a **local** plugin (an author's, not reviewed).

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

## The library (milestone 2)

A public repo `weijianz-opc/AllInOneIME-plugins`, served from raw.githubusercontent.com:

- `index.json`: `{schema, generated, plugins: [{name, version, api, minAppVersion, summary, hosts, base, files: {name: sha256}}]}`
- `index.json.sig`: Ed25519 signature of the exact bytes; the public key is built into the app (CryptoKit).
  Hashes alone aren't enough: whoever can push to the repo could change files and hashes together.
- Version folders (`plugins/stock/1.0.0/`) never change once published.
- Installing shows the hosts the plugin contacts ("what you type after @stock goes to query1.finance.yahoo.com"),
  downloads to `<name>.tmp/`, checks every hash, then renames into place. Updates are manual (a badge in Settings).
- Only the maintainer merges; CI checks the schema, hashes and hosts and refuses `eval` / `Function(`.

## Milestones

1. **@stock end to end, installed by hand** (this branch): manifest and store, the JavaScript host with
   `fetch`, the child-process runner, plugins in the command list, a Plugins section in Settings (installed
   plugins, uninstall, open the folder), tests with recorded Yahoo responses.
2. **Library**: signed index, browse / install / update in Settings, the registry repo with CI and a signing script.
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
