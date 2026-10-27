import Foundation
import AppKit
import UserNotifications

/// 内存守卫：后台周期监控各进程内存占用，发现「单进程吃掉过多内存」的异常者，
/// 按用户选择**仅提醒**或**自动结束**——防止某个应用内存泄漏把系统拖到只能硬重启。
///
/// 背景（真实案例）：微信曾把单进程内存涨到 98 GB（机器仅 16 GB 内存），macOS 靠
/// 疯狂换页硬撑，磁盘 IO 与 CPU 全部打满，系统僵死到强制退出窗口都点不动，只能断电重启。
/// 守卫的价值在于**趁系统还能响应时动手**：
/// - 阈值默认「单进程 ≥ 物理内存的 50%」，正常应用远达不到；
/// - 连续 2 次采样（约 1 分钟）都超阈值才算异常，不误伤编译 / AI 推理的正常峰值；
/// - 保护规则与「进程」页一致：系统进程、关键进程、本应用自身永不动，白名单额外豁免。
///
/// 生命周期：随应用运行（`AppState.init` 里 `applySettings()`），应用退出即停。
final class MemoryGuardian: ObservableObject {
    static let shared = MemoryGuardian()

    // MARK: - 持久化键

    private enum Keys {
        static let enabled = "guard.enabled"
        static let mode = "guard.mode"
        static let thresholdPercent = "guard.thresholdPercent"
        static let whitelist = "guard.whitelist"
        static let events = "guard.events"
    }

    // MARK: - 模型

    /// 发现异常后的处理方式。
    enum ActionMode: String, CaseIterable, Identifiable {
        /// 只发系统通知，让用户自己处理。
        case notify
        /// 直接结束进程（SIGTERM → SIGKILL），并通知告知。
        case autoKill

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .notify:   return L10n.t("仅提醒", "Notify only")
            case .autoKill: return L10n.t("自动结束", "End automatically")
            }
        }
    }

    /// 一次事件的实际处置结果。
    enum EventAction: String, Codable {
        case notified    /// 仅提醒
        case killed      /// 已自动结束
        case killFailed  /// 尝试结束但失败（进程已自行退出等）
        case skipped     /// 在白名单内，跳过

        var displayName: String {
            switch self {
            case .notified:   return L10n.t("已提醒", "Notified")
            case .killed:     return L10n.t("已结束", "Ended")
            case .killFailed: return L10n.t("结束失败", "Failed")
            case .skipped:    return L10n.t("白名单跳过", "Whitelisted")
            }
        }
    }

    /// 一次异常处置的记录。
    struct GuardEvent: Identifiable, Codable {
        let id: UUID
        let date: Date
        let processName: String
        let pid: pid_t
        let memoryBytes: Int64
        let action: EventAction
    }

    // MARK: - 运行状态

    /// 最近的事件（新的在前），最多保留 30 条，随 UserDefaults 持久化。
    @Published private(set) var events: [GuardEvent] = []
    /// 监控是否正在运行（enabled 且定时器已挂上）。
    @Published private(set) var isRunning = false

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.expunge.memory-guardian", qos: .utility)
    /// pid → 连续超阈值次数。进程退出或回落到阈值下即清零。
    private var exceedStreak: [pid_t: Int] = [:]
    /// 已处置过的 pid：同一次泄漏只提醒 / 只杀一次，不会每 30 秒重复轰炸。
    private var handledPids: Set<pid_t> = []

    // MARK: - 参数

    /// 采样间隔。30 秒足够快（微信案例从正常涨到 98 GB 用了远不止 1 分钟），
    /// 也足够慢（单次采样 < 10ms CPU，无感）。
    static let sampleInterval: TimeInterval = 30
    /// 连续超阈值采样次数达到该值才动手。2 次 ≈ 持续 1 分钟。
    static let requiredStreak = 2

    // MARK: - 设置读写（UserDefaults 持久化）

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    var mode: ActionMode {
        get { ActionMode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .notify }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.mode) }
    }

    /// 阈值：单进程内存占物理内存的百分比（10–90）。
    var thresholdPercent: Int {
        get { UserDefaults.standard.object(forKey: Keys.thresholdPercent) as? Int ?? 50 }
        set { UserDefaults.standard.set(min(90, max(10, newValue)), forKey: Keys.thresholdPercent) }
    }

    /// 进程名白名单（大小写不敏感）：编译器、AI 工具等峰值占用高的可以豁免。
    var whitelist: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.whitelist) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.whitelist) }
    }

    /// 当前阈值对应的字节数。
    var thresholdBytes: Int64 {
        Int64(Double(ProcessInfo.processInfo.physicalMemory) * Double(thresholdPercent) / 100.0)
    }

    /// 把设置变更落成运行状态：开了就启动监控，关了就停。
    func applySettings() {
        if isEnabled { start() } else { stop() }
    }

    // MARK: - 启停

    private func start() {
        guard timer == nil else { return }
        isRunning = true
        exceedStreak.removeAll()
        handledPids.removeAll()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.sampleInterval, repeating: Self.sampleInterval)
        t.setEventHandler { [weak self] in self?.sampleOnce() }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
        exceedStreak.removeAll()
        handledPids.removeAll()
    }

    /// 首次启用时请求通知权限（仅提醒模式下没权限 = 守卫白开）。
    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - 采样与判定

    private func sampleOnce() {
        let procs = ProcessLister.lightweightSample()
        let livePids = Set(procs.map(\.pid))
        // 处置记录只对「还活着的 pid」有效，进程退了就允许下个实例再次触发。
        handledPids = handledPids.filter { livePids.contains($0) }

        var newStreak: [pid_t: Int] = [:]
        var suspects: [LiveProcess] = []
        for p in procs where p.isKillable {
            if p.memoryBytes >= thresholdBytes {
                let streak = (exceedStreak[p.pid] ?? 0) + 1
                newStreak[p.pid] = streak
                if streak >= Self.requiredStreak { suspects.append(p) }
            }
        }
        exceedStreak = newStreak
        guard !suspects.isEmpty else { return }

        let wl = Set(whitelist.map { $0.lowercased() })
        for s in suspects where !handledPids.contains(s.pid) {
            handle(suspect: s, whitelist: wl)
            handledPids.insert(s.pid)
        }
    }

    /// 纯函数：一个样本是否达到「该动手」条件（自检用）。
    static func isSuspect(memoryBytes: Int64, thresholdBytes: Int64, streak: Int) -> Bool {
        memoryBytes >= thresholdBytes && streak >= requiredStreak
    }

    /// 纯函数：进程名是否命中白名单（大小写不敏感，自检用）。
    static func isWhitelisted(_ name: String, whitelist: [String]) -> Bool {
        let lower = name.lowercased()
        return whitelist.contains { $0.lowercased() == lower }
    }

    private func handle(suspect: LiveProcess, whitelist: Set<String>) {
        let gb = SizeFormat.human(suspect.memoryBytes)

        guard !whitelist.contains(suspect.name.lowercased()) else {
            record(processName: suspect.name, pid: suspect.pid, memoryBytes: suspect.memoryBytes, action: .skipped)
            return
        }

        switch mode {
        case .notify:
            record(processName: suspect.name, pid: suspect.pid, memoryBytes: suspect.memoryBytes, action: .notified)
            postNotification(
                title: L10n.t("内存守卫：发现异常占用", "Memory Guardian: abnormal usage"),
                body: L10n.t("\(suspect.name) 已占用 \(gb) 内存（连续超阈值），建议尽快退出或重启该应用。",
                             "\(suspect.name) is using \(gb) of memory (sustained over threshold). Consider quitting or restarting it."))
        case .autoKill:
            let n = ProcessTerminator.terminate(pids: [suspect.pid])
            let action: EventAction = n > 0 ? .killed : .killFailed
            record(processName: suspect.name, pid: suspect.pid, memoryBytes: suspect.memoryBytes, action: action)
            postNotification(
                title: action == .killed
                    ? L10n.t("内存守卫：已自动结束异常进程", "Memory Guardian: process ended")
                    : L10n.t("内存守卫：结束进程失败", "Memory Guardian: failed to end process"),
                body: action == .killed
                    ? L10n.t("\(suspect.name) 占用已达 \(gb)，为防止系统卡死已自动结束。重新打开即可继续使用。",
                             "\(suspect.name) reached \(gb) of memory and was ended to keep the system responsive. Just reopen it.")
                    : L10n.t("\(suspect.name) 占用已达 \(gb)，自动结束失败，请手动处理。", "\(suspect.name) reached \(gb) of memory; automatic end failed — handle it manually."))
        }
    }

    // MARK: - 事件记录

    private func record(processName: String, pid: pid_t, memoryBytes: Int64, action: EventAction) {
        let event = GuardEvent(id: UUID(), date: Date(),
                               processName: processName, pid: pid,
                               memoryBytes: memoryBytes, action: action)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.events.insert(event, at: 0)
            if self.events.count > 30 { self.events.removeLast(self.events.count - 30) }
            if let data = try? JSONEncoder().encode(self.events) {
                UserDefaults.standard.set(data, forKey: Keys.events)
            }
        }
    }

    private func loadEvents() {
        guard events.isEmpty,
              let data = UserDefaults.standard.data(forKey: Keys.events),
              let restored = try? JSONDecoder().decode([GuardEvent].self, from: data) else { return }
        events = restored
    }

    // MARK: - 系统通知

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
