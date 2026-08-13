import Foundation

/// 一次扫描的匹配条件。
///
/// 存在的理由：13 个扫描器原先各自拿用户输入的原始字符串做 `contains`，
/// 于是搜「微信」时 WeChat.app 漏掉（磁盘名是 WeChat），
/// 反而命中了 `Application Support/微信开发者工具`（目录名恰好含中文）。
///
/// 现在先把用户输入解析成「一个具体 app + 它的全部别名」，再把这些别名一起下发给扫描器。
struct ScanQuery {
    /// 用户原始输入
    let raw: String
    /// 已定位到的 app（可能为 nil：mimo/cc-connect 这类 CLI 工具没有 .app）
    let app: AppIdentity?
    /// 用于文件/目录名匹配的关键词集合（全小写）
    let keywords: [String]
    /// 其他已安装 app 的别名。命中这些的痕迹要排除掉——
    /// 否则搜 ChatGPT（bundle id com.openai.codex）会把另一个名字里带 Codex 的 app 的数据也算进来。
    let foreignKeywords: Set<String>

    /// 仅关键词模式：没找到对应 app，退回用原始输入匹配（保持 v1.0 对 CLI 工具的能力）
    init(raw: String) {
        self.raw = raw
        self.app = nil
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.keywords = k.isEmpty ? [] : [k]
        self.foreignKeywords = []
    }

    /// app 模式：用该 app 的全部别名做匹配。
    /// `others` 传入其他已安装 app，用于排除它们的痕迹。
    init(raw: String, app: AppIdentity, others: [AppIdentity] = []) {
        self.raw = raw
        self.app = app

        var set = Set<String>()
        // 文件名和 bundle id 末段是最可靠的痕迹线索：
        // WeChat.app 的残留目录通常叫 WeChat / com.tencent.xinWeChat，而不是「微信」
        set.insert(app.fileName.lowercased())
        if let bid = app.bundleId?.lowercased() { set.insert(bid) }
        if let suffix = app.bundleIdSuffix { set.insert(suffix) }
        set.insert(app.displayName.lowercased())

        // 去空格的紧凑写法：「Codex Sample App」→ codexsampleapp，
        // 用于命中 Application Support/CodexSampleAppStudio 这类无空格目录名
        for n in [app.fileName.lowercased(), app.displayName.lowercased()] {
            let compact = n.replacingOccurrences(of: " ", with: "")
            if compact != n { set.insert(compact) }
        }

        // 过滤掉过短的关键词，避免 "ai"、"cc" 之类扫出满屏无关项
        let filtered = set.filter { $0.count >= 3 }
        // 若全被过滤（如 app 名就叫 "Go"），保留原始输入兜底
        self.keywords = filtered.isEmpty
            ? [app.fileName.lowercased()]
            : filtered.sorted()

        // 收集其他 app 的可辨识名字。只取「比本 app 关键词更长」的，
        // 这样那个第三方 app 的目录会被排除，但不会把 codex 本身排掉。
        var foreign = Set<String>()
        for other in others where other.bundlePath != app.bundlePath {
            for candidate in [other.fileName.lowercased(),
                              other.displayName.lowercased(),
                              other.bundleId?.lowercased()].compactMap({ $0 }) {
                guard candidate.count >= 3 else { continue }
                // 只有当这个名字不是本 app 的关键词时才算「外来」
                if !self.keywords.contains(candidate) {
                    foreign.insert(candidate)
                    // 去掉空格的紧凑写法：Codex Sample App → codexsampleapp，
                    // 用于匹配 CodexSampleAppStudio 这类目录名
                    let compact = candidate.replacingOccurrences(of: " ", with: "")
                    if compact.count >= 3 && !self.keywords.contains(compact) {
                        foreign.insert(compact)
                    }
                }
            }
        }
        self.foreignKeywords = foreign
    }

    /// 给定的名字是否命中本次查询。
    func matches(_ name: String) -> Bool {
        let lower = name.lowercased()

        // 护栏：系统 / 共享框架自有数据（com.apple.*、group.com.apple.*、
        // io.flutter、org.chromium 等）。这些绝不属任何第三方 app，
        // 卸载时误删会伤系统或让别的 app 瘫痪。直接排除，不进关键词匹配。
        // 只比对 bundle id 风格前缀，不连带 SystemOwned 的「文件扩展名噪声」规则，
        // 否则会把 QoderWork.log 这类第三方 app 自己的正常文件也误伤。
        if SystemOwned.prefixes.contains(where: { lower == $0 || lower.hasPrefix("\($0).") }) {
            return false
        }

        // 关键词命中要求落在「词边界」上，避免 "work" 误命中
        // "network" / "workflow" 这类子串（QoderWork 卸载曾把一堆
        // com.apple.* 系统 plist 当成自己的痕迹扫出来）。
        // 边界判定用原始大小写 name（驼峰拐点 'S' 在低大小写串里会消失），
        // 子串搜索仍用 lower（低大小写是索引保持的，两者下标可对应）。
        guard keywords.contains(where: { Self.boundaryMatch(name, lower, keyword: $0) }) else { return false }
        // 命中了别的已安装 app 的名字 → 这痕迹属于那个 app，不是本次目标
        if isForeign(lower) { return false }
        return true
    }

    /// 关键词是否命中名字：含分隔符的多段关键词（如完整 bundle id
    /// `com.qoder.work`）直接子串即可，它已足够具体；否则要求关键词在名字里
    /// 落在词边界上（字符串首尾 / `. - _/` 分隔符 / 大小写驼峰切换 / CJK 字符）。
    /// `name` 用原始大小写（驼峰拐点依赖它），`lower` 是 `name` 的低大小写副本，
    /// 两者下标一一对应。
    private static func boundaryMatch(_ name: String, _ lower: String, keyword: String) -> Bool {
        if keyword.contains(".") { return lower.contains(keyword) }
        guard let range = lower.range(of: keyword) else { return false }
        let beforeOK = range.lowerBound == lower.startIndex
            || isBoundary(name, at: lower.index(before: range.lowerBound))
        let afterOK = range.upperBound == lower.endIndex
            || isBoundary(name, at: range.upperBound)
        return beforeOK && afterOK
    }

    /// 该位置是否构成「词边界」：分隔符、CJK 字符、或 ASCII 大写（驼峰拐点）。
    private static func isBoundary(_ s: String, at i: String.Index) -> Bool {
        let ch = s[i]
        if ". -_/".contains(ch) { return true }
        if isCJK(ch) { return true }
        return ch.isASCII && ch.isUppercase
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x3000...0x303F).contains(v)   // CJK 符号与标点
            || (0x3400...0x4DBF).contains(v)   // 扩展 A
            || (0x4E00...0x9FFF).contains(v)   // 基本汉字
            || (0xF900...0xFAFF).contains(v)   // 兼容汉字
            || (0xFF00...0xFFEF).contains(v)   // 全角字符
    }

    /// 这个名字看起来属于另一个已安装的 app 吗？
    private func isForeign(_ lower: String) -> Bool {
        for foreign in foreignKeywords where lower.contains(foreign) {
            // 只有当外来名字比本 app 的所有命中关键词都长时才判定为外来，
            // 避免「更长的名字」反过来把正主排掉
            let myBestHit = keywords.filter { lower.contains($0) }.map(\.count).max() ?? 0
            if foreign.count > myBestHit { return true }
        }
        return false
    }

    /// 用于展示的目标名
    var displayTarget: String {
        app?.displayName ?? raw
    }

    var isEmpty: Bool { keywords.isEmpty }
}
