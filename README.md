<img src="Resources/AppIcon.png" width="96" alt="AllInOneIME 图标" align="right">

# AllInOneIME

中文 | [English](README.en.md)

一个 macOS 输入法。平时就是普通拼音输入法，在本地运行，基于 Rime + 雾凇拼音。句子开头打 `@` 就是命令，
写完按 ⏎ 执行：`@improve` 用 Amazon Bedrock 上的大模型给出三种地道的英文说法和几种改写，`@question` 提问，
`@claude` 在终端里开 Claude Code，`@open` 找文件和 App。也可以按住右 ⌥ 说话。

![两步：@improve 加拼音，再按 ⏎ 出英文和中文改写](docs/demo.png)

![@improve 加英文：英文润色（含黑话）；输出设成中文：中文润色](docs/english.png)

更详细的说明（每个命令和设置、安装排查、隐私）见 [Wiki](https://github.com/weijianz-opc/AllInOneIME/wiki)。

## 怎么用

不打 `@` 的时候，它和别的拼音输入法一样：选词直接上屏，⏎ 就是回车，英文模式下字母直接上屏，不联网。

| 按键 | 作用 |
|---|---|
| 打拼音、空格 / 数字 | 选词，和普通拼音输入法一样 |
| `@`（句子开头） | 弹出命令列表，打字母筛选，⏎、Tab、空格或数字选中 |
| ⏎ | 执行命令。拼音没选完也可以直接按，会先像按空格一样选完 |
| 空格、⏎ / 数字 | 出结果后：上屏高亮项 / 对应项，0 是原文 |
| ⌘C | 复制高亮的结果（`@open` 是复制路径），候选框不关 |
| ⌃V | 在命令里（比如 `@improve ` 后面，或整句模式的草稿里）：把剪贴板里的文字接到已经打的字后面，不贴进 App。多行合成一行，一次最多 2000 字。哪个 App 里都能用；没有命令时照常交给 App |
| ⌘V | 和 ⌃V 一样，但有的 App 会自己处理 ⌘V（终端如 Ghostty、iTerm2、Terminal，还有备忘录），在那里会照常粘贴进 App，请用 ⌃V |
| ⏎（命令后面还没写内容） | 用剪贴板里的文字：先显示在命令里，再按 ⏎ 执行。比如复制一段话后 `@i` ⏎ ⏎ ⏎。哪个 App 里都能用 |
| Esc、⌫ | 回到这句话继续修改；直接打字就是接着往后写 |
| 单按 Shift | 切换中英文 |
| 按住右 ⌥ | 说话，松开结束。中文模式说中文，英文模式说英文。在命令里就接在后面，否则直接上屏 |
| ⇧空格 | 开关整句模式（见下） |

## @ 命令（试用）

| 命令 | 作用 |
|---|---|
| `@improve` | 润色 / 翻译：1–3 是输出语言的三种说法，4 起是改写，0 是原文 |
| `@question` | 提问，答案出现在候选里，⏎ 或空格上屏，⌘C 复制 |
| `@claude` | 在「终端」里打开 Claude Code，你写的话就是第一句，之后在终端里接着聊、让它干活。什么都不上屏 |
| `@open` | 边打边列出匹配的文件、文件夹和 App（聚焦搜索）。以 `~/`、`/` 开头就是路径，Tab 补全，进文件夹；⏎ 打开，⌘C 复制路径 |

例：`@q` ⏎，打 `什么是量子计算`，⏎。选好命令后按住右 ⌥ 说话也行。`@open` 会临时切到英文字母，用完回到中文。

![打 @ 弹出命令列表；@question 加问题，按 ⏎ 出答案](docs/commands.png)

![@open 边打边找 App；以 / 开头是路径，列出文件夹，Tab 补全](docs/open.png)

`@` 后面跟的不是命令时，比如 `@张三`、`@john`，`@` 照常上屏，在聊天软件里 @ 人不受影响。
`@question` 和 `@improve` 只在按执行键时发到你自己的 Bedrock；`@open` 只在本机搜索；`@claude` 用的是你本机装的
Claude Code（`claude` 命令）和它自己的账号，改文件、跑命令前它会照常先问你；没装 Claude Code 时不显示
`@claude`。

### 自己加命令

在配置文件（`~/.config/allinoneime/config.json`）里加 `customCommands`，就能有自己的 `@` 命令，排在内置命令后面。
命令名只能用英文字母，不能和内置命令重名；改完保存，下一句就生效。

```json
"customCommands": [
  { "name": "python", "type": "run", "argv": ["python3", "-c", "{input}"], "summary": "运行 Python" },
  { "name": "calc", "type": "run", "argv": ["bc", "-l"], "stdin": "{input}\n" },
  { "name": "sh", "type": "terminal", "argv": ["zsh", "-c", "{input}"] },
  { "name": "reply", "type": "prompt", "prompt": "Write a short, polite reply to the user's message." }
]
```

| `type` | 做什么 |
|---|---|
| `prompt` | 发给 AI，`prompt` 是给它的指令；回答出现在候选里，可以上屏或 ⌘C 复制 |
| `run` | 在后台运行 `argv`，打印的内容出现在候选里（多行照原样上屏）；出错时显示错误的最后一行 |
| `terminal` | 在新的终端窗口里运行 `argv`，不上屏 |

- `{input}` 换成命令后面写的内容，而且永远只占它所在的那一个参数，不经过 shell。要用 shell 就像上面的 `sh` 那样明确写 `zsh -c`。
- `stdin`：给程序标准输入的内容，`{input}` 同样会被替换。
- `run` 和 `terminal` 默认用英文字母输入（像 `@open`，用完回到中文），全角标点会转成半角：`print（“牛逼”）` → `print("牛逼")`。不想这样就设 `"ascii": false`。
- 程序在主目录里运行，用你的登录 shell 的 PATH（Homebrew、pyenv、nvm 装的都找得到）；`run` 默认 10 秒超时（`timeoutSeconds`），输出太多也会被停止，Esc 随时停止。
- `summary` 是命令列表里的说明，可以不写。
- 找不到 `argv` 里的程序时（比如没装 `python3`），这个命令不显示，`@python …` 照常当文字上屏；装好后切换一下输入框就会出现。

`run` 和 `terminal` 会在你的 Mac 上执行代码：只放你自己写的、信得过的命令；它们同样只在按执行键时运行，安全输入时不运行。

### 执行键

默认是 ⏎，可以在设置的「执行键」里换（config 里的 `actionKey`）：⏎、单按 ⌥（左右都行，按一下马上松开；
按住右 ⌥ 仍然是说话）、⌥空格，或者空格（词选完了再按一次空格，英文模式下连按两次）。
不管执行键是哪个，@ 命令都可以按 ⏎ 执行。⌥空格如果已经是 Alfred、Raycast 等的快捷键，会先被它们拿走。

### 整句模式

原来的用法：开启后不加 `@` 也进草稿，整句打完按执行键就润色 / 翻译，相当于每句都自动加了 `@improve`。
要原样上屏按 ⇧⏎（执行键不是 ⏎ 时就按 ⏎）。在设置里打开，或者按 ⇧空格（中文模式下）切换。默认关闭。

## 输入和输出

在设置里选两项：

- **默认输入**：中文（拼音）或英文，决定新的输入框从哪种模式开始。单按 Shift 随时切换。
- **输出（1–3 行）**：`@improve` 的 1–3 行用英文（默认）还是中文。原文是另一种语言就翻译，是同一种语言就润色：

| | 输出英文 | 输出中文 |
|---|---|---|
| 打中文 | 翻译成英文 | 中文润色 |
| 打英文 | 英文润色 | 翻译成中文 |

整句模式下英文也进草稿；不想这样的话，在设置里关掉「整句模式下英文也进草稿」。

## 改写风格

1–3 行之后是改写，**用原文的语言**：打中文出中文改写，打英文出英文改写。在设置里任选几种：

- 润色：语气不变，更自然
- 简洁
- 正式：发给领导、客户
- 口语
- 委婉
- 黑话：中文是大厂黑话（对齐、抓手、颗粒度…），英文是 Amazon 腔（bandwidth、circle back…）。坏消息会说得轻描淡写，比如 "this is a blocker bug" → "Oh! Looks like your team has the bandwidth to fix this minor issue!"

只改了标点、或者和其他行重复的改写不会显示。

### 黑话库（用你自己的词表）

黑话没有内置词库。你可以准备一个自己的词表（比如团队里常用的说法），模型会优先用里面的词。
候选里黑话那一行会注明用到的词是什么意思，例如「黑话 · PRFAQ＝新功能提案文档」。

词表是一个文本文件，每行一个词，后面可以加解释，用「：」「=」或 Tab 隔开（可以直接从表格复制两列粘贴）。
`#` 开头的行是注释：

```
PRFAQ：新功能提案文档（先写新闻稿和 FAQ）
COE：事故复盘文档
two-way door：可以随时撤回的决定
抓手：着力点
```

在设置的「改写风格 → 黑话库」里点「新建」，会在 `~/.config/allinoneime/jargon.txt` 建一个空词表并打开；
已经有词表文件的话，点「选择文件…」直接用它（config 里的 `jargonFile`）。改完马上生效。
最多读前 150 个词。勾上「黑话」时，词表会随请求一起发给 Bedrock。

<img src="docs/panel-dark.png" width="420" alt="深色模式下的候选框">

## 语音输入

<img src="docs/voice.png" width="340" alt="按住右 ⌥ 说话">

按住右 ⌥ 说话，松开后文字直接上屏。先打好命令（比如 `@improve `、`@question `）再说的话，文字接在命令后面，按 ⏎ 执行；也可以不松开右 ⌥ 直接按 ⏎，说完马上执行。语音用 macOS 自带的语音识别（SpeechAnalyzer）在本机完成，音频不上传；需要 macOS 26 或更新版本。

第一次使用时：

- macOS 会问是否允许 AllInOneIME 使用麦克风。也可以先在设置里点「允许使用麦克风」。
- 如果这台 Mac 还没有这种语言的语音模型，会自动下载一次。在设置里也可以手动下载。

按住约 0.2 秒后才开始录音，所以轻点右 ⌥ 不会打开麦克风（执行键设成「单按 ⌥」时，轻点就是执行）。按住时如果按了别的键（比如 ⌥ 组合键、⌥←），就当作快捷键，也不会录音。录音中按其他键会取消录音。

## 安装（从源码）

运行需要 macOS 14 以上，语音输入要 macOS 26 以上。编译需要 Xcode 26 以上，因为语音输入用到 macOS 26 SDK。
目前只在 macOS 27 + Xcode 27、Apple Silicon 上测试过。

```sh
git clone https://github.com/weijianz-opc/AllInOneIME.git
cd AllInOneIME
make install
```

`make install` 会下载 librime 和雾凇拼音词库并校验，编译后安装到 `~/Library/Input Methods`，
并在 `~/Applications` 放一个「AllInOneIME 设置」（英文系统里叫 AllInOneIME Settings）。

`make install` 会启用 AllInOneIME，并把它加进你的输入法列表，之后用 Ctrl+空格 切换
（🌐 键要在 系统设置 → 键盘 里把「按下 🌐 键时」设成「更改输入法」才会切换）。
如果最后提示要手动添加，说明这台 Mac 不让程序启用，就自己加一次：
系统设置 → 键盘 → 文字输入 › 输入法「编辑…」→ 左下角 + → 简体中文 → AllInOneIME。

Ctrl+空格 切不到 AllInOneIME，或者切过去一会儿又变回 U.S.：再运行一次 `make install`，
它会把 AllInOneIME 加回输入法列表。`make status` 里的 `listed:` 一行显示它在不在列表里。

以前装过 AI 拼音（AIPinyin）的话，直接 `make install` 就行：它会删掉旧的 AIPinyin.app 和「AI 拼音设置」，
输入法列表里那一项会换成新名字，不用重新添加。设置、黑话库和学到的词第一次启动时搬到新目录
（`~/.config/allinoneime` 等），旧目录留一个指向新目录的链接。

升级前看一下 [更新日志](CHANGELOG.md)，里面有每个版本的变化和升级须知。装的是哪个版本，看 `make status` 的 `version:` 一行。

卸载：`make uninstall`。

## 配置 AI

翻译和改写用你自己的 AI 服务，费用记在你的账号上：默认是 AWS 账号里的 Amazon Bedrock，也可以用 Claude API、Gemini 或兼容 OpenAI 的服务（见下面的「其他 AI 服务」）。

### Amazon Bedrock

1. 在 AWS 控制台开通 Bedrock，确认能用所选的模型。默认是 Claude Haiku 4.5，第一次用 Anthropic 模型要填一次用途说明。
2. 创建一个有 `bedrock:InvokeModelWithResponseStream` 权限的 access key，写进 `~/.aws/credentials` 里的一个 profile。
   目前只支持这种固定密钥，不支持 SSO 和 assume-role。
3. 打开「AllInOneIME 设置」，在聚焦搜索或「应用程序」里都能找到，也可以从菜单栏的输入法图标 → 设置… 打开。
   选好 profile、区域和模型，点「测试连接」。设置窗口最上面的「界面语言」可以选中文或 English；默认跟随系统
   （系统的首选语言里中文排在英文前面时显示中文，否则显示英文）。设置窗口、候选框里的提示和输入法菜单都跟着它。

<img src="docs/settings.png" width="420" alt="设置窗口">

### 其他 AI 服务：Claude API、Gemini、兼容 OpenAI 的服务

不用 AWS 也可以：在设置的「AI 服务」里选一个，粘贴 API key 点「保存」，再点「测试连接」。

| 服务 | 默认模型 | API key |
|---|---|---|
| Claude API | `claude-haiku-5-5`（最快最便宜；也可选 Sonnet 5.5、Opus 5.5，更用心但更慢更贵） | [Claude Console](https://platform.claude.com) |
| Gemini API | `gemini-3.8-flash` | Google AI Studio |
| 兼容 OpenAI 的服务 | OpenAI 的 `gpt-6-luna`（也可选 `gpt-5.4-mini`）；「常用服务…」里有 DeepSeek、通义千问、Kimi、智谱 GLM、硅基流动、OpenRouter、本机 Ollama，选了会填好 Base URL，再填它的模型 | 那个服务的 key；Base URL 填它的地址，比如 `https://api.deepseek.com/v1`，本机 Ollama 填 `http://localhost:11434/v1` |

- API key 存在系统钥匙串里，不写进配置文件。钥匙串里没有时，也会用 shell 里设的 `ANTHROPIC_API_KEY`、`GEMINI_API_KEY`（或 `GOOGLE_API_KEY`）、`OPENAI_API_KEY`。
- 「思考」默认是 low：输入法每句话都在等，思考越少越快。模型不支持这个参数时选「不设置」。
- 选 Claude Opus 5.5、Sonnet 5.5 时会带上 Claude API 的拒答兜底（`fallbacks: "default"`）：安全分类器拒绝时，服务端自动换一个模型重试。
- 配置文件里对应 `provider`（`"bedrock"`、`"anthropic"`、`"gemini"`、`"openai"`），以及 `anthropic`、`gemini`、`openai` 各自的 `model`、`baseURL`、`effort`、`temperature`（不填就用默认值）。

所有设置都存在 `~/.config/allinoneime/config.json`，改完后，下一次翻译就会用上新设置，不用重启。新加的几项：

| 键 | 作用 | 默认 |
|---|---|---|
| `defaultInput` | 默认输入：`"zh"` 中文、`"en"` 英文 | `"zh"` |
| `outputLanguage` | 1–3 行的语言：`"en"` / `"zh"` | `"en"` |
| `englishAI` | 整句模式下英文也进草稿 | `true` |
| `voiceInput` | 按住右 ⌥ 说话 | `true` |
| `actionKey` | 执行键：`"enter"`（⏎）、`"optionTap"`（单按 ⌥）、`"optionSpace"`（⌥空格）、`"space"`（空格） | `"enter"` |
| `uiLanguage` | 界面语言（设置窗口、候选框提示、菜单）：`"zh"`、`"en"` | `null`（跟随系统） |
| `rewriteStyles` | 改写风格，例如 `["润色", "简洁", "黑话"]` | `["润色", "简洁", "正式"]` |
| `jargonFile` | 你自己的黑话词表文件 | `null`（即 `~/.config/allinoneime/jargon.txt`） |

## 隐私

- 打拼音完全在本地。只有 `@improve`、`@question`（或整句模式下的句子）按执行键时，那一句话才会发到你选的 AI 服务（你自己的 Bedrock，或你填了 key 的服务）。勾上「黑话」并设了黑话库时，词表也会一起发过去。
- 语音只在按住右 ⌥ 时录音，在本机识别；只有在上面这些命令里，识别出的文字才会在你按执行键时发出去。
- 只有在命令（或整句模式的草稿）里按 ⌃V 或 ⌘V，或者命令后面没写内容就按执行键时，输入法才读一次剪贴板里的文字；密码管理器标成隐藏的内容不读。读到的文字先显示在草稿里，同样要你再按执行键才发出去。新版 macOS 会问是否允许 AllInOneIME 读取剪贴板，选「允许」；不想每次都问，可以在 系统设置 → 隐私与安全性 里把 AllInOneIME 的粘贴权限设成总是允许。
- 在密码框里（安全输入）不组字，也不能录音。只要系统处于安全输入状态（密码框、终端的安全键盘输入等），就不会发任何内容给 AI。
- 日志不记录输入内容。macOS 对所有第三方输入法都会提示"开发者能获取你输入的内容"，这是系统的通用提示。

## 开发

```sh
make test         # 单元测试，加上用真实 Rime 引擎跑的测试
make selftest     # 用模拟文本框驱动输入法：真实 Bedrock 调用，加上用合成语音测试本机识别
make realtest     # 在真实 App 的文本框里打字测试（需要屏幕已解锁，会占用前台约 1 分钟）
make screenshots  # 重新生成 docs/ 里的截图
make cli && .build/release/allinoneime-cli --styles 简洁,黑话 "我今天有点不舒服"   # 在终端里试翻译和改写
make icon         # 从 Resources/AppIcon.png 重新生成 App 图标和菜单栏图标
```

代码结构：

- `Sources/AllInOneIMECore`：Bedrock 客户端、SigV4、提示词、两级输入状态机（含英文草稿和语音手势），不依赖 AppKit
- `Sources/AllInOneIMERime`：librime 封装
- `Sources/AllInOneIME`：InputMethodKit 输入法、候选框、设置窗口、语音识别
- `Sources/AllInOneIMESettings`：「AllInOneIME 设置」启动器

Bundle ID 仍是 `com.aipinyin.inputmethod.AIPinyin`：macOS 按它记住已添加的输入法和麦克风权限，改了就要重新添加和授权。

## 许可证

GPL-3.0，见 [LICENSE](LICENSE)。用到的第三方组件（librime 及插件为 BSD-3-Clause，雾凇拼音为 GPL-3.0）
见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
