# AI Mac Cleaner

**macOS 深度卸载工具**——不只是删 `.app`，连依赖和痕迹一起拔干净。

[English](README.md) | **简体中文**

免费、开源、彻底。卸载任何 Mac 应用的同时，扫清它留下的所有痕迹：Homebrew 公式、npm/pipx 包、沙箱容器、launch agent、shell 配置污染、点文件、缓存……16 类扫描器，一次覆盖。

**用户数据进废纸篓**（聊天记录、配置、账号等，可找回），缓存和系统文件直接删除。

> **系统要求：** macOS 14 (Sonoma) 及以上。支持 Intel 和 Apple Silicon。[为什么需要 macOS 14？](#系统要求)

![AI Mac Cleaner 主界面](screenshots/mainCN.png)

---

## 功能

### 🧹 深度卸载
选中一个应用，AI Mac Cleaner 找出和它有关的一切。不只是 `.app` 包体——依赖、偏好设置、缓存、日志、容器、包管理器安装的 CLI 工具，全部列出。确认一次，全部清掉。

![深度卸载](screenshots/uninstallCN.png)

### 🔍 孤儿残留扫描
几个月前删掉的应用，数据往往还留在 `~/Library` 里。孤儿扫描反向查找：哪些目录已经没有活着的 app 认领？找出你根本不知道还存在的残留。

![孤儿扫描](screenshots/orphansCN.png)

### 🤖 AI Agent（问 AI）
用自然语言描述目标——「把 Cursor 彻底卸干净」或「扫一遍所有残留」——内置 AI Agent 会自己调用相应 skill、查看结果、出计划。**任何删除操作都要你确认后才执行。**

![AI Agent](screenshots/agentCN.png)

#### 配置模型
打开 ⚙ **设置 → 配置 AI 模型**，填入 API Key。支持 OpenAI、Anthropic 及兼容服务商。支持多个模型档，在问 AI 工具栏随时切换。

![模型配置](screenshots/model-configCN.png)

#### 斜杠命令
在输入框输入 `/` 查看可用命令：

| 命令 | 功能 |
|------|------|
| `/new` | 开始新会话（清空对话历史） |
| `/reset` | 重置 Agent 上下文 |
| `/remember` | 记下一件事，`/new` 和重启都不会丢 |

![斜杠命令](screenshots/slash-commandsCN.png)

#### AI 判断后果（进程）
勾选一个或多个进程，点 **AI 判断后果**——Agent 判断结束各个进程的后果。低风险的自动勾选，其余取消勾选并写明理由。

![AI 判断后果](screenshots/ai-consequenceCN.png)

#### AI 复核（应用 / 残留）
在应用或残留页点 **让 AI 复核** / **让 AI 帮我判断**。Agent 逐项检查你的清理清单，自动取消勾选建议保留的项（登录态、共享数据、凭证），并在对应行下写明理由。

![AI 复核](screenshots/ai-reviewCN.png)

### 🖥️ 进程管理
列出 Mac 上所有后台服务类进程——node 服务、Python 脚本、Docker 容器、Brew service。显示内存占用、CPU%、**监听端口**（如 `:3000`、`:8080`）。按端口号搜索，精确找到占用端口的进程，一键结束。

![进程管理](screenshots/processesCN.png)

### 🛡️ 安全设计
- **用户数据走废纸篓。** 聊天记录、配置、账号等可恢复。缓存和系统文件确认后直接删除。
- **没有通用 shell。** AI Agent 只能调用预定义的只读 skill，不能执行任意命令、不能读任意文件、不能联网。
- **执行前必确认。** 每次删除操作都要确认，不做静默操作。
- **系统保护。** 关键系统进程和路径在白名单里，永远不会被删。
- **数据不出本机。** 所有处理本地完成，不做任何网络请求。

---

## 安装

### 下载 DMG（推荐）

从 [Releases](https://github.com/hwd8080-ai/AIMacCleaner/releases) 下载 `AI Mac Cleaner-<版本>.dmg` 和同名 `.sha256`。先校验：

```bash
shasum -a 256 -c AI Mac Cleaner-<版本>.dmg.sha256   # 应输出 OK
```

打开 DMG，把 AI Mac Cleaner 拖到 Applications。首次启动：**右键 → 打开**。

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
.build/release/ai-mac-cleaner --scan 微信       # 扫描某个应用
.build/release/ai-mac-cleaner --self-test       # 跑自检
.build/release/ai-mac-cleaner --skills          # 列出 Agent 能调用的 skill
```

---

## 扫描范围

AI Mac Cleaner 覆盖 16 类残留：

| 类别 | 扫描内容 |
|------|---------|
| `.app` 包体 | 已安装的应用 |
| Homebrew | formula、cask、tap |
| npm / pipx | 全局安装的包 |
| 沙箱容器 | `~/Library/Containers` 数据 |
| Launch Agent | `~/Library/LaunchAgents` plist |
| Shell 配置 | `.zshrc`、`.bashrc`、`.fish` 写入 |
| 点文件/配置 | `.cursor`、`.claude` 等隐藏目录 |
| 缓存 | `~/Library/Caches` |
| 偏好设置 | `~/Library/Preferences` plist |
| 日志 | `~/Library/Logs` |
| 认证令牌 | Keychain 相关的凭证文件 |
| AI 工具数据 | Claude Code、Cursor、Windsurf、Copilot 等 20+ 工具 |
| 孤儿残留 | 无主 `~/Library` 子目录 |
| XDG 目录 | `~/.config`、`~/.local/share` |
| MAS 回执 | Mac App Store 安装记录 |
| Application Support | `~/Library/Application Support` |

---

## AI Agent 可调用的 Skill

内置 7 个 skill：

| Skill | 功能 |
|-------|------|
| `list_apps` | 列出所有已安装应用 |
| `scan_app` | 深度扫描指定应用 |
| `scan_leftovers` | 扫描孤儿残留和 AI 工具数据 |
| `list_processes` | 列出运行中的后台进程 |
| `review_plan` | 复核待执行的卸载计划 |
| `plan_uninstall` | 生成卸载计划待确认 |
| `show_history` | 查看历史卸载记录 |

所有 skill 默认只读。Agent 出计划，你确认后才执行。

---

## 常见问题

**安全吗？** 安全。用户数据（聊天记录、配置、账号）进废纸篓可找回；缓存和系统文件确认后直接删除。系统路径受保护，每次删除都要确认。

**会上传数据吗？** 不会。无埋点、无遥测、无网络请求。全部本地处理。

**和 AppCleaner / CleanMyMac 比呢？** 那些是闭源的，有的是付费软件。AI Mac Cleaner 开源免费，且集成了包管理器清理、孤儿扫描、AI 辅助、进程管理于一体。

**可以再分发吗？** 可以。MIT 协议，见 [LICENSE](LICENSE)。

---

## 系统要求

| 要求 | 最低配置 |
|------|---------|
| macOS | **14.0 (Sonoma)** 及以上 |
| 架构 | Intel (x86-64) 或 Apple Silicon (arm64) |
| 磁盘 | 约 25 MB 安装空间 |

> **为什么需要 macOS 14？** AI Mac Cleaner 使用了 Sonoma 引入的 SwiftUI API——`.onKeyPress` 处理键盘输入（回车发送/方向键导航/Tab 补全），以及新版 `.onChange(of:)` 闭包语法。降级到 macOS 13 需要替换这些 API，对小型项目维护成本过高。Sonoma 于 2023 年发布，覆盖了 2018 年及以后的所有 Mac。

---

## 协议

MIT © AI Mac Cleaner 贡献者
