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
        case .aiTool:   return L10n.t("AI 工具", "AI tools")
        case .devCache: return L10n.t("缓存与模型", "Caches & models")
        }
    }

    var explanation: String {
        switch self {
        case .orphan:
            return L10n.t("主 app 已卸载，但痕迹仍留在硬盘上。",
                          "The owning app is gone, but traces remain on disk.")
        case .aiTool:
            return L10n.t("已知 AI 编程工具留下的隐藏配置/数据。",
                          "Hidden config or data left by a known AI coding tool.")
        case .devCache:
            return L10n.t("AI 模型运行时、编辑器与开发/包管理器的缓存与模型文件。",
                          "Caches and model files from AI runtimes, editors, and dev / package managers.")
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
