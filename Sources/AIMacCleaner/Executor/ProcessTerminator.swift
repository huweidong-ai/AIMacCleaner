import AppKit
import Foundation
import Darwin

/// 卸载 / 删除前，主动把「目标 app 自身」的运行进程退掉。
///
/// **为什么需要**：`RemovalExecutor` 阶段 1 只会杀用户勾选的 `runningProcess` 类目项。
/// 但很多 app 的主进程并不在那张残留列表里 —— 于是 `.app` 被移进废纸篓、进程却还
/// 占着内存继续跑，表现就是用户说的「删了还在用」。这里在真正删文件之前，按
/// bundle id / 显示名 / 关键词把目标 app 的所有实例先优雅退出、不退就强杀。
///
/// **安全**：绝不终止本工具自身（否则卸载跑到一半进程没了，后面的活全砸了）。
enum ProcessTerminator {

    /// 纯函数：判断一个运行中的 app 是否应被本次卸载终止。
    ///
    /// 抽成纯函数是为了能单测，不依赖 `NSWorkspace` 实时进程表。
    ///
    /// 匹配规则（刻意避免裸子串，否则会误杀无关 app）：
    /// - **精确 / 前缀**：`bid == 目标` 或 `bid` 以 `目标.` 开头（捕获 `com.qoder.work.helper` 这类 helper）；
    ///   `name == 目标` 或 `name` 以 `目标 `（带空格）开头（捕获 "QoderWork Helper (GPU)"）。
    /// - **关键词兜底**：只在 bundle id 的「段边界」或英文「词边界」命中才算，例如关键词 `work`
    ///   必须落在 `.work.` / `.work` 结尾 / `work.` 开头 或名称里独立的 ` work ` 词上 ——
    ///   因此 `com.tencent.workbuddy` / `WorkBuddy` 不会被 `com.qoder.work` 的末段 `work` 误伤。
    ///
    /// 自身排除（bundle id 等于本工具、或 pid 是本进程）不在这里处理，由 `terminate` 统一过滤。
    static func isTarget(_ bid: String?, _ name: String?,
                         targetBundleId: String?, targetName: String?,
                         keywords: [String]) -> Bool {
        guard let b = bid?.lowercased(), let n = name?.lowercased() else { return false }
        let tBid = targetBundleId?.lowercased()
        let tName = targetName?.lowercased()
        let lowerKeywords = keywords.map { $0.lowercased() }

        // 1) 精确 + helper 前缀：最可靠，优先。
        if let t = tBid, b == t || b.hasPrefix(t + ".") { return true }
        if let t = tName, n == t || n.hasPrefix(t + " ") { return true }

        // 2) 关键词只作兜底，且必须落在段 / 词边界，杜绝 "work" 误杀 "WorkBuddy"。
        return lowerKeywords.contains { kw in
            // 通用末段词（app / helper / service…）跳过：否则会命中一切以 .app 结尾的 bundle id，
            // 复刻 AppIdentity.genericBundleSuffixes 的防护。
            guard !kw.isEmpty, !AppIdentity.genericBundleSuffixes.contains(kw) else { return false }
            // bundle id 段边界：整段相等、或出现在 `.<kw>.` / `.<kw>` 结尾 / `<kw>.` 开头
            let byBid = b == kw || b.hasPrefix(kw + ".")
                          || b.hasSuffix("." + kw) || b.contains("." + kw + ".")
            // 名称词边界：整词相等、或以「目标 」开头、或嵌在独立词 ` kw ` 中
            let byName = n == kw || n.hasPrefix(kw + " ")
                           || n.contains(" " + kw + " ")
            return byBid || byName
        }
    }

    /// 终止匹配给定 bundle id / 名称 / 关键词、且仍在运行的 app（排除自身）。
    /// - Returns: 实际发起终止的进程数。
    @discardableResult
    static func terminate(targetBundleId: String? = nil,
                          targetName: String? = nil,
                          keywords: [String] = []) -> Int {
        let ownBundle = Bundle.main.bundleIdentifier
        let ownPid = ProcessInfo.processInfo.processIdentifier

        let byBundle = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleId ?? "")
        let all = NSWorkspace.shared.runningApplications
        let matched = Set(byBundle).union(all.filter { app in
            isTarget(app.bundleIdentifier, app.localizedName,
                     targetBundleId: targetBundleId, targetName: targetName, keywords: keywords)
        })

        // 排除自己：正在执行的卸载工具不能被自己干掉。
        let targets = matched.filter { app in
            if let bid = app.bundleIdentifier, bid == ownBundle { return false }
            if app.processIdentifier == ownPid { return false }
            return true
        }
        guard !targets.isEmpty else { return 0 }

        // 1) 先优雅退出（发 Quit Apple Event，让 app 有机会保存）。
        for app in targets { app.terminate() }
        // 2) 给 1 秒收尾；还活着的强杀。
        Thread.sleep(forTimeInterval: 1.0)
        for app in targets where !app.isTerminated {
            if let bid = app.bundleIdentifier, bid == ownBundle { continue }
            if app.processIdentifier == ownPid { continue }
            app.forceTerminate()
        }
        return targets.count
    }

    /// 按 PID 终止一组进程（优雅退出 → 强杀）。用于「进程」tab 的手动清理。
    /// - Returns: 实际结束（已退出）的进程数。
    ///
    /// 排除自身与 `pid ≤ 1`，绝不终止 AI Mac Cleaner 自己或 init/launchd 之类。
    @discardableResult
    static func terminate(pids: [pid_t]) -> Int {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let targets = pids.filter { $0 != ownPid && $0 > 1 }
        guard !targets.isEmpty else { return 0 }

        // 1) 先 SIGTERM，给进程保存 / 退出的机会。
        for pid in targets { kill(pid, SIGTERM) }
        // 2) 等 1 秒收尾。
        Thread.sleep(forTimeInterval: 1.0)
        // 3) 还活着的强杀。
        var killed = 0
        for pid in targets {
            if kill(pid, 0) == 0 {        // 仍然存活
                kill(pid, SIGKILL)
            }
            // 再确认一次：已退出（ESRCH，kill 返回非 0）才算成功结束。
            if kill(pid, 0) != 0 { killed += 1 }
        }
        return killed
    }
}
