import Foundation

/// 残留数据的来源：启发式反查出的无主残留，或已知 AI 工具清单命中。
enum LeftoverSource: String, CaseIterable, Identifiable, Hashable {
    case orphan = "orphan"
    case aiTool = "aiTool"
    case devCache = "devCache"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .orphan:   return L10n.t("无主残留", "Orphaned")
        case .aiTool:   return L10n.t("AI 编程工具", "AI coding tools")
        case .devCache: return L10n.t("开发工具缓存", "Dev-tool caches")
        }
    }

    var explanation: String {
        switch self {
        case .orphan:
            return L10n.t("主 app 已卸载，但痕迹仍留在硬盘上。",
                          "The owning app is gone, but traces remain on disk.")
        case .aiTool:
            return L10n.t("已知 AI 编程工具（如 Claude、Cursor）留下的隐藏配置与缓存。",
                          "Hidden config and caches left by known AI coding tools (e.g. Claude, Cursor).")
        case .devCache:
            return L10n.t("编辑器、语言运行时、包管理器、构建工具与浏览器的缓存与模型文件（非 AI 编程工具）。",
                          "Caches and model files from editors, language runtimes, package managers, build tools and browsers — not AI coding tools.")
        }
    }
}

/// 一组归属于同一个「来源」的残留痕迹。
/// 统一了过去的 OrphanGroup 与 AIAgentGroup，让「残留」页用单一数据源展示。
struct LeftoverGroup: Identifiable {
    let id = UUID()
    /// 推断出的归属者：无主残留是 bundle id / 目录名；AI 工具是工具展示名。
    let owner: String
    let source: LeftoverSource
    var artifacts: [Artifact]

    var totalSize: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { artifacts.filter(\.selected).count }
    var selectedSize: Int64 { artifacts.filter(\.selected).reduce(0) { $0 + $1.size } }
}
