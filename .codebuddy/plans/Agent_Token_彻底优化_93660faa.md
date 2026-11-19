---
name: Agent Token 彻底优化
overview: 针对「问 AI」Agent 的 token 浪费问题，按 OpenClaw 官方 token 文档的做法系统性改造：skill 按需加载、上下文压缩、稳定前缀与 prompt cache、工具结果预算、token 用量可视化，保持现有功能与 CLI 兼容并补齐自检。
todos:
  - id: audit-call-sites
    content: Use [subagent:code-explorer] to audit all call sites of manifest, systemPrompt, AgentRun and AIMessage initializers
    status: completed
  - id: lazy-skill-catalog
    content: Add describe_skill meta-skill, compact catalog, prompt instructions and CLI/self-test count updates
    status: completed
    dependencies:
      - audit-call-sites
  - id: context-compaction
    content: Implement deterministic transcript and chat-history compaction with hard observation budget
    status: completed
    dependencies:
      - lazy-skill-catalog
  - id: prompt-cache
    content: Split stable system prompt from runtime notes; add domain-gated prompt cache with 400 fallback
    status: completed
    dependencies:
      - context-compaction
  - id: token-usage-ui
    content: Parse and accumulate token usage across protocols; persist on AIMessage and show bubble footer
    status: completed
    dependencies:
      - context-compaction
  - id: verify-deliver
    content: Add self-tests, run full suite and build_app.sh, smoke-test CLI and package
    status: completed
    dependencies:
      - lazy-skill-catalog
      - context-compaction
      - prompt-cache
      - token-usage-ui
---

## 产品需求

对「问 AI」Agent 做一次系统性 token 优化，彻底解决「思考太费 token」。用户已明确采纳上一轮提出的全部五项改造，要求「认真计划、彻底改到完美」。

## 核心功能

- Skill 按需加载：system prompt 只保留全部 skill 的极简目录（名称 + 一句话摘要），完整参数说明只在模型主动请求时按需注入，不再每轮全量内联 13 个 skill 的 manifest。
- 上下文压缩：单次 Agent 运行内只保留最近工具结果的完整观测，早期结果折叠成确定性摘要；跨对话历史在保留现有 15 轮裁剪的基础上进一步降低重复发送量，且摘要过程不额外计费（不做额外模型调用）。
- 稳定前缀与 prompt cache：把每轮变化的内容（剩余轮数提示、本机应用名单）从 system prompt 中剥离，改为放在末条用户消息里，使 system prompt 在一次运行的多轮之间字节级稳定；只对官方 OpenAI/Anthropic 域名尝试 prompt cache 字段，第三方兼容端点保持原样，遇到 400 自动去掉缓存参数重试。
- 工具结果预算：沿用并强化现有 1600 字符截断，给单次运行的总观测预算设硬上限，防止多轮累积把上下文撑大。
- token 用量可视化：每条 AI 回答气泡底部展示本次运行累计的输入/输出 token（以及缓存命中，端点返回时），让用户能直接看到消耗与优化效果。
- 必须具备的约束：不安装 OpenClaw 到用户机器（已通过官方文档完成研究）；保持现有全部功能、CLI 入口、skill 白名单安全边界与 236 项自检全部通过；不主动开启模型 thinking、不把思考文本回喂下一轮（沿用现有正确做法）。

## 技术栈与约束

- 现有项目：Swift 6 / SwiftPM 单包结构，macOS 原生 SwiftUI，手写 `build_app.sh` 打包到 `/Applications/AIMacCleaner.app`，无第三方依赖。
- 不新增依赖、不引入新架构；所有新增逻辑沿用现有纯函数 + `SelfTest` 可测风格（`ChatPolicy`、`LLMBrain` 的静态纯函数、逐项 Check 断言）。
- 兼容 OpenAI 兼容与 Anthropic 兼容两套协议、流式与非流式降级路径、多模型配置档；CLI 与 GUI 共用同一套 `SkillRegistry` 白名单。

## 实施策略与关键决策

1. **Skill 按需加载（最大收益点）**

- 在 `SkillRegistry` 新增一个元 skill `describe_skill`（参数 `name`），`invoke` 返回目标 skill 的完整声明（参数、必填项、风险等级、CLI）。它像其他 skill 一样走白名单、`SkillSpec.validate`、`CLIAgent.runSkill`，不引入模型直连执行通道。
- `LLMBrain.systemPrompt` 中把 `SkillRegistry.manifest` 换成紧凑目录（只含名字 + `summary`，可用 `SkillRegistry.briefCatalog` 新属性生成），并明确告知模型「需要某个 skill 的参数时用 describe_skill 获取」。
- `AgentRuntime` 的 skill 执行循环不变：元 skill 也从模型输出的 `expunge` 代码块发起，经同样的白名单解析与校验后执行；其观测结果作为下一轮上下文，模型据此填正确参数。
- 同步更新 CLI：`--skill describe_skill --args '{"name":"scan_app"}'` 可用；`--help`/usage 与 `SelfTest` 中「13 个 skill / 每个 cli 对应真实 flag」的断言一起改为 14 个并加入新 flag。`AIModelSettingsSheet` 里写死的 13 处若存在也要同步（以实际搜索为准）。

2. **上下文压缩（不额外计费）**

- 在 `AgentRuntime`/`LLMBrain` 增加纯函数 `ContextBudget`：对 `transcript` 按条目计算加权字符估算（中文按更保守权重，参考 OpenClaw 对 CJK 的加权思路），保留最近 2 条观测的完整内容（仍按现有 1600 字符截断），更早的条目折叠为一行确定性摘要：`skill 名 + ok/failed + result.summary 前 120 字符`，并标注「摘要，详情已折叠」。压缩结果替换 `observationBlock` 的输入，不再逐轮重发全部旧观测。
- 对话历史侧：`ChatPolicy.modelHistory` 保持不变（锚点、system 过滤、首轮 user 的既有语义都不能动）；新增可选纯函数 `historyDigest(_:)`：对锚点之后、15 轮窗口内、但超过最近 N 轮的旧消息生成一段不超过 800 字符的要点摘要，附在 messages 最前面作为一条 user 消息；摘要同样确定性生成，不调用模型。若历史未超阈值直接返回空。
- 明确不做的：不实现 `/compact` 那种付费模型摘要、不做向量库、不缓存跨会话内容（YAGNI，且用户要求不增加调用成本）。

3. **稳定前缀与 prompt cache**

- `LLMBrain.systemPrompt` 拆成 `stableSystem`（固定指令 + 紧凑 skill 目录 + 长期记忆，同一次运行内不变）和 `runtimeNote`（budgetNote + installedAppsNote）。`decide` 构造 messages 时把 `runtimeNote` 作为最后一条 user 消息的内容前缀（与 goal/观测合并），使 system 在一次 run 的 8 轮里字节稳定。
- `LLMStream` 与 `LLMClient` 新增 best-effort 缓存支持：仅当 `config.effectiveBaseURL` 的 host 精确等于 `api.openai.com` 或 `api.anthropic.com` 时，按各协议官方格式附加 cache 控制（OpenAI 系按官方当前支持的字段，Anthropic 用 `cache_control: ephemeral` 的 system block 形式）；第三方网关/本地代理一律不加未知字段。任何 400 响应自动剔除缓存字段重试一次，保证兼容端点不会因缓存参数挂掉。
- 实施前用联网搜索确认两家当前官方缓存字段名，不凭记忆猜；若某家字段不稳定，则该家只做稳定前缀、不加显式字段。

4. **token 用量可视化**

- 新增轻量结构 `TokenUsage`（`inputTokens`、`outputTokens`、`cacheReadTokens`、`cacheWriteTokens`，全部可选默认 0，遵循项目「新增字段 decodeIfPresent 兜底」惯例），定义在 `Models` 层。
- `LLMStream.Result` 增加 `usage`；解析 SSE 末帧的 `usage`（OpenAI 在最后一个 choice 之后、Anthropic 在 `message_delta`/`message_start` 事件）与一次性 JSON 的 `usage`，两套字段都归一化（参考 OpenClaw 的归一化做法），解析失败返回 0 而不是抛错。
- `AgentRun` 增加 `usage`，每次 `decide` 成功后累加；`AIMessage` 增加 `usage: TokenUsage?` 字段（同步 `CodingKeys` 与手写解码兜底），`AskAIView` 落盘 AI 回复时写入；`MessageBubble` 底部用一行小字展示「输入 X / 输出 Y token（缓存命中 Z）」，无数据时整行不显示。
- CLI 的 `run` 路径不需要 UI，但 `AgentRun.usage` 仍填充，便于自检断言。

5. **验证、回归与交付**

- `SelfTest.swift` 新增分组断言：紧凑目录显著短于旧 manifest、describe_skill 只暴露声明且风险为 readOnly、白名单仍拒绝 `rm`/`shell`、上下文摘要保留最近观测且折叠旧观测、stableSystem 在同 goal 的多轮间不变、token 解析覆盖两套协议样本（含缺失 usage 的容错）、AIMessage 新增字段的旧 JSON 解码不丢历史。
- 跑 `./build_app.sh`；`--self-test` 全绿（原 236 项 + 新增项）；用现有 `--agent`/`--skill describe_skill` 做 CLI 冒烟；确认 `--skills` 数量与说明一致、AskAI 流式与降级路径不变。
- 由于近期 GitHub push 多次超时，推送失败时按既有做法用 `git -c http.version=HTTP/1.1 push` 重试。

## 复杂度与瓶颈

- system prompt 从 O(全部 skill 详情) 降为 O(skill 数量 × 一行摘要)；按需加载只在需要时多一次极小的 skill 声明获取（本地确定性生成，不消耗 token）。
- 单次运行的请求体从「每轮重发完整 transcript」降为「最近观测 + 旧摘要」；`ChatPolicy` 历史摘要避免 15 轮原文逐轮重发。复杂度仍受 maxTurns=8 限制，可控。
- 缓存字段严格域名白名单 + 400 回退，避免兼容端点大面积故障。

## 关键文件（修改目标）

- `Sources/AIMacCleaner/Agent/SkillRegistry.swift`：紧凑目录、describe_skill 注册与解析。
- `Sources/AIMacCleaner/Agent/Skill.swift`：skill 声明的按需详情输出（复用 `manifestLine`、`spec` 字段，不破坏现有格式）。
- `Sources/AIMacCleaner/Agent/AgentRuntime.swift`：system prompt 拆分、上下文压缩、`AgentRun.usage`、transcript 观测预算。
- `Sources/AIMacCleaner/Models/ChatPolicy.swift`：历史摘要纯函数（不动 trim/afterAnchor/modelHistory 语义）。
- `Sources/AIMacCleaner/Services/LLMStream.swift`、`Sources/AIMacCleaner/Models/LLMClient.swift`：请求构造的缓存支持与 400 回退、usage 解析。
- `Sources/AIMacCleaner/Models/TokenUsage.swift`：新增，共享用量结构（文件名以实际实现为准）。
- `Sources/AIMacCleaner/Models/ChatMessage.swift`：AIMessage 新字段与兼容解码。
- `Sources/AIMacCleaner/UI/AskAIView.swift`：写入 usage、气泡底部展示一行。
- `Sources/AIMacCleaner/AIMacCleanerApp.swift`：CLI usage 文本和 skill 数量说明更新（如硬编码）。
- `Sources/AIMacCleaner/SelfTest.swift`：新增上述全部断言。
- 如调用点搜索发现其他引用 `SkillRegistry.manifest`、`systemPrompt`、`AgentRun` 构造的位置，逐一更新；不改动无关扫描器/删除逻辑。

## SubAgent

- **code-explorer**
- Purpose: 实现前用一次 medium 彻底度的只读排查，列出 `SkillRegistry.manifest`、`LLMBrain.systemPrompt`、`AgentRun`、`AIMessage` 构造与 CLI 数量文案的全部调用点，确认没有遗漏。
- Expected outcome: 输出完整文件:行号清单，避免新增字段/拆分 prompt 后出现编译遗漏或语义回退。