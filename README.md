# AI 拼音（AIPinyin）

一个 macOS 输入法：平时就是普通拼音输入法（本地运行，基于 Rime + 雾凇拼音）；整句打完再按一次空格，
就会用 Amazon Bedrock 上的大模型给出地道的英文说法和几种中文改写，选一个上屏。

![两步：先打拼音，再按空格出英文和中文改写](docs/demo.png)

## 怎么用

| 按键 | 作用 |
|---|---|
| 打拼音、空格 / 数字 | 选词，和普通拼音输入法一样，不联网 |
| 整句打完再按空格 | 出结果：1–3 是英文，4 起是中文改写，0 是原文 |
| 空格 / 数字 | 上屏高亮项 / 对应项 |
| ⏎ | 上屏中文原文 |
| Esc、⌫ | 回到这句话继续修改；直接打字就是接着往后写 |
| ⇧空格 | 开关 AI（关掉就是纯本地拼音） |
| 单按 Shift | 切换中英文 |

中文改写有五种预设，可以在设置里任选几种：润色（语气不变，更自然）、简洁、正式（发给领导、客户）、
口语、委婉。只改了标点、和原文一样的改写不会显示。

<img src="docs/panel-dark.png" width="420" alt="深色模式下的候选框">

## 安装（从源码）

需要 macOS 14 以上和 Xcode 16 以上（目前只在 macOS 27 + Xcode 27、Apple Silicon 上测试过）。

```sh
git clone https://github.com/weijianz-opc/AIPinyin.git
cd AIPinyin
make install
```

`make install` 会下载并校验 librime 和雾凇拼音词库，编译后安装到 `~/Library/Input Methods`，
并在 `~/Applications` 放一个「AI 拼音设置」。

装好后手动添加一次输入法（macOS 不允许程序自动启用第三方输入法）：
系统设置 → 键盘 → 文字输入 › 输入法「编辑…」→ 左下角 + → 简体中文 → AIPinyin。
之后用 Ctrl+空格 或 🌐 键切换。

卸载：`make uninstall`。

## 配置 AI（Amazon Bedrock）

翻译和改写用你自己 AWS 账号里的 Bedrock，费用记在你的账号上。

1. 在 AWS 控制台开通 Bedrock，并确认能用所选模型（默认 Claude Haiku 4.5；首次用 Anthropic 模型需要填一次用途说明）。
2. 创建有 `bedrock:InvokeModelWithResponseStream` 权限的 access key，写进 `~/.aws/credentials` 的一个 profile。
   目前只支持这种固定密钥，不支持 SSO 和 assume-role。
3. 打开「AI 拼音设置」（聚焦搜索或「应用程序」里能找到，也可以从菜单栏输入法图标 → 设置…打开），
   选 profile、区域和模型，点「测试连接」。

<img src="docs/settings.png" width="420" alt="设置窗口">

所有设置都存在 `~/.config/aipinyin/config.json`，改完下一次翻译就生效，不用重启。

## 隐私

- 打拼音完全在本地。只有你按空格请求结果时，那一句确认过的文字才会发到你自己的 Bedrock。
- 系统处于安全输入状态（密码框、终端的安全键盘输入等）时，不会发送任何内容。
- 日志不记录输入内容。macOS 对所有第三方输入法都会提示"开发者能获取你输入的内容"，这是系统的通用提示。

## 开发

```sh
make test         # 单元测试 + 用真实 Rime 引擎的测试
make selftest     # 用模拟文本框驱动输入法，含一次真实 Bedrock 调用
make realtest     # 在真实 App 的文本框里打字测试（需要屏幕已解锁，会占用前台约 1 分钟）
make screenshots  # 重新生成 docs/ 里的截图
make cli && .build/release/aipinyin-cli "我今天有点不舒服"   # 在终端里试翻译和改写
```

代码结构：`Sources/AIPinyinCore`（Bedrock 客户端、SigV4、两级输入状态机，不依赖 AppKit）、
`Sources/AIPinyinRime`（librime 封装）、`Sources/AIPinyin`（InputMethodKit 输入法、候选框、设置窗口）、
`Sources/AIPinyinSettings`（「AI 拼音设置」启动器）。

## 许可证

GPL-3.0，见 [LICENSE](LICENSE)。用到的第三方组件（librime 及插件为 BSD-3-Clause，雾凇拼音为 GPL-3.0）
见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
