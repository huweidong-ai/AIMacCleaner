import Foundation

/// AI 参与的「发现」环节 —— **只提议，不执行**。
///
/// 背景：内置扫描器是按规则匹配的，规则覆盖不到的路径它就永远看不见。
/// 真机案例（ego lite）：数据全在 `~/Library/Application Support/Citro Labs/ego lite`
/// —— 父目录叫 `Citro Labs`、不含 app 名，加上 keystone 框架启动项、
/// `~/.local/bin` 里的 CLI、嵌套在 `Logs/DiagnosticReports` 下的崩溃报告，
/// 通用规则一条都命中不了。模型见过这些软件，能补上「还可能藏在哪」这一层。
///
/// ## 信任边界（本文件存在的全部理由）
///
/// 1. **模型只输出路径字符串，没有任何删除工具接口。**
///    全代码只有 `FileDeleter.delete()` 能改文件系统，而它只被
///    「用户勾选 + 确认弹窗」之后的卸载流程调用。模型说「可删」不构成授权。
///
/// 2. **每条提议都要过本地校验网**（`judge`）：
///    黑名单 → 白名单 → 保护根 → app 包内 → 系统名 → **活 app 反查**
///    （被别的活 app 认领就丢）→ 用户记忆豁免 → 去重 → 必须真实存在。
///    任何一条不过就丢弃。这一层与内置扫描器同源，是**不信任模型**的实现。
///
/// 3. **通过校验也一律 `selected = false`**，且默认按 `.userData` 对待
///    → 真删起来走废纸篓，可找回。
///
/// ## 残余风险
///
/// 只有一类：模型可能把「多个 app 共享的配置」误认成目标 app 专属。
/// 对策是上面的 2 + 3（活 app 反查 + 默认不勾 + 废纸篓兜底）。
/// **不存在「让 AI 永远正确」的方案**——架构该做的是让失误可恢复、
/// 且必须经人确认。
/// 调用失败的种类：决定「要不要重试」。
enum AIProposeFailureKind: Equatable, Sendable {
    /// key 失效 / 没额度 / 配置错误（地址错、模型名错）：重试无意义，本次会话直接停用。
    case permanent
    /// 网络不通 / 超时 / 服务端 5xx / 限流：可能自愈，下次扫描再试。
    case transient
}

/// `propose` 的返回类型。把「调用失败」和「调用成功但模型没补充」分开，
/// 这样熔断逻辑不会把「模型确实没找到」误判成故障；失败时再带一个种类，
/// 让调用方区分「永久失效（不重试）」与「网络瞬时（可重试）」。
enum AIProposeResult: Equatable, Sendable {
    /// 模型调用成功；`artifacts` 可能为空（模型确实没补充任何路径）。
    case ok([Artifact])
    /// 调用失败；`permanent` 不重试，`transient` 下次再试。
    case failed(AIProposeFailureKind)

    /// 便捷取数：失败的场合当作空数组。
    var artifacts: [Artifact] {
        if case .ok(let a) = self { return a }
        return []
    }
}

enum AIScanProposer {

    // MARK: - 对外参数

    /// 单次最多采纳几条提议。模型可能一次性倒出几十条「可能相关」的路径，
    /// 全都塞进清单会让用户面对一堆他无法核对的条目 —— 上限把爆炸半径压在人能看完的范围内。
    static let maxItems = 12

    // MARK: - 校验网上下文

    /// 一次扫描内复用的判定素材。单独拎出来是为了**只算一次** ——
    /// `liveBundleIds()` 要递归读所有 app 的 Info.plist，放进逐条循环里会慢到不可用。
    struct Context {
        /// 除目标 app 自身（含其包内嵌套组件）外，全机器活着的 bundle id。
        let otherLiveIds: Set<String>
        /// 除目标 app 自身外，活 app 的名字类别名。
        let otherLiveNames: Set<String>
        /// 用户通过 `/remember` 记下的豁免路径。
        let keepPaths: Set<String>
        /// 目标 app 的 `.app` 绝对路径（已标准化）。
        let bundlePath: String
        /// 目标 app 的「自称」词集合（小写）：别名、文件名、显示名、bundle id、厂商段。
        /// 用来判断某个父目录名（`Google`）是不是它自家的厂商目录。
        let ownedTokens: Set<String>

        static func build(app: AppIdentity) -> Context {
            // 缓存版清单：allApps() / liveBundleIds() 都有进程内缓存，重复调用不读盘。
            let allApps = InventoryCache.shared.allApps()
            var names: Set<String> = []
            var ids = InventoryCache.shared.liveBundleIds()

            for a in allApps where a.bundlePath != app.bundlePath {
                names.formUnion(a.aliases)
                names.insert(a.fileName.lowercased())
                names.insert(a.displayName.lowercased())
                names.insert(a.fileName.lowercased().replacingOccurrences(of: " ", with: ""))
                names.insert(a.displayName.lowercased().replacingOccurrences(of: " ", with: ""))
                if let suffix = a.bundleIdSuffix { names.insert(suffix) }
            }

            // 目标 app 自己的一大家子要从「别人」里剔掉：
            // 只删 bundleId 顶层不够 —— Electron app 包里有一堆
            // `….helper` / `….helper.renderer`，留着它们会让 hasLiveSibling
            // 把目标 app 自己的痕迹判成「被别的活 app 认领」。
            if let bid = app.bundleId?.lowercased() { ids.remove(bid) }
            let bundle = URL(fileURLWithPath: app.bundlePath).standardizedFileURL
            ids.subtract(AppInventory.nestedBundleIds(in: bundle))

            var tokens: Set<String> = []
            tokens.formUnion(app.aliases)
            tokens.insert(app.fileName.lowercased())
            tokens.insert(app.displayName.lowercased())
            if let bid = app.bundleId?.lowercased() {
                tokens.insert(bid)
                if let vendor = OrphanScanner.vendorSegment(of: bid) { tokens.insert(vendor) }
            }

            return Context(otherLiveIds: ids,
                           otherLiveNames: names.filter { !$0.isEmpty },
                           keepPaths: MemoryStore.shared.keepPaths(),
                           bundlePath: bundle.path,
                           ownedTokens: tokens.filter { !$0.isEmpty })
        }
    }

    // MARK: - 判定结果

    /// 一条提议被拒的具体原因。带原因而不是只返回 nil：
    /// 自检能精确断言「是因为活 app 反查被拒」，而不是「反正返回了 nil」。
    enum Rejection: String {
        case empty
        case wildcard
        case relative
        case forbidden
        case notAllowed
        case protectedRoot
        case insideAppBundle
        case systemOwned
        case claimedByOtherApp
        case userExempt
        case alreadyKnown
        case missing
    }

    enum Verdict {
        case accept(String)   // 标准化后的绝对路径
        case reject(Rejection)
    }

    // MARK: - 对外 API

    /// 让模型补充提议「内置扫描器可能漏掉的残留路径」，过校验网后转成 Artifact。
    ///
    /// 返回 `AIProposeResult`：`.failed(kind)` 表示调用没成功，关联值区分
    /// 「永久（key 失效 / 没额度 / 配置错误，不重试）」与「瞬时（网络 / 超时 / 5xx / 限流，可重试）」；
    /// 调用成功但模型没补充任何路径，是 `.ok([])` 而**不是** `.failed` —— 模型跑通了，
    /// 不算故障。`AppState` 据此决定「永久失效则停用、网络错误则重试」。
    static func propose(app: AppIdentity, knownPaths: Set<String>, config: AIModelConfig) async -> AIProposeResult {
        guard config.isConfigured else { return .failed(.permanent) }
        let reply: String
        do {
            reply = try await LLMClient.complete(
                config: config,
                messages: [(role: "user", content: userPrompt(app: app, known: knownPaths))],
                system: systemPrompt
            )
        } catch LLMError.noContent {
            // HTTP 成功但模型没返回内容：调用是通的，按「没补充」处理，不计入故障。
            if ProcessInfo.processInfo.environment["AIPROPOSE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("AIPROPOSE: empty content (ok, nothing to add)\n".utf8))
            }
            return .ok([])
        } catch let e as LLMError {
            if ProcessInfo.processInfo.environment["AIPROPOSE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("AIPROPOSE: LLM call failed (\(e))\n".utf8))
            }
            return .failed(classify(e))
        } catch {
            // 网络层错误（URLSession 抛的），归为可重试的瞬时失败。
            if ProcessInfo.processInfo.environment["AIPROPOSE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("AIPROPOSE: LLM call threw (\(error))\n".utf8))
            }
            return .failed(.transient)
        }
        if ProcessInfo.processInfo.environment["AIPROPOSE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("AIPROPOSE raw reply:\n\(reply)\n".utf8))
        }

        let proposals = parse(reply)
        // 解析不出任何条目：调用是成功的，只是模型没补充 —— 归为 `.ok([])`，不计入故障。
        guard !proposals.isEmpty else { return .ok([]) }

        let context = Context.build(app: app)
        var out: [Artifact] = []
        var seen = Set<String>()
        for p in proposals {
            guard out.count < maxItems else { break }
            guard case .accept(let path) = judge(p.path, known: knownPaths, context: context),
                  seen.insert(path).inserted else { continue }
            out.append(makeArtifact(path: path, reason: p.reason))
        }
        return .ok(out)
    }

    /// 把 LLM 错误分类成「永久（不重试）/ 瞬时（可重试）」。
    ///
    /// - 401/403 鉴权失败、402 没额度、400 请求错误（模型名/格式）、404/其它 4xx（地址错）→ permanent；
    /// - 429 限流、5xx 服务端错误 → transient（可能自愈）；
    /// - missingKey / badURL → permanent（配置问题）；underlying（网络层）→ transient。
    private static func classify(_ e: LLMError) -> AIProposeFailureKind {
        switch e {
        case .missingKey, .badURL:
            return .permanent
        case .insufficientBalance:
            // 余额不足：重试无意义，属于「永久失效」——该熔断并提示充值，
            // 而不是让用户对着转圈等一个永远不会成功的结果。
            return .permanent
        case .http(let status, _):
            switch status {
            case 401, 402, 403, 400, 404:
                return .permanent
            case 429:
                return .transient
            default:
                return status >= 500 ? .transient : .permanent
            }
        case .noContent:
            // 不会走到这（已在 do/catch 里单独处理成 .ok([])），兜底成瞬时也无妨。
            return .transient
        case .upstreamFailed:
            // 网关转给别的上游且那次失败：纯瞬时，重试有意义，且**不该**被判成
            // 「key 失效」——Key 是好的，不该因此禁用整个会话。
            return .transient
        case .underlying:
            return .transient
        }
    }

    /// 单条路径过校验网，返回标准化后的路径；nil 表示被拒。
    static func validate(_ rawPath: String, known: Set<String>, context: Context) -> String? {
        if case .accept(let path) = judge(rawPath, known: known, context: context) { return path }
        return nil
    }

    /// 单条路径被拒的原因；nil 表示通过。
    static func rejectionReason(_ rawPath: String, known: Set<String>, context: Context) -> Rejection? {
        if case .reject(let r) = judge(rawPath, known: known, context: context) { return r }
        return nil
    }

    /// 「撤销 AI 分析」后该项应保持的勾选状态。
    ///
    /// `AppState.undoAIReview()` 会把应用页全部项恢复成默认勾选 ——
    /// 那是给内置扫描器结果用的（用户数据也默认勾）。AI 提议项不在这个约定里：
    /// 它们从没被默认勾过，撤销一次分析就自动勾上是纯粹的误删入口。
    static func selectionAfterUndo(_ artifact: Artifact, defaultSelected: Bool) -> Bool {
        artifact.category == .aiProposed ? false : defaultSelected
    }

    // MARK: - 校验网

    /// 逐条判定。**顺序即优先级**，每一道都是终审。
    static func judge(_ rawPath: String, known: Set<String>, context: Context) -> Verdict {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .reject(.empty) }
        // 通配/模糊路径不接受：我们只采纳确切路径，glob 的展开权不能交给模型。
        if trimmed.contains("*") || trimmed.contains("?") { return .reject(.wildcard) }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let path = (expanded as NSString).standardizingPath
        guard path.hasPrefix("/") else { return .reject(.relative) }

        for prefix in FileDeleter.forbiddenPrefixes where path.hasPrefix(prefix) {
            return .reject(.forbidden)
        }

        // 家目录根、~/Library、~/Documents 这类「容器本身」一律不收 ——
        // 它们不是某个 app 的痕迹，删掉等于清家。
        //
        // 放在白名单**之前**：白名单按前缀匹配且带尾斜杠，`~/Library/Application Support`
        // 这种恰好等于前缀的路径会先落到 `.notAllowed`。结论一样（都是拒），
        // 但这里的原因更准确 —— 自检要能断言「是因为它是保护根」。
        if protectedRoots.contains(path) { return .reject(.protectedRoot) }

        guard FileDeleter.isAllowed(path) else { return .reject(.notAllowed) }

        // app 包内部：卸载时 appBundle 那一项已经整体处理，
        // 再列一条包内子路径会让用户在「删了又冒出来」之间打转。
        if path == context.bundlePath || path.hasPrefix(context.bundlePath + "/") {
            return .reject(.insideAppBundle)
        }

        let last = (path as NSString).lastPathComponent
        if SystemOwned.isSystemOwned(last) { return .reject(.systemOwned) }

        // ── 活 app 反查：这一道是防误删的主力 ──
        // 被任何一个**别的**活 app 认领，就直接丢。模型分不清
        // 「~/Library/Application Support/Google/Chrome」属于谁，
        // 但已装 app 清单知道。
        if claimedByOtherApp(last, context: context) { return .reject(.claimedByOtherApp) }
        // 父目录也要查：`…/Google/Chrome` 的父级 `Google` 若被别的 app 认领
        // （而目标 app 又不是这家厂商），说明这是别家的数据。
        //
        // 但**伞形目录不参与这层判断**：`~/Library/Caches/xxx` 的父级叫 `Caches`，
        // 它属于系统而不属于任何 app —— 若拿它去反查，等于把所有缓存路径一律拒掉。
        let parent = (path as NSString).deletingLastPathComponent
        let parentName = (parent as NSString).lastPathComponent
        if !parentName.isEmpty, parentName != "/",
           !protectedRoots.contains(parent),
           !SystemOwned.isSystemOwned(parentName),
           !targetOwns(parentName, context: context),
           claimedByOtherApp(parentName, context: context) {
            return .reject(.claimedByOtherApp)
        }

        // 用户说过「这个别动」就真的不报 —— 与 OrphanScanner 同一套豁免。
        if MemoryPolicy.isExempt(path, keepPaths: context.keepPaths) { return .reject(.userExempt) }

        if known.contains(path) { return .reject(.alreadyKnown) }

        // 最后才查存在性：模型会编路径，不存在的东西报出来只是噪音。
        guard FileManager.default.fileExists(atPath: path) else { return .reject(.missing) }

        return .accept(path)
    }

    // MARK: - 归属判定

    /// 这个名字是否被**别的**活 app 认领。
    private static func claimedByOtherApp(_ rawName: String, context: Context) -> Bool {
        var name = rawName
        // Preferences / LaunchAgents 里的痕迹带 .plist，容器的名字不带后缀。
        if name.hasSuffix(".plist") { name = String(name.dropLast(".plist".count)) }
        let normalized = OrphanScanner.stripPrefixes(name).lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return false }
        if SystemOwned.isSystemOwned(normalized) { return true }

        // bundle-id 形状：复用孤儿扫描那套双向前缀 + 厂商兄弟判定。
        if normalized.contains(".") {
            return OrphanScanner.isClaimed(normalized, live: context.otherLiveIds)
        }
        // 纯名字目录：按活 app 名字认领（精确 → 去后缀 → 去版本 → 双向子串）。
        return nameClaimed(normalized, by: context.otherLiveNames)
    }

    private static func nameClaimed(_ n: String, by names: Set<String>) -> Bool {
        guard !names.isEmpty else { return false }
        if names.contains(n) { return true }
        let base = n.replacingOccurrences(of: "-desktop", with: "")
            .replacingOccurrences(of: "-app", with: "")
            .replacingOccurrences(of: "-mac", with: "")
            .replacingOccurrences(of: "-osx", with: "")
        if base != n && names.contains(base) { return true }
        let noVer = OrphanScanner.stripTrailingVersion(base)
        if noVer != base && names.contains(noVer) { return true }
        // 双向子串兜底时要求较长一侧 ≥4 个字符，否则 "ai"、"code" 这类短词会到处误伤。
        for other in names {
            if (other.contains(n) || n.contains(other)) && max(other.count, n.count) >= 4 { return true }
            if (other.contains(noVer) || noVer.contains(other)) && max(other.count, noVer.count) >= 4 {
                return true
            }
        }
        return false
    }

    /// 目标 app 自己是否「拥有」这个名字（用于判断父目录是不是它自家的厂商目录）。
    private static func targetOwns(_ rawName: String, context: Context) -> Bool {
        let n = rawName.lowercased()
        guard n.count >= 3 else { return false }
        return context.ownedTokens.contains { token in
            guard token.count >= 3 else { return false }
            return token.contains(n) || n.contains(token)
        }
    }

    // MARK: - 保护根

    /// 家目录本身与各「容器级」目录。这些路径通过白名单，但它们不是 app 痕迹。
    private static var protectedRoots: Set<String> {
        let home = NSHomeDirectory()
        var set: Set<String> = [home, "/Applications", "/Library"]
        for rel in ["", "/Library", "/Library/Application Support", "/Library/Caches",
                    "/Library/Preferences", "/Library/Containers", "/Library/Group Containers",
                    "/Library/Logs", "/Library/LaunchAgents", "/Library/HTTPStorages",
                    "/Library/WebKit", "/Library/Application Scripts", "/Library/Cookies",
                    "/Library/Saved Application State", "/Documents", "/Downloads", "/Desktop",
                    "/Movies", "/Music", "/Pictures", "/Public", "/Applications",
                    "/.local", "/.config", "/.cache"] {
            set.insert(home + rel)
        }
        for sys in ["/Library/Application Support", "/Library/LaunchAgents",
                    "/Library/LaunchDaemons", "/Library/Caches", "/Library/Logs",
                    "/Library/Preferences"] {
            set.insert(sys)
        }
        return set
    }

    // MARK: - 组装 Artifact

    /// 缓存 / 日志 / 崩溃报告可再生，其余一律按「含用户数据」对待。
    private static func isCacheLike(_ path: String) -> Bool {
        let markers = ["/Caches/", "/Logs/", "/.cache/", "/DiagnosticReports/", "/Saved Application State/"]
        return markers.contains { path.contains($0) }
    }

    /// 组装一条 AI 提议项。`internal` 以便自检端到端验证「默认不勾选」这条硬约束。
    static func makeArtifact(path: String, reason: String) -> Artifact {
        let risk: Risk = isCacheLike(path) ? .safe : .userData
        let clean = reason
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = clean.count > 160 ? String(clean.prefix(160)) + "…" : clean
        return Artifact(
            category: .aiProposed,
            path: path,
            size: size(of: path),
            risk: risk,
            meta: nil,
            // 硬约束：AI 提议项永不默认勾选。勾选权只在用户手上。
            selected: false,
            aiVerdict: .safe(reason: capped.isEmpty ? defaultReason : capped)
        )
    }

    private static var defaultReason: String {
        L10n.t("模型建议补充检查这条路径", "The model suggests checking this path")
    }

    private static func size(of path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            return (try? URL(fileURLWithPath: path).directorySize()) ?? 0
        }
        let attrs = try? fm.attributesOfItem(atPath: path)
        return Int64((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    // MARK: - 提示词

    private static var systemPrompt: String {
        L10n.t(
            """
            你是 macOS 深度卸载工具的「残留发现助手」。用户要卸载一个 app，内置扫描器已经扫过一轮（清单在下面，不要重复列出）。请补充列出【内置扫描器可能漏掉】的残留路径。

            硬性要求：
            1. 只输出用户级绝对路径，且必须位于给定家目录下，或 /Applications/ 下。
            2. 禁止输出系统路径（/System、/usr、/private、/var、/opt、/Library/Apple 等）和任何其他 app 的数据目录 —— 它们会被直接丢弃。
            3. 禁止输出通配或模糊路径（不要 *、不要 ?、不要变量），每条必须是一个具体的目录或文件。
            4. 禁止输出下方清单里已经出现的路径。
            5. 禁止输出家目录本身，以及 Library、Documents、Downloads、Desktop、Application Support 这类大目录本身。
            6. 最多 \(maxItems) 条。宁缺毋滥，不确定就不要列。
            7. 每条给一句中文理由，说明为什么它属于这个 app。

            只输出 JSON：{"items":[{"path":"<绝对路径>","reason":"<一句理由>"}]}。没有补充就输出 {"items":[]}。不要输出 JSON 以外的任何文字。
            """,
            """
            You are the leftover-discovery assistant of a macOS deep-uninstall tool. The user is uninstalling an app; the built-in scanners already ran (their findings are listed below — do not repeat them). List only the leftover paths the built-in scanners likely MISSED.

            Hard rules:
            1. Output only absolute user-level paths, located under the given home directory or under /Applications/.
            2. Never output system paths (/System, /usr, /private, /var, /opt, /Library/Apple, …) or any other app's data directories — they are discarded outright.
            3. Never output wildcards or vague paths (no *, no ?, no variables). Each entry must be one concrete file or directory.
            4. Never output a path already present in the list below.
            5. Never output the home directory itself, or umbrella directories such as Library, Documents, Downloads, Desktop, Application Support.
            6. At most \(maxItems) entries. When in doubt, leave it out.
            7. Give a one-sentence reason per entry explaining why it belongs to this app.

            Output ONLY JSON: {"items":[{"path":"<absolute path>","reason":"<one-line reason>"}]}. If there is nothing to add, output {"items":[]}. Do not output any text outside the JSON.
            """
        )
    }

    private static func userPrompt(app: AppIdentity, known: Set<String>) -> String {
        var head = L10n.t("待卸载应用：", "App to uninstall: ")
            + "\(app.displayName) (\(app.fileName).app)\n"
        head += L10n.t("路径：", "Path: ") + "\(app.bundlePath)\n"
        if let bid = app.bundleId { head += L10n.t("bundle id：", "Bundle ID: ") + "\(bid)\n" }
        if let v = app.version { head += L10n.t("版本：", "Version: ") + "\(v)\n" }
        head += L10n.t("已知名称：", "Known names: ")
            + app.aliases.sorted().joined(separator: ", ") + "\n"
        head += L10n.t("家目录：", "Home: ") + NSHomeDirectory() + "\n"

        // 已知清单只给一部分：全量上百条会把 token 吃光，而模型只需要
        // 「别重复」的信号。取前 60 条 + 一句总数说明。
        let sorted = known.sorted()
        let shown = Array(sorted.prefix(60))
        head += L10n.t("内置扫描器已找到的路径（共 \(known.count) 条，以下为部分，不要重复列出）：\n",
                       "Paths already found by the built-in scanners (\(known.count) total, partial list — do not repeat them):\n")
        head += shown.map { "- \($0)" }.joined(separator: "\n")
        return head
    }

    // MARK: - 解析

    /// 模型可能吐 ```json 代码块、可能前后带寒暄、也可能直接给数组。
    /// 三种都兼容；解析不出就当「没有提议」，不猜、不补全。
    static func parse(_ raw: String) -> [Proposal] {
        let text = AIJury.stripFences(raw)
        var entries: [[String: Any]] = []
        if let obj = AIJury.extractObject(text), let items = obj["items"] as? [[String: Any]] {
            entries = items
        } else if let arr = AIJury.extractArray(text) {
            entries = arr
        }
        var out: [Proposal] = []
        for e in entries {
            guard let p = e["path"] as? String, !p.isEmpty else { continue }
            let reason = (e["reason"] as? String) ?? ""
            out.append(Proposal(path: p, reason: reason))
        }
        return out
    }

    struct Proposal {
        let path: String
        let reason: String
    }
}
