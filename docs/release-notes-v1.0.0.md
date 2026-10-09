# AI Mac Cleaner v1.0.0

第一个公开版本。23,350 行 Swift，纯本地运行，无遥测。

## 解决什么问题

「拖进废纸篓」只删了应用壳。Homebrew 公式、npm 包、沙箱容器、启动项、Shell 配置、AI 工具的模型和缓存全留着。

更麻烦的是**留下来的东西该不该删，人往往拿不准**：微信登录态删了要重新扫码，Ollama 的模型一个几十 GB、删了重下巨慢。

AI Mac Cleaner 把「找全」和「判断」两件事都做了。

## 核心能力

**16 类残留扫描** — 应用包、Homebrew、npm / pipx、沙箱容器、启动项、Shell 配置、点文件、缓存、偏好设置、日志、认证凭证、AI 工具数据、孤儿残留、XDG 目录、MAS 回执、Application Support。

**深度卸载** — 选一个应用，一次性找出依赖、偏好、缓存、日志、容器、包管理器装的 CLI 工具，确认一次全部清掉。

**孤儿残留扫描** — 反向查找 `~/Library` 里已经没有活应用认领的目录，找出几个月前卸载后偷偷留下的数据。

**进程管理** — 列出后台进程（node、Python、Docker、Brew service），显示内存、CPU 和**监听端口**，按端口搜、一键结束。

## 问 AI：内置智能体

打开「问 AI」，用自然语言描述目标——「把 Cursor 彻底卸干净」——Agent 自己调起 11 个技能（8 个只读 + 3 个只出计划不落盘），查看结果、给出计划。

**任何删除操作都要你确认后才执行。** AI 只出主意，不动你的文件。

三处 AI 判断入口：

| 位置 | AI 做什么 |
|---|---|
| 应用页「让 AI 分析」 | 从待删清单里挑出**不该删**的项（登录态 / 凭据 / 被其他应用共享的数据 / 订阅授权 / 活跃数据库），自动取消勾选并写明理由 |
| 残留页「让 AI 帮我判断」 | 从孤儿残留里挑出**能放心删**的项，自动勾选并写明理由 |
| 进程页「AI 判断后果」 | 判断结束该进程会怎样——会不会丢未保存的工作、会不会让某个 GUI 应用崩溃，给出高 / 中 / 低风险 |

**纯 AI，不兜底。** 没配模型或调用失败就如实告诉你「这次没用上 AI」，绝不拿本地规则编一个结论糊弄你。

`/remember <你的偏好>` 可以存长期记忆，比如「JetBrains 的索引别动」——跨 `/new`、跨重启都保留。

## AI 工具残留专清

内置 15+ 款主流 AI 编程助手、ML 框架与编辑器的残留知识：Claude Code、Cursor、Windsurf、Cody、Continue、Aider、Tabnine、Amazon Q、Copilot、Zed、Ollama、LM Studio、Hugging Face、PyTorch、VS Code、JetBrains、Xcode 等。

它不光认得这些工具的数据在哪，还知道 **Ollama 模型一个 2–50 GB、Hugging Face 模型动辄上百 GB**——删之前就标好风险。

## 安全设计

- **用户数据走废纸篓**：聊天记录、配置、账号等可恢复；缓存和系统文件确认后直接删除
- **AI 没有通用权限**：Agent 只能调用 11 个预定义技能，其中 8 个只读，其余只生成计划或登记待你查看的条目——不能执行任意命令、不能读任意文件
- **执行前必确认**：每次删除都要确认，不做静默操作
- **系统保护**：关键系统进程和路径在白名单里，永远不会被删
- **数据不出本机（非AI 部分）**：扫描与清理完全在本机完成；使用 AI 时清单上下文发往你配置的模型服务商（用自己的 Key）

## 安装

下载 `AIMacCleaner-<版本>.dmg` 与同名 `.sha256`，先校验：

```bash
shasum -a 256 -c AIMacCleaner-<版本>.dmg.sha256   # 应输出 OK
```
打开 DMG 拖到「应用程序」。首次启动：**右键 → 打开**（未签名应用必需）。

从源码构建：

```bash
git clone https://github.com/hwd8080-ai/AIMacCleaner.git
cd AIMacCleaner
./build_app.sh                       # → /Applications/AIMacCleaner.app
```

## 配置 AI 模型

设置 → 配置 AI 模型，填你自己的 API Key。支持 OpenAI 兼容与 Anthropic 兼容两种协议（官方、本地代理、第三方中转都行，baseURL 可改），可配多套模型随时切换。密钥只存在本机 `UserDefaults`。

## 系统要求

macOS 14 (Sonoma) 及以上，Intel 与 Apple Silicon 均支持。

## 许可

MIT © AI Mac Cleaner 贡献者。「AI Mac Cleaner」名称、Logo 与图标为项目商标，不在 MIT 授权范围内——fork 请改名、去 logo。
