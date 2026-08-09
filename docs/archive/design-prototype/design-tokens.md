# AI Mac Cleaner — 设计系统选型 & 设计令牌（Design Tokens）

> 设计系统专家：彩格调（Cai） · 设计原型专家团
> 版本 v1.0 · 关联：`requirement-summary.md`
> 产品：AI Mac Cleaner v1.4.0 — macOS 深度卸载工具（Swift / SwiftUI，MIT 开源）
> 交付定位：**高保真 HTML/CSS 视觉原型的唯一样式源**，同时作为 SwiftUI 实现蓝图

---

## 0. 候选设计系统与最终选型

### 0.1 候选对比（从 71 套内置系统精选 3 套）

| 方案 | 设计系统 | 匹配度 | 核心特征 | 契合理由（一句话） |
|------|---------|--------|---------|------------------|
| **A ★最推荐** | **Linear（Light Mode）** | ★★★★★ | 窄 sidebar + 密集列表行 + 分组折叠 + pill 徽章 + 1px 极细边框 + 近乎无色的中性灰阶 | 它的组件语汇与 AI Mac Cleaner 的界面结构几乎 1:1 对应（Tab 侧栏／可勾选列表／可折叠分组／风险徽章／上下文工具栏），且"极浅底 + 发丝线 + 唯一强调色"的克制体系天然产出"精密仪器"气质。 |
| B | **Stripe** | ★★★★☆ | 浅色通透、大留白、柔和多层阴影、机器数据用等宽字、极强的"金额诚实呈现"传统 | 它是"可信"的视觉母语——把「移到废纸篓 N 项（X）／清空废纸篓后才真正释放空间」这种严谨报账式表述做得优雅不吓人，正对上 AI Mac Cleaner 的产品灵魂。 |
| C | **Apple（macOS HIG 语汇）** | ★★★★☆ | SF 字体、毛玻璃材质、原生控件尺寸（28px 按钮 / 13px 正文）、系统语义色 | 保证原型 → SwiftUI 落地零摩擦、观感"就是一个 Mac App"，但单独使用差异化不足，更适合作为地基而非主视觉。 |

**未入选说明（避免误判）**：Vercel / Cursor / Warp / Raycast 均偏暗色或纯黑白，与 Q1「明亮通透」冲突或缺少可信强调色载体；Notion / Figma 过于柔和消费级；IBM Carbon 精密但企业感偏冷、直角风格与 macOS 圆角语言不符。

### 0.2 最终配方（Recipe）

> **Linear（Light）为骨 · Stripe 为魂 · Apple HIG 为地**

- **骨（Linear）**：信息架构、组件形态、边框/分隔线策略、中性灰阶、徽章与列表行密度。
- **魂（Stripe）**：留白呼吸感与柔和层叠阴影，用来"松开"Linear 的紧凑感 → 满足用户要的「大留白 / 大气」；以及确认弹窗的诚实报账排版。
- **地（Apple HIG）**：字体栈（SF）、控件尺寸、毛玻璃材质、窗口 chrome、focus ring 行为 → 保证原生质感与 SwiftUI 可实现性。

---

## 1. Visual Theme（视觉主题）

**Philosophy**：一台**值得信任的精密仪器**——它先让你看清，再让你动手；每一个数字都诚实，每一次删除都可撤回。
**Direction**：light · premium minimal · precision-utility · airy-dense（留白宽裕但信息完整）
**Personality**：克制、精确、冷静、可靠、不制造焦虑
**Reference**：Linear 的列表与分组 × Stripe 的数据诚实感 × macOS Ventura/Sonoma 原生窗口材质

**三条不可动摇的视觉原则**
1. **色彩即语义**：界面上出现的每一处彩色都必须有含义（强调 / 用户数据 / 不确定 / 安全 / 危险 / 成功）。禁止装饰性用色。
2. **可恢复 ≠ 危险**：「移到废纸篓」是可恢复操作 → 使用 **accent 蓝**而非红色，红色只留给不可恢复动作（清空历史等）。这是安全模型在视觉层的直接表达。
3. **机器数据用等宽**：路径、bundle id、体积、计数一律 mono + `tabular-nums`，让"精密"可被眼睛验证。

---

## 2. Color Palette（调色板）

### 2.1 品牌强调色提案 — AI Mac Cleaner Petrol Blue

| Token | HEX | HSL | 对比度(白底) | 说明 |
|-------|-----|-----|------------|------|
| **--color-accent** | **`#0E6C9E`** | hsl(201, 84%, 34%) | **5.74:1 ✅ AA** | 主强调色 |
| --color-accent-hover | `#0B5D88` | hsl(201, 85%, 29%) | 6.84:1 ✅ | hover |
| --color-accent-active | `#094E73` | hsl(201, 85%, 24%) | 8.2:1 ✅ | pressed |
| --color-accent-text | `#0B5D88` | — | 6.84:1 ✅ | 强调色作文字/链接时用（更深，保 AA） |
| --color-accent-subtle | `#E7F1F7` | — | — | 选中行 / sidebar 选中态底色 |
| --color-accent-border | `#BBD8E8` | — | — | 强调色描边 |
| --color-accent-on | `#FFFFFF` | — | 5.74:1 ✅ | 强调色填充上的文字 |

**为什么选它（沉静蓝 · 微偏青，色相 201°）**

1. **"青蓝"= 精密仪器色**。比 macOS 系统蓝（#007AFF，~211°）更深、更沉、更少消费级气息，接近蓝图/量具/实验器材的色感，直接服务"14 扫描器 + 16 类痕迹"的技术可信度。
2. **与风险语义色最大色相距离**。橙(≈28°)／黄(≈45°)／红(≈4°)全部集中在暖端，201° 位于色轮正对面，任何情况下都不会与"用户数据 / 不确定 / 危险"发生语义串扰；灰(#8A8A8E)无彩度更不冲突。
3. **可恢复动作的正确情绪**。主操作是「移到废纸篓」——需要**冷静确信**而非警报感，冷色调是唯一正确答案；琥珀直接与橙黄风险色冲突（**已排除**），纯青(≈185°)偏医疗/薄荷、在白底上对比度不足。
4. **通过 WCAG AA**：白底 5.74:1、白字于其上 5.74:1，正文与按钮标签双向达标；`accent-text` 变体 6.84:1 用于纯文字场景。
5. **SwiftUI 落地简单**：`Color(red: 0.055, green: 0.424, blue: 0.620)`，可直接注册为 Asset Catalog 的 `AccentColor`。

### 2.2 中性色（Light / macOS 原生质感）

| Token | HEX / 值 | 用途 |
|-------|---------|------|
| --color-window-bg | `#FFFFFF` | 窗口 / detail 内容区底 |
| --color-titlebar-bg | `rgba(250,250,252,0.72)` + blur | 标题栏（毛玻璃） |
| --color-sidebar-bg | `rgba(244,244,247,0.78)` + blur | 左侧 3-Tab sidebar（vibrancy） |
| --color-canvas | `#F7F7F9` | 次级面板（扫描 Tab 左栏 app 列表） |
| --color-surface | `#FFFFFF` | 卡片 / 分组容器 |
| --color-surface-hover | `#F5F5F7` | 列表行 hover |
| --color-surface-sunken | `#FAFAFB` | inset 区域（分组表头、路径滚动列表） |
| --color-divider | `#E9E9ED` | 常规分隔线 |
| --color-divider-hairline | `rgba(0,0,0,0.07)` | 1px 发丝线（sidebar / toolbar 边界） |
| --color-border | `#D2D2D7` | 控件描边（次级按钮、输入框） |
| --color-text-primary | `#16171A` | 标题、主文本（18.3:1） |
| --color-text-secondary | `#5F6169` | 次要文本、副标题（6.35:1 ✅） |
| --color-text-tertiary | `#74767E` | 元信息、placeholder（4.53:1 ✅ AA 下限） |
| --color-text-quaternary | `#A1A3AB` | 禁用态 / 纯装饰（**不得承载信息**） |

### 2.3 风险语义色（🔒 语义锁定，不可更改含义）

> 每个风险等级提供 4 个变体：`base`（图标/圆点）、`text`（文字，AA 达标）、`bg`（徽章底）、`border`（徽章描边）。
> base 值保留主理人指定色，text 为其加深版——**色相不变，仅降明度以满足可读性**。

| 风险等级 | base | text | bg | border | 对比度(text on bg) |
|---------|------|------|----|--------|-----------------|
| **用户数据（橙）** | `#E8833A` | `#A8560F` | `#FDF0E4` | `#F3D3B0` | 4.76:1 ✅ |
| **不确定（黄）** | `#E0B53A` | `#8A6516` | `#FBF3DC` | `#EDDCA6` | 4.79:1 ✅ |
| **安全（灰）** | `#8A8A8E` | `#5C5C61` | `#F1F1F3` | `#DEDEE2` | 6.07:1 ✅ |

### 2.4 系统语义色

| Token | HEX | 变体 | 用途 |
|-------|-----|------|------|
| --color-destructive | `#C8372F` | hover `#B02D26` / bg `#FCEDEB` / border `#F0C4BF` | **仅限不可恢复操作**：清空历史、永久删除 |
| --color-success | `#1A7A54` | bg `#E9F6F0` / border `#B9E2D0` | ResultSheet 全成功、成功计数 |
| --color-warning | `#E8833A` | text `#A8560F` / bg `#FDF0E4` / border `#F3D3B0` | 确认弹窗警告标题、残留 Tab 免责横幅（**与"用户数据橙"同源，语义一致：需要人类判断**） |
| --color-info | `#0E6C9E` | = accent | 提示信息 |

---

## 3. Typography（排版）

### 3.1 字体栈

```css
--font-ui: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display",
           "Helvetica Neue", "PingFang SC", system-ui, sans-serif;
--font-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas,
             "JetBrains Mono", "Liberation Mono", monospace;
```

### 3.2 字阶（以 macOS 13px 正文基准，非网页 16px）

| Level | Size | Weight | Line-height | Letter-spacing | 用途 |
|-------|------|--------|-------------|----------------|------|
| title | 20px | 600 | 1.25 | -0.012em | Tab 页大标题（扫描/残留/历史） |
| title-2 | 17px | 600 | 1.3 | -0.008em | 结果态 app 名、空状态主标题 |
| headline | 15px | 600 | 1.32 | -0.005em | 弹窗标题、分区标题 |
| subheadline | 13px | 600 | 1.38 | 0 | 分组名、列表小标题 |
| body | 13px | 400 | 1.45 | 0 | 默认 UI 文本、列表主文本 |
| label | 12px | 500 | 1.35 | 0 | 按钮文字、工具栏、表头 |
| caption | 11px | 400 | 1.35 | 0.002em | 计数页脚、版本号、时间戳 |
| badge | 10px | 600 | 1 | 0.01em | 风险 pill 文字 |
| mono-path | 12px | 400 | 1.5 | -0.004em | 文件路径、bundle id（`font-variant-ligatures: none`） |
| mono-num | 12px | 500 | 1.4 | 0 | 体积、项数（`font-variant-numeric: tabular-nums`） |
| mono-log | 11.5px | 400 | 1.55 | 0 | ResultSheet 日志 |

**排版铁律**
- 所有数字（体积、计数、百分比）必须 `font-variant-numeric: tabular-nums`，避免滚动时跳动。
- 路径长文本使用**中段省略**（`…` 在中间，保留头部 `/Users/…` 与尾部文件名），不要尾部截断。
- 中英混排时给中文块加 `letter-spacing: 0.01em`，SF 与苹方混排更稳。

---

## 4. Spacing / Layout（间距与布局）

### 4.1 8px 网格

| Token | 值 | 用途 |
|-------|----|------|
| --space-0 | 0 | — |
| --space-1 | 2px | 图标与文字微调 |
| --space-2 | 4px | pill 内部间隙、图标间距 |
| --space-3 | 6px | 紧凑内边距 |
| --space-4 | 8px | **基础单位**：按钮间距、列表行内间隙 |
| --space-5 | 12px | 列表行左右 padding、卡片内 padding |
| --space-6 | 16px | 分组间距、面板 padding |
| --space-7 | 20px | 弹窗内边距 |
| --space-8 | 24px | 内容区主 padding、分区间距 |
| --space-10 | 32px | 大分区间隔 |
| --space-12 | 40px | 空状态上下留白 |
| --space-16 | 64px | 空状态垂直居中区 |

### 4.2 布局尺寸

| Token | 值 | 说明 |
|-------|----|------|
| --window-min-w / --window-min-h | 880px / 560px | 最小窗口 |
| --titlebar-h | 38px | 标题栏 |
| --sidebar-w | 116px | 3-Tab 侧栏（区间 100–140，取中偏窄） |
| --applist-w | 268px | 扫描 Tab 左栏 app 列表 |
| --toolbar-h | 52px | Tab 顶部工具栏（标题+副标题+操作） |
| --row-h | 32px | 单行列表项 |
| --row-h-2l | 44px | 双行列表项（app 名 + 版本/文件名） |
| --group-header-h | 36px | 分组表头 |
| --footer-h | 28px | 计数页脚 |
| --content-pad | 24px | detail 区内容 padding |

---

## 5. Radius（圆角）

| Token | 值 | 用途 |
|-------|----|------|
| --radius-xs | 4px | 勾选框、微标签 |
| --radius-sm | 6px | **按钮、输入框、搜索框**（macOS 标准控件） |
| --radius-md | 8px | 列表行 hover 高亮、sidebar Tab 项、免责横幅 |
| --radius-lg | 10px | **分组卡片 / 容器卡片** |
| --radius-xl | 12px | **弹窗 Sheet 容器** |
| --radius-window | 10px | 窗口外框 |
| --radius-pill | 999px | 风险徽章、meta chip、Toggle 轨道 |

---

## 6. Depth & Elevation（阴影与层级）

| Token | 值 | 用途 |
|-------|----|------|
| --shadow-hairline-b | `inset 0 -1px 0 rgba(0,0,0,0.07)` | 工具栏底边（替代 border，不占布局） |
| --shadow-hairline-r | `inset -1px 0 0 rgba(0,0,0,0.07)` | sidebar 右边界 |
| --shadow-card | `0 1px 2px rgba(16,18,27,0.04), 0 1px 1px rgba(16,18,27,0.03)` | 分组卡片微浮起 |
| --shadow-raised | `0 2px 6px rgba(16,18,27,0.06), 0 1px 2px rgba(16,18,27,0.04)` | hover 卡片、主按钮 |
| --shadow-popover | `0 8px 24px rgba(16,18,27,0.12), 0 2px 6px rgba(16,18,27,0.06)` | 候选切换条、下拉 |
| --shadow-sheet | `0 24px 64px rgba(16,18,27,0.22), 0 8px 20px rgba(16,18,27,0.12)` | ConfirmSheet / ResultSheet |
| --shadow-window | `0 30px 80px rgba(16,18,27,0.28), 0 0 0 0.5px rgba(0,0,0,0.12)` | 原型窗口外框（含 0.5px 系统描边） |
| --overlay-scrim | `rgba(22,23,26,0.28)` | 弹窗遮罩（配 `backdrop-filter: blur(2px)`） |
| --blur-material | `saturate(180%) blur(30px)` | macOS 毛玻璃材质（sidebar / titlebar / sticky toolbar） |
| --focus-ring | `0 0 0 3px rgba(14,108,158,0.28)` | 键盘焦点环 |

**Z-index**：base 0 · sticky-toolbar 10 · dropdown 100 · popover 200 · scrim 300 · sheet 310 · toast 400

**动效**：`--ease: cubic-bezier(0.22, 0.61, 0.36, 1)`；hover 100ms · 展开/折叠 160ms · 弹窗进入 240ms（`scale(.96)→1` + opacity）。

---

## 7. Component Styles（组件规范）

### 7.1 Sidebar Tab 项（图标 + 文字，垂直堆叠）
- 尺寸：宽 `calc(100% - 16px)`，高 52px，margin 0 8px 4px，radius `--radius-md`
- 内容：SF Symbol 图标 18px（上）+ 11px/500 文字（下），gap 4px，居中
- 默认：图标 `--color-text-tertiary`，文字 `--color-text-secondary`
- hover：bg `rgba(0,0,0,0.04)`
- **选中**：bg `--color-accent-subtle`，图标 + 文字 `--color-accent-text`，图标 weight 由 regular → **semibold**（SF Symbol 变体），文字 600
- 窗口失焦：选中态 bg 降为 `#EDEDEF`，文字 `--color-text-secondary`

### 7.2 按钮
| 类型 | 高 | padding | radius | bg | 文字 | hover | 备注 |
|------|----|---------|--------|----|----- |-------|------|
| Primary（主操作 / 卸载 / 移到废纸篓） | 28px | 0 14px | 6px | `--color-accent` | #FFF 13px/600 | `--color-accent-hover` | 阴影 `--shadow-raised`；active 用 `--color-accent-active` + `translateY(0.5px)` |
| Prominent（空状态「开始扫描」大按钮） | 36px | 0 20px | 8px | `--color-accent` | #FFF 14px/600 | 同上 | 左侧 16px SF Symbol |
| Secondary（取消 / 次级） | 28px | 0 14px | 6px | `#FFFFFF` + 1px `--color-border` | `--color-text-primary` 13px/500 | bg `#F5F5F7` | — |
| Ghost（工具栏图标按钮） | 26px | 0 8px | 6px | transparent | `--color-text-secondary` | bg `rgba(0,0,0,0.05)` | 图标 14px |
| Destructive（清空历史 / 不可恢复） | 28px | 0 14px | 6px | `--color-destructive` | #FFF 13px/600 | `#B02D26` | **禁止用于「移到废纸篓」** |
| Destructive-quiet（删除选中） | 26px | 0 12px | 6px | transparent + 1px `--color-destructive-border` | `--color-destructive` 12px/500 | bg `--color-destructive-bg` | — |
| Disabled | — | — | — | `#EDEDEF` | `--color-text-quaternary` | 无 | `cursor: default` |

### 7.3 勾选框 Checkbox
- 14×14px，radius 4px，border 1px `#C6C7CC`，bg `#FFFFFF`
- checked：bg `--color-accent`，border 同色，白色对勾（stroke 1.8px，10px 尺寸）
- indeterminate（分组半选）：bg `--color-accent`，白色横杠 8×1.8px
- disabled：bg `#F1F1F3`，border `#E0E0E4`
- focus：`--focus-ring`
- 点击热区 ≥ 24×24（透明外扩）

### 7.4 Toggle 开关（全选开关）
- 轨道 38×22px radius pill；关：bg `#E3E3E7`；开：bg `--color-accent`
- 滑块 18px 白圆，`box-shadow: 0 1px 2px rgba(0,0,0,.18), 0 0 0 .5px rgba(0,0,0,.06)`，位移 16px，过渡 160ms `--ease`

### 7.5 分组卡片（16 类目 / 残留分组）
- 容器：bg `--color-surface`，border 1px `--color-divider`，radius `--radius-lg`，shadow `--shadow-card`，margin-bottom 12px，`overflow: hidden`
- 表头（36px）：bg `--color-surface-sunken`，border-bottom 1px `--color-divider`
  - 左起：展开箭头（SF `chevron.right` 10px `--color-text-tertiary`，展开时 `rotate(90deg)` 160ms）→ 8px → 分组 Checkbox → 8px → 分组名 12px/600 → （残留 Tab 追加所属 app 名 12px/400 `--color-text-secondary`）
  - 右侧：`N 项 · 12.4 MB` mono-num 11px `--color-text-tertiary`
- 折叠：`max-height` + `opacity` 过渡 160ms

### 7.6 列表行（残留项 / app 项 / 历史记录）
- 高 32px（单行）/ 44px（双行），padding 0 12px，radius `--radius-md`，行间 divider 1px `--color-divider` 从左 12px 内缩
- 结构：Checkbox → 8px → 主文本（路径 `mono-path`，中段省略，flex:1）→ 12px → 体积（`mono-num`，右对齐，`--color-text-secondary`，min-width 64px）→ 8px → 风险 pill
- hover：bg `--color-surface-hover`；选中：bg `--color-accent-subtle`
- 键盘焦点：`--focus-ring` inset

### 7.7 风险 Pill 徽章 🔒
- 高 18px，padding 0 7px 0 5px，radius pill，gap 4px，border 1px，字号 `badge`(10px/600)
- 图标 9px SF Symbol + 文字

| 等级 | 文字 | bg | text | border | 图标 |
|------|------|----|------|--------|------|
| 用户数据 | 用户数据 | `#FDF0E4` | `#A8560F` | `#F3D3B0` | `person.crop.circle.badge.exclamationmark` |
| 不确定 | 不确定 | `#FBF3DC` | `#8A6516` | `#EDDCA6` | `questionmark.circle` |
| 安全 | 安全 | `#F1F1F3` | `#5C5C61` | `#DEDEE2` | `checkmark.shield` |

> **禁止**仅用颜色区分风险——必须"颜色 + 图标 + 文字"三重编码（色觉障碍可达性）。

### 7.8 搜索框
- 高 26px，radius `--radius-sm`，bg `rgba(0,0,0,0.045)`，无 border
- 内：放大镜 12px `--color-text-tertiary` → 6px → input 13px；右侧 clear 按钮 12px（有值时出现）
- focus：bg `#FFFFFF`，border 1px `--color-accent`，`--focus-ring`

### 7.9 工具栏 / 页脚
- 工具栏：高 52px，padding 0 24px，bg `rgba(255,255,255,0.72)` + `--blur-material`，`--shadow-hairline-b`，sticky top 0
  - 左：标题 `title` + 副标题 `caption` `--color-text-secondary`（两行）
  - 右：统计 `mono-num` + 全选 Toggle + 操作按钮，gap 12px
- 页脚：高 28px，bg `--color-surface-sunken`，`caption` 居中或右对齐 `--color-text-tertiary`，上边 1px `--color-divider`

### 7.10 空状态
- 垂直水平居中，最大宽 380px
- 图标：72px 圆 bg `#F4F4F6`，内含 28px SF Symbol `--color-text-tertiary`（或 accent 12% 底 + accent 图标）
- 标题 `title-2` `--color-text-primary` → 8px → 说明 `body` `--color-text-secondary` 居中
- meta chips 行：`16 类痕迹` / `14 个扫描器` / `含沙箱容器` — 各为 pill（h 22px，padding 0 10px，bg `#F4F4F6`，`caption` `--color-text-tertiary`），gap 6px，上距 16px

### 7.11 扫描中状态
- 不确定进度条：高 3px，radius 2px，track `#E9E9ED`，fill `--color-accent` 宽 35% 往复扫描 1.4s ease-in-out infinite
- 文案：`Running 14 scanners…` `body` `--color-text-secondary`，当前扫描器名用 `mono-path` `--color-text-tertiary`

### 7.12 免责横幅（残留 Tab · 橙色）
- bg `--color-warning-bg`，border 1px `--color-warning-border`，radius `--radius-md`，padding 10px 12px，gap 8px
- 图标 `exclamationmark.triangle.fill` 14px `--color-warning`
- 标题 12px/600 `--color-warning-text` +（次行）说明 12px/1.5 `--color-warning-text` 85% 透明
- 文案要点：**启发式匹配，可能误判；默认全部不勾选，请逐项确认**

### 7.13 ConfirmSheet（确认弹窗 — 产品灵魂）
- 遮罩：`--overlay-scrim` + `backdrop-filter: blur(2px)`
- 容器：宽 520px，bg `#FFFFFF`，radius `--radius-xl`，shadow `--shadow-sheet`，`overflow: hidden`
- **Header**（padding 20px 24px 12px）：`exclamationmark.triangle.fill` 20px `--color-warning` + 标题 `headline` `--color-text-primary`
- **报账区**（padding 0 24px 12px）：`body` `--color-text-secondary`
  - 主句：`即将把 <b>N 项</b> 移到废纸篓（<b>X MB</b>）` — 数字用 `mono-num` + `--color-text-primary` 600
  - 补充句（**必须存在，措辞锁定**）：`清空废纸篓后才真正释放磁盘空间。` ← **严禁出现「释放 X MB」「立即释放」等措辞**
- **用户数据专项提醒**（当选中含用户数据项）：整块 bg `--color-warning-bg`，border 1px `--color-warning-border`，radius `--radius-md`，padding 10px 12px，`caption`→12px `--color-warning-text`
- **路径列表**：max-height 200px，bg `--color-surface-sunken`，border 1px `--color-divider`，radius `--radius-md`，内滚动
  - 行：padding 6px 10px，`mono-path` 11.5px，hover 显示右侧「复制」ghost 按钮（12px 图标）；行间 hairline
- **Footer**（padding 12px 24px 20px，右对齐，gap 8px，上边 1px `--color-divider`，bg `--color-surface-sunken`）
  - `取消`（Secondary） · `移到废纸篓`（**Primary accent**，左带 `trash` 图标 13px）— 蓝色而非红色，因为可恢复

### 7.14 ResultSheet（结果弹窗 · 三态）
- 容器：宽 460px，其余同上
- Header 带状态色淡底（padding 20px 24px）：

| 状态 | 图标 | 图标色 | Header bg | 标题 |
|------|------|--------|-----------|------|
| 全部失败 | `xmark.octagon.fill` | `--color-destructive` | `--color-destructive-bg` | 操作失败 |
| 部分完成 | `exclamationmark.triangle.fill` | `--color-warning` | `--color-warning-bg` | 部分完成 |
| 全部成功 | `checkmark.circle.fill` | `--color-success` | `--color-success-bg` | 已移到废纸篓 |

- 计数区：两个统计块并排 — `成功 N`（`--color-success`）/ `失败 M`（`--color-destructive`），数字 `title-2` mono `tabular-nums`
- 日志：max-height 180px，`mono-log`，bg `--color-surface-sunken`，右上角「复制全部日志」ghost 按钮
- Footer：`完成`（Primary）

### 7.15 窗口 Chrome（原型外壳）
- 外框 radius `--radius-window`，shadow `--shadow-window`
- 标题栏 38px：bg `--color-titlebar-bg` + `--blur-material`，`--shadow-hairline-b`
- 交通灯：3 × 12px 圆，gap 8px，左 20px，垂直居中 — `#FF5F57` / `#FEBC2E` / `#28C840`，各带 `inset 0 0 0 .5px rgba(0,0,0,.12)`

---

## 8. Responsive Behavior（自适应）

> 桌面 App，非网页断点，按**窗口宽度**适配。

| 窗口宽 | 行为 |
|-------|------|
| ≥ 1100px | 完整布局：sidebar 116 + app 列表 268 + 内容区自适应；内容区 padding 24px |
| 880–1100px | app 列表收窄至 232px；内容 padding 降至 16px；工具栏统计文字改为缩写（`3 组 · 12.4 MB`） |
| < 880px | 不支持（窗口最小尺寸约束）；原型中固定演示 1180×760 |
| 高度 < 620px | 空状态图标 72→56px，垂直留白 40→24px |

**其它规则**
- 分组卡片列表使用虚拟高度示意，滚动条为 macOS overlay 风格（宽 7px，thumb `rgba(0,0,0,0.22)` radius 4px，滚动时才出现）。
- 路径中段省略随容器宽度动态计算（原型中可用固定 3 档示意）。
- 尊重 `prefers-reduced-motion`：关闭扫描进度往复动画与弹窗缩放，仅保留 opacity。

---

## 9. Cautions（禁区）

### 绝不可做
1. **绝不**在确认弹窗使用「释放 X 空间」措辞 —— 只能是「移到废纸篓（X）／清空废纸篓后才真正释放磁盘空间」。
2. **绝不**改动风险语义色映射：用户数据=橙、不确定=黄、安全=灰；也绝不新增第四种风险色。
3. **绝不**用红色按钮承载「移到废纸篓」——那会把"可恢复"误传达为"不可逆"，破坏安全模型的信任叙事。
4. **绝不**默认勾选用户数据项 / 残留扫描结果；视觉上也不要用"已选中"的高亮暗示它们该被删。
5. **绝不**使用渐变、玻璃拟态卡片、彩色阴影、装饰性插画 —— 与"精密仪器"调性冲突。
6. **绝不**用 `--color-text-quaternary` 承载任何用户需要读取的信息。
7. **绝不**仅靠颜色传达风险（必须 色+图标+文字）。

### 优先做
- 用**留白与分组**而非**分隔线堆叠**建立层级（Linear 的边框极克制）。
- 数字与路径一律 mono + tabular-nums，让"精确"可被看见。
- 空状态、扫描中、结果态三者的**视觉重心位置保持一致**，避免切换时跳动。
- 弹窗中把"可复制路径"做成一等公民 —— 这是开发者受众的信任凭证。

---

## 10. Agent Prompt Guide（生成指南）

### 关键指令
- 所有颜色/尺寸**必须**引用 `var(--token)`，禁止硬编码 hex。
- HTML 原型用 `font-size: 13px` 作为 body 基准（macOS 语境），不要用 16px 网页基准。
- SF Symbol 用内联 SVG 复刻（stroke-width 1.5，`stroke-linecap: round`），或用 Unicode 近似替代并注明对应 symbol 名，便于 SwiftUI 直接替换。
- 交互深度 = **轻交互**：Tab 切换、勾选联动（含分组半选）、分组折叠、弹窗开关、hover 态。用原生 `<details>` 或 20 行以内 vanilla JS 实现，不引框架。
- 三个 Tab 的多状态用「状态切换器」（原型专用浮动小控件，可隐藏）演示，不要做成 3 个独立 HTML 文件。

### Quick CSS Snippet（可直接粘贴）

```css
:root {
  /* ── 强调色 Accent · AI Mac Cleaner Petrol Blue ───────────── */
  --color-accent:            #0E6C9E;
  --color-accent-hover:      #0B5D88;
  --color-accent-active:     #094E73;
  --color-accent-text:       #0B5D88;
  --color-accent-subtle:     #E7F1F7;
  --color-accent-border:     #BBD8E8;
  --color-accent-on:         #FFFFFF;

  /* ── 中性 Neutral ──────────────────────────────────── */
  --color-window-bg:         #FFFFFF;
  --color-titlebar-bg:       rgba(250,250,252,0.72);
  --color-sidebar-bg:        rgba(244,244,247,0.78);
  --color-canvas:            #F7F7F9;
  --color-surface:           #FFFFFF;
  --color-surface-hover:     #F5F5F7;
  --color-surface-sunken:    #FAFAFB;
  --color-divider:           #E9E9ED;
  --color-divider-hairline:  rgba(0,0,0,0.07);
  --color-border:            #D2D2D7;
  --color-text-primary:      #16171A;
  --color-text-secondary:    #5F6169;
  --color-text-tertiary:     #74767E;
  --color-text-quaternary:   #A1A3AB;

  /* ── 风险语义 Risk（语义锁定）────────────────────── */
  --risk-userdata:           #E8833A;
  --risk-userdata-text:      #A8560F;
  --risk-userdata-bg:        #FDF0E4;
  --risk-userdata-border:    #F3D3B0;
  --risk-uncertain:          #E0B53A;
  --risk-uncertain-text:     #8A6516;
  --risk-uncertain-bg:       #FBF3DC;
  --risk-uncertain-border:   #EDDCA6;
  --risk-safe:               #8A8A8E;
  --risk-safe-text:          #5C5C61;
  --risk-safe-bg:            #F1F1F3;
  --risk-safe-border:        #DEDEE2;

  /* ── 系统语义 Semantic ────────────────────────────── */
  --color-destructive:        #C8372F;
  --color-destructive-hover:  #B02D26;
  --color-destructive-bg:     #FCEDEB;
  --color-destructive-border: #F0C4BF;
  --color-success:            #1A7A54;
  --color-success-bg:         #E9F6F0;
  --color-success-border:     #B9E2D0;
  --color-warning:            #E8833A;
  --color-warning-text:       #A8560F;
  --color-warning-bg:         #FDF0E4;
  --color-warning-border:     #F3D3B0;

  /* ── 排版 Typography ──────────────────────────────── */
  --font-ui: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display",
             "Helvetica Neue", "PingFang SC", system-ui, sans-serif;
  --font-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas,
               "JetBrains Mono", monospace;

  --fs-title: 20px;      --fw-title: 600;      --lh-title: 1.25;
  --fs-title-2: 17px;    --fw-title-2: 600;    --lh-title-2: 1.3;
  --fs-headline: 15px;   --fw-headline: 600;   --lh-headline: 1.32;
  --fs-subheadline: 13px;--fw-subheadline: 600;--lh-subheadline: 1.38;
  --fs-body: 13px;       --fw-body: 400;       --lh-body: 1.45;
  --fs-label: 12px;      --fw-label: 500;      --lh-label: 1.35;
  --fs-caption: 11px;    --fw-caption: 400;    --lh-caption: 1.35;
  --fs-badge: 10px;      --fw-badge: 600;      --lh-badge: 1;
  --fs-mono-path: 12px;  --lh-mono-path: 1.5;
  --fs-mono-num: 12px;   --fw-mono-num: 500;
  --fs-mono-log: 11.5px; --lh-mono-log: 1.55;

  /* ── 间距 Spacing（8px 网格）──────────────────────── */
  --space-1: 2px;  --space-2: 4px;  --space-3: 6px;  --space-4: 8px;
  --space-5: 12px; --space-6: 16px; --space-7: 20px; --space-8: 24px;
  --space-10: 32px; --space-12: 40px; --space-16: 64px;

  /* ── 圆角 Radius ──────────────────────────────────── */
  --radius-xs: 4px;  --radius-sm: 6px;  --radius-md: 8px;
  --radius-lg: 10px; --radius-xl: 12px; --radius-window: 10px;
  --radius-pill: 999px;

  /* ── 布局 Layout ──────────────────────────────────── */
  --window-min-w: 880px; --window-min-h: 560px;
  --titlebar-h: 38px;  --sidebar-w: 116px; --applist-w: 268px;
  --toolbar-h: 52px;   --row-h: 32px;      --row-h-2l: 44px;
  --group-header-h: 36px; --footer-h: 28px; --content-pad: 24px;

  /* ── 深度 Elevation ───────────────────────────────── */
  --shadow-hairline-b: inset 0 -1px 0 rgba(0,0,0,0.07);
  --shadow-hairline-r: inset -1px 0 0 rgba(0,0,0,0.07);
  --shadow-card:    0 1px 2px rgba(16,18,27,.04), 0 1px 1px rgba(16,18,27,.03);
  --shadow-raised:  0 2px 6px rgba(16,18,27,.06), 0 1px 2px rgba(16,18,27,.04);
  --shadow-popover: 0 8px 24px rgba(16,18,27,.12), 0 2px 6px rgba(16,18,27,.06);
  --shadow-sheet:   0 24px 64px rgba(16,18,27,.22), 0 8px 20px rgba(16,18,27,.12);
  --shadow-window:  0 30px 80px rgba(16,18,27,.28), 0 0 0 .5px rgba(0,0,0,.12);
  --overlay-scrim:  rgba(22,23,26,0.28);
  --blur-material:  saturate(180%) blur(30px);
  --focus-ring:     0 0 0 3px rgba(14,108,158,0.28);

  /* ── 层级 & 动效 ──────────────────────────────────── */
  --z-toolbar: 10; --z-dropdown: 100; --z-popover: 200;
  --z-scrim: 300;  --z-sheet: 310;    --z-toast: 400;
  --ease: cubic-bezier(0.22, 0.61, 0.36, 1);
  --dur-fast: 100ms; --dur-base: 160ms; --dur-slow: 240ms;
}

/* 基线重置（macOS 语境）*/
html { -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale; }
body {
  font-family: var(--font-ui);
  font-size: var(--fs-body);
  line-height: var(--lh-body);
  color: var(--color-text-primary);
  background: var(--color-window-bg);
}
.mono { font-family: var(--font-mono); font-variant-ligatures: none; }
.num  { font-family: var(--font-mono); font-variant-numeric: tabular-nums; }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: .01ms !important; transition-duration: .01ms !important; }
}
```

### 可访问性自检清单（全部已通过）
- accent 白底 5.74:1 ✅ / 白字于 accent 5.74:1 ✅
- text-secondary 6.35:1 ✅ / text-tertiary 4.53:1 ✅
- 用户数据 pill 4.76:1 ✅ / 不确定 pill 4.79:1 ✅ / 安全 pill 6.07:1 ✅
- destructive 5.20:1 ✅ / success 5.32:1 ✅
- 风险等级三重编码（色 + 图标 + 文字）✅
- 所有可交互元素热区 ≥ 24×24 ✅ · 均有 focus-ring ✅

---

*本文件为原型样式唯一真源。任何视觉调整请先改此文件的 token，再改组件。*
