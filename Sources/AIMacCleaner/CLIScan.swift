import Foundation

/// CLI 扫描模式：`AI Mac Cleaner --scan <target>` 或 `--uninstall <target>`
enum CLIScan {
    static var allScanners: [any Scanner] {
        [
            AppBundleScanner(),
            BrewScanner(),
            RawBinaryScanner(),
            XDGUserDataScanner(),
            LaunchAgentScanner(),
            ProcessScanner(),
            LibraryDataScanner(),
            ContainerScanner(),
            BrowserPWAScanner(),
            DotfileScanner(),
            ShellConfigScanner(),
            AuthTokenScanner(),
            NpmScanner(),
            PipxScanner(),
            MASScanner()
        ]
    }

    /// 把用户输入解析成扫描条件，并打印锁定结果。
    static func resolve(target: String, verbose: Bool = true) -> ScanQuery {
        let allApps = AppInventory.allApps()
        let hits = AppInventory.search(target, in: allApps)
        guard let best = hits.first else {
            if verbose {
                print(L10n.t("未匹配到已安装 app，按关键词模式扫描：\(target)", "No installed app matched; scanning by keyword: \(target)"))
            }
            return ScanQuery(raw: target)
        }
        let query = ScanQuery(raw: target, app: best, others: allApps)
        if verbose {
            var line = L10n.t("已锁定: ", "Resolved: ") + "\(best.displayName)  (\(best.bundlePath))"
            if let bid = best.bundleId { line += "  [\(bid)]" }
            print(line)
            print(L10n.t("匹配关键词: ", "Keywords: ") + query.keywords.joined(separator: ", "))
            if hits.count > 1 {
                let others = hits.dropFirst().prefix(4)
                    .map { "\($0.displayName) (\($0.fileName).app)" }
                    .joined(separator: ", ")
                print(L10n.t("其他候选（未选中）: \(others)", "Other candidates (not selected): \(others)"))
            }
            print("")
        }
        return query
    }

    /// 「AI 补充发现」是否可用：已配置模型 + 已锁定到具体 app。
    ///
    /// 返回 nil 表示这轮不走 AI。两条缺一即整步跳过，行为与未接 AI 时完全一致。
    /// 只在 `--scan`（只列出）启用；`--uninstall` 是破坏性动作，不采纳模型提议。
    private static func aiProposer(for query: ScanQuery) -> (AppIdentity, AIModelConfig)? {
        guard let app = query.app,
              let cfg = ModelConfigStore.current.active, cfg.isConfigured
        else { return nil }
        return (app, cfg)
    }

    /// 扫描并打印
    static func scan(target: String) -> Int32 {
        let query = resolve(target: target)
        let sem = DispatchSemaphore(value: 0)
        var allArtifacts: [Artifact] = []
        let aiPropose = Self.aiProposer(for: query)
        Task.detached {
            for scanner in allScanners {
                let results = await scanner.scan(query: query)
                allArtifacts.append(contentsOf: results)
            }
            // 去重
            var seen = Set<String>()
            allArtifacts = allArtifacts.filter { seen.insert($0.path).inserted }
            if let (app, config) = aiPropose {
                let proposed = await AIScanProposer.propose(app: app, knownPaths: seen, config: config).artifacts
                for p in proposed where seen.insert(p.path).inserted {
                    allArtifacts.append(p)
                }
            }
            sem.signal()
        }
        // 开了 AI 补充发现就要给模型留出网络时间，否则稳定超时。
        let timeout: TimeInterval = aiPropose == nil ? 60 : 120
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            print(L10n.t("✗ 扫描超时", "✗ Scan timed out"))
            return 1
        }

        let plan = RemovalPlan(targetName: query.displayTarget, artifacts: allArtifacts)
        if allArtifacts.isEmpty {
            print(L10n.t("未找到任何痕迹：\(query.displayTarget)", "No traces found: \(query.displayTarget)"))
            return 0
        }

        print(L10n.t("扫描目标: \(query.displayTarget)", "Target: \(query.displayTarget)"))
        // 分开报：勾选的是会删的，全部的含默认不勾选的用户数据（容器动辄几个 GB）
        if plan.scannedTotalSize != plan.totalSize {
            print(L10n.t(
                "发现 \(allArtifacts.count) 项，共 \(SizeFormat.human(plan.scannedTotalSize))（默认勾选 \(plan.selectedCount) 项 / \(SizeFormat.human(plan.totalSize))）",
                "\(L10n.plural(allArtifacts.count, zh: "项", one: "item", many: "items")), \(SizeFormat.human(plan.scannedTotalSize)) total (\(plan.selectedCount) selected by default / \(SizeFormat.human(plan.totalSize)))"))
        } else {
            print(L10n.t("发现 \(allArtifacts.count) 项，合计 \(SizeFormat.human(plan.totalSize))", "\(L10n.plural(allArtifacts.count, zh: "项", one: "item", many: "items")), \(SizeFormat.human(plan.totalSize)) total"))
        }
        print(String(repeating: "─", count: 60))
        // AI 参与过就要说清楚：静默采纳模型的提议等于让用户不知道清单里混了什么。
        if aiPropose != nil {
            let n = allArtifacts.filter { $0.category == .aiProposed }.count
            print(L10n.t("※ AI 补充发现：采纳 \(n) 条（均已过本地校验，默认不勾选）",
                         "※ AI suggestions: \(n) adopted (all locally validated, unchecked by default)"))
        }

        for (category, items) in plan.grouped {
            print("\n[\(category.displayName)]  " + L10n.plural(items.count, zh: "项", one: "item", many: "items"))
            for item in items {
                let mark = item.risk == .safe ? "●" : (item.risk == .userData ? "○" : "?")
                var line = "  \(mark) \(item.path)  (\(SizeFormat.human(item.size)), \(item.risk.label))"
                if let meta = item.meta { line += "  {\(meta)}" }
                // AI 提议项把模型的理由一并打印：CLI 里没有勾选项，
                // 用户只能靠这句理由判断要不要手动删。
                if item.category == .aiProposed,
                   case .safe(let reason)? = item.aiVerdict {
                    line += "  [AI: \(reason)]"
                }
                print(line)
            }
        }
        return 0
    }

    /// 卸载（保留 selected 状态）
    static func uninstall(target: String, runPackageUninstallers: Bool, includeUserData: Bool,
                          dryRun: Bool = false, resetOnly: Bool = false) -> Int32 {
        let query = resolve(target: target)
        let sem = DispatchSemaphore(value: 0)
        var allArtifacts: [Artifact] = []
        Task.detached {
            for scanner in allScanners {
                let results = await scanner.scan(query: query)
                allArtifacts.append(contentsOf: results)
            }
            var seen = Set<String>()
            allArtifacts = allArtifacts.filter { seen.insert($0.path).inserted }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut {
            print(L10n.t("✗ 扫描超时", "✗ Scan timed out"))
            return 1
        }
        if allArtifacts.isEmpty {
            print(L10n.t("未找到任何痕迹：\(target)", "No traces found: \(target)"))
            return 0
        }

        // --reset：只清数据、保留 app 本身。
        // 用于「配置炸了想恢复出厂」，全量卸载对这个场景太重。
        // 除了 app bundle，包管理器条目和 CLI 程序也要留下 —— 那些都是
        //「安装」的一部分，不是「数据」。
        if resetOnly {
            let keep: Set<ArtifactCategory> = [
                .appBundle, .cliBinary, .brewFormula, .brewCask,
                .npmGlobal, .pipxVenv, .masApp
            ]
            allArtifacts = allArtifacts.filter { !keep.contains($0.category) }
            if allArtifacts.isEmpty {
                print(L10n.t("没有可重置的数据（只找到 app 本身和安装条目）。",
                             "Nothing to reset — only the app itself and install entries were found."))
                return 0
            }
            print(L10n.t("※ 重置模式（--reset）：只清数据，保留 app 本身。",
                         "※ Reset mode (--reset): clears data only, the app itself is kept."))
        }

        // 默认只选 safe；显式指定 --include-userdata 才选 userData。
        // --reset 例外：重置的目的就是清掉配置和数据，默认全选（仍走废纸篓，可挽回）。
        let selected = allArtifacts.map { a -> Artifact in
            var copy = a
            if a.risk == .safe || includeUserData || resetOnly {
                copy.selected = true
            }
            return copy
        }
        let plan = RemovalPlan(targetName: target, artifacts: selected)
        let executor = RemovalExecutor(plan: plan, runPackageUninstallers: runPackageUninstallers,
                                       dryRun: dryRun)
        let outcome = executor.execute()
        return outcome.failureCount == 0 ? 0 : 1
    }

    /// 打印历史
    static func showHistory() -> Int32 {
        let records = HistoryStore.listAll()
        if records.isEmpty {
            print(L10n.t("暂无卸载历史", "No uninstall history"))
            return 0
        }
        for r in records {
            print("─")
            print(L10n.t("目标:     \(r.targetName)", "Target:    \(r.targetName)"))
            print(L10n.t("时间:     ", "Time:      ") + r.startedAt.formatted(date: .abbreviated, time: .shortened))
            print(L10n.t("成功:     \(r.deletedCount) 项", "Succeeded: \(L10n.plural(r.deletedCount, zh: "项", one: "item", many: "items"))"))
            print(L10n.t("失败:     \(r.failedCount) 项", "Failed:    \(L10n.plural(r.failedCount, zh: "项", one: "item", many: "items"))"))
            if let trashed = r.trashedBytes, trashed > 0 {
                print(L10n.t("废纸篓:   \(SizeFormat.human(trashed))（清空后才真正释放）", "Trashed:   \(SizeFormat.human(trashed)) (reclaimed only after emptying Trash)"))
            } else {
                print(L10n.t("释放:     \(SizeFormat.human(r.freedBytes))", "Freed:     \(SizeFormat.human(r.freedBytes))"))
            }
        }
        return 0
    }

    /// 列出所有已安装 app（app 列表入口的 CLI 版）
    static func listApps() -> Int32 {
        let apps = InventoryCache.shared.allApps()
        print(L10n.t("已安装 \(apps.count) 个 app：\n", "\(L10n.plural(apps.count, zh: "个 app", one: "installed app", many: "installed apps")):\n"))
        for app in apps {
            var line = "  \(app.displayName)"
            if app.displayName.lowercased() != app.fileName.lowercased() {
                line += "  (\(app.fileName).app)"
            }
            if let v = app.version { line += "  v\(v)" }
            if let bid = app.bundleId { line += "  [\(bid)]" }
            print(line)
        }
        return 0
    }

    /// 反向扫描孤儿痕迹
    static func scanOrphans() -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var groups: [LeftoverGroup] = []
        Task.detached {
            groups = await OrphanScanner.scanAll()
            sem.signal()
        }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            print(L10n.t("✗ 孤儿扫描超时", "✗ Orphan scan timed out"))
            return 1
        }

        if groups.isEmpty {
            print(L10n.t("未发现孤儿痕迹 —— 所有痕迹都能对应到已安装的 app。", "No orphaned traces — every trace maps to an installed app."))
            return 0
        }

        let total = groups.reduce(Int64(0)) { $0 + $1.totalSize }
        let count = groups.reduce(0) { $0 + $1.artifacts.count }
        print(L10n.t("发现 \(groups.count) 组孤儿痕迹，共 \(count) 项 / \(SizeFormat.human(total))", "\(L10n.plural(groups.count, zh: "组", one: "orphan group", many: "orphan groups")), \(L10n.plural(count, zh: "项", one: "item", many: "items")) / \(SizeFormat.human(total))"))
        print(L10n.t("（基于启发式判定：目录名是 bundle-id 形状、且没有任何已装 app 认领）", "(Heuristic: directory name looks like a bundle ID and no installed app claims it)"))
        print(L10n.t("全部默认不勾选，请逐项人工确认后再删。", "All unchecked by default — verify each item before removing."))
        print(String(repeating: "─", count: 60))
        for g in groups {
            print("\n▸ \(g.owner)   \(SizeFormat.human(g.totalSize))  (" + L10n.plural(g.artifacts.count, zh: "项", one: "item", many: "items") + ")")
            for a in g.artifacts {
                print("    ○ [\(a.category.rawValue)] \(a.path)  (\(SizeFormat.human(a.size)))")
            }
        }
        return 0
    }
}
