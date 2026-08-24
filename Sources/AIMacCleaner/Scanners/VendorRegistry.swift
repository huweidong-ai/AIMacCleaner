import Foundation

/// 同源厂商残留识别。
///
/// **为什么需要**：现代大厂常把一个产品拆成多个独立入口——
/// OpenAI 既有 ChatGPT 桌面 app（整合了 Codex 模式），又有 Codex CLI
/// （`~/.codex/` 数据目录 + `npm i -g @openai/codex`）、Chrome 扩展宿主常驻进程
/// （`plugins/cache/openai-bundled/chrome`，注册菜单栏图标）、相关 launch agent。
/// 这些入口**安装/卸载互不相连**：卸载 ChatGPT.app 时，按 bundle id 扫不到
/// `~/.codex/`，于是留下一个 637 MB 的死目录，以及一个点不动的菜单栏幽灵图标
/// （那个常驻进程的主程序早被删了）。
///
/// 这里用一张「厂商 → 痕迹特征」映射表，在卸载某厂商 app 时，额外把同厂商的
/// 其他入口拉出来，单独列成一组「同厂商残留」，让用户勾选是否一并清理。
enum VendorRegistry {

    /// 一条厂商残留特征定义。
    struct VendorTrace {
        /// 展示名（双语）
        let displayName: String
        /// 探测函数：返回非 nil 表示该痕迹确实存在，值是它的路径/进程描述
        let probe: () -> String?
        /// 风险等级：`.codex` 目录可能含会话/配置（userData），常驻进程是 safe
        let risk: Risk
        /// 删除处置：目录走废纸篓、进程走「杀」
        let disposition: Disposition

        enum Disposition {
            case trashDir    // 走废纸篓（可恢复）
            case killProcess // 杀进程（meta 填 PID / 进程描述）
        }
    }

    /// 厂商条目：给定 bundle id / 显示名命中后，列出该厂商的其他残留特征。
    struct Vendor {
        /// 厂商识别关键词（低大小写）。命中 app 的 bundle id 或别名任一即认领。
        let identifiers: [String]
        /// 厂商展示名
        let name: String
        /// 该厂商已知的其他残留
        let traces: [VendorTrace]
    }

    // MARK: - 厂商表

    /// 已登记的厂商。先收 OpenAI（本次真实踩坑），后续可平滑扩展 Google / Adobe / 微软 等。
    static let vendors: [Vendor] = [
        Vendor(
            identifiers: ["openai", "chatgpt", "codex"],
            name: "OpenAI",
            traces: [
                // 1) Codex CLI / 旧 Codex 桌面端的数据目录（用户家目录根，不在 ~/Library）
                VendorTrace(
                    displayName: L10n.t("Codex CLI 数据目录", "Codex CLI data"),
                    probe: {
                        let p = NSHomeDirectory() + "/.codex"
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue
                        else { return nil }
                        return p
                    },
                    risk: .userData,
                    disposition: .trashDir
                ),
                // 2) OpenAI 常驻的 Chrome 扩展宿主进程（菜单栏幽灵图标来源）
                VendorTrace(
                    displayName: L10n.t("OpenAI 常驻进程（菜单栏图标）", "OpenAI resident process (menu bar)"),
                    probe: {
                        let pids = residentOpenAIProcesses()
                        return pids.isEmpty ? nil : "PID: " + pids.joined(separator: ",")
                    },
                    risk: .safe,
                    disposition: .killProcess
                ),
                // 3) OpenAI 相关 launch agent
                VendorTrace(
                    displayName: L10n.t("OpenAI 启动项", "OpenAI launch agent"),
                    probe: {
                        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
                        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
                        let hit = files.first { f in
                            let lower = f.lowercased()
                            return lower.contains("openai") || lower.contains("chatgpt") || lower.contains("codex")
                        }
                        guard let h = hit else { return nil }
                        return dir + "/" + h
                    },
                    risk: .safe,
                    disposition: .trashDir
                )
            ]
        )
    ]

    // MARK: - 对外 API

    /// 给定已定位的 app，返回它所属厂商（若有）。
    static func vendor(for app: AppIdentity) -> Vendor? {
        let haystack = ([app.bundleId ?? "", app.displayName, app.fileName]
                        + app.aliases).map { $0.lowercased() }
        return vendors.first { vendor in
            vendor.identifiers.contains { id in
                haystack.contains { $0.contains(id) }
            }
        }
    }

    /// 探测某厂商当前确实存在的残留，转成 `Artifact`（未勾选/按风险定默认）。
    /// 不存在的痕迹直接跳过，避免列出空项骗用户。
    static func leftoverArtifacts(for vendor: Vendor) -> [Artifact] {
        vendor.traces.compactMap { trace in
            guard let hit = trace.probe() else { return nil }
            let category: ArtifactCategory = (trace.disposition == .killProcess)
                ? .runningProcess
                : .vendorLeftover
            let size = trace.disposition == .trashDir ? directorySize(hit) : 0
            // 用户数据默认不勾选（留一线可找回）；safe 默认勾选。
            let selected = (trace.risk != .userData)
            var art = Artifact(category: category, path: hit, size: size,
                               risk: trace.risk, meta: (trace.disposition == .killProcess ? hit : nil),
                               selected: selected)
            art.note = trace.displayName
            return art
        }
    }

    /// 便捷：给定 app，直接返回同厂商残留 Artifact（空数组表示无）。
    static func vendorLeftovers(for app: AppIdentity) -> [Artifact] {
        guard let v = vendor(for: app) else { return [] }
        return leftoverArtifacts(for: v)
    }

    // MARK: - 辅助

    /// 找 OpenAI 常驻进程（非 AppStore/系统）：命令行含 ChatGPT/OpenAI/codex 关键词、
    /// 且不属于当前已装 app 的进程。
    private static func residentOpenAIProcesses() -> [String] {
        guard let output = Shell.run("/usr/bin/pgrep", ["-fil", "openai"]),
              !output.isEmpty else { return [] }
        var pids: [String] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let pid = String(parts[0])
            let cmd = String(parts[1])
            // 排除 AI Mac Cleaner 自身
            if cmd.contains("/AIMacCleaner.app/") || cmd.hasSuffix("/AIMacCleaner") { continue }
            pids.append(pid)
        }
        return pids
    }

    /// 目录大小（递归），失败返回 0。
    private static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(at: url,
              includingPropertiesForKeys: [.fileSizeKey],
              options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
