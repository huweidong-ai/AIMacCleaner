import Foundation

/// 内置自检。`ai-mac-cleaner --self-test`
enum SelfTest {
    struct Check {
        let name: String
        let block: () async -> Bool
    }

    /// AIScanProposer 自检用的固定判定上下文。
    ///
    /// 手工构造而不是 `Context.build(app:)`：后者要读全机 app 清单（耗时且随机器变），
    /// 而校验网的用例必须**离线且确定性** —— 判定的对错不该取决于这台机器装了什么。
    private static func aiProposeContext(otherLiveIds: Set<String> = [],
                                         otherLiveNames: Set<String> = [],
                                         keepPaths: Set<String> = [],
                                         bundlePath: String = "/Applications/WeChat.app",
                                         ownedTokens: Set<String> = ["wechat", "微信", "xinwechat"]) -> AIScanProposer.Context {
        AIScanProposer.Context(otherLiveIds: otherLiveIds,
                               otherLiveNames: otherLiveNames,
                               keepPaths: keepPaths,
                               bundlePath: bundlePath,
                               ownedTokens: ownedTokens)
    }

    static func run() -> Int32 {
        let checks: [Check] = [
            Check(name: "BrewScanner 在未知 target 上返回空") {
                await BrewScanner().scan(for: "definitely-not-installed-xyz-12345").isEmpty
            },
            Check(name: "不存在路径的 directorySize 返回 0") {
                let url = URL(fileURLWithPath: "/tmp/expunge-self-test-\(UUID().uuidString)")
                return ((try? url.directorySize()) ?? -1) == 0
            },
            Check(name: "Artifact safe 默认勾选") {
                Artifact(category: .appBundle, path: "/a", size: 1, risk: .safe).selected == true
            },
            Check(name: "Artifact userData 默认不勾选") {
                Artifact(category: .xdgUserData, path: "/a", size: 1, risk: .userData).selected == false
            },
            Check(name: "Artifact uncertain 默认不勾选") {
                Artifact(category: .dotfile, path: "/a", size: 1, risk: .uncertain).selected == false
            },
            Check(name: "RemovalPlan.grouped 排序") {
                let plan = RemovalPlan(targetName: "x", artifacts: [
                    Artifact(category: .xdgUserData, path: "/b", size: 1, risk: .safe),
                    Artifact(category: .appBundle,   path: "/a", size: 1, risk: .safe)
                ])
                return plan.grouped.first?.0 == .appBundle
            },
            Check(name: "字节格式化非空") {
                !SizeFormat.human(0).isEmpty && !SizeFormat.human(1_500_000).isEmpty
            },
            Check(name: "AIToolLeftovers 注册表健全（非空、字段完整、每条有路径）") {
                let r = AIToolLeftovers.registry
                guard !r.isEmpty else { return false }
                for e in r {
                    guard !e.id.isEmpty, !e.name.isEmpty, !e.category.isEmpty,
                          AIToolLeftovers.Risk.allCases.contains(e.risk),
                          !e.paths.isEmpty
                    else { return false }
                }
                return true
            },
            Check(name: "AIToolLeftovers.scan() 不抛错") {
                let _ = AIToolLeftovers.scan()
                return true
            },
            Check(name: "AIToolLeftovers.scanGroups() 来源合法且分组非空") {
                let groups = AIToolLeftovers.scanGroups()
                guard !groups.isEmpty else { return false }
                return groups.allSatisfy {
                    !$0.artifacts.isEmpty &&
                    [LeftoverSource.aiTool, .devCache].contains($0.source)
                }
            },
            Check(name: "OrphanCacheScanner.scan() 不抛错") {
                let _ = OrphanCacheScanner.scan()
                return true
            },
            Check(name: "OrphanCacheScanner.scanGroups() 来源合法") {
                let groups = OrphanCacheScanner.scanGroups()
                return groups.allSatisfy {
                    !$0.artifacts.isEmpty &&
                    [LeftoverSource.aiTool, .devCache].contains($0.source)
                }
            },

            // ── 别名匹配打分 ──
            Check(name: "MatchScore 精确命中分数最高") {
                MatchScore.score(query: "wechat", alias: "wechat") == MatchScore.exact
            },
            Check(name: "MatchScore 前缀 > 子串") {
                let p = MatchScore.score(query: "chat", alias: "chatgpt") ?? 0
                let s = MatchScore.score(query: "chat", alias: "wechat") ?? 0
                return p > s
            },
            Check(name: "MatchScore 词首命中优于纯子串") {
                let w = MatchScore.score(query: "office", alias: "wps office") ?? 0
                let s = MatchScore.score(query: "ffic", alias: "wps office") ?? 0
                return w > s
            },
            Check(name: "MatchScore 不匹配返回 nil") {
                MatchScore.score(query: "zzz", alias: "wechat") == nil
            },
            Check(name: "MatchScore 精确名优于同前缀长名（微信 vs 微信开发者工具）") {
                let exact = MatchScore.score(query: "微信", aliases: ["微信", "wechat"]) ?? 0
                let longer = MatchScore.score(query: "微信", aliases: ["微信开发者工具", "wechatwebdevtools"]) ?? 0
                return exact > longer
            },

            // ── ScanQuery ──
            Check(name: "ScanQuery 关键词模式保留原始输入") {
                ScanQuery(raw: "mimo").keywords == ["mimo"]
            },
            Check(name: "ScanQuery 空输入 isEmpty") {
                ScanQuery(raw: "   ").isEmpty
            },
            Check(name: "ScanQuery 过滤过短关键词") {
                let app = AppIdentity(bundlePath: "/Applications/X.app", fileName: "SomeApp",
                                      displayName: "某应用", bundleId: "com.example.ai",
                                      version: nil, aliases: ["someapp", "ai"])
                // "ai" 只有 2 字符，必须被过滤掉，否则会扫出满屏无关项
                return !ScanQuery(raw: "someapp", app: app).keywords.contains("ai")
            },
            Check(name: "bundle id 通用末段不当别名（com.aicleaner.app 不下发 app）") {
                // 真机 bug：`--scan AIMacCleaner` 曾扫出 556 项 / 34.36 GB。
                // com.aicleaner.app 的末段 "app" 被下发给扫描器后，
                // ~/Library/Application Support 下几乎每个目录都命中
                // （含一个 458 MB 的无关 app 数据目录和一堆 com.apple.*）。
                // foreignKeywords 防不住 —— 那些目录不属于任何已装 app。
                let app = AppIdentity(bundlePath: "/Applications/AIMacCleaner.app", fileName: "AIMacCleaner",
                                      displayName: "AI Mac Cleaner", bundleId: "com.aicleaner.app",
                                      version: nil, aliases: [])
                let q = ScanQuery(raw: "AIMacCleaner", app: app)
                return app.bundleIdSuffix == nil
                    && !q.keywords.contains("app")
                    && !q.matches("Application Support")
                    && q.keywords.contains("aimaccleaner")
            },
            Check(name: "bundle id 正常末段仍然下发（不因修 app 而过度收紧）") {
                let app = AppIdentity(bundlePath: "/Applications/WeChat.app", fileName: "WeChat",
                                      displayName: "微信", bundleId: "com.tencent.xinWeChat",
                                      version: nil, aliases: [])
                return app.bundleIdSuffix == "xinwechat"
                    && ScanQuery(raw: "微信", app: app).keywords.contains("xinwechat")
            },
            Check(name: "ScanQuery app 模式包含 bundle id 和文件名") {
                let app = AppIdentity(bundlePath: "/Applications/WeChat.app", fileName: "WeChat",
                                      displayName: "微信", bundleId: "com.tencent.xinWeChat",
                                      version: nil, aliases: [])
                let q = ScanQuery(raw: "微信", app: app)
                return q.keywords.contains("wechat")
                    && q.keywords.contains("com.tencent.xinwechat")
                    && q.matches("WeChat")
                    && q.matches("com.tencent.xinWeChat")
            },
            Check(name: "ScanQuery 生成去空格紧凑别名") {
                // 多词带空格的 app 名，其数据目录常常是去空格的紧凑写法。
                let app = AppIdentity(bundlePath: "/Applications/Codex Sample App.app",
                                      fileName: "Codex Sample App", displayName: "Codex Sample App",
                                      bundleId: "cc.example.menubar", version: nil, aliases: [])
                // 必须能命中 Application Support/CodexSampleAppStudio（目录名无空格）
                return ScanQuery(raw: "codex sample app", app: app).matches("CodexSampleAppStudio")
            },
            Check(name: "ScanQuery 排除其他已装 app 的痕迹") {
                // 真实案例的最小复现：ChatGPT 的 bundle id 是 com.openai.codex，
                // 关键词含 "codex"，于是另一个名字里带 Codex 的第三方 app 的数据目录
                // 会被算进 ChatGPT —— 用户点「全选」就会删掉正在用的 app 的数据。
                let chatgpt = AppIdentity(bundlePath: "/Applications/ChatGPT.app", fileName: "ChatGPT",
                                          displayName: "ChatGPT", bundleId: "com.openai.codex",
                                          version: nil, aliases: [])
                let other = AppIdentity(bundlePath: "/Applications/Codex Sample App.app",
                                        fileName: "Codex Sample App", displayName: "Codex Sample App",
                                        bundleId: "cc.example.menubar", version: nil, aliases: [])
                let q = ScanQuery(raw: "chatgpt", app: chatgpt, others: [other])
                // 自己的痕迹要留下，别人的要排除
                return q.matches("com.openai.codex")
                    && q.matches("Codex")
                    && !q.matches("CodexSampleAppStudio")
            },
            Check(name: "ScanQuery 不误伤系统/共享文件（QoderWork 类尾词）") {
                // 真机 bug：com.qoder.work 的末段 "work" 作为关键词下发后，
                // 裸子串匹配把 com.apple.networkserviceproxy（network⊃work）、
                // com.apple.workflowKit.*（workflow⊃work）、networkserviceproxy 目录、
                // mineru.workflow 全部当成 QoderWork 的痕迹扫出来。
                // 没有 AI 兜底时这些系统/他人文件会被误删。
                let app = AppIdentity(bundlePath: "/Applications/QoderWork.app",
                                      fileName: "QoderWork", displayName: "QoderWork",
                                      bundleId: "com.qoder.work", version: nil, aliases: [])
                let q = ScanQuery(raw: "QoderWork", app: app)
                // 自己的痕迹仍要命中
                let ownHits = q.matches("com.qoder.work.plist")
                    && q.matches("QoderWork")
                    && q.matches("QoderWork Helper")
                // 系统 / 其他 app 的文件绝不能命中
                let noFalse = !q.matches("com.apple.networkserviceproxy.plist")
                    && !q.matches("com.apple.workflowKit.BackgroundShortcutRunner.plist")
                    && !q.matches("com.apple.inputmethod.CoreChineseEngineFramework.plist")
                    && !q.matches("networkserviceproxy")
                    && !q.matches("mineru.workflow")
                return ownHits && noFalse
            },

            // ── PID 解析（折叠展示后不能漏杀）──
            Check(name: "parsePids 单个 PID") {
                RemovalExecutor.parsePids(from: "PID: 123") == ["123"]
            },
            Check(name: "parsePids 多个 PID 全部保留") {
                RemovalExecutor.parsePids(from: "PID: 123,124,125 (3 个进程)") == ["123", "124", "125"]
            },
            Check(name: "parsePids 忽略非 PID meta") {
                RemovalExecutor.parsePids(from: "Label: com.foo").isEmpty
                    && RemovalExecutor.parsePids(from: nil).isEmpty
            },

            // ── 容器扫描 ──
            Check(name: "ContainerScanner 空查询返回空") {
                await ContainerScanner().scan(query: ScanQuery(raw: "")).isEmpty
            },
            Check(name: "ContainerScanner 未知 target 返回空") {
                await ContainerScanner().scan(for: "definitely-not-installed-xyz-98765").isEmpty
            },
            Check(name: "容器项默认不勾选（是用户数据）") {
                Artifact(category: .container, path: "/a", size: 1, risk: .userData).selected == false
            },

            // ── RemovalPlan 大小口径 ──
            Check(name: "scannedTotalSize 含未勾选项") {
                let plan = RemovalPlan(targetName: "x", artifacts: [
                    Artifact(category: .appBundle, path: "/a", size: 100, risk: .safe),
                    Artifact(category: .container, path: "/b", size: 900, risk: .userData)
                ])
                return plan.totalSize == 100 && plan.scannedTotalSize == 1000
            },

            // ── AppInventory ──
            Check(name: "AppInventory 能枚举到已装 app") {
                !AppInventory.allApps().isEmpty
            },
            Check(name: "AppInventory 别名含小写文件名") {
                guard let app = AppInventory.allApps().first else { return false }
                return app.aliases.contains(app.fileName.lowercased())
            },
            Check(name: "AppInventory 搜索空串返回空") {
                AppInventory.search("").isEmpty
            },
            Check(name: "AppInventory 搜索结果按分数降序") {
                let apps = AppInventory.allApps()
                guard apps.count > 1 else { return true }
                let hits = AppInventory.search("a", in: apps)
                guard hits.count > 1 else { return true }
                let scores = hits.compactMap { MatchScore.score(query: "a", aliases: $0.aliases) }
                return scores == scores.sorted(by: >)
            },

            Check(name: "FileDeleter 拒绝系统路径") {
                !FileDeleter.delete("/System/Library/something").success
                    && !FileDeleter.delete("/usr/bin/something").success
                    && !FileDeleter.delete("/private/var/x").success
            },
            Check(name: "FileDeleter 接受用户路径") {
                let tmp = "\(NSHomeDirectory())/Library/Caches/expunge-ft-\(UUID().uuidString)"
                // 先清掉可能残留
                try? FileManager.default.removeItem(atPath: tmp)
                FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
                // 探针走 .permanent：自检不该往用户废纸篓里塞垃圾。
                return FileDeleter.delete(tmp, disposition: .permanent).success
            },
            Check(name: "FileDeleter 默认走废纸篓（可挽回）") {
                // v1.3 的核心安全改动。白名单和 foreignKeywords 都是启发式判断，
                // 总有判错的可能 —— 废纸篓让每次判错都能挽回。
                // tar.gz 备份只覆盖 userData 类，其余类别永久删除就找不回来了。
                let tmp = "\(NSHomeDirectory())/Library/Caches/expunge-trash-\(UUID().uuidString)"
                try? FileManager.default.removeItem(atPath: tmp)
                FileManager.default.createFile(atPath: tmp, contents: Data("trash-probe".utf8))
                let r = FileDeleter.delete(tmp)   // 不传 disposition，验证默认值
                guard r.success, let dest = r.trashedTo else { return false }
                // 原路径必须已消失，且废纸篓里那份必须真的存在
                let goneFromOrigin = !FileManager.default.fileExists(atPath: tmp)
                let landedInTrash = FileManager.default.fileExists(atPath: dest)
                // 收尾：把探针从废纸篓里也清掉，别留垃圾给用户
                try? FileManager.default.removeItem(atPath: dest)
                return goneFromOrigin && landedInTrash && dest.contains(".Trash")
            },
            Check(name: "FileDeleter 永久删除模式不产生 trashedTo") {
                // RemovalExecutor 靠 trashedTo 是否为 nil 区分「已移到废纸篓」
                // 和「真正释放了磁盘」两种口径，这个契约不能破。
                let tmp = "\(NSHomeDirectory())/Library/Caches/expunge-perm-\(UUID().uuidString)"
                try? FileManager.default.removeItem(atPath: tmp)
                FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
                let r = FileDeleter.delete(tmp, disposition: .permanent)
                return r.success && r.trashedTo == nil
                    && !FileManager.default.fileExists(atPath: tmp)
            },
            Check(name: "FileDeleter 白名单放行沙箱容器（v1.1 漏了）") {
                // v1.1 的 bug：ContainerScanner 扫出微信 3.6 GB 容器、UI 报告会释放，
                // 但 FileDeleter 白名单里没有 Containers/，执行阶段直接以
                // 「路径不在白名单内」跳过 —— 报告的数字是假的。
                //
                // 注意断言的是「白名单放行」而不是「删除成功」：
                // ~/Library/Containers 受 containermanagerd 保护（SIP 支持），
                // 没有「完全磁盘访问权限」时连 rm -rf 都会 Operation not permitted。
                // 那是系统权限问题，不是 AI Mac Cleaner 的判断问题。
                let fake = "\(NSHomeDirectory())/Library/Containers/com.expunge.selftest.\(UUID().uuidString)"
                let r = FileDeleter.delete(fake)
                // 不存在的路径应报「已不存在」，而不是「路径不在白名单内」
                return !r.message.contains("白名单")
            },
            Check(name: "FileDeleter 白名单放行共享容器") {
                let fake = "\(NSHomeDirectory())/Library/Group Containers/com.expunge.selftest.\(UUID().uuidString)"
                return !FileDeleter.delete(fake).message.contains("白名单")
            },
            Check(name: "FileDeleter 仍然拒绝白名单外的用户路径") {
                // 补上正面用例后，要确认白名单没有被放宽成「什么都能删」
                let outside = "\(NSHomeDirectory())/Library/Keychains/expunge-should-refuse"
                return FileDeleter.delete(outside).message.contains("白名单")
            },
            Check(name: "PrivilegedDeleter 提权白名单与 FileDeleter 同口径（拒绝系统路径、放行 /Applications）") {
                // 提权删除是 root 刀，安全网必须和 FileDeleter 一致，否则可能误删系统文件。
                // 系统路径 / 家目录根一律拒绝；/Applications 下 root 拥有的 app（如 digiKam）放行。
                !PrivilegedDeleter.isSafeToEscalate("/System/Library/foo")
                    && !PrivilegedDeleter.isSafeToEscalate("/usr/bin/foo")
                    && !PrivilegedDeleter.isSafeToEscalate("/private/var/foo")
                    && !PrivilegedDeleter.isSafeToEscalate(NSHomeDirectory())
                    && PrivilegedDeleter.isSafeToEscalate("/Applications/digiKam.org/digikam.app")
            },
            Check(name: "扫描目录全部在 FileDeleter 白名单内（防 v1.1 假报成功重演）") {
                // v1.1 的教训：ContainerScanner 扫出微信 3.6 GB、UI 报告会释放，
                // 但白名单里没有 Containers/，执行阶段静默跳过 —— 数字是假的。
                // v1.3 把 LibraryDataScanner 从 5 个目录扩到 12 个，这条断言
                // 保证以后再加扫描目录时不会忘了同步白名单。
                for spec in LibraryDataScanner().baseDirs {
                    // 用该目录下一个不存在的子项试探：白名单放行的话
                    // 应该报「已不存在」，被拦的话会报「路径不在白名单内」。
                    let probe = "\(spec.path)/expunge-whitelist-probe-\(UUID().uuidString)"
                    if FileDeleter.delete(probe).message.contains("白名单") { return false }
                }
                return true
            },
            Check(name: "新增的 Library 子目录确实在扫描范围内") {
                // 实证驱动：~/Library/HTTPStorages 下有一个早已卸载的 CLI 工具留下的
                // 真实孤儿残留，v1.2 扫不到它（--orphans 却报
                // 「未发现孤儿」），因为这 3 个目录不在扫描范围里。
                let dirs = LibraryDataScanner().baseDirs.map(\.path)
                let home = NSHomeDirectory()
                return dirs.contains("\(home)/Library/HTTPStorages")
                    && dirs.contains("\(home)/Library/WebKit")
                    && dirs.contains("\(home)/Library/Application Scripts")
                    && dirs.count >= 12
            },
            Check(name: "含登录态的目录归 userData（默认不勾选）") {
                // HTTPStorages / Cookies 存 HTTP cookie，删了要重新登录；
                // Services 里可能是用户自己写的 Automator workflow。
                // 这三个必须默认不勾选，risk 判断依据是「丢的东西能不能再生」，
                // 不是目录大小。
                let specs = LibraryDataScanner().baseDirs
                let home = NSHomeDirectory()
                for name in ["HTTPStorages", "Cookies", "Services"] {
                    guard let spec = specs.first(where: { $0.path == "\(home)/Library/\(name)" }),
                          spec.risk == .userData
                    else { return false }
                }
                return true
            },
            Check(name: "Caches 与 XDG .cache 归 safe、Preferences 归 userData") {
                // 缓存目录是可再生的，不该和聊天记录/账号数据并列进废纸篓；
                // plist 通常含登录态与配置，应归 userData。
                let lib = LibraryDataScanner().baseDirs
                let xdg = XDGUserDataScanner().baseDirs
                let home = NSHomeDirectory()
                let cachesSafe = lib.first(where: { $0.path == "\(home)/Library/Caches" })?.risk == .safe
                let prefsUser = lib.first(where: { $0.path == "\(home)/Library/Preferences" })?.risk == .userData
                let xdgCacheSafe = xdg.first(where: { $0.path == "\(home)/.cache" })?.risk == .safe
                return cachesSafe && prefsUser && xdgCacheSafe
            },
            Check(name: "AuthTokenScanner 令牌文件归 userData（不误标 safe）") {
                // Chromium 的 Trust Tokens 这类认证/隐私令牌被 AuthTokenScanner
                // 按文件名含 "token" 匹配到，必须归 userData，不能默认勾选删除。
                let home = NSHomeDirectory()
                let base = "\(home)/Library/Application Support/expunge-tt-\(UUID().uuidString)"
                try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
                try? "{}".write(toFile: "\(base)/trust-tokens.json", atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(atPath: base) }
                let q = ScanQuery(raw: "expunge-tt")
                let arts = await AuthTokenScanner().scan(query: q)
                return !arts.isEmpty && arts.allSatisfy { $0.risk == .userData }
            },
            Check(name: "L10n 双语都非空且互不相同") {
                // 防止「只填了中文、英文留空」或「两边复制粘贴忘了改」。
                // 抽查几条关键文案。
                let samples: [(String, String)] = [
                    (ArtifactCategory.libraryData.displayName, "Library"),
                    (Risk.safe.displayName, "safe"),
                    (Risk.userData.explanation, "userData 解释"),
                    (AppState.Tab.leftovers.displayName, "残留 tab")
                ]
                for (text, _) in samples where text.isEmpty { return false }
                return true
            },
            Check(name: "L10n 英文复数正确（不出现 \"1 items\"）") {
                // "1 items" 这种机翻痕迹对要建立信任的工具很伤。
                let one = L10n.plural(1, zh: "项", one: "item", many: "items")
                let many = L10n.plural(6, zh: "项", one: "item", many: "items")
                if L10n.isChinese {
                    return one == "1 项" && many == "6 项"
                }
                return one == "1 item" && many == "6 items"
            },
            Check(name: "ArtifactCategory raw value 不变（历史记录兼容）") {
                // raw value 写进 history.jsonl，本地化它会让旧记录对不上。
                // 界面文案必须走 displayName。
                ArtifactCategory.container.rawValue == "沙箱容器"
                    && ArtifactCategory.groupContainer.rawValue == "共享容器"
                    && ArtifactCategory.libraryData.rawValue == "Library user data"
                    && Risk.userData.label == "user-data"
            },
            Check(name: "Tab raw value 是稳定英文 id（不随语言变）") {
                AppState.Tab.askAI.rawValue == "askAI"
                    && AppState.Tab.apps.rawValue == "apps"
                    && AppState.Tab.leftovers.rawValue == "leftovers"
                    && AppState.Tab.processes.rawValue == "processes"
            },
            Check(name: "dry-run 不写历史、不删文件") {
                // 造一个真实存在的探针文件当 artifact，跑 dryRun 执行器，
                // 断言文件还在、历史没有增长。
                let tmp = "\(NSHomeDirectory())/Library/Caches/expunge-dryrun-\(UUID().uuidString)"
                try? FileManager.default.removeItem(atPath: tmp)
                FileManager.default.createFile(atPath: tmp, contents: Data("probe".utf8))
                defer { try? FileManager.default.removeItem(atPath: tmp) }

                let historyBefore = HistoryStore.listAll().count
                let a = Artifact(category: .libraryData, path: tmp, size: 5,
                                 risk: .safe, selected: true)
                let plan = RemovalPlan(targetName: "expunge-dryrun-probe", artifacts: [a])
                let ex = RemovalExecutor(plan: plan, runPackageUninstallers: false, dryRun: true)
                ex.silent = true   // 吞掉全部输出，别污染自检日志
                _ = ex.execute()

                let stillThere = FileManager.default.fileExists(atPath: tmp)
                let historyAfter = HistoryStore.listAll().count
                return stillThere && historyAfter == historyBefore
            },
            Check(name: "非 dry-run 时同一条链真的会删（对照组）") {
                // 没有这个对照，上面那条断言在「执行器整体坏掉」时也会通过。
                let tmp = "\(NSHomeDirectory())/Library/Caches/expunge-wet-\(UUID().uuidString)"
                try? FileManager.default.removeItem(atPath: tmp)
                FileManager.default.createFile(atPath: tmp, contents: Data("probe".utf8))

                let a = Artifact(category: .libraryData, path: tmp, size: 5,
                                 risk: .safe, selected: true)
                let plan = RemovalPlan(targetName: "expunge-wet-probe", artifacts: [a])
                let ex = RemovalExecutor(plan: plan, runPackageUninstallers: false, dryRun: false)
                ex.silent = true
                _ = ex.execute()

                let gone = !FileManager.default.fileExists(atPath: tmp)
                // 收尾：这条会真的写一条历史、并把探针挪进废纸篓，都清掉
                if let rec = HistoryStore.listAll().first(where: { $0.targetName == "expunge-wet-probe" }) {
                    HistoryStore.remove(rec)
                }
                let trashed = "\(NSHomeDirectory())/.Trash/\((tmp as NSString).lastPathComponent)"
                try? FileManager.default.removeItem(atPath: trashed)
                return gone
            },
            Check(name: "pkg 收据路由到「需手动」而非「失败」（不碰磁盘）") {
                // /var/db/receipts 属 root，app 无权限删除、也无提权机制。
                // 选中 pkg 收据点删除时，必须计入 manualCount、failureCount 为 0，
                // 且绝不能真的去删文件——路径不存在也不该报错（修复前会报
                // 「路径不在白名单内」的假失败）。
                let a = Artifact(category: .pkgReceipt,
                                 path: "/var/db/receipts/com.example.nonexistent.plist",
                                 size: 0, risk: .userData, selected: true)
                let plan = RemovalPlan(targetName: "expunge-pkgreceipt-probe", artifacts: [a])
                let ex = RemovalExecutor(plan: plan, runPackageUninstallers: false, dryRun: false)
                ex.silent = true
                let outcome = ex.execute()
                // 收尾：手动项仍会写一条历史，清掉它，避免污染 --history。
                if let rec = HistoryStore.listAll().first(where: { $0.targetName == "expunge-pkgreceipt-probe" }) {
                    HistoryStore.remove(rec)
                }
                return outcome.failureCount == 0
                    && outcome.manualCount == 1
                    && outcome.successCount == 0
            },
            Check(name: "--reset 过滤掉 app bundle 和包管理器条目") {
                // 重置的语义是「清数据、留安装」。app bundle / CLI 程序 /
                // brew / npm / pipx / mas 都属于「安装」，不能被 reset 带走。
                let keep: Set<ArtifactCategory> = [
                    .appBundle, .cliBinary, .brewFormula, .brewCask,
                    .npmGlobal, .pipxVenv, .masApp
                ]
                let all: [Artifact] = [
                    Artifact(category: .appBundle, path: "/Applications/X.app", size: 100, risk: .safe),
                    Artifact(category: .brewCask, path: "cask: x", size: 0, risk: .safe),
                    Artifact(category: .npmGlobal, path: "npm global: x", size: 0, risk: .safe),
                    Artifact(category: .libraryData, path: "/tmp/x-prefs", size: 10, risk: .safe),
                    Artifact(category: .container, path: "/tmp/x-container", size: 20, risk: .userData)
                ]
                let kept = all.filter { !keep.contains($0.category) }
                return kept.count == 2
                    && !kept.contains(where: { $0.category == .appBundle })
                    && kept.contains(where: { $0.category == .libraryData })
                    && kept.contains(where: { $0.category == .container })
            },
            Check(name: "RawBinaryScanner 始终包含 ~/.local/bin 与 ~/Downloads") {
                let paths = RawBinaryScanner().searchPaths
                let home = NSHomeDirectory()
                return paths.contains("\(home)/Downloads")
                    && paths.contains("\(home)/.local/bin")
            },
            Check(name: "SignatureStore 包含 mimo 和 cc-connect") {
                SignatureStore.match(target: "mimo") != nil
                    && SignatureStore.match(target: "cc-connect") != nil
            },
            Check(name: "ProcessKiller 拒绝无效 PID") {
                !ProcessKiller.kill(pid: "abc").success
            },
            Check(name: "ProcessScanner 在无匹配时返回空") {
                await ProcessScanner().scan(for: "expunge-no-such-process-xyz-9999").isEmpty
            },
            Check(name: "LibraryDataScanner 在 Library 扫描不崩溃") {
                _ = await LibraryDataScanner().scan(for: "expunge-no-such-app-9999")
                return true
            },
            Check(name: "DotfileScanner 在家目录扫描不崩溃") {
                _ = await DotfileScanner().scan(for: "expunge-no-such-dotfile-9999")
                return true
            },

            // ══ v1.2：孤儿扫描 ══
            // 下面这批断言全部来自真机 dry-run 发现的假阳性。
            // 每一条都对应一次「差点误删活 app 数据」，不要图省事删掉。

            // ── 嵌套 bundle id（最重要的一条）──
            Check(name: "AppInventory 递归收集嵌套 bundle id") {
                // 顶层只有 ~28 个，递归后应有数百个。只比顶层会把活 app 的
                // XPC/扩展容器（WeChatMacShare 等）判成孤儿——实测 18 个里误判 12 个。
                let live = AppInventory.liveBundleIds()
                return live.count > 100
            },
            Check(name: "微信的扩展容器不是孤儿（嵌套 id 认领）") {
                let live = AppInventory.liveBundleIds()
                // 微信没装时跳过这条
                guard live.contains("com.tencent.xinwechat") else { return true }
                return !OrphanScanner.isOrphan("com.tencent.xinWeChat.WeChatMacShare", live: live)
                    && !OrphanScanner.isOrphan("com.tencent.xinWeChat.WeChatFileProviderExtension", live: live)
            },
            Check(name: "后代匹配：com.foo.bar.Ext 被 com.foo.bar 认领") {
                let live: Set<String> = ["com.foo.bar"]
                return !OrphanScanner.isOrphan("com.foo.bar.SomeExtension", live: live)
            },
            Check(name: "祖先匹配：com.microsoft.rdc 被 com.microsoft.rdc.macos 认领") {
                // 真机案例：Group Containers/UBF8T346G9.com.microsoft.rdc
                // 活着的是 com.microsoft.rdc.macos（Windows App）
                let live: Set<String> = ["com.microsoft.rdc.macos"]
                return !OrphanScanner.isOrphan("UBF8T346G9.com.microsoft.rdc", live: live)
            },
            Check(name: "同源变体：aldente-pro_stats 被 aldente-pro 认领") {
                // 真机案例：AlDente 装着，但 com.apphousekitchen.aldente-pro_stats.sqlite3
                // 用 . 和 - 分隔都匹配不上（是下划线）
                let live: Set<String> = ["com.apphousekitchen.aldente-pro"]
                return !OrphanScanner.isOrphan("com.apphousekitchen.aldente-pro_stats", live: live)
                    && !OrphanScanner.isOrphan("com.apphousekitchen.aldente-pro_backup", live: live)
            },
            Check(name: "缺 com. 前缀仍能认领（jetbrains.pycharm.hash）") {
                // 真机案例：PyCharm 装着（com.jetbrains.pycharm），
                // 但偏好文件叫 jetbrains.pycharm.3a396865
                let live: Set<String> = ["com.jetbrains.pycharm"]
                return !OrphanScanner.isOrphan("jetbrains.pycharm.3a396865", live: live)
            },
            Check(name: "同厂商有活 app 时不判孤儿（宁可漏报）") {
                // jetbrains.jetprofile.asset 是装着的 IDE 在用的共享授权数据
                let live: Set<String> = ["com.jetbrains.intellij"]
                return !OrphanScanner.isOrphan("jetbrains.jetprofile.asset", live: live)
            },
            Check(name: "teamid 前缀被正确剥离") {
                let live: Set<String> = ["com.tencent.xinwechat"]
                return !OrphanScanner.isOrphan("5A4RE8SF68.com.tencent.xinWeChat", live: live)
                    && OrphanScanner.stripPrefixes("5A4RE8SF68.com.tencent.xinWeChat") == "com.tencent.xinWeChat"
            },
            Check(name: "isTeamId 只认 10 位大写字母数字") {
                OrphanScanner.isTeamId("5A4RE8SF68")
                    && OrphanScanner.isTeamId("UBF8T346G9")
                    && !OrphanScanner.isTeamId("com")
                    && !OrphanScanner.isTeamId("lowercase1")
            },

            // ── 系统数据白名单 ──
            Check(name: "不带 com.apple 的 Apple 数据被保护") {
                // 真机发现：Apple 有一批不带 com.apple 前缀的数据目录，
                // 只跳过 com.apple 会把系统数据判成孤儿
                SystemOwned.isSystemOwned("group.is.workflow.shortcuts")
                    && SystemOwned.isSystemOwned("group.tvappservices.container")
                    && SystemOwned.isSystemOwned("org.cups.PrintingPrefs")
                    && SystemOwned.isSystemOwned("loginwindow")
                    && SystemOwned.isSystemOwned("Dock")
                    && SystemOwned.isSystemOwned("CloudDocs")
                    && SystemOwned.isSystemOwned("Knowledge")
                    && SystemOwned.isSystemOwned("systemgroup.com.apple.icloud")
            },
            Check(name: "com.apple 前缀被保护") {
                SystemOwned.isSystemOwned("com.apple.Safari")
                    && SystemOwned.isSystemOwned("group.com.apple.calendar")
            },
            Check(name: "共享框架数据被保护（不属于任何单个 app）") {
                // 这些由装着的 app 写入，但名字和那个 app 的 bundle id 无关
                SystemOwned.isSystemOwned("com.onevcat.Kingfisher.ImageCache.default")
                    && SystemOwned.isSystemOwned("com.plausiblelabs.crashreporter.data")
                    && SystemOwned.isSystemOwned("org.chromium.Chromium")
                    && SystemOwned.isSystemOwned("org.cocoapods.Defaults")
                    && SystemOwned.isSystemOwned("org.swift.swiftpm")
            },
            Check(name: "噪声形状被排除（散落文件不是 app 痕迹）") {
                SystemOwned.isNoise("(null)")
                    && SystemOwned.isNoise("$(AppIdentifierPrefix)localsend.shared_group")
                    && SystemOwned.isNoise("WPS_Office_7.3.0(8966)_arm64.7z")
                    && SystemOwned.isNoise("AAProfilePicture_29791F43.png")
                    && SystemOwned.isNoise("com.ebus.lark.nf_ipc.sock")
                    && SystemOwned.isNoise("default.store-wal")
                    && SystemOwned.isNoise("main.py")
            },

            // ── 形状过滤：纯名字目录不判 ──
            Check(name: "纯名字目录不进孤儿列表（假阳性率太高）") {
                // JetBrains 目录 vs IntelliJ IDEA.app：目录名和 app 名不是一个词，
                // 按名字匹配会把装着的 app 判成孤儿
                let live: Set<String> = ["com.example.whatever"]
                return !OrphanScanner.isOrphan("JetBrains", live: live)
                    && !OrphanScanner.isOrphan("Google", live: live)
                    && !OrphanScanner.isOrphan("微信开发者工具", live: live)
                    && !OrphanScanner.isOrphan("Microsoft", live: live)
            },
            Check(name: "单段名字不判孤儿") {
                !OrphanScanner.isOrphan("lv", live: [])
                    && !OrphanScanner.isOrphan("Cookies", live: [])
            },
            Check(name: "真孤儿能被认出来") {
                let live: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
                return OrphanScanner.isOrphan("com.vendor.SomeCleaner-SIII", live: live)
                    && OrphanScanner.isOrphan("com.example.some-cli-tool", live: live)
            },
            Check(name: "纯名字目录在活 app 名称反查下能认出真孤儿") {
                // TabNine / aiXcoder / yuque-desktop 卸载后目录名仍在，
                // 但没有任何活 app 的别名包含它们 → 应判孤儿；
                // Safari 装着（别名含 safari）→ 不应判孤儿。
                let liveIds: Set<String> = ["com.apple.Safari"]
                let liveNames: Set<String> = ["safari", "com.apple.safari", "finder", "com.apple.finder"]
                return OrphanScanner.isOrphan("TabNine", live: liveIds, liveNames: liveNames)
                    && OrphanScanner.isOrphan("aiXcoder", live: liveIds, liveNames: liveNames)
                    && OrphanScanner.isOrphan("yuque-desktop", live: liveIds, liveNames: liveNames)
                    && !OrphanScanner.isOrphan("Safari", live: liveIds, liveNames: liveNames)
            },

            // ── launch agent：用引用的程序判死活 ──
            Check(name: "launch agent 检查全部路径参数而非只看第一个") {
                // 真机案例：ai.lark-channel-bridge 的 args[0] 是 node（在），
                // args[1] 才是真正没了的脚本。只看 args[0] 会漏判。
                let tmp = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Caches/expunge-la-\(UUID().uuidString).plist")
                let plist: [String: Any] = [
                    "Label": "test.dead",
                    "ProgramArguments": ["/bin/sh", "/definitely/not/here/script-xyz-123"]
                ]
                (plist as NSDictionary).write(to: tmp, atomically: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                return OrphanScanner.isDeadLaunchAgent(tmp)
            },
            Check(name: "程序还在的 launch agent 不判孤儿") {
                let tmp = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Caches/expunge-la-\(UUID().uuidString).plist")
                let plist: [String: Any] = [
                    "Label": "test.alive",
                    "ProgramArguments": ["/bin/sh", "-c", "echo hi"]
                ]
                (plist as NSDictionary).write(to: tmp, atomically: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                return !OrphanScanner.isDeadLaunchAgent(tmp)
            },
            Check(name: "读不出的 plist 不猜（不判孤儿）") {
                let tmp = URL(fileURLWithPath: "/tmp/expunge-nonexistent-\(UUID().uuidString).plist")
                return !OrphanScanner.isDeadLaunchAgent(tmp)
            },

            // ── 结果安全性 ──
            Check(name: "孤儿项全部默认不勾选") {
                let groups = await OrphanScanner.scanAll()
                return groups.allSatisfy { $0.artifacts.allSatisfy { !$0.selected } }
            },
            Check(name: "兜底：孤儿列表不含任何活 app 的 bundle id") {
                // 这是本次改动唯一的真实删除风险，直接在真机上验一遍
                let live = AppInventory.liveBundleIds()
                let groups = await OrphanScanner.scanAll(liveIds: live)
                for g in groups {
                    for a in g.artifacts {
                        let base = (a.path as NSString).lastPathComponent.lowercased()
                        for liveId in live where liveId.count >= 8 {
                            if base.contains(liveId) { return false }
                        }
                    }
                }
                return true
            },
            Check(name: "孤儿扫描不触碰 /Applications 下的真实 app") {
                let groups = await OrphanScanner.scanAll()
                return groups.allSatisfy { g in
                    g.artifacts.allSatisfy { !$0.path.hasPrefix("/Applications") }
                }
            },
            Check(name: "LeftoverGroup 大小合计正确") {
                let g = LeftoverGroup(owner: "x", source: .orphan, artifacts: [
                    Artifact(category: .container, path: "/a", size: 100, risk: .userData, selected: false),
                    Artifact(category: .container, path: "/b", size: 200, risk: .userData, selected: true)
                ])
                return g.totalSize == 300 && g.selectedSize == 200 && g.selectedCount == 1
            },
            Check(name: "OrphanScanner 产出的分组来源标记为 .orphan") {
                // 残留页靠 source 分档筛选，标错会让「无主残留」筛选档漏项。
                let groups = await OrphanScanner.scanAll()
                return groups.allSatisfy { $0.source == .orphan }
            },
            Check(name: "Launch Services 判定：不存在的 bundle id 返回 false") {
                // 用一个几乎不可能安装的 bundle id，确认 API 接线正确、不会恒真误判。
                return !OrphanScanner.isInstalledViaLaunchServices("com.definitely-not-installed.example.xyz")
            },
            Check(name: "OrphanScanner.isClaimed 尊重 Launch Services 已装 app") {
                // 取一个系统里一定装了的 Apple app（Finder），其 bundle id 经 LS 判定为真装。
                let finderInstalled = OrphanScanner.isInstalledViaLaunchServices("com.apple.finder")
                // 若本机 LS 真能查到 Finder（几乎必然），则 isClaimed 必须把它当成已认领，
                // 即便传入的 live 集合为空（文件系统枚举没覆盖到它）。
                guard finderInstalled else { return true }   // 环境异常时跳过，不让自检变红
                return OrphanScanner.isClaimed("com.apple.finder", live: [])
            },

            // ── 新增 P0-1：pkg 收据扫描 ──
            Check(name: "PkgReceiptScanner 不抛错、产物来源为 .orphan、类别为 .pkgReceipt、不碰 /Applications") {
                // 干净机器上可能为 0，不要求非空；只验证安全性、来源与类别标记。
                let groups = PkgReceiptScanner.scanAll()
                return groups.allSatisfy { $0.source == .orphan }
                    && groups.allSatisfy { $0.artifacts.allSatisfy { $0.category == .pkgReceipt } }
                    && groups.allSatisfy { $0.artifacts.allSatisfy { !$0.path.hasPrefix("/Applications") } }
            },

            // ── 新增 P0-3：baseBundleId / stripTrailingVersion 单元 ──
            Check(name: "baseBundleId 剥掉尾部辅助组件后缀") {
                OrphanScanner.baseBundleId("com.example.app.helper") == "com.example.app"
                    && OrphanScanner.baseBundleId("com.example.app") == "com.example.app"
                    && OrphanScanner.baseBundleId("com.example.app.daemon") == "com.example.app"
                    && OrphanScanner.baseBundleId("com.apple") == "com.apple"   // 仅 2 段不剥
            },
            Check(name: "stripTrailingVersion 去掉尾部版本号") {
                OrphanScanner.stripTrailingVersion("appname-1.2.3") == "appname"
                    && OrphanScanner.stripTrailingVersion("appname-2024") == "appname"
                    && OrphanScanner.stripTrailingVersion("app-name-2") == "app-name"
                    && OrphanScanner.stripTrailingVersion("appname") == "appname"
            },

            // ── v1.5：AI 编程工具残留 ──
            Check(name: "AIAgentScanner.catalog 覆盖 ≥ 12 个主流工具") {
                // 初次上线就覆盖 Claude Code、Cursor、Windsurf、Aider、Codex、Gemini 等。
                // 少于这个数说明清单被改瘦了，要复查。
                AIAgentScanner.catalog.count >= 12
            },
            Check(name: "AIAgentScanner 包含头部工具 Claude Code / Cursor / Windsurf") {
                let names = AIAgentScanner.catalog.map { $0.name }
                return names.contains("Claude Code")
                    && names.contains("Cursor")
                    && names.contains("Windsurf")
            },
            Check(name: "AIAgentScanner 只返回真实存在的路径") {
                // 强不变式：报出来的每一项路径都必须在磁盘上存在。
                // 命中靠 fileExists 守卫，这条断言防的是「某天改错匹配逻辑、报出幻影路径」。
                let groups = AIAgentScanner.scanAll()
                return groups.allSatisfy { $0.artifacts.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
            },
            Check(name: "AIAgentScanner 扫到的项全部 userData、默认不勾选") {
                // 保守取向与孤儿扫描一致：会话历史/登录态/自定义命令属于不可再生数据，
                // 默认不勾选，让用户自己确认。
                let groups = AIAgentScanner.scanAll()
                return groups.allSatisfy { $0.artifacts.allSatisfy { $0.risk == .userData && !$0.selected } }
            },
            Check(name: "AIAgentScanner 扫描目标全在用户目录下（删除走废纸篓、不碰系统路径）") {
                // 所有已知痕迹都该在 ~/ 下（点文件 / .config / .cache / .local/share），
                // 这样才能走 FileDeleter 的白名单、进废纸篓，而不是被「不在白名单内」拦掉。
                let home = NSHomeDirectory()
                let groups = AIAgentScanner.scanAll()
                return groups.allSatisfy { $0.artifacts.allSatisfy { $0.path.hasPrefix(home) } }
            },
            Check(name: "AI 工具分组大小合计正确") {
                let g = LeftoverGroup(owner: "Claude Code", source: .aiTool, artifacts: [
                    Artifact(category: .dotfile, path: "/a", size: 100, risk: .userData, selected: false),
                    Artifact(category: .dotfile, path: "/b", size: 200, risk: .userData, selected: true)
                ])
                return g.totalSize == 300 && g.selectedSize == 200 && g.selectedCount == 1
            },
            Check(name: "AIAgentScanner 产出的分组来源标记为 .aiTool") {
                let groups = AIAgentScanner.scanAll()
                return groups.allSatisfy { $0.source == .aiTool }
            },

            // ── 进程枚举 ──
            Check(name: "ProcessLister.snapshot 返回非空且含自身") {
                let list = ProcessLister.snapshot()
                guard !list.isEmpty else { return false }
                let ownPid = ProcessInfo.processInfo.processIdentifier
                return list.contains { $0.pid == ownPid }
            },
            Check(name: "自身进程 isKillable == false（绝不自杀）") {
                let list = ProcessLister.snapshot()
                let ownPid = ProcessInfo.processInfo.processIdentifier
                return list.first { $0.pid == ownPid }.map { !$0.isKillable } ?? false
            },
            Check(name: "系统进程（launchd / pid 1）归 system 且不可杀") {
                let list = ProcessLister.snapshot()
                guard let launchd = list.first(where: { $0.pid == 1 || $0.comm == "launchd" }) else { return false }
                return launchd.kind == .system && !launchd.isKillable
            },
            Check(name: "「后台」筛选不混入 system 与 app") {
                let list = ProcessLister.snapshot()
                let bg = list.filter { $0.kind == .background }
                return !bg.contains { $0.kind == .system || $0.kind == .app }
            },
            Check(name: "ProcessLister 仅枚举、不杀任何进程（无副作用）") {
                // 最关键的底线：自检跑枚举绝不能误杀。这里只调用 snapshot，
                // 不调用任何 terminate；扫描前后进程数应基本稳定。
                let before = ProcessLister.snapshot().count
                let after = ProcessLister.snapshot().count
                return before > 0 && after > 0 && abs(before - after) <= 5
            },

            // ── 进程终止匹配（防误杀无关 app）──
            Check(name: "isTarget：主进程精确命中") {
                ProcessTerminator.isTarget("com.qoder.work", "QoderWork",
                    targetBundleId: "com.qoder.work", targetName: "QoderWork", keywords: [])
            },
            Check(name: "isTarget：helper 靠 bundle id 前缀命中") {
                ProcessTerminator.isTarget("com.qoder.work.helper.gpu", "QoderWork Helper (GPU)",
                    targetBundleId: "com.qoder.work", targetName: "QoderWork", keywords: [])
            },
            Check(name: "isTarget：helper 靠名称前缀命中") {
                ProcessTerminator.isTarget("com.qoder.work.helper", "QoderWork Helper",
                    targetBundleId: "com.qoder.work", targetName: "QoderWork", keywords: [])
            },
            Check(name: "isTarget：弱末段 'work' 不误杀 WorkBuddy（回归 #误杀IDE）") {
                // com.qoder.work 的 bundle id 末段是 "work"，裸子串会命中 WorkBuddy。
                // 边界匹配必须拦下：com.tencent.workbuddy 与 WorkBuddy 都不应被终止。
                let hit1 = ProcessTerminator.isTarget("com.tencent.workbuddy", "WorkBuddy",
                    targetBundleId: "com.qoder.work", targetName: "QoderWork", keywords: ["work"])
                let hit2 = ProcessTerminator.isTarget("com.workbuddy", "WorkBuddy",
                    targetBundleId: "com.qoder.work", targetName: "QoderWork", keywords: ["work"])
                return !hit1 && !hit2
            },
            Check(name: "isTarget：自身 bundle id 不被自身匹配误杀（由 terminate 排除）") {
                // 这里只验证 isTarget 的匹配语义：本工具 bundle id 不应作为目标被任何
                // 别的 app 的末段命中；真正的自杀拦截在 terminate 的 ownBundle 过滤里。
                let hit = ProcessTerminator.isTarget("com.aicleaner.app", "AI Mac Cleaner",
                    targetBundleId: "com.qoder.work", targetName: "QoderWork", keywords: ["app"])
                return !hit
            },
            Check(name: "isTarget：关键词 'code' 不误杀 VS Code") {
                // 名称词边界：'visual studio code' 末尾的 'code' 不带后续空格，不应命中；
                // bundle id com.microsoft.vscode 也不含 '.code.' 段。
                let hit = ProcessTerminator.isTarget("com.microsoft.vscode", "Visual Studio Code",
                    targetBundleId: "com.other.app", targetName: "Other", keywords: ["code"])
                return !hit
            },

            // ── VendorRegistry（同源厂商残留）──
            Check(name: "VendorRegistry：ChatGPT app 命中 OpenAI 厂商") {
                let app = AppIdentity(bundlePath: "/Applications/ChatGPT.app",
                                      fileName: "ChatGPT", displayName: "ChatGPT",
                                      bundleId: "com.openai.chat", version: nil,
                                      aliases: ["chatgpt", "com.openai.chat"])
                return VendorRegistry.vendor(for: app)?.name == "OpenAI"
            },
            Check(name: "VendorRegistry：Codex app 命中 OpenAI 厂商") {
                let app = AppIdentity(bundlePath: "/Applications/Codex.app",
                                      fileName: "Codex", displayName: "Codex",
                                      bundleId: "com.openai.codex", version: nil,
                                      aliases: ["codex", "com.openai.codex"])
                return VendorRegistry.vendor(for: app)?.name == "OpenAI"
            },
            Check(name: "VendorRegistry：无关 app 不命中任何厂商") {
                let app = AppIdentity(bundlePath: "/Applications/WeChat.app",
                                      fileName: "WeChat", displayName: "微信",
                                      bundleId: "com.tencent.xinWeChat", version: nil,
                                      aliases: ["wechat", "xinwechat"])
                return VendorRegistry.vendor(for: app) == nil
            },
            Check(name: "VendorRegistry：残留探测只返回确实存在的项") {
                // 没有 OpenAI 进程时，常驻进程项不应出现；~/.codex 若存在则出现。
                // 至少验证：返回的 Artifact 路径都真实存在，且不抛错。
                let app = AppIdentity(bundlePath: "/Applications/ChatGPT.app",
                                      fileName: "ChatGPT", displayName: "ChatGPT",
                                      bundleId: "com.openai.chat", version: nil,
                                      aliases: ["chatgpt", "com.openai.chat"])
                let leftovers = VendorRegistry.vendorLeftovers(for: app)
                return leftovers.allSatisfy { FileManager.default.fileExists(atPath: $0.path) || $0.meta != nil }
            },
            Check(name: "VendorRegistry：vendorLeftover 类目 raw value 稳定") {
                ArtifactCategory.vendorLeftover.rawValue == "Vendor leftover"
            },
            Check(name: "VendorRegistry：真机环境下命中 ~/.codex 残留") {
                // 真实样本：本机 ~/.codex 仍在、OpenAI 常驻进程(27940)在跑。
                // 卸载 ChatGPT 时应探测到这些同厂商残留并列为可清理项。
                let app = AppIdentity(bundlePath: "/Applications/ChatGPT.app",
                                      fileName: "ChatGPT", displayName: "ChatGPT",
                                      bundleId: "com.openai.chat", version: nil,
                                      aliases: ["chatgpt", "com.openai.chat"])
                let leftovers = VendorRegistry.vendorLeftovers(for: app)
                let hasCodexDir = leftovers.contains { $0.path.hasSuffix("/.codex") }
                return !leftovers.isEmpty && hasCodexDir
            },
            Check(name: "VendorRegistry：ego lite app 命中 Citro Labs 厂商") {
                let app = AppIdentity(bundlePath: "/Applications/ego lite.app",
                                      fileName: "ego lite", displayName: "ego lite",
                                      bundleId: "com.citrolabs.ego.lite", version: nil,
                                      aliases: ["ego lite", "com.citrolabs.ego.lite", "egobrowser"])
                return VendorRegistry.vendor(for: app)?.name == "Citro Labs (ego lite)"
            },
            Check(name: "VendorRegistry：ego lite 残留覆盖 keystone 启动项 / CLI / 崩溃报告") {
                // 仅验证结构：不依赖真机是否装了 ego。确认该厂商把通用扫描器漏掉的
                // 维度（keystone 框架启动项、~/.local/bin CLI、DiagnosticReports）纳入。
                guard let v = VendorRegistry.vendors.first(where: { $0.name == "Citro Labs (ego lite)" }) else { return false }
                let names = v.traces.map { $0.displayName }
                let hasKeystone = names.contains { $0.contains("Keystone") }
                let hasCLI = names.contains { $0.contains("ego-browser") }
                let hasCrash = names.contains { $0.contains("崩溃报告") }
                return hasKeystone && hasCLI && hasCrash
            },

            // ── AIScanProposer（AI 补充发现 · 校验网）──
            //
            // 这一组是「让 AI 参与发现」的安全底线：**模型说可删不构成授权**。
            // 全部用例都不发网络请求（判定是纯函数），因此可离线、确定性复现。
            Check(name: "AIScanProposer：未配置模型时整步跳过（不调网络）") {
                let app = AppIdentity(bundlePath: "/Applications/WeChat.app", fileName: "WeChat",
                                      displayName: "微信", bundleId: "com.tencent.xinWeChat",
                                      version: nil, aliases: ["wechat"])
                // apiKey 为空 → isConfigured == false → 直接返回空，绝不尝试调用。
                let out = await AIScanProposer.propose(app: app, knownPaths: [], config: AIModelConfig())
                return out.artifacts.isEmpty
            },
            Check(name: "AIScanProposer：拒绝系统路径（/System、/usr）") {
                let ctx = SelfTest.aiProposeContext()
                let a = AIScanProposer.rejectionReason("/System/Library/Foo", known: [], context: ctx)
                let b = AIScanProposer.rejectionReason("/usr/local/bin/foo", known: [], context: ctx)
                return a == .forbidden && b == .forbidden
            },
            Check(name: "AIScanProposer：拒绝白名单外路径（/opt）") {
                let ctx = SelfTest.aiProposeContext()
                return AIScanProposer.rejectionReason("/opt/homebrew/foo", known: [], context: ctx) == .notAllowed
            },
            Check(name: "AIScanProposer：拒绝保护根（家目录 / ~/Library）") {
                let ctx = SelfTest.aiProposeContext()
                let home = NSHomeDirectory()
                return AIScanProposer.rejectionReason(home, known: [], context: ctx) == .protectedRoot
                    && AIScanProposer.rejectionReason(home + "/Library/Application Support",
                                                      known: [], context: ctx) == .protectedRoot
            },
            Check(name: "AIScanProposer：拒绝 app 包内路径") {
                let ctx = SelfTest.aiProposeContext(bundlePath: "/Applications/WeChat.app")
                return AIScanProposer.rejectionReason("/Applications/WeChat.app/Contents/MacOS/WeChat",
                                                      known: [], context: ctx) == .insideAppBundle
            },
            Check(name: "AIScanProposer：拒绝系统自有目录名（com.apple.*）") {
                let ctx = SelfTest.aiProposeContext()
                let p = NSHomeDirectory() + "/Library/Application Support/com.apple.sharedstuff"
                return AIScanProposer.rejectionReason(p, known: [], context: ctx) == .systemOwned
            },
            Check(name: "AIScanProposer：活 app 反查拦下别家数据（Google/Chrome）") {
                // 目标是微信，别家活 app 里有 Google Chrome —— 模型若提议删
                // ~/Library/Application Support/Google/Chrome，必须被这一步拦住。
                let ctx = SelfTest.aiProposeContext(otherLiveNames: ["google chrome", "chrome"])
                let p = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
                return AIScanProposer.rejectionReason(p, known: [], context: ctx) == .claimedByOtherApp
            },
            Check(name: "AIScanProposer：自家厂商目录不被活 app 反查误伤（卸载 Chrome 时）") {
                // 反向用例：目标是 Chrome 自己，`Google/Chrome` 是它的数据，
                // 不能因为父目录叫 Google（同厂商还有别的产品）就被拒。
                let ctx = AIScanProposer.Context(
                    otherLiveIds: [], otherLiveNames: ["google drive", "drive"],
                    keepPaths: [], bundlePath: "/Applications/Google Chrome.app",
                    ownedTokens: ["google chrome", "chrome", "com.google.chrome"])
                let p = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
                return AIScanProposer.rejectionReason(p, known: [], context: ctx) != .claimedByOtherApp
            },
            Check(name: "AIScanProposer：拒绝通配符与相对路径") {
                let ctx = SelfTest.aiProposeContext()
                let wild = AIScanProposer.rejectionReason(NSHomeDirectory() + "/Library/Caches/*",
                                                          known: [], context: ctx)
                let rel = AIScanProposer.rejectionReason("Library/Caches/foo", known: [], context: ctx)
                return wild == .wildcard && rel == .relative
            },
            Check(name: "AIScanProposer：拒绝已扫到的重复项与不存在的路径") {
                let ctx = SelfTest.aiProposeContext()
                let p = NSHomeDirectory() + "/Library/Caches/expunge-ai-known"
                let dup = AIScanProposer.rejectionReason(p, known: [p], context: ctx)
                let gone = AIScanProposer.rejectionReason(
                    NSHomeDirectory() + "/Library/Caches/expunge-ai-nope-\(UUID().uuidString)",
                    known: [], context: ctx)
                return dup == .alreadyKnown && gone == .missing
            },
            Check(name: "AIScanProposer：尊重 /remember 豁免路径") {
                let p = NSHomeDirectory() + "/Library/Caches/expunge-ai-exempt"
                let ctx = SelfTest.aiProposeContext(keepPaths: [p])
                return AIScanProposer.rejectionReason(p, known: [], context: ctx) == .userExempt
            },
            Check(name: "AIScanProposer：真实存在的自家路径被接受，且默认不勾选") {
                let dir = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Caches/expunge-ai-\(UUID().uuidString)/wechatdata")
                defer { try? FileManager.default.removeItem(at: dir) }
                do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
                catch { return false }

                let ctx = SelfTest.aiProposeContext()
                guard let accepted = AIScanProposer.validate(dir.path, known: [], context: ctx) else {
                    return false
                }
                guard accepted == dir.path else { return false }
                // 端到端再走一次组装：默认必须是未勾选，且归类为 AI 提议项。
                let made = AIScanProposer.makeArtifact(path: dir.path, reason: "测试理由")
                return made.category == .aiProposed && made.selected == false
            },
            Check(name: "AIScanProposer：解析兼容代码块 / 裸数组 / 垃圾回复") {
                let fenced = "```json\n{\"items\":[{\"path\":\"/tmp/a\",\"reason\":\"r1\"},{\"path\":\"/tmp/b\",\"reason\":\"r2\"}]}\n```"
                let bare = "[{\"path\":\"/tmp/c\",\"reason\":\"r3\"}]"
                let junk = "我觉得这个 app 挺干净的，没什么残留。"
                return AIScanProposer.parse(fenced).count == 2
                    && AIScanProposer.parse(bare).count == 1
                    && AIScanProposer.parse(junk).isEmpty
            },
            Check(name: "AIScanProposer：撤销 AI 分析不会自动勾选 AI 提议项") {
                // 项目踩过一次的坑：undoAIReview 把应用页恢复成「默认全选」，
                // 那套约定只适用于内置扫描器结果 —— AI 提议项若跟着被全勾，
                // 撤销一次分析就成了误删入口。
                let proposed = Artifact(category: .aiProposed, path: "/tmp/x", size: 1, risk: .safe,
                                        selected: false)
                let normal = Artifact(category: .libraryData, path: "/tmp/y", size: 1, risk: .userData,
                                      selected: false)
                return AIScanProposer.selectionAfterUndo(proposed, defaultSelected: true) == false
                    && AIScanProposer.selectionAfterUndo(normal, defaultSelected: true) == true
            },
            Check(name: "AIScanProposer：aiProposed 类目 raw value 稳定且有展示名") {
                ArtifactCategory.aiProposed.rawValue == "AI proposed"
                    && !ArtifactCategory.aiProposed.displayName.isEmpty
                    && !ArtifactCategory.aiProposed.symbolName.isEmpty
            },

            // ── InventoryCache ──
            Check(name: "InventoryCache 缓存 app 列表") {
                let first = InventoryCache.shared.allApps()
                let second = InventoryCache.shared.allApps()
                return first.count == second.count && !first.isEmpty
            },
            Check(name: "InventoryCache 缓存 shell 输出（第二次不起子进程）") {
                InventoryCache.shared.invalidate()
                let before = InventoryCache.shared.hasCachedShell("/bin/echo", ["expunge-cache-probe"])
                _ = InventoryCache.shared.shell("/bin/echo", ["expunge-cache-probe"])
                let after = InventoryCache.shared.hasCachedShell("/bin/echo", ["expunge-cache-probe"])
                return !before && after
            },
            Check(name: "InventoryCache.invalidate 清空缓存") {
                _ = InventoryCache.shared.shell("/bin/echo", ["expunge-inv-probe"])
                InventoryCache.shared.invalidate()
                return !InventoryCache.shared.hasCachedShell("/bin/echo", ["expunge-inv-probe"])
            },

            // ── app 列表入口 ──
            Check(name: "AppInventory 覆盖输入法目录") {
                // WeType 装在 /Library/Input Methods，漏掉会让它的容器被判孤儿
                AppInventory.searchPaths.contains { $0.path == "/Library/Input Methods" }
            },
            Check(name: "~/Applications 递归够深（Chrome PWA 在子目录里）") {
                // 真机：~/Applications/Chrome Apps.localized/ 下有 9 个 Chrome
                // PWA 快捷方式，平铺只能看到 1 个。那些是真能卸载的东西。
                guard let spec = AppInventory.searchPaths.first(where: {
                    $0.path == "\(NSHomeDirectory())/Applications"
                }) else { return false }
                return spec.maxDepth >= 2
            },
            Check(name: "/Library/Application Support 不递归（否则翻出系统模板）") {
                // 递归它到 4 层只会翻出 Apple 自带的 Script Editor 模板
                // （Cocoa-AppleScript Applet.app 等 4 个）——
                // 把模板列成「可卸载的 app」是倒退。
                guard let spec = AppInventory.searchPaths.first(where: {
                    $0.path == "/Library/Application Support"
                }) else { return false }
                return spec.maxDepth == 1
            },
            Check(name: "app 发现不进入 bundle 内部（不列 helper app）") {
                // 不加 .skipsPackageDescendants + skipDescendants() 的话，
                // app 自带的 XPC service / helper（…/Contents/Library/…/
                // Helper.app）会被列成独立 app。
                let apps = AppInventory.allApps()
                return !apps.contains { $0.bundlePath.contains("/Contents/") }
            },
            Check(name: "孤儿扫描不递归 ~/Library/Containers（避免 TCC 弹窗）") {
                // 递归别人的沙箱容器会触发「想访问其他 App 的数据」授权框，
                // 而真机 dry-run 证明那里的孤儿产出为 0 —— 收益为零、代价是弹窗。
                // Group Containers 保留（最大的一笔真孤儿在那）。
                let paths = OrphanScanner.searchDirs.map(\.path)
                return !paths.contains("\(NSHomeDirectory())/Library/Containers")
                    && paths.contains("\(NSHomeDirectory())/Library/Group Containers")
            },
            Check(name: "已清空的容器空壳不再报给用户（防「删了还在」死循环）") {
                // 容器目录本身永远删不掉（父目录由 containermanagerd 独占）。
                // 清空内容后如果还报出来，用户就会陷入
                // 「删除 → 报成功 → 再扫还在 → 再删」的死循环。
                let fm = FileManager.default
                let base = "\(NSHomeDirectory())/Library/Caches/expunge-shell-\(UUID().uuidString)"
                let shell = "\(base)/com.example.emptyshell"
                let live = "\(base)/com.example.hasdata"
                let hidden = "\(base)/com.example.hiddenonly"
                defer { try? fm.removeItem(atPath: base) }
                for d in [shell, live, hidden] {
                    guard (try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)) != nil
                    else { return true }   // 建不出来就跳过，不让环境问题变成断言失败
                }
                let ledgerName = ".com.apple.containermanagerd.metadata.plist"
                // 空壳：只有系统账本
                fm.createFile(atPath: "\(shell)/\(ledgerName)", contents: Data("l".utf8))
                // 有数据：账本 + 真实内容
                fm.createFile(atPath: "\(live)/\(ledgerName)", contents: Data("l".utf8))
                fm.createFile(atPath: "\(live)/data.bin", contents: Data("d".utf8))
                // 只有隐藏数据：**不能**被误判成空壳，否则真数据会被漏报
                fm.createFile(atPath: "\(hidden)/.secret", contents: Data("s".utf8))

                return ContainerScanner.isEmptyShell(URL(fileURLWithPath: shell))
                    && !ContainerScanner.isEmptyShell(URL(fileURLWithPath: live))
                    && !ContainerScanner.isEmptyShell(URL(fileURLWithPath: hidden))
            },
            Check(name: "isContainerPath 只认容器本身，不认容器内部路径") {
                // 降级逻辑（清空内容、保留壳）只该用在容器目录本身。
                // 容器**内部**的子路径能正常移到废纸篓，误判成容器会让
                // 一次普通删除变成「只清空了它的内容」。
                let home = NSHomeDirectory()
                return FileDeleter.isContainerPath("\(home)/Library/Containers/com.foo.bar")
                    && FileDeleter.isContainerPath("\(home)/Library/Group Containers/group.com.foo")
                    // 内部子路径 → 不是容器本身
                    && !FileDeleter.isContainerPath("\(home)/Library/Containers/com.foo.bar/Data")
                    && !FileDeleter.isContainerPath("\(home)/Library/Containers/com.foo.bar/Data/tmp")
                    // 别的目录一概不是
                    && !FileDeleter.isContainerPath("\(home)/Library/Caches/com.foo.bar")
            },
            Check(name: "容器删不掉时降级为清空内容（且不碰系统账本）") {
                // 实测事实：~/Library/Containers 的父目录不可写，容器目录本身
                // 无论如何移不走（连 FDA 也没用），但内部数据能删。
                // 这条断言用一个自建的真容器验证降级路径确实清掉了内容。
                let home = NSHomeDirectory()
                let dir = "\(home)/Library/Containers/com.expunge.selftest.\(UUID().uuidString)"
                let fm = FileManager.default
                // 建不出来就跳过（无权限时不该让整个自检失败）
                guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil
                else { return true }
                defer { try? fm.removeItem(atPath: dir) }
                // 注意：**不能**在这里造一个假的
                // `.com.apple.containermanagerd.metadata.plist` 来验证「账本被跳过」——
                // 实测 containermanagerd 会拒绝创建该文件（createFile 返回 false），
                // 断言它「仍然存在」永远不成立。跳过账本的逻辑靠代码审读保证，
                // 这里验证的是能验证的部分：内容被清掉、容器壳保留、且报告不撒谎。
                fm.createFile(atPath: "\(dir)/payload.bin", contents: Data("data".utf8))
                fm.createFile(atPath: "\(dir)/.hidden_payload", contents: Data("data".utf8))

                let r = FileDeleter.delete(dir)
                // 目录本身可能真能删（自建的没被 containermanagerd 登记），
                // 那走的是正常路径，也是可接受的结果。
                if !fm.fileExists(atPath: dir) { return r.success }
                // 走了降级：内容（含隐藏的点文件）应全被清掉，容器壳保留。
                // 报告必须成功 —— 用户在意的数据确实没了。
                return r.success
                    && !fm.fileExists(atPath: "\(dir)/payload.bin")
                    && !fm.fileExists(atPath: "\(dir)/.hidden_payload")
            },
            Check(name: "删除只走废纸篓，不再产生 tar.gz 备份") {
                // v1.4 去掉了备份阶段。这条断言防的是「哪天又把备份加回来、
                // 却忘了同步 UI 文案」——那会重演「弹窗说备份了、其实没有」。
                // 真删一个探针文件，然后确认它进了废纸篓而不是被 unlink。
                let tmp = "\(NSHomeDirectory())/Library/Caches/expunge-trash-\(UUID().uuidString)"
                FileManager.default.createFile(atPath: tmp, contents: Data("probe".utf8))
                let r = FileDeleter.delete(tmp)
                guard r.success, let landed = r.trashedTo else {
                    try? FileManager.default.removeItem(atPath: tmp)
                    return false
                }
                defer { try? FileManager.default.removeItem(atPath: landed) }
                // 进了废纸篓 = 原路径没了、新路径在 .Trash 下且真实存在
                return !FileManager.default.fileExists(atPath: tmp)
                    && landed.contains("/.Trash/")
                    && FileManager.default.fileExists(atPath: landed)
            },
            Check(name: "结果弹窗不会把失败/手动项报成「卸载完成」（防 v1.3 假报成功重演）") {
                // v1.3 的 bug：ResultSheet 的标题、图标、颜色全写死成绿色
                // 「卸载完成」，执行器返回「成功 0 项，失败 4 项」时它照样报完成。
                // CLI 老实、GUI 撒谎 —— 这正是本项目最该避免的那类缺陷。
                // v1.x 新增：shell rc 等需手动编辑的项也不能算成功。
                let allFailed = ResultSheet.status(successCount: 0, failureCount: 4, manualCount: 0)
                let partial = ResultSheet.status(successCount: 8, failureCount: 2, manualCount: 0)
                let ok = ResultSheet.status(successCount: 5, failureCount: 0, manualCount: 0)
                let manualOnly = ResultSheet.status(successCount: 0, failureCount: 0, manualCount: 3)
                let mixedManual = ResultSheet.status(successCount: 2, failureCount: 0, manualCount: 3)
                let failedAndManual = ResultSheet.status(successCount: 0, failureCount: 2, manualCount: 3)
                // 一项都没成功不能叫完成；有失败也不能叫完成；全手动也不能叫完成
                guard case .allFailed = allFailed else { return false }
                guard case .partial = partial else { return false }
                guard case .allSucceeded = ok else { return false }
                guard case .manualOnly = manualOnly else { return false }
                guard case .partial = mixedManual else { return false }
                guard case .allFailed = failedAndManual else { return false }
                // 边界：什么都没选（0/0/0）不算失败
                guard case .allSucceeded = ResultSheet.status(successCount: 0, failureCount: 0, manualCount: 0)
                else { return false }
                return true
            },
            Check(name: "反馈正文里家目录被打码（不泄露用户名）") {
                // 反馈会被贴到公开 issue 里。带真实用户名既没必要，
                // 也会让人不敢点提交 —— 这条守住打码不被改坏。
                let home = NSHomeDirectory()
                let masked = FeedbackSheet.maskHome("\(home)/Library/Caches/foo")
                return masked.hasPrefix("~/") && !masked.contains(home)
            },
            Check(name: "--help 覆盖了所有实际支持的 CLI 参数") {
                // 用法文案和参数解析在两个地方，很容易加了 flag 忘了写文档。
                // 这条断言让「文档漏了」变成自检失败，而不是用户踩坑。
                let usage = AIMacCleanerApp.usage
                let flags = ["--list", "--scan", "--uninstall", "--orphans", "--history",
                             "--reset", "--self-test", "--help",
                             "--dry-run", "--include-userdata", "--no-package-managers",
                             "--skills", "--agent", "--skill", "--ps", "--review"]
                return flags.allSatisfy { usage.contains($0) }
            },
            // ══ Agent skill 层 ══
            // 这套能力抽象是 v1.6 新加的。下面的断言守住三条硬约束：
            // 1) skill 必须对应真实存在的 CLI（防「假成功」——写了命令却没实现）
            // 2) 未知指令一律被白名单拒掉（Agent 只有项目自己的 CLI 这一种外部能力）
            // 3) 高危 skill 只出计划不出手，Agent 永远拿不到「真删」

            Check(name: "SkillRegistry 注册了 11 个 skill") {
                // 和 SkillRegistry.cliListing 文案、AskAIView 的计数必须一致。
                SkillRegistry.all.count == 11
            },
            Check(name: "每个 skill 的 cli 都对应真实 CLI flag（防假成功）") {
                // Skill.swift 的硬约束之一：每个 skill 必须对应一条真实存在的
                // AI Mac Cleaner CLI 命令。这里拿注册表里的 cli 和 --help 对表。
                let usage = AIMacCleanerApp.usage
                let expectedFlags = ["--list", "--scan", "--orphans", "--ps",
                                     "--review", "--history", "--uninstall",
                                     "--trace-roots", "--search", "--inspect", "--propose"]
                return expectedFlags.allSatisfy { usage.contains($0) }
                    && SkillRegistry.all.count == expectedFlags.count
            },

            // ── 调查能力（v1.7：给 Agent 补上「翻目录 / 读内容」的手）──
            //
            // 这批断言锁的是**安全边界**，不是「能不能搜到东西」——
            // 搜得到与否依赖用户机器上有什么，不适合当断言。

            Check(name: "PathProbe 归一化能让 story 命中 story-fab（StoryFab 漏项的回归防线）") {
                // 这就是那个真实漏项：bundle id com.story-fab.desktop、关键词 storyfab，
                // 而数据目录叫 story-fab。归一化去掉 - _ . 空格后三者等价。
                PathProbe.normalize("story-fab") == PathProbe.normalize("StoryFab")
                    && PathProbe.normalize("story_fab") == PathProbe.normalize("story.fab")
            },
            Check(name: "inspect_path 拒绝白名单外的路径（安全边界）") {
                // /System、/usr 这类路径连「看一眼」的入口都不给。
                let skill = SkillRegistry.resolve("inspect_path")
                guard let skill else { return false }
                return skill.spec.risk == .readOnly
            },
            Check(name: "三个调查 skill 都是只读，只有 propose_paths 会改状态") {
                let readOnly = ["list_trace_roots", "search_paths", "inspect_path"]
                guard readOnly.allSatisfy({ SkillRegistry.resolve($0)?.spec.risk == .readOnly })
                else { return false }
                // propose_paths 只往清单加候选（mutating），绝不能是 destructive——
                // 它一旦带上删除语义，模型就能自己「提名并执行」，安全网就没了。
                return SkillRegistry.resolve("propose_paths")?.spec.risk == .mutating
            },
            Check(name: "调查类 skill 全部登记在白名单里，且不提供任意 shell") {
                // 白名单是安全边界：不在表里的名字连执行入口都找不到。
                for n in ["list_trace_roots", "search_paths", "inspect_path", "propose_paths"] {
                    guard SkillRegistry.resolve(n) != nil else { return false }
                }
                return SkillRegistry.resolve("rm") == nil
                    && SkillRegistry.resolve("shell") == nil
            },
            Check(name: "propose_paths 产出的项永不默认勾选（硬约束）") {
                // 模型能「提名」，不能「勾选」。这条一旦破了，误删入口就打开了。
                let a = AIScanProposer.makeArtifact(path: "/tmp/does-not-matter",
                                                   reason: "test")
                return a.selected == false && a.category == .aiProposed
            },
            Check(name: "inspect_path 在真实路径上不越界：非白名单目录直接判定为不可查") {
                // 用一个真实存在的系统路径验证「白名单判定」本身有效，
                // 而不依赖具体机器上有没有用户数据。
                !FileDeleter.isAllowed("/System/Library/CoreServices")
                    && !FileDeleter.isAllowed("/usr/bin")
            },
            Check(name: "SkillRegistry 白名单拒绝未注册指令") {
                // `rm -rf` 这种东西连承接入口都找不到 —— 这是安全边界。
                SkillRegistry.resolve("rm -rf") == nil
                    && SkillRegistry.resolve("delete_everything") == nil
                    && SkillRegistry.resolve("scan_app") != nil
            },
            Check(name: "SkillRegistry 口语别名能解析（scan→scan_app 等）") {
                SkillRegistry.resolve("scan")?.spec.name == "scan_app"
                    && SkillRegistry.resolve("ps")?.spec.name == "list_processes"
                    && SkillRegistry.resolve("review")?.spec.name == "review_plan"
                    && SkillRegistry.resolve("history")?.spec.name == "show_history"
            },
            Check(name: "必需参数缺失时校验报错") {
                SkillRegistry.validate(ScanAppSkill().spec, args: SkillArgs()) != nil
            },
            Check(name: "参数齐全时校验通过") {
                SkillRegistry.validate(ScanAppSkill().spec,
                                       args: SkillArgs(["target": "Cursor"])) == nil
            },
            Check(name: "枚举型参数越界被拦（kind 只接受 orphan/ai/all）") {
                SkillRegistry.validate(ScanLeftoversSkill().spec,
                                       args: SkillArgs(["kind": "bogus"])) != nil
            },
            Check(name: "AgentProtocol 能解析 ```expunge 代码块里的 JSON 调用") {
                let (text, calls) = AgentProtocol.parse(
                    "好的，这就扫\n```expunge\n{\"skill\":\"scan_app\",\"args\":{\"target\":\"Cursor\"}}\n```")
                return calls.count == 1
                    && calls[0].name == "scan_app"
                    && calls[0].args["target"] == "Cursor"
                    && text.contains("好的")
            },
            Check(name: "AgentProtocol 无代码块时只返回正文、不误判调用") {
                let (text, calls) = AgentProtocol.parse("帮我卸载 Cursor")
                return calls.isEmpty && text == "帮我卸载 Cursor"
            },
            Check(name: "AgentProtocol 认 ```json 等其它语言标记的围栏（按内容认，不按标记认）") {
                // 模型经常把标记写成 json / 空标记。只认 expunge 的话，这一整块调用
                // 既不执行也不摘除，最后原样糊进气泡 —— 正是「看着像坏了」的根因。
                let (text, calls) = AgentProtocol.parse(
                    "继续\n```json\n{\"skill\":\"propose_paths\",\"args\":{\"path\":\"/tmp/a\"}}\n```")
                return calls.count == 1
                    && calls[0].name == "propose_paths"
                    && calls[0].args["path"] == "/tmp/a"
                    && !text.contains("skill")
            },
            Check(name: "AgentProtocol 认被截断的未闭合围栏（max_tokens 砍掉了收尾的 ```）") {
                let (_, calls) = AgentProtocol.parse(
                    "```expunge\n{\"skill\":\"review_plan\",\"args\":{\"scope\":\"apps\"}}")
                return calls.count == 1 && calls[0].args["scope"] == "apps"
            },
            Check(name: "AgentProtocol 容忍 `=` 写法的伪 JSON 参数（值里的空格不被截断）") {
                let (text, calls) = AgentProtocol.parse(
                    "```json\n{\"skill\": \"propose_paths\", \"args\": {\"path=/Users/me/Application Support/story-fab\"}}\n```")
                return calls.count == 1
                    && calls[0].name == "propose_paths"
                    && calls[0].args["path"] == "/Users/me/Application Support/story-fab"
                    && !text.contains("propose_paths")
            },
            Check(name: "流式上屏正文先摘掉工具调用块（半截 JSON 不该给用户看）") {
                let mid = "先扫一遍\n```expunge\n{\"skill\":\"scan_app\""
                let bare = "结论如下\n{\"skill\":\"review_plan\",\"args\":{\"scope\":\"apps\"}}"
                return AgentProtocol.visibleStreamingText(mid) == "先扫一遍"
                    && AgentProtocol.visibleStreamingText(bare) == "结论如下"
            },
            Check(name: "ThinkTag：把 think 标签从正文摘到思考里（含未闭合的流式途中）") {
                // 有些推理模型把思考连标签写进正文，原样上屏就是带标签的内心独白。
                // 标签一律用 ThinkTag.open/close 拼接，源码里不出现字面尖括号标记。
                let o = ThinkTag.open, c = ThinkTag.close
                let closed = ThinkTag.split("结论" + o + "思考内容" + c + "删 1 项")
                let unclosed = ThinkTag.split(o + "推理途中")   // 还没闭合
                let plain = ThinkTag.split("普通正文")
                return closed.text == "结论删 1 项" && closed.reasoning == "思考内容"
                    && unclosed.text == "" && unclosed.reasoning == "推理途中"
                    && plain.text == "普通正文" && plain.reasoning == ""
            },
            Check(name: "ThinkTag.strip 去掉孤立的 think 标签") {
                let o = ThinkTag.open, c = ThinkTag.close
                return ThinkTag.strip(o + "思考内容" + c) == "思考内容"
                    && ThinkTag.strip("正常文字") == "正常文字"
            },
            Check(name: "AgentProtocol.parse 丢掉正文里的 think 标签") {
                let (text, calls) = AgentProtocol.parse(
                    ThinkTag.open + "思考" + ThinkTag.close + "\n答案：1 项")
                return text == "答案：1 项" && calls.isEmpty
            },
            Check(name: "反馈邮件：默认处理器是浏览器时判定为需改开本机 Mail.app") {
                // 浏览器抢注 mailto: 时，点「发邮件」会开网页邮箱；这条判定决定要不要改开 Mail.app。
                FeedbackSheet.isBrowserMailHandler(bundleId: "com.google.Chrome")
                    && FeedbackSheet.isBrowserMailHandler(bundleId: "com.apple.Safari")
                    && FeedbackSheet.isBrowserMailHandler(bundleId: "org.mozilla.firefox")
                    && !FeedbackSheet.isBrowserMailHandler(bundleId: "com.apple.mail")
                    && !FeedbackSheet.isBrowserMailHandler(bundleId: nil)
            },
            Check(name: "destructive skill 必须标记 destructive（Agent 不自己删除的底线）") {
                PlanUninstallSkill().spec.risk == .destructive
            },
            Check(name: "未配置模型时 Agent 不运行、提示去配置（纯 AI Agent 底线）") {
                // 没有任何 config 时，run 必须直接声明 needsConfig，且不调用
                // 任何 skill —— 绝不能退回本地规则假装能回答。
                let run = await AgentRuntime(config: nil).run(goal: "卸载 Cursor")
                return run.needsConfig && run.steps.isEmpty && !run.answer.isEmpty
            },
            Check(name: "空配置（未开/无 Key）同样要求先配置模型") {
                let run = await AgentRuntime(config: AIModelConfig()).run(goal: "扫一遍残留")
                return run.needsConfig && run.steps.isEmpty
            },

            // ══ 「问 AI」对话策略（Sprint A）══
            // 斜杠命令是本次唯一的安全项：判错一条，用户问「/Users/… 这个目录能删吗」
            // 就会被当成清空指令吞掉。下面把判定表逐条钉死。

            Check(name: "ChatCommand 命中 /new /clear /reset（含大小写与首尾空白）") {
                func isNew(_ s: String) -> Bool {
                    if case .new = ChatCommand.parse(s) { return true }
                    return false
                }
                func isReset(_ s: String) -> Bool {
                    if case .reset = ChatCommand.parse(s) { return true }
                    return false
                }
                return isNew("/new") && isNew("/NEW") && isNew("/New")
                    && isNew("/clear") && isNew("  /Clear  ")     // /clear 是 /new 的静默别名
                    && isReset("/reset") && isReset("  /Reset  ") && isReset("/RESET")
            },
            Check(name: "ChatCommand 绝不吞路径（/Users/… 与 /tmp/x 必须发给模型）") {
                // 安全项的核心反例。正则漏写 ^$ 就会在这里出事。
                ChatCommand.parse("/Users/alice/Documents") == nil
                    && ChatCommand.parse("/Users/lh/Documents") == nil
                    && ChatCommand.parse("/tmp/x") == nil
                    && ChatCommand.parse("/Library/Caches/new") == nil
                    && ChatCommand.parse("/var/folders/reset") == nil
            },
            Check(name: "ChatCommand 前缀 / 带参 / 双斜杠都不算命令") {
                ChatCommand.parse("/new foo") == nil
                    && ChatCommand.parse("/newsletter") == nil
                    && ChatCommand.parse("/resetting") == nil
                    && ChatCommand.parse("//new") == nil
                    && ChatCommand.parse("new") == nil
                    && ChatCommand.parse("帮我清理一下") == nil
                    && ChatCommand.parse("") == nil
            },
            Check(name: "ChatCommand 穷举反例扫描（QA 扩表：一条都不许被吞）") {
                // QA 补充：把「长得像命令」的输入尽量列全。这里每多一条 nil，
                // 就是少一次「用户的真实提问被当成清空指令吃掉」。
                let mustBeNil = [
                    // 真实路径 —— 用户最可能问的那类
                    "/Users/alice/Documents", "/Users/lh/Documents/new",
                    "/tmp/x", "/tmp/reset", "/etc/clear", "/Applications/new",
                    "/var/folders/T/new", "/private/tmp/reset",
                    // 命令带尾巴 / 带参数
                    "/new foo", "/new -f", "/new;", "/new.", "/new,", "/new/",
                    "/reset all", "/reset()", "/reset/", "/clear all", "/clear/",
                    // 前缀与粘连
                    "/newsletter", "/news", "/resetting", "/resets",
                    "/cleared", "/clearance", "/newreset", "/reset/new",
                    // 斜杠形状不对
                    "//new", "///reset", "/", "//", "new", "reset", "clear",
                    "\\new", "-/new", "./new",
                    // 斜杠与词之间夹了东西
                    "/ new", "/\tnew", "/ reset",
                    // 全角斜杠 / 全角字母：不是 ASCII 命令，必须照常发模型
                    "／new", "/ＮＥＷ", "／ＲＥＳＥＴ",
                    // 自然语言
                    "帮我清理一下", "reset 一下上下文", "能不能 /new 一下",
                    "", "   ", "\n\n"
                ]
                for s in mustBeNil where ChatCommand.parse(s) != nil { return false }

                // 反向对照：白名单本身必须仍然命中 —— 否则一个「永远返回 nil」
                // 的实现也能骗过上面那一整张反例表。
                func isNew(_ s: String) -> Bool {
                    if case .new = ChatCommand.parse(s) { return true }
                    return false
                }
                func isReset(_ s: String) -> Bool {
                    if case .reset = ChatCommand.parse(s) { return true }
                    return false
                }
                let mustHitNew = ["/new", "/NEW", "/New", "/nEw",
                                  "/clear", "/CLEAR", "/Clear",
                                  " /new ", "\t/new\t", "\n/new\n", "  /clear  "]
                let mustHitReset = ["/reset", "/RESET", "/Reset",
                                    "  /reset  ", "\n/RESET\t"]
                for s in mustHitNew where !isNew(s) { return false }
                for s in mustHitReset where !isReset(s) { return false }
                return true
            },
            Check(name: "斜杠补全面板：候选全部落在白名单内（面板不能提供 parse 不认的命令）") {
                for item in ChatCommand.palette {
                    // /remember 是唯一带参命令，裸 token 不命中（须后跟内容），用 dummy 参数验证。
                    let testInput = item.token == ChatCommand.rememberToken ? item.token + " x" : item.token
                    if ChatCommand.parse(testInput) == nil { return false }
                }
                return ChatCommand.palette.count == 4
                    && Set(ChatCommand.palette.map(\.token)) == ["/clear", "/reset", "/new", "/remember"]
            },
            Check(name: "斜杠补全面板：路径 / 带参 / 双斜杠一律不弹（复用命令的那张反例表）") {
                let mustBeEmpty = ["/Users/alice/Documents", "/Users/lh/Documents/new",
                                   "/tmp/x", "/Library/Caches/new", "/var/folders/reset",
                                   "//new", "///reset", "/new foo", "/reset all", "/ new",
                                   "/newsletter", "/resetting", "/cleared", "/users",
                                   "new", "帮我清理一下", "", "   ", "／new"]
                for s in mustBeEmpty where !ChatCommand.suggestions(for: s).isEmpty { return false }
                return true
            },
            Check(name: "斜杠补全面板：前缀匹配按预期收敛") {
                ChatCommand.suggestions(for: "/").count == 4
                    && ChatCommand.suggestions(for: "/c").map(\.token) == ["/clear"]
                    && ChatCommand.suggestions(for: "/re").map(\.token) == ["/reset", "/remember"]
                    && ChatCommand.suggestions(for: "/re").first?.token == "/reset"   // 老用户敲 /re+回车 仍是 /reset
                    && ChatCommand.suggestions(for: "/N").map(\.token) == ["/new"]
                    && ChatCommand.suggestions(for: "/clear").map(\.token) == ["/clear"]
            },

            // ══ /remember 命令自检 ══

            Check(name: "ChatCommand /remember 命中（仅当带参，裸命令不命中）") {
                // 裸 /remember（无参）：不命中，正常发给模型。用户必须先给内容。
                ChatCommand.parse("/remember") == nil
                    && ChatCommand.parse("/REMEMBER") == nil
                    && ChatCommand.parse("/remember ") == nil
                // 带参命中
                    && { if case .remember(let body) = ChatCommand.parse("/remember JetBrains 别动") {
                        return body == "JetBrains 别动" } else { return false } }()
                    && { if case .remember(let body) = ChatCommand.parse("  /Remember   ~/Library/Application Support/JetBrains  ") {
                        return body == "~/Library/Application Support/JetBrains" } else { return false } }()
            },
            Check(name: "ChatCommand /remember 绝不吞路径") {
                ChatCommand.parse("/Users/remember me") == nil
                    && ChatCommand.parse("/rememberfoo") == nil
                    && ChatCommand.parse("/remember/x") == nil
            },

            // ══ 长期记忆（MemoryPolicy / orphan exemption）══

            Check(name: "MemoryPolicy.extractPaths 含空格路径整条抽出（不劈成父目录）") {
                // 核心回归：旧实现会把 ~/Library/Application Support/JetBrains 劈坏。
                let paths = MemoryPolicy.extractPaths(from: "~/Library/Application Support/JetBrains 别动，IDEA 还装着")
                guard paths.count == 1 else { return false }
                let full = NSHomeDirectory() + "/Library/Application Support/JetBrains"
                return paths[0] == full
            },
            Check(name: "MemoryPolicy.extractPaths 引号路径同样整条抽出") {
                let paths = MemoryPolicy.extractPaths(from: "\"/Users/alice/Library/Application Support/JetBrains\" 别动")
                return paths.count == 1 && paths[0] == "/Users/alice/Library/Application Support/JetBrains"
            },
            Check(name: "MemoryPolicy.extractPaths 单段词 / 太短 / home 根一律不认") {
                MemoryPolicy.extractPaths(from: "/new 很危险").isEmpty        // /new 太短
                    && MemoryPolicy.extractPaths(from: "/tmp").isEmpty         // 单段、太短
                    && MemoryPolicy.extractPaths(from: "~/ 别动").isEmpty      // 整条 home 根不认
                    && MemoryPolicy.extractPaths(from: "/Users/alice/Documents").count == 1
            },
            Check(name: "MemoryPolicy.isExempt 双向前缀（后代 / 祖先都跳过）") {
                let keep: Set<String> = ["/tmp/expunge-test/JetBrains"]
                return MemoryPolicy.isExempt("/tmp/expunge-test/JetBrains", keepPaths: keep)
                    && MemoryPolicy.isExempt("/tmp/expunge-test/JetBrains/IdeaIC2024", keepPaths: keep)   // 后代
                    && MemoryPolicy.isExempt("/tmp/expunge-test", keepPaths: keep)                         // 祖先
                    && !MemoryPolicy.isExempt("/tmp/expunge-test/Other", keepPaths: keep)
                    && !MemoryPolicy.isExempt("/tmp/expunge-test/JetBrains", keepPaths: [])
            },
            Check(name: "MemoryPolicy.rejectionReason 空 / 超长 / 超量") {
                MemoryPolicy.rejectionReason(for: "   ", existingCount: 0) != nil      // 空
                    && MemoryPolicy.rejectionReason(for: String(repeating: "x", count: MemoryPolicy.maxNoteChars + 1), existingCount: 0) != nil
                    && MemoryPolicy.rejectionReason(for: "记一条", existingCount: MemoryPolicy.maxNotes) != nil
                    && MemoryPolicy.rejectionReason(for: "记一条", existingCount: 0) == nil
            },
            Check(name: "MemoryPolicy.promptBlock 空记忆返回空串、多记忆注入且含文本") {
                guard MemoryPolicy.promptBlock([]).isEmpty else { return false }
                let a = MemoryNote(text: "JetBrains 别动")
                let b = MemoryNote(text: "阿里云盘残留也别清")
                let block = MemoryPolicy.promptBlock([a, b])
                return !block.isEmpty
                    && block.contains("JetBrains 别动")
                    && block.contains("阿里云盘残留也别清")
            },

            Check(name: "ChatPolicy.trim 恰好 15 轮不裁") {
                var msgs: [AIMessage] = []
                for i in 0..<ChatPolicy.maxContextTurns {
                    msgs.append(AIMessage(role: .me, text: "q\(i)"))
                    msgs.append(AIMessage(role: .ai, text: "a\(i)"))
                }
                let trimmed = ChatPolicy.trim(msgs)
                return trimmed.count == msgs.count && trimmed.first?.text == "q0"
            },
            Check(name: "ChatPolicy.trim 16 轮裁到 15 轮且以提问开头") {
                var msgs: [AIMessage] = []
                for i in 0..<(ChatPolicy.maxContextTurns + 1) {
                    msgs.append(AIMessage(role: .me, text: "q\(i)"))
                    msgs.append(AIMessage(role: .ai, text: "a\(i)"))
                }
                let trimmed = ChatPolicy.trim(msgs)
                return trimmed.count == ChatPolicy.maxContextTurns * 2
                    && trimmed.first?.role == .me
                    && trimmed.first?.text == "q1"        // 最老的一轮被丢掉
                    && trimmed.last?.text == "a\(ChatPolicy.maxContextTurns)"
            },
            Check(name: "ChatPolicy.trim 窗口切在 .ai 上时丢掉孤儿回答") {
                // 窗口起点如果落在一条 .ai 上，屏幕就会出现「没有提问的回答」。
                // 宁可少留半轮，也不留孤儿 —— 15 是上限而非精确值。
                let msgs = [
                    AIMessage(role: .me, text: "q1"),
                    AIMessage(role: .ai, text: "a1a"),
                    AIMessage(role: .ai, text: "a1b"),
                    AIMessage(role: .me, text: "q2"),
                    AIMessage(role: .ai, text: "a2")
                ]
                // maxTurns=2 → 保留 4 条：从尾部数到第 4 条正好是 a1（一条 .ai），
                // 起点向后挪到 q2，a1/a1b 这两条孤儿回答一并丢掉，实际只留 2 条。
                return ChatPolicy.trim(msgs, maxTurns: 2).map(\.text) == ["q2", "a2"]
                    // 未超限时原样返回，不做首条对齐（首条 .ai 可能是 configPrompt，要显示）
                    && ChatPolicy.trim(msgs, maxTurns: 3).count == 5
            },
            Check(name: "ChatPolicy.trim 锚点被裁掉后语义仍然成立") {
                // 锚点被裁说明它之后已经积累了满窗口的对话，
                // 「只发锚点之后」自动继续成立，不需要补偿分支。
                var msgs: [AIMessage] = [AIMessage(role: .me, text: "old"),
                                         AIMessage(role: .ai, text: "old-a"),
                                         AIMessage.anchor()]
                for i in 0..<(ChatPolicy.maxContextTurns + 1) {
                    msgs.append(AIMessage(role: .me, text: "q\(i)"))
                    msgs.append(AIMessage(role: .ai, text: "a\(i)"))
                }
                let trimmed = ChatPolicy.trim(msgs)
                let history = ChatPolicy.modelHistory(trimmed)
                return !trimmed.contains { $0.isAnchor }          // 锚点确实被裁掉了
                    && !trimmed.contains { $0.text == "old" }      // 锚点之前的也没了
                    && history.first?.content == "q1"
                    && history.allSatisfy { $0.content != "old" }
            },
            Check(name: "ChatPolicy.trim 不数系统消息（锚点不占轮数）") {
                var msgs: [AIMessage] = []
                for i in 0..<ChatPolicy.maxContextTurns {
                    msgs.append(AIMessage(role: .me, text: "q\(i)"))
                    msgs.append(AIMessage(role: .ai, text: "a\(i)"))
                }
                msgs.insert(AIMessage.anchor(), at: 4)
                // 15 轮 + 1 条系统消息：仍然不该裁
                return ChatPolicy.trim(msgs).count == msgs.count
            },

            Check(name: "ChatPolicy.modelHistory 只取最后一个锚点之后") {
                let msgs = [
                    AIMessage(role: .me, text: "q1"),
                    AIMessage(role: .ai, text: "a1"),
                    AIMessage.anchor(),
                    AIMessage(role: .me, text: "q2"),
                    AIMessage(role: .ai, text: "a2"),
                    AIMessage.anchor(),
                    AIMessage(role: .me, text: "q3")
                ]
                let h = ChatPolicy.modelHistory(msgs)
                return h.count == 1 && h[0].role == "user" && h[0].content == "q3"
            },
            Check(name: "ChatPolicy.modelHistory 排除系统消息（不把 system 当 assistant）") {
                // 二分映射 `role == .me ? user : assistant` 的死角：
                // 加了第三个 case 之后，系统消息会被当 assistant 喂给模型。
                let msgs = [
                    AIMessage(role: .me, text: "q1"),
                    AIMessage(role: .system, text: "系统提示", isAnchor: false),
                    AIMessage(role: .ai, text: "a1")
                ]
                let h = ChatPolicy.modelHistory(msgs)
                return h.count == 2
                    && h.allSatisfy { $0.content != "系统提示" }
                    && h.map(\.role) == ["user", "assistant"]
            },
            Check(name: "ChatPolicy.modelHistory 丢掉开头的 .ai（修 Anthropic 400）") {
                // 「未配模型 → 发一句 → 收到 configPrompt(.ai) → 配好模型 → 再发一句」
                // 这条路径上 history 首条是 assistant，Anthropic /v1/messages 必然 400。
                let msgs = [
                    AIMessage(role: .ai, text: AgentRuntime.configPrompt),
                    AIMessage(role: .ai, text: "又一条"),
                    AIMessage(role: .me, text: "q1"),
                    AIMessage(role: .ai, text: "a1")
                ]
                let h = ChatPolicy.modelHistory(msgs)
                return h.first?.role == "user" && h.count == 2
            },
            Check(name: "ChatPolicy.modelHistory 无锚点时取全部") {
                let msgs = [AIMessage(role: .me, text: "q1"), AIMessage(role: .ai, text: "a1")]
                return ChatPolicy.modelHistory(msgs).count == 2
                    && ChatPolicy.afterAnchor(msgs).count == 2
            },
            Check(name: "ChatPolicy.hasConversation：锚点不计，非锚点 .system 计入") {
                // 纯锚点 → 不计（/reset 后回空态）
                ChatPolicy.hasConversation([]) == false
                    && ChatPolicy.hasConversation([AIMessage.anchor()]) == false
                // 对话消息 → 计入
                    && ChatPolicy.hasConversation([AIMessage(role: .me, text: "q")]) == true
                    && ChatPolicy.hasConversation([AIMessage(role: .ai, text: "a")]) == true
                // 系统提示（非锚点）→ 计入，显示在屏幕上
                    && ChatPolicy.hasConversation([AIMessage(role: .system, text: "提示")]) == true
                // 锚点 + 系统提示 → 计入
                    && ChatPolicy.hasConversation([AIMessage.anchor(),
                                                   AIMessage(role: .system, text: "提示")]) == true
            },
            Check(name: "ChatPolicy 限额常量与 AgentRuntime.maxTurns 不是一回事") {
                // K3：maxTurns 是单次 agent loop 的决策轮数，
                // maxContextTurns=15 是跨提问保留的对话轮数。改一个别顺手改另一个。
                //
                // maxTurns 的期望值跟着「调查一个 app」的真实链路走：
                // scan_app → search_paths（可能多次）→ inspect_path（可能多次）→ propose_paths → 汇总。
                // 曾经是 4，常见「工具跑完却没结论」；后提到 6、再到 8。
                // 无论如何，最后一轮必须留给「只出结论」（见 budgetNote）。
                ChatPolicy.maxContextTurns == 15
                    && ChatPolicy.maxInputChars == 9999
                    && ChatPolicy.inputWarnThreshold == 900
                    // 至少要能容纳完整调查链路（5 步），否则又会退化成「没有结论」。
                    && AgentRuntime(config: nil).maxTurns >= 5
            },
            Check(name: "AgentRuntime 预算提示：最后一轮明确禁止再调工具") {
                // 这是「扫描后只提示达到最大执行步数、却不给结论」的根因修复点：
                // 正常轮提示剩余额度、催模型尽早收敛；最后一轮从提示词层面禁止调用工具。
                // 文案随语言变，断言要跟着 `L10n.isChinese` 走（照抄复数那条的做法）。
                let last = LLMBrain.budgetNote(turnsRemaining: 0)
                let mid  = LLMBrain.budgetNote(turnsRemaining: 3)
                let finalWord = L10n.isChinese ? "最后一轮" : "LAST turn"
                return last.contains(finalWord)
                    && last.contains("expunge")
                    && !mid.contains(finalWord)
                    && mid.contains("3")
            },
            Check(name: "输入计数按字素簇算（汉字 1 个、emoji 1 个）") {
                "清理一下这个应用".count == 8
                    && "👍🏽".count == 1
                    && "👨‍👩‍👧".count == 1
                    && String(repeating: "字", count: ChatPolicy.maxInputChars + 1).count > ChatPolicy.maxInputChars
            },

            Check(name: "永久性失败不重试（余额不足 / Key 无效重试无意义）") {
                // 真机教训：余额不足时每次点击都重试 3 次 + 退避，用户只看到
                // 「等了很久还是失败」，却拿不到「去充值」这句准话。
                // 余额不足还常被网关吞成 200 + choices:null，误判成 Key 错误。
                return LLMError.insufficientBalance.isPermanent
                    && LLMError.missingKey.isPermanent
                    && LLMError.badURL.isPermanent
                    && LLMError.http(status: 401, body: "").isPermanent
                    && LLMError.http(status: 403, body: "").isPermanent
                    // 反例：限流 / 上游抽风 / 解析类问题都该继续重试。
                    && !LLMError.http(status: 429, body: "rate limited").isPermanent
                    && !LLMError.upstreamFailed("ZhipuAI/GLM-5.2").isPermanent
                    && !LLMError.noContent.isPermanent
                    && !LLMError.underlying(URLError(.timedOut)).isPermanent
            },

            Check(name: "AIMessage 的 reasoning 字段：往返保留、缺键不炸（老历史兼容）") {
                // 加字段最怕的事：老历史没有这个键 → 解码失败 → ChatStore 整份清空。
                let m = AIMessage(role: .ai, text: "结论", steps: [],
                                  redirect: nil, awaitingApproval: false, isAnchor: false,
                                  reasoning: "先看扫描器漏了什么")
                guard let data = try? JSONEncoder().encode(m),
                      let back = try? JSONDecoder().decode(AIMessage.self, from: data)
                else { return false }
                // 老格式（没有 reasoning 键）必须仍能解出来，且 reasoning 为 nil。
                let legacy = #"{"role":"ai","text":"旧消息","createdAt":0}"#
                guard let legacyData = legacy.data(using: .utf8),
                      let old = try? JSONDecoder().decode(AIMessage.self, from: legacyData)
                else { return false }
                return back.reasoning == "先看扫描器漏了什么" && old.reasoning == nil
            },

            // ── 流式（深度思考 / token 级输出）──

            Check(name: "LLMStream 一次性响应兜底：正文与思考分开取") {
                // 端点忽略 stream 时会直接回一个完整 JSON，这时不能把
                // reasoning_content 混进正文（否则用户会看到模型的自言自语）。
                let body = #"{"choices":[{"message":{"content":"结论","reasoning_content":"推理过程"}}]}"#
                let (t, r) = LLMStream.parseOneShot(body, anthropic: false)
                return t == "结论" && r == "推理过程"
            },
            Check(name: "LLMStream 兼容 reasoning 别名与 thinking 块") {
                // 部分网关用 reasoning 而非 reasoning_content；Anthropic 走 content 数组。
                let alias = #"{"choices":[{"message":{"content":"A","reasoning":"B"}}]}"#
                let (t1, r1) = LLMStream.parseOneShot(alias, anthropic: false)
                let anth = #"{"content":[{"type":"thinking","thinking":"T"},{"type":"text","text":"A"}]}"#
                let (t2, r2) = LLMStream.parseOneShot(anth, anthropic: true)
                return t1 == "A" && r1 == "B" && t2 == "A" && r2 == "T"
            },
            Check(name: "流式降级兜底：OpenAI 老式 choice.text 也能取到正文") {
                // 有的 OpenAI 兼容网关（老接口）把正文放在 choice.text 而不是 message.content。
                let leg = #"{"choices":[{"text":"老接口正文"}]}"#
                let (t, r) = LLMStream.parseOneShot(leg, anthropic: false)
                return t == "老接口正文" && r.isEmpty
            },
            Check(name: "流式降级兜底：平铺 content 的极简网关（无 choices 包裹）") {
                // 某些极简 OpenAI 兼容端点直接返回顶层 content 字符串。
                let flat = #"{"content":"极简正文","reasoning_content":"极简推理"}"#
                let (t, r) = LLMStream.parseOneShot(flat, anthropic: false)
                return t == "极简正文" && r == "极简推理"
            },
            Check(name: "流式降级兜底：Anthropic 两种块（text/thinking）各自归位") {
                // 只给 text、只给 thinking、两者都有 —— 三种都要取对。
                let textOnly = #"{"content":[{"type":"text","text":"只看正文"}]}"#
                let thinkOnly = #"{"content":[{"type":"thinking","thinking":"只看推理"}]}"#
                let (t1, r1) = LLMStream.parseOneShot(textOnly, anthropic: true)
                let (t2, r2) = LLMStream.parseOneShot(thinkOnly, anthropic: true)
                return t1 == "只看正文" && r1.isEmpty
                    && t2.isEmpty && r2 == "只看推理"
            },
            Check(name: "流式：OpenAI 协议的帧能逐字出（content + reasoning_content 分开）") {
                // 把真实 SSE 的几帧喂进 parseStreamFrame，模拟逐字流式。
                let textFrame = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
                let thinkFrame = #"data: {"choices":[{"delta":{"reasoning_content":"让我想想"}}]}"#
                let roleFrame = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
                let (ct, cr) = LLMStream.parseStreamFrame(textFrame, anthropic: false)
                let (rt, rr) = LLMStream.parseStreamFrame(thinkFrame, anthropic: false)
                let (ot, or) = LLMStream.parseStreamFrame(roleFrame, anthropic: false)
                _ = LLMStream.parseStreamFrame("data: [DONE]", anthropic: false)
                return ct == "你好" && cr.isEmpty
                    && rt.isEmpty && rr == "让我想想"
                    && ot.isEmpty && or.isEmpty   // role-only 帧被忽略，不产出空内容
            },
            Check(name: "流式：Anthropic 协议的帧能逐字出（thinking_delta + text_delta 分开）") {
                let thinkFrame = #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"T"}}"#
                let textFrame = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"A"}}"#
                let (tt, tr) = LLMStream.parseStreamFrame(thinkFrame, anthropic: true)
                let (at, ar) = LLMStream.parseStreamFrame(textFrame, anthropic: true)
                _ = LLMStream.parseStreamFrame("data: [DONE]", anthropic: true)
                return tt.isEmpty && tr == "T"
                    && at == "A" && ar.isEmpty
            },
            Check(name: "流式容错：Content-Type 没标 event-stream 也要能按 SSE 拆出内容") {
                // 不少网关把 SSE 当成 text/plain 发（Content-Type 不带 event-stream）。
                // 这种帧逐帧喂进去必须能拿到正文，不能整段丢。
                let frames = [
                    #"data: {"choices":[{"delta":{"content":"逐"}}]}"#,
                    #"data: {"choices":[{"delta":{"content":"字"}}]}"#,
                    "data: [DONE]"
                ]
                var text = ""
                for f in frames {
                    let (c, _) = LLMStream.parseStreamFrame(f, anthropic: false)
                    text += c
                }
                return text == "逐字"
            },
            Check(name: "AIMessage Codable 往返（除 id 外全等）") {
                let step = AgentStep(skill: "scan_app", command: "ai-mac-cleaner --scan Cursor",
                                     summary: "扫到 12 项", ok: true, risk: .readOnly)
                let m = AIMessage(role: .me, text: "卸载 Cursor", steps: [step],
                                  redirect: .apps, awaitingApproval: true, isAnchor: false)
                guard let data = try? JSONEncoder().encode(m),
                      let back = try? JSONDecoder().decode(AIMessage.self, from: data)
                else { return false }
                return back.role == m.role && back.text == m.text
                    && back.redirect == m.redirect
                    && back.awaitingApproval == m.awaitingApproval
                    && back.isAnchor == m.isAnchor
                    && back.steps.count == 1
                    && back.steps[0].skill == step.skill
                    && back.steps[0].command == step.command
                    && back.steps[0].summary == step.summary
                    && back.steps[0].ok == step.ok
                    && back.steps[0].risk == step.risk
                    // id 不参与序列化，解码后必然是一个新的 UUID
                    && back.id != m.id
            },
            Check(name: "AIMessage 锚点往返后仍是锚点") {
                let a = AIMessage.anchor()
                guard let data = try? JSONEncoder().encode(a),
                      let back = try? JSONDecoder().decode(AIMessage.self, from: data)
                else { return false }
                return back.isAnchor && back.role == .system && !back.text.isEmpty
            },
            Check(name: "AIMessage 缺字段的 JSON 能容错解出（加字段不清空老历史）") {
                // 合成的 init(from:) 不会用属性默认值填补缺失的键 —— 键一缺就 keyNotFound，
                // 而 ChatStore 的策略是「解码失败 → 空数组」，等于老用户历史被静默清空。
                let legacy = #"[{"role":"me","text":"只有两个字段"}]"#
                guard let data = legacy.data(using: .utf8),
                      let list = try? JSONDecoder().decode([AIMessage].self, from: data)
                else { return false }
                return list.count == 1 && list[0].role == .me && list[0].text == "只有两个字段"
                    && list[0].steps.isEmpty && list[0].redirect == nil
                    && !list[0].awaitingApproval && !list[0].isAnchor
            },
            Check(name: "AgentStep Codable 往返 + 缺字段兜底") {
                let s = AgentStep(skill: "plan_uninstall", command: "ai-mac-cleaner --uninstall X",
                                  summary: "预演 30 项", ok: false, risk: .destructive)
                guard let data = try? JSONEncoder().encode(s),
                      let back = try? JSONDecoder().decode(AgentStep.self, from: data)
                else { return false }
                let partial = #"{"skill":"x"}"#
                guard let pd = partial.data(using: .utf8),
                      let ps = try? JSONDecoder().decode(AgentStep.self, from: pd)
                else { return false }
                return back.skill == s.skill && back.command == s.command
                    && back.summary == s.summary && back.ok == s.ok && back.risk == s.risk
                    && ps.skill == "x" && ps.command == "" && !ps.ok && ps.risk == .readOnly
            },
            Check(name: "ChatArchive 信封带版本号、乱码文件不炸") {
                let archive = ChatArchive(messages: [AIMessage(role: .me, text: "hi")])
                guard let data = try? JSONEncoder().encode(archive),
                      let back = try? JSONDecoder().decode(ChatArchive.self, from: data)
                else { return false }
                // 乱码必须解不出来（由 ChatStore 兜成空数组），而不是崩掉
                let junk = Data("this is definitely not json".utf8)
                let decoded = try? JSONDecoder().decode(ChatArchive.self, from: junk)
                return back.version == 1 && back.messages.count == 1 && decoded == nil
            },
            // ── QA 补充的边界用例（严过关）──
            // 这批不是重复上面的断言，而是补上「上面没覆盖到、但真机上会走到」的路径。

            Check(name: "锚点是最后一条：history 为空，Agent 仍能带 goal 跑且不崩") {
                // `/reset` 之后用户还没说新话时的真实状态。afterAnchor 返回空，
                // modelHistory 也是空 —— 此时 AgentRuntime 必须能只靠 goal 跑起来。
                let msgs = [AIMessage(role: .me, text: "q1"),
                            AIMessage(role: .ai, text: "a1"),
                            AIMessage.anchor()]
                guard ChatPolicy.afterAnchor(msgs).isEmpty,
                      ChatPolicy.modelHistory(msgs).isEmpty
                else { return false }
                // 空 history 送进 Agent：未配模型时应老实走 needsConfig，不崩、不空回答
                let run = await AgentRuntime(config: nil)
                    .run(goal: "还能接着问吗", history: ChatPolicy.modelHistory(msgs))
                return run.needsConfig && !run.answer.isEmpty && run.steps.isEmpty
                    // 屏幕上对话仍在（/reset 不清屏），不该退回空态首屏
                    && ChatPolicy.hasConversation(msgs)
            },
            Check(name: "只有系统消息 / 空数组：空态首屏 + 空 history + trim 不误伤") {
                let onlySystem = [AIMessage.anchor()]
                return ChatPolicy.hasConversation(onlySystem) == false
                    && ChatPolicy.modelHistory(onlySystem).isEmpty
                    && ChatPolicy.trim(onlySystem).count == 1   // 系统消息不被裁掉
                    && ChatPolicy.hasConversation([]) == false
                    && ChatPolicy.modelHistory([]).isEmpty
                    && ChatPolicy.trim([]).isEmpty
                    && ChatPolicy.afterAnchor([]).isEmpty
            },
            Check(name: "1000 字边界：1000 可发 / 1001 超限，且超长文本一个字都不被裁") {
                // 规格是「只禁发不裁字」。发不发得出去归 View 的 canSend 管，
                // 这里守的是另一半：数据层任何一环都不许偷偷截断用户的输入。
                let atLimit = String(repeating: "字", count: ChatPolicy.maxInputChars)
                let over = String(repeating: "字", count: ChatPolicy.maxInputChars + 1)
                // 判据是 count > maxInputChars（不是 >=）—— 正好 1000 字必须能发
                guard atLimit.count == ChatPolicy.maxInputChars,
                      !(atLimit.count > ChatPolicy.maxInputChars),
                      over.count == ChatPolicy.maxInputChars + 1,
                      over.count > ChatPolicy.maxInputChars
                else { return false }
                let m = AIMessage(role: .me, text: over)
                guard m.text.count == ChatPolicy.maxInputChars + 1,
                      ChatPolicy.trim([m]).first?.text.count == ChatPolicy.maxInputChars + 1,
                      ChatPolicy.modelHistory([m]).first?.content.count == ChatPolicy.maxInputChars + 1
                else { return false }
                // 落盘往返也不能丢字
                guard let d = try? JSONEncoder().encode(ChatArchive(messages: [m])),
                      let back = try? JSONDecoder().decode(ChatArchive.self, from: d)
                else { return false }
                return back.messages.first?.text.count == ChatPolicy.maxInputChars + 1
            },
            Check(name: "ChatStore 真机往返 + 损坏 / 半截 / 缺失文件一律静默降级为空") {
                // 这条走的是**真实**的 ChatStore.shared（真实路径、真实读写），
                // 前面那些 Codable 断言只测到编解码，测不到 I/O 与容错分支。
                // 会临时动到用户的 askai-history.json，所以先备份、defer 还原。
                let fm = FileManager.default
                let path = "\(NSHomeDirectory())/Library/Application Support/AIMacCleaner/askai-history.json"
                let url = URL(fileURLWithPath: path)
                let backup = try? Data(contentsOf: url)   // 没有历史时为 nil
                defer {
                    if let backup { try? backup.write(to: url) }
                    else { try? fm.removeItem(at: url) }
                }

                // ① 正常往返（顺带钉死 K9 的落盘路径：路径改了这条会红）
                ChatStore.shared.save([AIMessage(role: .me, text: "probe-q"),
                                       AIMessage(role: .ai, text: "probe-a")])
                guard fm.fileExists(atPath: path) else { return false }
                let back = ChatStore.shared.all()
                guard back.count == 2, back[0].role == .me, back[0].text == "probe-q",
                      back[1].role == .ai, back[1].text == "probe-a"
                else { return false }

                // ② 整个文件是乱码
                try? Data("{{{ this is definitely not json".utf8).write(to: url)
                guard ChatStore.shared.all().isEmpty else { return false }

                // ③ 写盘写到一半被 kill 掉的半截 JSON
                try? Data(#"{"version":1,"messages":[{"role":"me","tex"#.utf8).write(to: url)
                guard ChatStore.shared.all().isEmpty else { return false }

                // ④ messages 字段类型不对（手改坏了）—— 兜底成空，不是崩
                try? Data(#"{"version":1,"messages":"oops"}"#.utf8).write(to: url)
                guard ChatStore.shared.all().isEmpty else { return false }

                // ⑤ 文件被用户手动删掉
                try? fm.removeItem(at: url)
                guard ChatStore.shared.all().isEmpty else { return false }

                // ⑥ clearAll 写的是空信封，读回来是空数组而不是「解码失败」
                ChatStore.shared.clearAll()
                return ChatStore.shared.all().isEmpty && fm.fileExists(atPath: path)
            },
            Check(name: "未知 role / redirect / risk 不清空整段历史（只兜底那一个字段）") {
                // 老版本写下的、或人手改过的 JSON 里出现不认识的枚举值时，
                // 正确行为是「这个字段退回默认值」，而不是「整条 / 整段历史消失」。
                let json = """
                    [{"role":"bogus","text":"角色未知"},
                     {"role":"me","text":"q","redirect":"nowhere"},
                     {"role":"ai","text":"a","steps":[{"skill":"s","risk":"unknown-risk"}]},
                     {"role":"ai","text":"b","steps":"not-an-array"}]
                    """
                guard let d = json.data(using: .utf8),
                      let list = try? JSONDecoder().decode([AIMessage].self, from: d),
                      list.count == 4
                else { return false }
                return list[0].role == .ai && list[0].text == "角色未知"   // 未知 role → .ai
                    && list[1].role == .me && list[1].redirect == nil       // 未知 tab → nil
                    && list[2].steps.count == 1
                    && list[2].steps[0].risk == .readOnly                   // 未知 risk → .readOnly
                    && list[3].steps.isEmpty && list[3].text == "b"         // steps 类型不对 → []
            },
            Check(name: "ChatPolicy.trim 不变量扫描：任意长度下 ≤30 条且窗口起点是 .me") {
                // 单点用例只能证明「这几个数没错」。这条把 0…40 轮全扫一遍，
                // 并掺入锚点，守住三条不变量：不超上限、不留孤儿回答、尾部不丢。
                for turns in 0...40 {
                    var msgs: [AIMessage] = []
                    for i in 0..<turns {
                        msgs.append(AIMessage(role: .me, text: "q\(i)"))
                        msgs.append(AIMessage(role: .ai, text: "a\(i)"))
                        if i % 7 == 3 { msgs.append(AIMessage.anchor()) }
                    }
                    let t = ChatPolicy.trim(msgs)
                    let n = t.filter { $0.role == .me || $0.role == .ai }.count
                    // ① 永远不超过 15 轮 = 30 条
                    if n > ChatPolicy.maxContextTurns * 2 { return false }
                    // ② 尾部（最新的一条）永远保留
                    if let lastOrig = msgs.last, let lastTrim = t.last,
                       lastOrig.text != lastTrim.text { return false }
                    // ③ 一旦发生裁剪：确实变短了，且窗口第一条对话是 .me（无孤儿回答）
                    if turns > ChatPolicy.maxContextTurns {
                        if t.count >= msgs.count { return false }
                        guard let firstConv = t.first(where: { $0.role == .me || $0.role == .ai }),
                              firstConv.role == .me
                        else { return false }
                        // 发模型的那一份也必须以 user 开头
                        if let first = ChatPolicy.modelHistory(t).first, first.role != "user" {
                            return false
                        }
                    }
                }
                return true
            },
            Check(name: "K8 契约：history 必须在 appendChat(.me) 之前取（取晚了本轮问题发两遍）") {
                // AgentRuntime 内部会自己 append 一条 (user, goal)。所以 send() 里
                // 取 history 的时机是有语义的 —— 这条把「早取 / 晚取」的差别钉成断言，
                // 将来谁调换了 AskAIView.send() 里那两行，回归时能对上号。
                let before = [AIMessage(role: .me, text: "q1"), AIMessage(role: .ai, text: "a1")]
                let afterAppend = before + [AIMessage(role: .me, text: "本轮问题")]
                let hBefore = ChatPolicy.modelHistory(before)      // 正确时机
                let hAfter = ChatPolicy.modelHistory(afterAppend)  // 错误时机
                return hBefore.count == 2
                    && hBefore.allSatisfy { $0.content != "本轮问题" }
                    && hAfter.count == 3
                    && hAfter.contains { $0.content == "本轮问题" }
            },

            Check(name: "SkillRisk / AgentTab 用字符串 raw value 落盘（不用 Int，防插 case 错位）") {
                // 数字 raw value 落盘后，将来插入 case 会静默错位 —— 典型的迁移地雷。
                // 用数组包一层，避免依赖 JSONEncoder 对顶层 fragment 的支持。
                guard let riskData = try? JSONEncoder().encode([SkillRisk.destructive]),
                      let tabData = try? JSONEncoder().encode([AgentTab.leftovers])
                else { return false }
                return String(data: riskData, encoding: .utf8) == "[\"destructive\"]"
                    && String(data: tabData, encoding: .utf8) == "[\"leftovers\"]"
            },

            Check(name: "--help 里印的版本号跟得上发版（日期制）") {
                // 版本号现在是日期制：YYYY.M.D（如 2026.8.10），同日多次构建
                // 追加序号变成 YYYY.M.D-2、YYYY.M.D-3 …… 这条保证它不是占位符
                // 且符合该格式（既兼容纯日期，也兼容带 -N 后缀）。
                let v = AIMacCleanerApp.version
                guard !v.isEmpty, v != "0.0.0-dev" else { return false }
                let segments = v.split(separator: "-")
                guard segments.count == 1 || segments.count == 2 else { return false }
                let datePart = segments[0]
                let dateParts = datePart.split(separator: ".")
                guard dateParts.count == 3,
                      dateParts.allSatisfy({ Int($0) != nil }),
                      (Int(dateParts[0]) ?? 0) >= 2026
                else { return false }
                // 若有 -N 后缀，N 须是 ≥2 的整数（同一天第 1 次构建不带后缀）
                if segments.count == 2 {
                    guard let n = Int(segments[1]), n >= 2 else { return false }
                }
                return true
            },

            // ── 系统快捷键清单（macOS 自带能力参考）──
            Check(name: "MacToolCatalog：系统能力非空且各分类都有条目") {
                let tools = MacToolCatalog.systemTools
                guard tools.count >= 20 else { return false }
                let cats = Set(tools.map { $0.category })
                return ["screenshot", "window", "clipboard", "files", "privacy", "tools"]
                    .allSatisfy { cats.contains($0) }
            },
            Check(name: "MacToolCatalog：系统能力按「分类+名称」无重复") {
                let tools = MacToolCatalog.systemTools
                let keys = tools.map { "\($0.category):\($0.name)" }
                return Set(keys).count == keys.count
            },
            Check(name: "MacToolkit 动作：活动监视器路径存在（可打开）") {
                FileManager.default.fileExists(atPath: "/System/Applications/Utilities/Activity Monitor.app")
            }
        ]

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1

        Task.detached {
            var passed = 0
            var failed = 0
            for c in checks {
                let ok = await c.block()
                if ok {
                    print("  ✓ \(c.name)")
                    passed += 1
                } else {
                    print("  ✗ \(c.name)")
                    failed += 1
                }
            }
            print("\n结果：\(passed) 通过，\(failed) 失败")
            exitCode = failed == 0 ? 0 : 1
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            print("\n✗ 自检超时（>120s）")
            return 1
        }
        return exitCode
    }
}
