import Foundation

/// 通过 `pgrep -fil <target>` 查找正在运行的进程。
struct ProcessScanner: Scanner {
    let name = "ProcessScanner"

    func scan(query: ScanQuery) async -> [Artifact] {
        guard !query.isEmpty else { return [] }

        var seenPids = Set<String>()
        // 可执行文件 → 它派生的所有 PID。折叠展示，但一个都不能漏杀。
        var pidsByExecutable: [String: [String]] = [:]
        var executableOrder: [String] = []

        // 逐个关键词跑 pgrep。进程名通常是可执行文件名（WeChat），
        // 不会是本地化显示名（微信），所以必须用全部别名各查一次。
        for keyword in query.keywords {
            // keyword 作为独立 argv 传给 pgrep，不经过 shell，因此不需要转义引号。
            guard let output = Shell.run("/usr/bin/pgrep", ["-fil", keyword]),
                  !output.isEmpty else { continue }

            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { continue }
                let pid = String(parts[0])
                let fullCommand = String(parts[1])

                // 同一进程可能被多个别名命中，按 pid 去重
                guard seenPids.insert(pid).inserted else { continue }

                // 排除 AI Mac Cleaner 自己：卸载别的 app 时不该把自己列出来杀掉
                if fullCommand.contains("/AIMacCleaner.app/") || fullCommand.hasSuffix("/AIMacCleaner") { continue }

                // 只保留可执行文件路径。Electron/Chromium 系的 app（微信、VS Code）
                // 会派生一堆 helper，每条命令行长达数百字符，全打出来根本没法读。
                let executable = executablePath(from: fullCommand)

                // pgrep -f 扫的是整行命令，会把「命令行里含目标关键词但属于别的 app」的
                // 进程也带进来。比如扫 GitHub 时，Clash Verge 的 bundle id 是
                // io.github.clash-verge-rev，命令行含 "github"，pgrep 就会命中
                // verge-mihomo。用 ScanQuery 的匹配/排他逻辑再滤一遍：
                // 可执行文件路径或整行命令至少有一处命中本 app、且不被更长外来名覆盖。
                guard query.matches(executable) || query.matches(fullCommand) else { continue }

                if pidsByExecutable[executable] == nil {
                    executableOrder.append(executable)
                }
                pidsByExecutable[executable, default: []].append(pid)
            }
        }

        // 每个可执行文件一项，PID 全部保留在 meta 里供执行器逐个杀。
        return executableOrder.map { exe in
            let pids = pidsByExecutable[exe] ?? []
            let label = pids.count > 1
                ? "PID: \(pids.joined(separator: ",")) (\(pids.count) 个进程)"
                : "PID: \(pids.first ?? "?")"
            return Artifact(
                category: .runningProcess,
                path: exe,
                size: 0,
                risk: .safe,
                meta: label
            )
        }
    }

    /// 从完整命令行里切出可执行文件路径，丢掉参数。
    /// 路径可能含空格（"WeChatAppEx Helper (GPU)"），所以不能简单按空格切——
    /// 从左往右累加片段，遇到第一个 `-` 开头的参数就停。
    private func executablePath(from command: String) -> String {
        let segments = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var accumulated: [String] = []
        for seg in segments {
            if seg.hasPrefix("-") && !accumulated.isEmpty { break }
            accumulated.append(seg)
            let candidate = accumulated.joined(separator: " ")
            // 累加到一个真实存在的可执行文件就停
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // 找不到就退回第一段，至少不返回整条命令行
        return segments.first ?? command
    }
}
