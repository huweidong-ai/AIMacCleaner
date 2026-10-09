[🇨🇳 中文](README.zh-CN.md) · [🇺🇸 English](README.md)

# AI Mac Cleaner

**会思考的 macOS 卸载助手**——不止删 `.app`，还能用 AI 读懂你的清理清单：说一句「把 Cursor 彻底卸掉」，它自己调起扫描、列出该删的痕迹；删之前，再让 AI 帮你看一眼哪些登录态、凭据不能动。

免费、开源、纯本地。AI 用你自己的 Key 调用，清单上下文发往你配置的模型服务商；AI Mac Cleaner 自己不上传、更不替你做删除决定。

> 系统要求：macOS 14 (Sonoma) 及以上；支持 Intel 与 Apple Silicon。

![主界面](screenshots/mainCN.png)

---

## 它解决什么

普通「拖进废纸篓」只删了应用壳，Homebrew 公式、npm 包、沙箱容器、启动项、Shell 配置、AI 工具的缓存和模型全留着。更麻烦的是——**留下的东西该不该删，人往往拿不准**：微信的登录态删了要重新扫码，Ollama 的模型一个就几十 GB、删了重下巨慢。

AI Mac Cleaner 把「找全」和「判断」两件事都做了：扫描 16 类残留，再用 AI 在删前帮你划清「该删 / 该留」。

---

## AI 能力（重点）

### 1. 对话式卸载：用一句话让 AI 动手

打开「问 AI」，用自然语言描述目标，例如：

- 「把 Cursor 彻底卸干净」
- 「扫一遍所有残留，挑能安全删的」
- 「Docker 占了好多空间，帮我看看」

内置 AI Agent 会自己调用 7 个只读技能（列应用、扫应用、扫残留、列进程、复核、生成卸载计划、看历史），查看结果、给出计划。**任何删除操作都要你确认后才执行**——AI 只出主意，不动你的文件。

![AI Agent](screenshots/agentCN.png)

### 2. 让 AI 替你判断：删什么、留什么

最实用的一块。三处都能调 AI：

- **应用页「让 AI 分析」**：AI 从待删除清单里挑出**不该删**的项（登录态 / 凭据 / 被其它应用共享的数据 / 订阅授权 / 活跃数据库），自动取消勾选并写明理由。
- **残留页「让 AI 帮我判断」**：AI 从孤儿残留里挑出**能放心删**的项（缓存 / 日志 / 明确属于该应用且不含登录态的容器 / 临时文件），自动勾选并写明理由。
- **进程页「AI 判断后果」**：勾选进程点一下，AI 判断结束它会怎样——会不会丢未保存的工作、会不会让某个 GUI 应用崩溃，给出高 / 中 / 低风险。

> **纯 AI，不兜底。** 没配模型或调用失败就如实告诉你「这次没用上 AI」，绝不拿本地规则编一个结论糊弄你。

![AI 复核](screenshots/ai-reviewCN.png)
![AI 判断后果](screenshots/ai-consequenceCN.png)

### 3. 它懂 AI 工具自己的残留

专门为 AI 时代的工作站打造：内置 **15 款**主流 AI 编程助手、ML 框架与编辑器的残留知识——Claude Code、Cursor、Windsurf、Cody、Tabnine、Amazon Q、Ollama、LM Studio、Hugging Face、PyTorch、VS Code、JetBrains、Xcode 等。它不光认得这些工具的数据在哪，还知道 **Ollama 模型一个 2–50 GB、Hugging Face 模型动辄上百 GB**——删之前就给你标好风险，避免误删要重下半天的大文件。

### 4. 长期记忆：你教过它的，下次还记得

在「问 AI」里输入 `/remember <你的偏好>`，比如「JetBrains 的索引别动」。这条记忆跨 `/new`、跨重启都保留，之后 AI 做判断时会参考它。用 `/reset` 清空当前对话上下文（不影响记忆），用 `/new` 开新会话。

![斜杠命令](screenshots/slash-commandsCN.png)

### 5. 多模型、自带密钥、纯本地

打开 ⚙ **设置 → 配置 AI 模型**，填你自己的 API Key：

- 支持 **OpenAI 兼容** 与 **Anthropic 兼容** 两种协议（官方、本地代理、第三方中转都行，baseURL 可改）。
- 可配置**多套模型**，在「问 AI」工具栏随时切换；可设默认档。
- 密钥只存在本机 `UserDefaults`，AI Mac Cleaner 不碰你的 Key 之外的任何东西。

![模型配置](screenshots/model-configCN.png)

---

## 基础清理能力

AI 是亮点，但不联网也能用：

- **深度卸载**：选一个应用，一次性找出依赖、偏好、缓存、日志、容器、包管理器装的 CLI 工具，确认一次全部清掉。![深度卸载](screenshots/uninstallCN.png)
- **孤儿残留扫描**：反向查找 `~/Library` 里已经没有活应用认领的目录，找出几个月前卸载后偷偷留下的数据。![孤儿扫描](screenshots/orphansCN.png)
- **进程管理**：列出后台进程（node、Python、Docker、Brew service），显示内存、CPU 和**监听端口**，按端口搜、一键结束。![进程管理](screenshots/processesCN.png)

扫描覆盖 **16 类**残留：应用包、Homebrew、npm / pipx、沙箱容器、启动项、Shell 配置、点文件、缓存、偏好设置、日志、认证凭证、AI 工具数据、孤儿残留、XDG 目录、MAS 回执、Application Support。

---

## 安全设计

- **用户数据走废纸篓**：聊天记录、配置、账号等可恢复；缓存和系统文件确认后直接删除。
- **AI 没有通用权限**：Agent 只能调用 7 个预定义的只读技能，不能执行任意命令、不能读任意文件。
- **执行前必确认**：每次删除都要确认，不做静默操作。
- **系统保护**：关键系统进程和路径在白名单里，永远不会被删。
- **数据不出本机（非 AI 部分）**：扫描与清理完全在本机完成；使用 AI 时，清理清单的上下文会发往你配置的模型服务商（用自己的 Key），AI Mac Cleaner 本身不做任何埋点、遥测或后台上传。

---

## 安装

### 下载 DMG（推荐）

从 [Releases](https://github.com/hwd8080-ai/AIMacCleaner/releases) 下载 `AI Mac Cleaner-<版本>.dmg` 与同名 `.sha256`，先校验：

```bash
shasum -a 256 -c AI\ Mac\ Cleaner-<版本>.dmg.sha256   # 应输出 OK
```

打开 DMG，把 AI Mac Cleaner 拖到「应用程序」。首次启动：**右键 → 打开**。

### 从源码构建

```bash
git clone https://github.com/hwd8080-ai/AIMacCleaner.git
cd AIMacCleaner
./build_app.sh                       # → /Applications/AIMacCleaner.app
open /Applications/AIMacCleaner.app
```

打 DMG 发布包：

```bash
./build_release.sh                   # → dist/AIMacCleaner-<版本>.dmg + .sha256
```

### 仅命令行

```bash
swift build -c release
.build/release/ai-mac-cleaner --scan 微信              # 扫描某个应用
.build/release/ai-mac-cleaner --self-test              # 跑自检
.build/release/ai-mac-cleaner --skills                 # 列出 Agent 能调用的 skill
.build/release/ai-mac-cleaner --agent "把 Cursor 卸干净"   # 让 AI 直接动手（仍要你确认）
```

---

## 使用

1. 下载安装后打开，首次建议先在 **设置 → 配置 AI 模型** 填入 API Key（不填也能手动清理，只是用不了 AI 判断）。
2. 想省事就点 **「问 AI」**，用一句话说要干嘛，比如「把 Cursor 彻底卸干净」；AI 会扫描并给出计划，确认后执行。
3. 想自己把控就点 **「应用」**：勾选要删的项，点 **「让 AI 分析」** 让它帮你标出不该删的（登录态、凭据）。
4. 卸载很久的应用，点 **「残留」** 扫孤儿目录，点 **「让 AI 帮我判断」** 让它勾出能放心删的。
5. 卡顿或端口被占，点 **「进程」** 查看，必要时用 **「AI 判断后果」** 确认再结束。

---

## 许可

MIT © AI Mac Cleaner 贡献者——详见 [LICENSE](LICENSE)。

### 商标声明

「**AI Mac Cleaner**」这个名称、Logo 和应用图标是本项目的商标，**不在** MIT 许可范围内。你可以自由使用源码、编译自己的版本，但不能用本项目的名字或图标发布衍生版本。Fork、改名、做成你自己的东西——MIT 就是为这个准备的。

## 参与贡献

欢迎提Issue 和PR，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。
