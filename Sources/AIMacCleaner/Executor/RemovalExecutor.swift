import Foundation

/// 主执行器：串联 杀进程 → unload agent → 包管理器卸载 → 删文件 → 写历史。
///
/// v1.5 起按 `Artifact.risk` 自动分流删除去向（见 `trashUserData`）：
/// - `userData` 类 → 废纸篓（可恢复）；除非 `trashUserData == false` 才一并彻底删除。
/// - `safe` / `uncertain` 类 → 直接彻底删除（不可恢复）。
/// 这是产品层面的一次取舍：可安全删除的（应用、缓存、日志、安装器）本就可重生，
/// 没必要都进废纸篓让用户事后手动清空；用户数据才是真正不可再生的部分，默认留一线可找回。
class RemovalExecutor {
    let plan: RemovalPlan
    let selected: [Artifact]
    let runPackageUninstallers: Bool
    /// 是否把「用户数据」类移到废纸篓（可恢复）。默认 true —— 用户数据留一线可找回。
    /// false 时用户数据也直接彻底删除（与可安全删除的项一样，不可恢复）。
    let trashUserData: Bool
    /// 自卸载模式：目标就是本工具自身时置 true。删除完成后不写历史
    /// —— 历史库文件本身会被一并移到废纸篓，写了反而会在原路径重新创建支持目录，
    /// 留下一个本该被删掉的空壳。删完由调用方统一退出应用。
    let skipHistory: Bool
    /// 预演模式：**四个阶段全部只打印、不执行**，也不写历史。
    ///
    /// 刻意包含杀进程和包管理器卸载 —— 一个会杀进程或跑
    /// `brew uninstall` 的「dry run」不是 dry run。唯一的副作用是
    /// 扫描阶段读磁盘（那在构造 plan 时就已经发生了）。
    let dryRun: Bool
    var onProgress: ((String) -> Void)?
    /// 与 onProgress 同步收集的完整日志，用于写入历史记录。
    private var logLines: [String] = []

    init(plan: RemovalPlan, selected: [Artifact]? = nil,
         runPackageUninstallers: Bool = true, dryRun: Bool = false,
         trashUserData: Bool = true, skipHistory: Bool = false) {
        self.plan = plan
        self.selected = selected ?? plan.artifacts.filter(\.selected)
        self.runPackageUninstallers = runPackageUninstallers
        self.dryRun = dryRun
        self.trashUserData = trashUserData
        self.skipHistory = skipHistory
    }

    struct Outcome {
        let record: HistoryStore.RemovalRecord
        /// 真正被自动删除/处理掉的项数。
        let successCount: Int
        /// 自动处理失败（如权限不足、进程杀不掉）的项数。
        let failureCount: Int
        /// 未自动处理、需用户按日志提示手动操作的项数（如 ~/.zshrc 配置行）。
        let manualCount: Int
    }

    func execute() -> Outcome {
        let startedAt = Date()
        var deleted: [HistoryStore.DeletedArtifact] = []
        // 真正彻底删除（不经废纸篓）所释放的字节数。v1.5 起「可安全删除」的项走
        // 直接删除，所以这里不再恒为 0 —— 这部分空间是实打实腾出来的。
        // 保留这个字段也为了历史记录口径不变（旧记录里它是真的释放量）。
        var freedBytes: Int64 = 0
        // 移到废纸篓的字节数。**这部分磁盘空间还没真正释放** —— 东西还在
        // ~/.Trash 里占着。必须与 freedBytes 分开报，否则就是这个项目
        // v1.1 栽过的那种假报成功（UI 说释放了 3.6 GB，其实一个字节都没少）。
        var trashedBytes: Int64 = 0
        var failures = 0
        var manualCount = 0

        if dryRun {
            log(L10n.t("\n※ 预演模式（--dry-run）：以下全部只列出，不会真的执行。\n",
                       "\n※ Dry run (--dry-run): everything below is listed only, nothing is executed.\n"))
        }

        // 1. 杀进程
        log(L10n.t("━━ 阶段 1/4：终止进程 ━━", "━━ Stage 1/4: Terminate processes ━━"))
        for a in selected where a.category == .runningProcess {
            // meta 形如 "PID: 123" 或 "PID: 123,124,125 (3 个进程)"——
            // 一个 Electron app 会派生多个 helper，折叠成一项展示，但必须逐个杀，
            // 漏掉任何一个都会导致后面删文件时被占用而失败。
            let pids = Self.parsePids(from: a.meta)
            guard !pids.isEmpty else { continue }

            if dryRun {
                let list = pids.joined(separator: ", ")
                log(L10n.t("  · 会终止 PID \(list): \(a.path)", "  · would kill PID \(list): \(a.path)"))
                continue
            }

            var allOK = true
            var messages: [String] = []
            for pid in pids {
                let r = ProcessKiller.kill(pid: pid)
                if r.success {
                    log(L10n.t("  ✓ 终止 \(pid): \(a.path)", "  ✓ Killed \(pid): \(a.path)"))
                } else {
                    log(L10n.t("  ! 终止失败 \(pid): \(r.message)", "  ! Kill failed \(pid): \(r.message)"))
                    allOK = false
                    failures += 1
                }
                messages.append("\(pid): \(r.message)")
            }
            deleted.append(.init(category: a.category.rawValue, path: a.path, risk: a.risk.label,
                                 success: allOK, requiresManual: false,
                                 message: messages.joined(separator: "; ")))
        }

        // 3. unload launch agents
        log(L10n.t("\n━━ 阶段 2/4：unload launch agents ━━", "\n━━ Stage 2/4: Unload launch agents ━━"))
        for a in selected where a.category == .launchAgent {
            if dryRun {
                log(L10n.t("  · 会 unload \(a.path)", "  · would unload \(a.path)"))
                continue
            }
            let r = LaunchAgentManager.unload(plistPath: a.path)
            deleted.append(.init(category: a.category.rawValue, path: a.path, risk: a.risk.label,
                                 success: r.success, requiresManual: false, message: r.message))
            if r.success { log("  ✓ \(a.path)") }
            else { log("  ! \(a.path): \(r.message)"); failures += 1 }
        }

        // 4. 包管理器卸载
        if runPackageUninstallers {
            log(L10n.t("\n━━ 阶段 3/4：包管理器卸载 ━━", "\n━━ Stage 3/4: Package manager uninstall ━━"))
            for a in selected {
                let r: ActionResult
                switch a.category {
                case .brewFormula:
                    let name = (a.path as NSString).lastPathComponent
                    if dryRun {
                        log(L10n.t("  · 会执行 brew uninstall --formula \(name)",
                                   "  · would run brew uninstall --formula \(name)"))
                        continue
                    }
                    r = PackageUninstallers.brew(.formula, name: name)
                case .brewCask:
                    if let token = a.path.split(separator: ":").last.map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        if dryRun {
                            log(L10n.t("  · 会执行 brew uninstall --cask \(token)",
                                       "  · would run brew uninstall --cask \(token)"))
                            continue
                        }
                        r = PackageUninstallers.brew(.cask, name: String(token))
                    } else {
                        r = ActionResult(success: false, message: L10n.t("无法解析 cask 名", "Could not parse cask name"))
                    }
                case .npmGlobal:
                    let name = (a.path as NSString).lastPathComponent
                    if dryRun {
                        log(L10n.t("  · 会执行 npm uninstall -g \(name)",
                                   "  · would run npm uninstall -g \(name)"))
                        continue
                    }
                    r = PackageUninstallers.npm(name)
                case .pipxVenv:
                    let name = (a.path as NSString).lastPathComponent
                    if dryRun {
                        log(L10n.t("  · 会执行 pipx uninstall \(name)",
                                   "  · would run pipx uninstall \(name)"))
                        continue
                    }
                    r = PackageUninstallers.pipx(name)
                case .masApp:
                    if let idMeta = a.meta, let id = idMeta.replacingOccurrences(of: "MAS id: ", with: "").components(separatedBy: " ").first {
                        if dryRun {
                            log(L10n.t("  · 会执行 mas uninstall \(id)",
                                       "  · would run mas uninstall \(id)"))
                            continue
                        }
                        r = PackageUninstallers.mas(id)
                    } else {
                        r = ActionResult(success: false, message: L10n.t("无法解析 MAS id", "Could not parse MAS id"))
                    }
                default:
                    continue
                }
                deleted.append(.init(category: a.category.rawValue, path: a.path, risk: a.risk.label,
                                     success: r.success, requiresManual: false, message: r.message))
                if r.success { log("  ✓ \(a.path)") }
                else { log("  ! \(a.path): \(r.message)"); failures += 1 }
            }
        }

        // 5. 删除文件
        log(L10n.t("\n━━ 阶段 4/4：删除文件 ━━", "\n━━ Stage 4/4: Remove files ━━"))
        for a in selected {
            // 已通过包管理器删的就不再删
            if [.brewFormula, .brewCask, .npmGlobal, .pipxVenv, .masApp, .launchAgent, .runningProcess].contains(a.category) {
                continue
            }
            // shell rc 是文本片段，不能整文件删，只能提示用户手动编辑。
            // 这些项必须和「真正成功删除」区分开，否则结果弹窗会假报成功。
            if a.category == .shellRc {
                if !dryRun {
                    deleted.append(.init(category: a.category.rawValue, path: a.path, risk: a.risk.label,
                                         success: false, requiresManual: true,
                                         message: L10n.t("需手动编辑", "Edit manually")))
                    manualCount += 1
                }
                log(L10n.t("  ⚠️ \(a.path) — 请手动编辑", "  ⚠️ \(a.path) — edit manually"))
                continue
            }
            // pkg 收据位于 /var/db/receipts，属 root 所有，app 以普通用户身份运行、
            // 也没有提权机制，强行走 FileDeleter 只会触发「路径不在白名单内」的假失败。
            // 这里改为标记「需手动」，并给出精确的 sudo 命令——用户在自己授权下清理。
            // 不能算成功、也不能算失败：它是预期内、需要用户介入的动作。
            if a.category == .pkgReceipt {
                let cmd = "sudo rm \(a.path)"
                if !dryRun {
                    deleted.append(.init(category: a.category.rawValue, path: a.path, risk: a.risk.label,
                                         success: false, requiresManual: true,
                                         message: L10n.t("需要管理员权限，终端执行：\(cmd)",
                                                        "Requires admin; run in Terminal: \(cmd)")))
                    manualCount += 1
                }
                log(L10n.t("  ⚠️ \(a.path) — 需管理员权限，终端执行：\(cmd)",
                           "  ⚠️ \(a.path) — requires admin; in Terminal: \(cmd)"))
                continue
            }
            if dryRun {
                let goesToTrash = (a.risk == .userData && trashUserData)
                let verb = goesToTrash
                    ? L10n.t("移到废纸篓", "move to Trash")
                    : L10n.t("彻底删除", "permanently delete")
                log(L10n.t("  · 会\(verb) \(a.path)  (\(SizeFormat.human(a.size)))",
                           "  · would \(verb) \(a.path)  (\(SizeFormat.human(a.size)))"))
                if goesToTrash { trashedBytes += a.size } else { freedBytes += a.size }
                continue
            }
            let goesToTrash = (a.risk == .userData && trashUserData)
            let r = FileDeleter.delete(a.path, disposition: goesToTrash ? .trash : .permanent)
            // 只有真正的「权限不足」失败才允许提权兜底；容器由 containermanagerd 独占
            // 管理，即便 root 也删不干净，沿用原有的诚实提示、不提供提权入口。
            let escalatable = r.needsElevation
                && a.category != .container
                && a.category != .groupContainer
            deleted.append(.init(category: a.category.rawValue, path: a.path, risk: a.risk.label,
                                 success: r.success, requiresManual: false,
                                 message: r.message, needsElevation: escalatable))
            if r.success {
                if goesToTrash {
                    if r.trashedTo != nil {
                        // 容器走了降级（清内容、留壳）时，不能只说「→ 废纸篓」——
                        // 那会让用户以为整个目录都没了，回头在 Finder 里看到它还在
                        // 就会怀疑工具在骗人。FileDeleter 已经在 message 里说明了，
                        // 这里如实转述。
                        if r.message.contains("容器空壳") {
                            log(L10n.t("  ✓ \(a.path)  (\(SizeFormat.human(a.size))) → 内容已进废纸篓（空目录由系统保留，不占空间）",
                                       "  ✓ \(a.path)  (\(SizeFormat.human(a.size))) → contents moved to Trash (empty dir kept by the system, takes no space)"))
                        } else {
                            log(L10n.t("  ✓ \(a.path)  (\(SizeFormat.human(a.size))) → 废纸篓", "  ✓ \(a.path)  (\(SizeFormat.human(a.size))) → Trash"))
                        }
                        trashedBytes += a.size
                    } else if r.message.contains("内容已空") {
                        // 容器壳里本来就没用户数据，没有任何东西进废纸篓 ——
                        // 不该计入 trashedBytes，否则又是一次虚报。
                        log(L10n.t("  ✓ \(a.path)（内容本来就是空的，空目录由系统保留）",
                                   "  ✓ \(a.path) (already empty; the empty dir is kept by the system)"))
                    } else {
                        // 到这里只剩「已不存在」—— 本来就没占空间，不该计入任何口径。
                        log(L10n.t("  ✓ \(a.path)（已不存在）", "  ✓ \(a.path) (already gone)"))
                    }
                } else {
                    // 直接彻底删除 —— 磁盘空间真的释放了（不再是「还在废纸篓里占着」）。
                    freedBytes += a.size
                    log(L10n.t("  ✓ \(a.path)  (\(SizeFormat.human(a.size))) → 已彻底删除",
                               "  ✓ \(a.path)  (\(SizeFormat.human(a.size))) → permanently deleted"))
                }
            } else {
                log("  ! \(a.path): \(r.message)")
                failures += 1
                // 这里曾经建议用户去开「完全磁盘访问权限」—— **那是错的**。
                // ~/Library/Containers 由 containermanagerd 独占管理，父目录不可写，
                // 容器目录本身无论如何都移不走；实测授予 FDA 后仍然失败。
                // 给出一个解决不了问题的指引比不给更糟：用户白折腾一圈，
                // 还会以为是自己没设置对。
                //
                // 现在 FileDeleter 会自动降级去清空容器内容（那才是占空间的部分），
                // 所以走到这个分支说明连内容都没清掉 —— 那是真的没办法。
                if r.message.contains("permission") || r.message.contains("Operation not permitted") {
                    if a.category == .container || a.category == .groupContainer {
                        log(L10n.t("    → 该容器由系统的 containermanagerd 独占管理，无法删除。",
                                   "    → This container is exclusively managed by the system's containermanagerd and cannot be removed."))
                        log(L10n.t("      这不是权限设置问题（「完全磁盘访问权限」也解决不了）。空容器不占磁盘空间，可以忽略。",
                                   "      This is not a permissions setting you can change (Full Disk Access does not help). Empty containers take no disk space and can be ignored."))
                    }
                }
            }
        }

        let record = HistoryStore.RemovalRecord(
            id: UUID().uuidString,
            targetName: plan.targetName,
            startedAt: startedAt,
            finishedAt: Date(),
            deletedCount: deleted.filter(\.success).count,
            failedCount: failures,
            manualCount: manualCount,
            freedBytes: freedBytes,
            trashedBytes: trashedBytes,
            deletedArtifacts: deleted,
            log: logLines.joined(separator: "\n")
        )
        // 预演不写历史 —— history.jsonl 是「实际发生过什么」的记录，
        // 把没发生的事写进去会让 --history 变得不可信。
        // 自卸载（skipHistory）也不写：历史库文件本就被移到废纸篓，
        // 写了会在原路径重新创建支持目录，留下本该消失的空壳。
        if !dryRun && !skipHistory {
            HistoryStore.append(record)
        }

        if dryRun {
            log(L10n.t("\n━━ 预演结束（什么都没改）━━", "\n━━ Dry run finished (nothing was changed) ━━"))
            log(L10n.t("会处理 \(selected.count) 项：", "Would process \(selected.count) items:"))
            if trashedBytes > 0 {
                log(L10n.t("  · \(SizeFormat.human(trashedBytes)) 移到废纸篓（用户数据，可找回）",
                           "  · \(SizeFormat.human(trashedBytes)) to Trash (user data, recoverable)"))
            }
            if freedBytes > 0 {
                log(L10n.t("  · \(SizeFormat.human(freedBytes)) 直接彻底删除（不可恢复）",
                           "  · \(SizeFormat.human(freedBytes)) permanently deleted (not recoverable)"))
            }
            log(L10n.t("去掉 --dry-run 即真正执行。", "Re-run without --dry-run to apply."))
            return Outcome(record: record, successCount: 0, failureCount: 0, manualCount: 0)
        }

        log(L10n.t("\n━━ 完成 ━━", "\n━━ Done ━━"))
        if manualCount > 0 {
            log(L10n.t("※ \(manualCount) 项需手动处理（见上方 ⚠️ 标记），未计入「已处理」。",
                       "※ \(manualCount) item(s) require manual action (see ⚠️ above) and are not counted as processed."))
        }
        log(L10n.t("成功 \(record.deletedCount) 项，失败 \(record.failedCount) 项，需手动 \(manualCount) 项",
                   "\(record.deletedCount) succeeded, \(record.failedCount) failed, \(manualCount) manual"))
        if trashedBytes > 0 {
            // 措辞不能说「已释放」—— 东西还在废纸篓里占着盘。
            log(L10n.t("已移到废纸篓：\(SizeFormat.human(trashedBytes))（清空废纸篓后才真正释放）", "Moved to Trash: \(SizeFormat.human(trashedBytes)) (disk space reclaimed only after emptying the Trash)"))
        }
        if freedBytes > 0 {
            // 这些是被直接彻底删除的「可安全删除」项，磁盘空间这次真的释放了。
            log(L10n.t("已彻底删除：\(SizeFormat.human(freedBytes))（磁盘空间已释放）", "Permanently deleted: \(SizeFormat.human(freedBytes)) (disk space reclaimed)"))
        }
        return Outcome(record: record, successCount: record.deletedCount, failureCount: failures, manualCount: manualCount)
    }

    /// 设为 true 时完全不输出（自检用）。
    ///
    /// 光设 `onProgress = { _ in }` 不够 —— `log` 还会 `print` 到 stdout，
    /// 自检日志里会混进两行预演文案。
    var silent = false

    private func log(_ s: String) {
        guard !silent else { return }
        onProgress?(s)
        logLines.append(s)
        print(s)
    }

    /// 从 meta 里解析出全部 PID。
    /// 支持 "PID: 123" 和 "PID: 123,124,125 (3 个进程)" 两种格式。
    static func parsePids(from meta: String?) -> [String] {
        guard let meta = meta, meta.hasPrefix("PID: ") else { return [] }
        let body = meta.dropFirst("PID: ".count)
        // 去掉 " (N 个进程)" 后缀
        let numeric = body.split(separator: " ").first ?? body
        return numeric
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Int($0) != nil }
    }
}
