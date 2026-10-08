import SwiftUI

@main
struct AIMacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    /// 版本号由 `build_app.sh` 在打包时生成 `AppVersion.generated.swift` 注入
    /// （日期制：YYYY.M.D 或同日多次构建的 YYYY.M.D-N），是 `--help`、
    /// 「关于」面板与反馈页的统一来源。这里不再写死，避免两处各说各话。

    /// 语言选择存在 UserDefaults 里。用 `@AppStorage` 而不是直接读
    /// `L10n.override` 是为了让切换语言后 SwiftUI 立刻重建视图树 ——
    /// 否则要重启 app 才看到新文案。
    @AppStorage("expunge.language") private var languageRaw: String = L10n.Language.system.rawValue

    private var languageBinding: Binding<L10n.Language> {
        Binding(
            get: { L10n.Language(rawValue: languageRaw) ?? .system },
            set: { languageRaw = $0.rawValue }
        )
    }

    /// 主题模式（跟随系统/浅色/深色），存 UserDefaults。
    /// 和语言一样用 `@AppStorage`：切换后视图树立刻重建，外观即时生效。
    @AppStorage("expunge.theme") private var themeRaw: String = ThemeMode.system.rawValue

    private var themeBinding: Binding<ThemeMode> {
        Binding(
            get: { ThemeMode(rawValue: themeRaw) ?? .system },
            set: { themeRaw = $0.rawValue }
        )
    }

    init() {
        let args = CommandLine.arguments
        let userArgs = Array(args.dropFirst())

        // 改名后首次启动：把旧版数据目录（~/Library/Application Support/Expunge）
        // 迁移到 AIMacCleaner，避免老用户的历史/记忆/反馈读不到。
        LegacySupportMigration.migrateIfNeeded()

        if userArgs.contains("--self-test") {
            exit(SelfTest.run())
        }
        if let idx = userArgs.firstIndex(of: "--scan"),
           idx + 1 < userArgs.count {
            exit(CLIScan.scan(target: userArgs[idx + 1]))
        }
        if let idx = userArgs.firstIndex(of: "--uninstall"),
           idx + 1 < userArgs.count {
            let skipPm = userArgs.contains("--no-package-managers")
            let includeUD = userArgs.contains("--include-userdata")
            let dryRun = userArgs.contains("--dry-run")
            exit(CLIScan.uninstall(target: userArgs[idx + 1], runPackageUninstallers: !skipPm,
                                   includeUserData: includeUD, dryRun: dryRun))
        }
        // --reset：只清数据、保留 app。走同一条执行链，只是过滤掉安装类条目。
        if let idx = userArgs.firstIndex(of: "--reset"),
           idx + 1 < userArgs.count {
            let dryRun = userArgs.contains("--dry-run")
            exit(CLIScan.uninstall(target: userArgs[idx + 1], runPackageUninstallers: false,
                                   includeUserData: true, dryRun: dryRun, resetOnly: true))
        }
        if userArgs.contains("--history") {
            exit(CLIScan.showHistory())
        }
        if userArgs.contains("--list") {
            exit(CLIScan.listApps())
        }
        if userArgs.contains("--orphans") {
            exit(CLIScan.scanOrphans())
        }
        // --ai-tools：列出已知的 AI / 开发工具残留（macOS Library 缓存、ML 模型、
        // 开发包管理器缓存），与 AIAgentScanner 互补、不重复。仅扫描不删除。
        if userArgs.contains("--ai-tools") {
            exit(AIToolLeftovers.scanCLI())
        }
        // --orphan-caches：动态发现 scratch 根下的孤儿依赖 / 构建缓存。
        // 仅扫描不删除。
        if userArgs.contains("--orphan-caches") {
            exit(OrphanCacheScanner.scanCLI())
        }
        // --pkg-receipts：列出孤儿 pkg 收据（.pkg 安装器残留）+ 散落文件（仅扫描、不删除）。
        if userArgs.contains("--pkg-receipts") {
            exit(PkgReceiptScanner.scanCLI())
        }

        // ── Agent 子命令：全部复用与 GUI 完全相同的 skill 层 ──
        // 安全边界由 SkillRegistry 白名单兜底：任何未注册的指令都拿不到执行入口，
        // 因此模型编出的 `rm -rf` 这类命令连承接的地方都没有。
        if userArgs.contains("--skills") {
            exit(CLIAgent.printSkills())
        }
        if userArgs.contains("--agent") {
            let goal = CLIAgent.collectGoal(after: "--agent", in: userArgs)
            let model = CLIAgent.value(after: "--model", in: userArgs)
            exit(CLIAgent.runAgent(goal: goal, model: model))
        }
        if let idx = userArgs.firstIndex(of: "--skill"), idx + 1 < userArgs.count {
            let name = userArgs[idx + 1]
            let json = CLIAgent.value(after: "--args", in: userArgs)
            exit(CLIAgent.runSkill(name: name, args: CLIAgent.args(fromJSON: json)))
        }
        // ── 调查类子命令（给Agent / 人用的「翻目录」能力）──
        // 全部只读，唯一例外是 --propose（只往清单里加候选，永不代表授权删除）。
        if userArgs.contains("--trace-roots") {
            exit(CLIAgent.runSkill(name: "list_trace_roots", args: SkillArgs()))
        }
        if let idx = userArgs.firstIndex(of: "--search"), idx + 1 < userArgs.count {
            var args: [String: String] = ["token": userArgs[idx + 1]]
            if let l = CLIAgent.value(after: "--limit", in: userArgs) { args["limit"] = l }
            exit(CLIAgent.runSkill(name: "search_paths", args: SkillArgs(args)))
        }
        if let idx = userArgs.firstIndex(of: "--inspect"), idx + 1 < userArgs.count {
            // --target 可选：给了才能排除目标 app 自身（否则它自己的数据目录
            // 会被「活 app 反查」判成被别人认领）。
            let target = CLIAgent.value(after: "--target", in: userArgs)
            let session = AgentSession()
            if let target { session.lastApp = AppState.resolveQuery(from: target).app }
            exit(CLIAgent.runSkill(name: "inspect_path",
                                   args: SkillArgs(["path": userArgs[idx + 1]]),
                                   session: session))
        }
        if let idx = userArgs.firstIndex(of: "--propose"), idx + 1 < userArgs.count {
            // 校验网需要知道「除目标 app 外的其它活 app」，所以必须同时给出目标。
            let target = CLIAgent.value(after: "--target", in: userArgs)
            guard let target, let app = AppState.resolveQuery(from: target).app else {
                FileHandle.standardError.write(Data(L10n.t(
                    "--propose 需要 --target <已安装应用>（校验网要排除目标之外的其它活 app）。\n",
                    "--propose requires --target <installed app> (validation must exclude the other live apps).\n").utf8))
                return
            }
            let session = AgentSession()
            session.lastApp = app
            session.lastTarget = app.displayName
            exit(CLIAgent.runSkill(name: "propose_paths",
                                   args: SkillArgs(["path": userArgs[idx + 1]]),
                                   session: session))
        }
        if userArgs.contains("--ps") {
            var args: [String: String] = [:]
            if let f = CLIAgent.value(after: "--filter", in: userArgs) { args["filter"] = f }
            if let k = CLIAgent.value(after: "--keyword", in: userArgs) { args["keyword"] = k }
            if let l = CLIAgent.value(after: "--limit", in: userArgs) { args["limit"] = l }
            exit(CLIAgent.runSkill(name: "list_processes", args: SkillArgs(args)))
        }
        if userArgs.contains("--review") {
            var args: [String: String] = [:]
            if let s = CLIAgent.value(after: "--scope", in: userArgs) { args["scope"] = s }
            exit(CLIAgent.runSkill(name: "review_plan", args: SkillArgs(args)))
        }

        // 走到这里说明没有任何 CLI 子命令匹配。
        // 无参数 = 正常双击启动 GUI；有参数但没匹配上 = 用户敲错了。
        // 后者必须报错退出：否则在终端里敲错一个 flag 得到的是一个
        // 静默启动、永不返回的 GUI 进程（--help 就是这么卡住的）。
        if !userArgs.isEmpty {
            FileHandle.standardError.write(Data(Self.usage.utf8))
            // --help / -h 是主动求助，不是错误
            exit(userArgs.contains("--help") || userArgs.contains("-h") ? 0 : 2)
        }
    }

    nonisolated static let usage = """
        AI Mac Cleaner \(Self.version) —— Mac 深度卸载工具 / deep uninstaller for macOS

        用法 / Usage:
          AIMacCleaner                                  启动图形界面 / launch the GUI
          ai-mac-cleaner --list                           列出已安装 app / list installed apps
          ai-mac-cleaner --scan <名称>                     只扫描，不删除 / scan only
          ai-mac-cleaner --uninstall <名称> [选项]          扫描并卸载 / scan and uninstall
          ai-mac-cleaner --orphans                        查找孤儿残留 / find orphaned leftovers
          ai-mac-cleaner --ai-tools                       列出 AI / 开发工具残留（缓存·模型·包管理器）/ list AI & dev-tool leftovers
          ai-mac-cleaner --orphan-caches                  动态发现孤儿依赖/构建缓存（node_modules 等）/ find orphan dep & build caches
          ai-mac-cleaner --pkg-receipts                  列出孤儿 pkg 收据与散落残留 / list orphan pkg receipts
          ai-mac-cleaner --history                        卸载历史 / uninstall history
          ai-mac-cleaner --reset <名称>                    重置 app（保留程序本体）/ reset an app
          ai-mac-cleaner --skills                         列出 Agent 可调用的 skill / list agent skills
          ai-mac-cleaner --agent "自然语言目标" [--model <档名>]   启动 Agent：自动决定调哪些 skill / launch the agent
          ai-mac-cleaner --skill <名称> [--args '{...}']    直接调一个 skill / call a skill directly
          ai-mac-cleaner --ps [--filter background|user|system] [--keyword <名>] [--limit <N>]   列出进程 / list processes
          ai-mac-cleaner --review [--scope apps|leftovers]   分析删除清单 / review a removal plan
          ai-mac-cleaner --trace-roots                     列出可搜索的痕迹根目录 / list trace roots
          ai-mac-cleaner --search <宽泛词> [--limit <N>]     在痕迹目录里按宽 token 枚举候选 / search traces by broad token
          ai-mac-cleaner --inspect <绝对路径>               查看一个路径的归属线索 / inspect one path
          ai-mac-cleaner --propose <路径[,路径...]> --target <应用>   把候选提交进清单（仍需用户勾选确认）/ submit candidates
          ai-mac-cleaner --self-test                      运行自检 / run self-test
          ai-mac-cleaner --help                           显示本帮助 / show this help

        --uninstall / --reset 的选项 / Options:
          --dry-run                预演：只列出会做什么，什么都不改 / preview only
          --include-userdata       同时清理用户数据 / also remove user data
          --no-package-managers    跳过 brew/npm/pipx/mas / skip package managers

        Agent 只能通过 11 个 skill 干活（--skills 可看全部）：没有通用 shell、不联网，
        只能在白名单目录内读元数据和极短文件头（最多 512 字节）用于判断归属。
        所有 skill 都不会删除文件，删除只发生在你确认之后。
        The agent works only through 11 skills (see --skills): no shell, no network; it may read
        metadata and tiny file heads (512 bytes max) inside allow-listed dirs to verify ownership.
        No skill deletes anything; removal happens only after you confirm.

        内置扫描器靠关键词命中，会在「目录名和app 名对不上」时漏项（StoryFab → story-fab）。
        遇到这种app，用 --search拿更宽的词去找，再用 --inspect 逐个确认归属。
        The built-in scanners match on keywords and miss paths whose name doesn't line up with the
        app name. For those, search with a broader token, then inspect each hit to confirm ownership.

        默认走废纸篓，可恢复。/ Deletes to Trash by default — recoverable.

        """


    var body: some Scene {
        WindowGroup("AI Mac Cleaner") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 880, minHeight: 560)
                // 全局强调色 = Petrol Blue。所有 Color.accentColor 与
                // borderedProminent 按钮会自动套用，无需逐处改色。
                .tint(Theme.accent)
                // 主题由 AppKit 层（NSApp.appearance + 各 NSWindow.appearance）统一控制，
                // 不通过 .preferredColorScheme 走 SwiftUI 内部覆盖。后者在 macOS 上从
                // 非 nil 切回 nil 时容易残留旧 colorScheme，出现「标题栏已浅、内容仍深」。
                // ThemeManager.apply() 在启动/切换时同步设置 appearance 并强制重绘。
                // 主题切换不要动画，防止深色/浅色过渡期间产生黑底残留、白横线。
                .animation(.none, value: themeRaw)
                // 主题键变化时同步把决定推给 AppKit，比 UserDefaults.didChangeNotification
                // 更早生效，缩短「标题栏已切、内容区还黑」的过渡窗口。
                .onChange(of: themeRaw) { _ in
                    ThemeManager.apply()
                    // 强制 SwiftUI 整树立即重建，否则 AppKit appearance 已切、
                    // SwiftUI 内容区还要等下一帧才跟新 effectiveAppearance。
                    state.objectWillChange.send()
                }
        }
        .windowResizability(.contentMinSize)
        // 新开窗口的默认尺寸：1040×680，远超 sidebar 常驻所需（~603px）。
        // 这样「默认展开」由 SwiftUI 自己保证 —— 只要用户没手动关过 sidebar、
        // 窗口也没窄到触发 autoCollapsed，一打开就是展开态。
        // 注意：defaultSize 只在「首次创建窗口」生效；已记住的旧窄尺寸会覆盖它。
        // 彻底解决旧尺寸问题靠 build_app.sh 发布时清一次 Saved Application State。
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .help) {
                Link(L10n.t("AI Mac Cleaner 主页", "AI Mac Cleaner Homepage"), destination: URL(string: "https://github.com/hwd8080-ai/AIMacCleaner")!)
                Link(L10n.t("提交 Bug 或建议", "Report a Bug or Suggestion"), destination: URL(string: "https://github.com/hwd8080-ai/AIMacCleaner/issues")!)
                Divider()
                Button(L10n.t("关于 AI Mac Cleaner", "About AI Mac Cleaner")) {
                    state.showAbout = true
                }
            }
            // 语言切换。`@AppStorage` 会驱动整个视图树重建，所以切换后
            // 界面文案立刻生效，不需要重启。
            CommandMenu(L10n.t("语言", "Language")) {
                Picker(L10n.t("界面语言", "Interface Language"), selection: languageBinding) {
                    ForEach(L10n.Language.allCases, id: \.rawValue) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.inline)
            }
            // 主题切换（独立「主题」菜单）：.system 时不覆盖系统外观
            CommandMenu(L10n.t("主题", "Theme")) {
                Picker("", selection: themeBinding) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }
            CommandMenu(L10n.t("设置", "Settings")) {
                Button(L10n.t("配置 AI 模型…", "Configure AI model…")) {
                    state.showAIModelSettings = true
                }
            }
        }
    }
}
